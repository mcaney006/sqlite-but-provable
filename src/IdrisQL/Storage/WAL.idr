module IdrisQL.Storage.WAL

import Data.Bits
import Data.Buffer
import Data.IORef
import System.File
import IdrisQL.Error
import IdrisQL.Storage.Codec
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page

-- Write-ahead log: a 32-byte header followed by records.
--
--   header: 8 magic "IDQLWAL\0", u32 format version, u32 page size,
--           u64 database id, u64 salt
--   record: u32 type (1 page image, 2 commit), u32 page id, u64 LSN,
--           u64 transaction id, u32 payload length (4096 or 0),
--           payload, u32 checksum
--
-- The checksum covers the 28 header bytes and the payload and is seeded with
-- the salt, which changes at every checkpoint. A page record holds the full
-- image of a page as of the commit that logged it (physical redo logging).

WalHeaderSize : Int
WalHeaderSize = 32

RecHeaderSize : Int
RecHeaderSize = 28

recPage : Int
recPage = 1

recCommit : Int
recCommit = 2

walMagic : List Int
walMagic = [73, 68, 81, 76, 87, 65, 76, 0]

export
record Wal where
  constructor MkWal
  st : Storage
  path : String
  hostLittle : Bool
  dbId : Bits64
  logRef : IORef (Maybe LogFile)
  saltRef : IORef Int
  sizeRef : IORef Int
  lsnRef : IORef Int
  hdr : Buffer

export
newWal : Storage -> (path : String) -> (hostLittle : Bool) -> (dbId : Bits64) -> (nextLsn : Int) -> DB Wal
newWal st path hostLittle dbId nextLsn = do
  logRef <- newIORef Nothing
  saltRef <- newIORef 0
  sizeRef <- newIORef 0
  lsnRef <- newIORef nextLsn
  hdr <- alloc WalHeaderSize
  pure (MkWal st path hostLittle dbId logRef saltRef sizeRef lsnRef hdr)

export
walSize : Wal -> IO Int
walSize w = readIORef w.sizeRef

||| The LSN the next record will carry.
export
walNextLsn : Wal -> IO Int
walNextLsn w = readIORef w.lsnRef

export
walSalt : Wal -> IO Int
walSalt w = readIORef w.saltRef

export
closeWal : Wal -> IO ()
closeWal w = do
  Just lg <- readIORef w.logRef | Nothing => pure ()
  closeLog lg
  writeIORef w.logRef Nothing

putBytesAt : Buffer -> Int -> List Int -> IO ()
putBytesAt _ _ [] = pure ()
putBytesAt b o (x :: xs) = wrU8 b o x >> putBytesAt b (o + 1) xs

||| Truncate the log and start a new generation with the given salt. Called
||| only when every committed page is in its page file.
export
resetWal : Wal -> (salt : Int) -> DB ()
resetWal w salt = do
  liftIO (closeWal w)
  lg <- createLog w.st w.path
  liftIO $ do
    putBytesAt w.hdr 0 walMagic
    wrU32 w.hdr 8 FormatVersion
    wrU32 w.hdr 12 PageSize
    wrBits64 w.hdr 16 w.dbId
    wrBits64 w.hdr 24 (cast salt)
  appendLog w.st lg w.hdr 0 WalHeaderSize
  _ <- flushLog lg
  writeIORef w.logRef (Just lg)
  writeIORef w.saltRef salt
  writeIORef w.sizeRef WalHeaderSize

openLog : Wal -> DB LogFile
openLog w = do
  Just lg <- readIORef w.logRef
    | Nothing => throw (IOFailure "the write-ahead log is not open")
  pure lg

seedFor : Int -> Bits32
seedFor salt = hashSeed `xor` cast salt

appendRecord : Wal -> (rtype : Int) -> (txid : Int) -> (pageId : Int) -> (lsn : Int) -> Maybe Page -> DB ()
appendRecord w rtype txid pageId lsn payload = do
  lg <- openLog w
  salt <- readIORef w.saltRef
  let plen : Int = case payload of
                     Nothing => 0
                     Just _ => PageSize
  liftIO $ do
    wrU32 w.hdr 0 rtype
    wrU32 w.hdr 4 pageId
    wrBits64 w.hdr 8 (cast lsn)
    wrBits64 w.hdr 16 (cast txid)
    wrU32 w.hdr 24 plen
  h1 <- liftIO (hashWords w.hostLittle w.hdr 0 RecHeaderSize (seedFor salt))
  appendLog w.st lg w.hdr 0 RecHeaderSize
  h2 <- case payload of
          Nothing => pure h1
          Just p => do
            appendLog w.st lg (rawBuffer p) 0 PageSize
            liftIO (hashWords w.hostLittle (rawBuffer p) 0 PageSize h1)
  liftIO (wrU32 w.hdr 28 (cast (hashFinish h2)))
  appendLog w.st lg w.hdr 28 4
  modifyIORef w.sizeRef (+ (RecHeaderSize + plen + 4))

