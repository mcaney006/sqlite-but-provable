module IdrisQL.Storage.BufferPool

import Data.IOArray
import Data.IORef
import Data.List
import Data.SortedMap
import Data.SortedSet
import IdrisQL.Error
import IdrisQL.Storage.Codec
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page

-- A fixed number of page frames with clock eviction. A frame is in one of
-- three states:
--
--   Clean           identical to the page file
--   DirtyCommitted  changed by a committed transaction; its image is in the
--                   log, so it may be written to its page file at any time
--   DirtyTxn        changed by the open transaction; it must never reach a
--                   page file. If it has to be evicted it goes to a spill
--                   file, which is discarded on rollback.
--
-- That rule is what makes recovery redo-only: page files never contain
-- uncommitted data.
--
-- When the open transaction changes a DirtyCommitted frame, the committed
-- image exists nowhere else that can be read back (the log is append-only
-- and unseekable), so a copy is kept as a shadow. Rollback restores it;
-- commit drops it; eviction of the frame writes it to the page file.

public export
data FrameState = Clean | DirtyCommitted | DirtyTxn

export
record Frame where
  constructor MkFrame
  page : Page
  idRef : IORef Int
  pinRef : IORef Int
  stateRef : IORef FrameState
  refBit : IORef Bool

export
framePage : Frame -> Page
framePage f = f.page

public export
record PoolStats where
  constructor MkPoolStats
  capacity : Int
  cached : Int
  hits : Int
  misses : Int
  evictions : Int
  spills : Int

export
record Pool where
  constructor MkPool
  st : Storage
  dir : String
  hostLittle : Bool
  capacity : Int
  frames : IOArray Frame
  usedRef : IORef Int
  table : IORef (SortedMap Int Int)
  hand : IORef Int
  ||| Pages changed by the open transaction, cached or spilled.
  txnPages : IORef (SortedSet Int)
  ||| The subset of `txnPages` whose newest image is in a spill file.
  spilled : IORef (SortedSet Int)
  fanoutDirs : IORef (SortedSet Int)
  ||| Committed images of pages the open transaction has since changed.
  shadows : IORef (SortedMap Int Page)
  hitsRef : IORef Int
  missRef : IORef Int
  evictRef : IORef Int
  spillRef : IORef Int

export
newPool : Storage -> (dir : String) -> (hostLittle : Bool) -> (capacity : Int) -> DB Pool
newPool st dir hostLittle capacity = do
  let cap = max 8 capacity
  frames <- newArray cap
  pure (MkPool st dir hostLittle cap frames
          !(newIORef 0) !(newIORef empty) !(newIORef 0)
          !(newIORef empty) !(newIORef empty) !(newIORef empty) !(newIORef empty)
          !(newIORef 0) !(newIORef 0) !(newIORef 0) !(newIORef 0))

export
storePath : (dir : String) -> (pageId : Int) -> String
storePath dir pageId = dir ++ "/p/" ++ show (pageId `div` 256) ++ "/" ++ show pageId ++ ".pg"

spillPath : (dir : String) -> (pageId : Int) -> String
spillPath dir pageId = dir ++ "/spill/" ++ show pageId ++ ".pg"

||| Seal a page and write it to its page file.
export
writeStorePage : Pool -> (pageId : Int) -> Page -> DB ()
writeStorePage pool pageId p = do
  let fan = pageId `div` 256
  known <- readIORef pool.fanoutDirs
  when (not (contains fan known)) $ do
    _ <- makeDir (pool.dir ++ "/p/" ++ show fan)
    modifyIORef pool.fanoutDirs (insert fan)
  liftIO (sealPage pool.hostLittle p)
  writeFileFrom pool.st (storePath pool.dir pageId) (rawBuffer p) PageSize

||| Read a page file into `p` without going through the pool.
export
readStorePage : Pool -> (pageId : Int) -> Page -> DB ()

loadFile : Pool -> (what : String) -> (path : String) -> Page -> DB ()
loadFile pool what path p = do
  Just n <- readFileInto pool.st path (rawBuffer p) PageSize
    | Nothing => throw (Corrupt (what ++ " is missing"))
  when' (n /= PageSize) (Corrupt (what ++ " holds " ++ show n ++ " bytes"))
  ok <- liftIO (verifyPage pool.hostLittle p)
  when' (not ok) (Corrupt (what ++ " fails its checksum"))

readStorePage pool pageId p = loadFile pool ("page " ++ show pageId) (storePath pool.dir pageId) p

