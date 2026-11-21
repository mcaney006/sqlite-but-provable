module IdrisQL.Storage.FileIO

import Data.Buffer
import Data.IORef
import System.Directory
import System.File
import System.File.Buffer
import IdrisQL.Error

-- The only module that touches the filesystem. It offers exactly what the
-- Idris 2 base library offers: whole-file read, truncating write, append,
-- flush to the operating system, remove, and directory create/list/remove.
-- There is no seek, rename, fsync or file lock (docs/PLATFORM_CONSTRAINTS.md).

||| What a completed log flush guarantees. This build has one level because
||| base exposes `fflush` and nothing stronger.
public export
data Durability
  = ||| The bytes were handed to the operating system. They survive the death
    ||| of this process. A power failure or kernel crash can still lose them.
    FlushedToOS

public export
Show Durability where
  show FlushedToOS = "flushed to the operating system (no fsync)"

||| Storage access with counters and an optional injected fault. Every
||| mutating operation is charged against `budget`; once it reaches zero the
||| operation fails with `InjectedFault`, optionally after writing only the
||| first half of its bytes.
export
record Storage where
  constructor MkStorage
  budget : IORef (Maybe Int)
  tearNext : IORef Bool
  writeOps : IORef Int
  writeBytes : IORef Int
  readOps : IORef Int

export
newStorage : IO Storage
newStorage = do
  budget <- newIORef Nothing
  tearNext <- newIORef False
  writeOps <- newIORef 0
  writeBytes <- newIORef 0
  readOps <- newIORef 0
  pure (MkStorage budget tearNext writeOps writeBytes readOps)

||| Let `afterWrites` more mutating operations succeed, then fail every later
||| one. With `torn`, the first failing write stores half of its bytes.
export
injectFault : Storage -> (afterWrites : Int) -> (torn : Bool) -> IO ()
injectFault st n torn = do
  writeIORef st.budget (Just n)
  writeIORef st.tearNext torn

export
clearFault : Storage -> IO ()
clearFault st = do
  writeIORef st.budget Nothing
  writeIORef st.tearNext False

public export
record StorageStats where
  constructor MkStorageStats
  writeOps : Int
  writeBytes : Int
  readOps : Int

export
storageStats : Storage -> IO StorageStats
storageStats st =
  [| MkStorageStats (readIORef st.writeOps) (readIORef st.writeBytes) (readIORef st.readOps) |]

data Verdict = Proceed | Tear

charge : Storage -> (what : String) -> (bytes : Int) -> DB Verdict
charge st what bytes = do
  b <- readIORef st.budget
  case b of
    Just 0 => do
      t <- readIORef st.tearNext
      if t then writeIORef st.tearNext False >> pure Tear
           else throw (InjectedFault what)
    _ => do
      writeIORef st.budget (map (\k => k - 1) b)
      modifyIORef st.writeOps (+ 1)
      modifyIORef st.writeBytes (+ bytes)
      pure Proceed

ioErr : String -> FileError -> DbError
ioErr what e = IOFailure (what ++ ": " ++ show e)

||| Read up to `len` bytes of `path` into `buf`. `Nothing` when the file does
||| not exist; otherwise the number of bytes read.
export
readFileInto : Storage -> (path : String) -> Buffer -> (len : Int) -> DB (Maybe Int)
readFileInto st path buf len = do
  r <- openFile path Read
  case r of
    Left FileNotFound => pure Nothing
    Left e => throw (ioErr ("open " ++ path) e)
    Right h => do
      got <- readBufferData h buf 0 len
      closeFile h
      case got of
        Left e => throw (ioErr ("read " ++ path) e)
        Right n => modifyIORef st.readOps (+ 1) >> pure (Just n)

||| Replace the contents of `path` with the first `len` bytes of `buf`. The
||| replacement is not atomic: a crash can leave a shorter file.
export
writeFileFrom : Storage -> (path : String) -> Buffer -> (len : Int) -> DB ()
writeFileFrom st path buf len = do
  v <- charge st ("write " ++ path) len
  Right h <- openFile path WriteTruncate
    | Left e => throw (ioErr ("open " ++ path) e)
  r <- writeBufferData h buf 0 (case v of
                                  Proceed => len
                                  Tear => len `div` 2)
  closeFile h
  case (r, v) of
    (Left (e, _), _) => throw (ioErr ("write " ++ path) e)
    (Right (), Tear) => throw (InjectedFault ("torn write " ++ path))
    (Right (), Proceed) => pure ()

export
record LogFile where
  constructor MkLogFile
  path : String
  handle : File

||| Create or truncate an append-only file and keep it open for writing.
export
createLog : Storage -> (path : String) -> DB LogFile
createLog st path = do
  Proceed <- charge st ("truncate " ++ path) 0
    | Tear => throw (InjectedFault ("truncate " ++ path))
  Right h <- openFile path WriteTruncate
    | Left e => throw (ioErr ("open " ++ path) e)
  pure (MkLogFile path h)

export
appendLog : Storage -> LogFile -> Buffer -> (off : Int) -> (len : Int) -> DB ()
appendLog st lg buf off len = do
  v <- charge st ("append " ++ lg.path) len
  r <- writeBufferData lg.handle buf off (case v of
                                            Proceed => len
                                            Tear => len `div` 2)
  case (r, v) of
    (Left (e, _), _) => throw (ioErr ("append " ++ lg.path) e)
    (Right (), Tear) => fflush lg.handle >> throw (InjectedFault ("torn append " ++ lg.path))
    (Right (), Proceed) => pure ()

export
flushLog : LogFile -> DB Durability
flushLog lg = do
  fflush lg.handle
  bad <- fileError lg.handle
  if bad then throw (IOFailure ("flush " ++ lg.path)) else pure FlushedToOS

export
closeLog : LogFile -> IO ()
closeLog lg = closeFile lg.handle

||| Open `path` for sequential reading; `Nothing` when it does not exist.
export
openForRead : (path : String) -> DB (Maybe File)
openForRead path = do
  r <- openFile path Read
  case r of
    Left FileNotFound => pure Nothing
    Left e => throw (ioErr ("open " ++ path) e)
    Right h => pure (Just h)

||| Read up to `len` bytes into the start of `buf`; fewer are returned only
||| at end of file.
export
readSome : File -> Buffer -> (len : Int) -> DB Int
readSome h buf len = do
  Right n <- readBufferData h buf 0 len
    | Left e => throw (ioErr "read" e)
  pure n

||| Create a directory. True when it was created, False when it already
||| existed. `mkdir` is atomic, which makes this usable as a lock.
export
makeDir : (path : String) -> DB Bool
makeDir path = do
  r <- createDir path
  case r of
    Right () => pure True
    Left FileExists => pure False
    Left e => throw (ioErr ("mkdir " ++ path) e)

export
removeDirectory : (path : String) -> IO ()
removeDirectory path = removeDir path

||| Entries of a directory, or the empty list when it does not exist.
export
listDirectory : (path : String) -> DB (List String)
listDirectory path = do
  r <- listDir path
  case r of
    Right names => pure names
    Left FileNotFound => pure []
    Left e => throw (ioErr ("list " ++ path) e)

||| Remove a file; a missing file is not an error.
export
removePath : Storage -> (path : String) -> DB ()
removePath st path = do
  Proceed <- charge st ("remove " ++ path) 0
    | Tear => throw (InjectedFault ("remove " ++ path))
  r <- removeFile path
  case r of
    Right () => pure ()
    Left FileNotFound => pure ()
    Left e => throw (ioErr ("remove " ++ path) e)

export
pathExists : (path : String) -> IO Bool
pathExists path = exists path
