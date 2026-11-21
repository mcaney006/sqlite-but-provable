module IdrisQL.Storage.Pager

import Data.IORef
import Data.List
import Data.So
import System
import IdrisQL.Error
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Codec
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page
import IdrisQL.Storage.Recovery
import IdrisQL.Storage.WAL

-- A database is a directory:
--
--   LOCK/          exists while a process has the database open
--   wal            write-ahead log
--   p/<n>/<id>.pg  one file per page, 256 pages per subdirectory
--   spill/         uncommitted pages evicted from the buffer pool
--
-- The pager owns page allocation, the page-level transaction (begin, commit,
-- rollback), checkpoints, and recovery at open.

public export
record Options where
  constructor MkOptions
  ||| Buffer pool capacity in pages.
  cachePages : Int
  ||| A commit that leaves the log at least this large triggers a checkpoint.
  checkpointBytes : Int
  ||| Take over a lock left behind by a dead process. The caller asserts
  ||| that no other process has the database open.
  breakLock : Bool

public export
defaultOptions : Options
defaultOptions = MkOptions 256 4194304 False

export
record Pager where
  constructor MkPager
  st : Storage
  dir : String
  pool : Pool
  wal : Wal
  opts : Options
  txnOpen : IORef Bool
  txnId : IORef Int
  ||| Set when a log or page-file write failed. The on-disk state is then
  ||| only trustworthy after recovery, so the pager refuses further work.
  poisoned : IORef Bool
  recovery : RecoveryInfo
  commitCount : IORef Int
  checkpointCount : IORef Int

export
pagerPool : Pager -> Pool
pagerPool pg = pg.pool

export
pagerStorage : Pager -> Storage
pagerStorage pg = pg.st

export
pagerDir : Pager -> String
pagerDir pg = pg.dir

export
pagerRecovery : Pager -> RecoveryInfo
pagerRecovery pg = pg.recovery

lockPath : String -> String
lockPath dir = dir ++ "/LOCK"

acquireLock : String -> Options -> DB ()
acquireLock dir opts = do
  created <- makeDir (lockPath dir)
  when' (not created && not opts.breakLock)
    (Locked (dir ++ " is open in another process, or a process died while it had it open. "
             ++ "If nothing else is using it, remove the directory " ++ lockPath dir ++ "."))

-- Meta page access.

export
metaU32 : Pager -> (off : Int) -> {auto 0 ok : InPage off 4} -> DB Int
metaU32 pg off = withPage pg.pool 0 (\p => liftIO (getU32 p off))

export
metaBits64 : Pager -> (off : Int) -> {auto 0 ok : InPage off 8} -> DB Bits64
metaBits64 pg off = withPage pg.pool 0 (\p => liftIO (getBits64 p off))

export
inTxn : Pager -> IO Bool
inTxn pg = readIORef pg.txnOpen

requireTxn : Pager -> DB ()
requireTxn pg = do
  active <- readIORef pg.txnOpen
  when' (not active) (TxError "a page was modified outside a transaction")

export
setMetaU32 : Pager -> (off : Int) -> {auto 0 ok : InPage off 4} -> Int -> DB ()
setMetaU32 pg off v = do
  requireTxn pg
  withPageMut pg.pool 0 (\p => liftIO (setU32 p off v))

export
setMetaBits64 : Pager -> (off : Int) -> {auto 0 ok : InPage off 8} -> Bits64 -> DB ()
setMetaBits64 pg off v = do
  requireTxn pg
  withPageMut pg.pool 0 (\p => liftIO (setBits64 p off v))

writeMagic : Page -> IO ()
writeMagic p = do
  setU8 p 24 73
  setU8 p 25 68
  setU8 p 26 82
  setU8 p 27 73
  setU8 p 28 83
  setU8 p 29 81
  setU8 p 30 76
  setU8 p 31 0

magicOk : Page -> IO Bool
magicOk p = do
  bs <- sequence [getU8 p 24, getU8 p 25, getU8 p 26, getU8 p 27,
                  getU8 p 28, getU8 p 29, getU8 p 30, getU8 p 31]
  pure (bs == magicBytes)

-- Validate the header page and return (database id, last transaction, next LSN).
readMeta : Pool -> DB (Bits64, Int, Int)
readMeta pool = withPage pool 0 $ \p => do
  t <- liftIO (pageType p)
  ok <- liftIO (magicOk p)
  when' (t /= ptMeta || not ok) (Corrupt "page 0 is not an IdrisQL database header")
  version <- liftIO (getU32 p offVersion)
  when' (version > FormatVersion)
    (Unsupported ("database format version " ++ show version
                  ++ " is newer than this build (version " ++ show FormatVersion ++ ")"))
  when' (version < 1) (Corrupt "database format version 0")
  psize <- liftIO (getU32 p offPageSize)
  when' (psize /= PageSize)
    (Unsupported ("page size " ++ show psize ++ "; this build uses " ++ show PageSize))
  dbId <- liftIO (getBits64 p offDbId)
  lastTxn <- liftIO (getBits64 p offLastTxn)
  nextLsn <- liftIO (getBits64 p offNextLsn)
  pure (dbId, cast lastTxn, cast nextLsn)