frameAt : Pool -> Int -> DB Frame
frameAt pool i = do
  Just f <- readArray pool.frames i
    | Nothing => throw (RuntimeError ("buffer pool frame " ++ show i ++ " is unset"))
  pure f

evict : Pool -> Frame -> DB ()
evict pool f = do
  pageId <- readIORef f.idRef
  when (pageId >= 0) $ do
    s <- readIORef f.stateRef
    case s of
      Clean => pure ()
      DirtyCommitted => writeStorePage pool pageId f.page
      DirtyTxn => do
        sh <- readIORef pool.shadows
        case lookup pageId sh of
          Nothing => pure ()
          Just committed => do
            writeStorePage pool pageId committed
            modifyIORef pool.shadows (delete pageId)
        liftIO (sealPage pool.hostLittle f.page)
        writeFileFrom pool.st (spillPath pool.dir pageId) (rawBuffer f.page) PageSize
        modifyIORef pool.spilled (insert pageId)
        modifyIORef pool.spillRef (+ 1)
    modifyIORef pool.table (delete pageId)
    writeIORef f.idRef (-1)
    writeIORef f.stateRef Clean
    modifyIORef pool.evictRef (+ 1)

-- Clock sweep: skip pinned frames, give recently used frames a second pass.
findVictim : Pool -> (tries : Int) -> DB Int
findVictim pool tries =
  if tries <= 0
    then throw (RuntimeError "buffer pool exhausted: every cached page is pinned")
    else do
      i <- readIORef pool.hand
      writeIORef pool.hand ((i + 1) `mod` pool.capacity)
      f <- frameAt pool i
      pins <- readIORef f.pinRef
      recent <- readIORef f.refBit
      if pins > 0 then findVictim pool (tries - 1)
        else if recent then writeIORef f.refBit False >> findVictim pool (tries - 1)
        else pure i

-- A frame that holds no page, and its index.
acquire : Pool -> DB (Int, Frame)
acquire pool = do
  used <- readIORef pool.usedRef
  if used < pool.capacity
    then do
      p <- newPage
      f <- pure (MkFrame p !(newIORef (-1)) !(newIORef 0) !(newIORef Clean) !(newIORef False))
      _ <- writeArray pool.frames used f
      writeIORef pool.usedRef (used + 1)
      pure (used, f)
    else do
      i <- findVictim pool (2 * pool.capacity + 1)
      f <- frameAt pool i
      evict pool f
      pure (i, f)

install : Pool -> (pageId : Int) -> (Int, Frame) -> FrameState -> IO ()
install pool pageId (i, f) s = do
  writeIORef f.idRef pageId
  writeIORef f.pinRef 1
  writeIORef f.stateRef s
  writeIORef f.refBit True
  modifyIORef pool.table (insert pageId i)

||| Fetch a page and pin it. A pinned frame is never evicted.
export
pin : Pool -> (pageId : Int) -> DB Frame
pin pool pageId = do
  t <- readIORef pool.table
  case lookup pageId t of
    Just i => do
      f <- frameAt pool i
      modifyIORef f.pinRef (+ 1)
      writeIORef f.refBit True
      modifyIORef pool.hitsRef (+ 1)
      pure f
    Nothing => do
      modifyIORef pool.missRef (+ 1)
      slot <- acquire pool
      sp <- readIORef pool.spilled
      let what = "page " ++ show pageId
      if contains pageId sp
        then do loadFile pool ("spilled " ++ what) (spillPath pool.dir pageId) (snd slot).page
                liftIO (install pool pageId slot DirtyTxn)
        else do loadFile pool what (storePath pool.dir pageId) (snd slot).page
                liftIO (install pool pageId slot Clean)
      pure (snd slot)

||| Pin a frame for a page that does not exist yet. Its contents are zero.
export
pinNew : Pool -> (pageId : Int) -> DB Frame
pinNew pool pageId = do
  slot <- acquire pool
  liftIO $ do
    initPage (snd slot).page 0
    install pool pageId slot DirtyTxn
  modifyIORef pool.txnPages (insert pageId)
  pure (snd slot)

export
unpin : Frame -> IO ()
unpin f = modifyIORef f.pinRef (\n => n - 1)

||| Record that the open transaction is about to change this page.
export
markDirty : Pool -> Frame -> DB ()
markDirty pool f = do
  pageId <- readIORef f.idRef
  s <- readIORef f.stateRef
  case s of
    DirtyCommitted => do
      committed <- newPage
      liftIO (copyPage f.page committed)
      modifyIORef pool.shadows (insert pageId committed)
    _ => pure ()
  writeIORef f.stateRef DirtyTxn
  modifyIORef pool.txnPages (insert pageId)