||| Log the full image of a page. Stamps the page with the record's LSN and
||| seals its checksum first, so the logged image is a valid page file.
export
appendPage : Wal -> (txid : Int) -> (pageId : Int) -> Page -> DB ()
appendPage w txid pageId p = do
  lsn <- readIORef w.lsnRef
  writeIORef w.lsnRef (lsn + 1)
  liftIO $ do
    setPageLsn p (cast lsn)
    sealPage w.hostLittle p
  appendRecord w recPage txid pageId lsn (Just p)

||| Log the commit record and flush. The transaction is committed when this
||| returns: recovery will redo its pages from that point on.
export
appendCommit : Wal -> (txid : Int) -> DB Durability
appendCommit w txid = do
  lsn <- readIORef w.lsnRef
  writeIORef w.lsnRef (lsn + 1)
  appendRecord w recCommit txid 0 lsn Nothing
  lg <- openLog w
  flushLog lg

public export
data WalRecord
  = ||| Transaction id, page id, page image. The image is only valid during
    ||| the callback that receives it.
    WalPage Int Int Page
  | WalCommit Int

public export
record WalScan where
  constructor MkWalScan
  ||| A log with a complete header was found.
  present : Bool
  dbId : Bits64
  salt : Int
  ||| Valid records read.
  records : Int
  ||| The log ended in bytes that do not form a valid record.
  tornTail : Bool
  maxLsn : Int
  maxTxn : Int

matchesAt : Buffer -> Int -> List Int -> IO Bool
matchesAt _ _ [] = pure True
matchesAt b o (x :: xs) = do
  y <- rdU8 b o
  if x == y then matchesAt b (o + 1) xs else pure False

||| Read the log from the start, calling `onRecord` for each valid record,
||| and stop at the first byte sequence that is not one.
export
scanWal : (path : String) -> (hostLittle : Bool) -> (onRecord : WalRecord -> DB ()) -> DB WalScan
scanWal path hostLittle onRecord = do
  Just h <- openForRead path
    | Nothing => pure (MkWalScan False 0 0 0 False 0 0)
  hdr <- alloc WalHeaderSize
  page <- newPage
  finally (body h hdr page) (closeRead h)
  where
    records : File -> Buffer -> Page -> (dbId : Bits64) -> (salt : Int) ->
              (count : Int) -> (maxLsn : Int) -> (maxTxn : Int) -> DB WalScan
    records h hdr page dbId salt count maxLsn maxTxn = do
      let done : Bool -> DB WalScan = \torn => pure (MkWalScan True dbId salt count torn maxLsn maxTxn)
      n <- readSome h hdr RecHeaderSize
      if n == 0 then done False
        else if n < RecHeaderSize then done True
        else do
          rtype <- liftIO (rdU32 hdr 0)
          pageId <- liftIO (rdU32 hdr 4)
          lsn <- liftIO (rdBits64 hdr 8)
          txid <- liftIO (rdBits64 hdr 16)
          plen <- liftIO (rdU32 hdr 24)
          let isPage = rtype == recPage && plen == PageSize
          let isCommit = rtype == recCommit && plen == 0
          if not (isPage || isCommit) then done True
            else do
              h1 <- liftIO (hashWords hostLittle hdr 0 RecHeaderSize (seedFor salt))
              got <- if isPage then readSome h (rawBuffer page) PageSize else pure 0
              if got < plen then done True
                else do
                  h2 <- if isPage then liftIO (hashWords hostLittle (rawBuffer page) 0 PageSize h1)
                                  else pure h1
                  m <- readSome h hdr 4
                  stored <- liftIO (rdU32 hdr 0)
                  if m < 4 || stored /= cast (hashFinish h2) then done True
                    else do
                      onRecord (if isPage then WalPage (cast txid) pageId page
                                          else WalCommit (cast txid))
                      records h hdr page dbId salt (count + 1)
                              (max maxLsn (cast lsn)) (max maxTxn (cast txid))

    body : File -> Buffer -> Page -> DB WalScan
    body h hdr page = do
      n <- readSome h hdr WalHeaderSize
      if n < WalHeaderSize
        -- A header cut short means a crash while the log was being reset,
        -- which happens only after every page reached its page file.
        then pure (MkWalScan False 0 0 0 (n > 0) 0 0)
        else do
          okMagic <- liftIO (matchesAt hdr 0 walMagic)
          version <- liftIO (rdU32 hdr 8)
          psize <- liftIO (rdU32 hdr 12)
          when' (not okMagic) (Corrupt "write-ahead log has the wrong signature")
          when' (version /= FormatVersion)
            (Corrupt ("write-ahead log format version " ++ show version ++ " is not supported"))
          when' (psize /= PageSize)
            (Corrupt ("write-ahead log page size " ++ show psize ++ " does not match"))
          dbId <- liftIO (rdBits64 hdr 16)
          salt <- liftIO (rdBits64 hdr 24)
          records h hdr page dbId (cast salt) 0 0 0