-- Run a storage-mutating step; if it fails the pager stops accepting work.
guarded : Pager -> DB a -> DB a
guarded pg act = catchDB act (\e => writeIORef pg.poisoned True >> throw e)

||| Write every committed page to its page file, then truncate the log.
||| A crash before the truncation leaves the log intact, and recovery
||| redoes the same images.
export
checkpoint : Pager -> DB ()
checkpoint pg = guarded pg $ do
  _ <- flushCommitted pg.pool
  salt <- liftIO (walSalt pg.wal)
  resetWal pg.wal (salt + 1)
  modifyIORef pg.checkpointCount (+ 1)

export
beginTxn : Pager -> DB ()
beginTxn pg = do
  bad <- readIORef pg.poisoned
  when' bad (IOFailure "an earlier storage failure left this connection unusable; reopen the database")
  active <- readIORef pg.txnOpen
  when' active (TxError "a transaction is already open")
  modifyIORef pg.txnId (+ 1)
  writeIORef pg.txnOpen True

||| Commit protocol:
|||   1. append the image of every page in the write set to the log,
|||   2. append the commit record and flush the log,
|||   3. only then allow those pages to reach page files.
||| Step 2 is the commit point.
export
commitTxn : Pager -> DB ()
commitTxn pg = do
  active <- readIORef pg.txnOpen
  when' (not active) (TxError "no transaction is open")
  changed <- liftIO (txnPageIds pg.pool)
  if isNil changed
    then writeIORef pg.txnOpen False
    else do
      tx <- readIORef pg.txnId
      setMetaBits64 pg offLastTxn (cast tx)
      ids <- liftIO (txnPageIds pg.pool)
      lsn <- liftIO (walNextLsn pg.wal)
      setMetaBits64 pg offNextLsn (cast (lsn + cast (length ids) + 1))
      guarded pg $ do
        for_ ids $ \pageId => do
          f <- pin pg.pool pageId
          finally (appendPage pg.wal tx pageId (framePage f)) (liftIO (unpin f))
        _ <- appendCommit pg.wal tx
        commitFrames pg.pool
      writeIORef pg.txnOpen False
      modifyIORef pg.commitCount (+ 1)
      size <- liftIO (walSize pg.wal)
      when (size >= pg.opts.checkpointBytes) (checkpoint pg)

export
rollbackTxn : Pager -> DB ()
rollbackTxn pg = do
  active <- readIORef pg.txnOpen
  when' (not active) (TxError "no transaction is open")
  writeIORef pg.txnOpen False
  bad <- readIORef pg.poisoned
  -- After a storage failure the spill files cannot be trusted to delete;
  -- recovery at the next open clears them.
  if bad then catchDB (rollbackFrames pg.pool) (\_ => pure ())
         else rollbackFrames pg.pool

-- Page allocation. Free pages form a singly linked list through their right
-- pointers, headed in the meta page.

||| Allocate a page of the given type with an empty slot directory.
export
allocPage : Pager -> (ptype : Int) -> DB Int
allocPage pg ptype = do
  requireTxn pg
  hd <- metaU32 pg offFreeHead
  if hd /= 0
    then do
      next <- withPageMut pg.pool hd $ \p => do
        t <- liftIO (pageType p)
        when' (t /= ptFree) (Corrupt ("free list reaches page " ++ show hd ++ " of type " ++ show t))
        next <- liftIO (rightPointer p)
        liftIO (initPage p ptype)
        pure next
      setMetaU32 pg offFreeHead next
      count <- metaU32 pg offFreeCount
      setMetaU32 pg offFreeCount (count - 1)
      pure hd
    else do
      n <- metaU32 pg offPageCount
      setMetaU32 pg offPageCount (n + 1)
      f <- pinNew pg.pool n
      liftIO $ do
        initPage (framePage f) ptype
        unpin f
      pure n

export
freePage : Pager -> (pageId : Int) -> DB ()
freePage pg pageId = do
  requireTxn pg
  when' (pageId <= 1) (Corrupt ("attempt to free reserved page " ++ show pageId))
  hd <- metaU32 pg offFreeHead
  withPageMut pg.pool pageId $ \p => liftIO $ do
    initPage p ptFree
    setRightPointer p hd
  setMetaU32 pg offFreeHead pageId
  count <- metaU32 pg offFreeCount
  setMetaU32 pg offFreeCount (count + 1)