||| Run `k` on a pinned page and unpin it afterwards, also on failure. `k`
||| must not keep the `Page` after it returns.
export
withPage : Pool -> (pageId : Int) -> (Page -> DB a) -> DB a
withPage pool pageId k = do
  f <- pin pool pageId
  finally (k f.page) (liftIO (unpin f))

||| Like `withPage`, for a page the open transaction is about to change.
export
withPageMut : Pool -> (pageId : Int) -> (Page -> DB a) -> DB a
withPageMut pool pageId k = do
  f <- pin pool pageId
  finally (markDirty pool f >> k f.page) (liftIO (unpin f))

forFrames : Pool -> (Frame -> DB ()) -> DB ()
forFrames pool k = do
  used <- readIORef pool.usedRef
  go used 0
  where
    go : Int -> Int -> DB ()
    go used i = if i >= used then pure () else do
      f <- frameAt pool i
      k f
      go used (i + 1)

||| The write set of the open transaction, ascending.
export
txnPageIds : Pool -> IO (List Int)
txnPageIds pool = map Prelude.toList (readIORef pool.txnPages)

-- Forget the spilled pages, then delete their files. A file that cannot be
-- deleted is no longer referenced, and the next open empties the directory.
dropSpillFiles : Pool -> DB ()
dropSpillFiles pool = do
  sp <- readIORef pool.spilled
  writeIORef pool.spilled empty
  for_ (Prelude.toList sp) $ \pageId =>
    catchDB (removePath pool.st (spillPath pool.dir pageId)) (\_ => pure ())

||| Called after the commit record is flushed. Frames of the transaction
||| become eligible for page files; spilled pages move to page files now.
export
commitFrames : Pool -> DB ()
commitFrames pool = do
  forFrames pool $ \f => do
    DirtyTxn <- readIORef f.stateRef | _ => pure ()
    writeIORef f.stateRef DirtyCommitted
  sp <- readIORef pool.spilled
  tmp <- newPage
  for_ (Prelude.toList sp) $ \pageId => do
    t <- readIORef pool.table
    case lookup pageId t of
      Just _ => pure ()
      Nothing => do
        loadFile pool ("spilled page " ++ show pageId) (spillPath pool.dir pageId) tmp
        writeStorePage pool pageId tmp
  dropSpillFiles pool
  writeIORef pool.txnPages empty
  writeIORef pool.shadows empty

||| Discard everything the open transaction changed.
export
rollbackFrames : Pool -> DB ()
rollbackFrames pool = do
  forFrames pool $ \f => do
    DirtyTxn <- readIORef f.stateRef | _ => pure ()
    pins <- readIORef f.pinRef
    when' (pins > 0) (TxError "rollback while a page of the transaction is pinned")
    pageId <- readIORef f.idRef
    sh <- readIORef pool.shadows
    case lookup pageId sh of
      Just committed => do
        liftIO (copyPage committed f.page)
        writeIORef f.stateRef DirtyCommitted
      Nothing => do
        modifyIORef pool.table (delete pageId)
        writeIORef f.idRef (-1)
        writeIORef f.stateRef Clean
        writeIORef f.refBit False
  dropSpillFiles pool
  writeIORef pool.txnPages empty
  writeIORef pool.shadows empty

||| Write every committed dirty frame to its page file. Returns how many.
export
flushCommitted : Pool -> DB Int
flushCommitted pool = do
  count <- newIORef 0
  forFrames pool $ \f => do
    DirtyCommitted <- readIORef f.stateRef | _ => pure ()
    pageId <- readIORef f.idRef
    writeStorePage pool pageId f.page
    writeIORef f.stateRef Clean
    modifyIORef count (+ 1)
  readIORef count

export
poolStats : Pool -> IO PoolStats
poolStats pool = do
  t <- readIORef pool.table
  pure (MkPoolStats pool.capacity (cast (length (SortedMap.toList t)))
          !(readIORef pool.hitsRef) !(readIORef pool.missRef)
          !(readIORef pool.evictRef) !(readIORef pool.spillRef))

||| Number of frames currently pinned. Zero between statements.
export
pinnedFrames : Pool -> DB Int
pinnedFrames pool = do
  count <- newIORef 0
  forFrames pool $ \f => do
    pins <- readIORef f.pinRef
    when (pins > 0) (modifyIORef count (+ 1))
  readIORef count