||| The ids on the free list, in list order. Fails on a cycle or on a page
||| that is not marked free.
export
freeListPages : Pager -> DB (List Int)
freeListPages pg = do
  hd <- metaU32 pg offFreeHead
  count <- metaU32 pg offFreeCount
  walk hd count []
  where
    walk : Int -> Int -> List Int -> DB (List Int)
    walk 0 remaining acc = do
      when' (remaining /= 0) (Corrupt ("free list is " ++ show remaining ++ " pages shorter than its count"))
      pure (reverse acc)
    walk pageId remaining acc = do
      when' (remaining <= 0) (Corrupt "free list is longer than its count, or cyclic")
      next <- withPage pg.pool pageId $ \p => do
        t <- liftIO (pageType p)
        when' (t /= ptFree) (Corrupt ("page " ++ show pageId ++ " is on the free list with type " ++ show t))
        liftIO (rightPointer p)
      walk next (remaining - 1) (pageId :: acc)

-- Opening and closing.

export
createDatabase : Storage -> (dir : String) -> Options -> DB Pager
createDatabase st dir opts = do
  _ <- makeDir dir
  present <- liftIO (pathExists (storePath dir 0))
  when' present (IOFailure (dir ++ " already holds a database"))
  acquireLock dir opts
  catchDB build (\e => liftIO (removeDirectory (lockPath dir)) >> throw e)
  where
    build : DB Pager
    build = do
      _ <- makeDir (dir ++ "/p")
      _ <- makeDir (dir ++ "/spill")
      little <- hostLittleEndian
      now <- liftIO time
      pid <- liftIO getPID
      let dbId : Bits64 = cast (now * 1000003 + cast pid)
      pool <- newPool st dir little opts.cachePages
      wal <- newWal st (dir ++ "/wal") little dbId 1
      resetWal wal 1
      pg <- pure (MkPager st dir pool wal opts !(newIORef False) !(newIORef 0)
                    !(newIORef False) noRecovery !(newIORef 0) !(newIORef 0))
      beginTxn pg
      f0 <- pinNew pool 0
      liftIO $ do
        let p = framePage f0
        initPage p ptMeta
        writeMagic p
        setU32 p offVersion FormatVersion
        setU32 p offPageSize PageSize
        setBits64 p offDbId dbId
        setU32 p offPageCount 2
        setU32 p offCatalogRoot 1
        setU32 p offNextObjectId 1
        unpin f0
      f1 <- pinNew pool 1
      liftIO $ do
        initPage (framePage f1) ptLeaf
        unpin f1
      commitTxn pg
      checkpoint pg
      pure pg

export
openDatabase : Storage -> (dir : String) -> Options -> DB Pager
openDatabase st dir opts = do
  present <- liftIO (pathExists (storePath dir 0))
  when' (not present) (IOFailure ("no IdrisQL database at " ++ dir))
  acquireLock dir opts
  catchDB load (\e => liftIO (removeDirectory (lockPath dir)) >> throw e)
  where
    load : DB Pager
    load = do
      little <- hostLittleEndian
      _ <- makeDir (dir ++ "/spill")
      leftovers <- listDirectory (dir ++ "/spill")
      for_ (filter (\n => n /= "." && n /= "..") leftovers) $ \n =>
        removePath st (dir ++ "/spill/" ++ n)
      pool <- newPool st dir little opts.cachePages
      (info, scan) <- recover pool (dir ++ "/wal") little
      (dbId, lastTxn, nextLsn) <- readMeta pool
      when' (scan.present && scan.dbId /= dbId)
        (Corrupt "the write-ahead log belongs to a different database")
      wal <- newWal st (dir ++ "/wal") little dbId (max nextLsn (scan.maxLsn + 1))
      resetWal wal (scan.salt + 1)
      pure (MkPager st dir pool wal opts !(newIORef False) !(newIORef (max lastTxn scan.maxTxn))
              !(newIORef False) info !(newIORef 0) !(newIORef 0))

||| Roll back any open transaction, checkpoint, and release the lock.
export
closeDatabase : Pager -> DB ()
closeDatabase pg = do
  let release = liftIO $ do
        closeWal pg.wal
        removeDirectory (lockPath pg.dir)
  flip finally release $ do
    active <- readIORef pg.txnOpen
    when active (rollbackTxn pg)
    bad <- readIORef pg.poisoned
    when (not bad) (checkpoint pg)

||| Drop the connection the way a dying process would: no rollback, no
||| checkpoint. Only the lock is released, so that a test can reopen the
||| directory and exercise recovery.
export
abandonDatabase : Pager -> IO ()
abandonDatabase pg = do
  closeWal pg.wal
  removeDirectory (lockPath pg.dir)

public export
record PagerStats where
  constructor MkPagerStats
  pageCount : Int
  freePages : Int
  commits : Int
  checkpoints : Int
  walBytes : Int
  pool : PoolStats
  storage : StorageStats

export
pagerStats : Pager -> DB PagerStats
pagerStats pg = do
  pageCount <- metaU32 pg offPageCount
  freePages <- metaU32 pg offFreeCount
  pure (MkPagerStats pageCount freePages
          !(readIORef pg.commitCount) !(readIORef pg.checkpointCount)
          !(liftIO (walSize pg.wal)) !(liftIO (poolStats pg.pool))
          !(liftIO (storageStats pg.st)))
