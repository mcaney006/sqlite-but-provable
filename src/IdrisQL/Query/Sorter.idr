module IdrisQL.Query.Sorter

import Data.Buffer
import Data.IORef
import Data.List
import System.File
import IdrisQL.Catalog.Record
import IdrisQL.Error
import IdrisQL.SQL.AST
import IdrisQL.Storage.Codec
import IdrisQL.Storage.FileIO
import IdrisQL.Types

-- External merge sort. Rows are sorted in memory in chunks of at most
-- `memoryRows`; when the input is larger, each sorted chunk is written to a
-- run file and the runs are merged by reading them sequentially. Memory use
-- is one chunk during the first phase and one row per run during the merge.

public export
record SortEnv where
  constructor MkSortEnv
  st : Storage
  tmpDir : String
  memoryRows : Nat
  ||| Source of unique run-file names.
  counter : IORef Int
  ||| Actions that release what an unfinished sort still holds.
  cleanups : IORef (List (DB ()))
  ||| Runs written to disk since the connection opened.
  runsWritten : IORef Int

export
newSortEnv : Storage -> (tmpDir : String) -> (memoryRows : Nat) -> IO SortEnv
newSortEnv st tmpDir memoryRows =
  pure (MkSortEnv st tmpDir (max 16 memoryRows) !(newIORef 0) !(newIORef []) !(newIORef 0))

||| Close files and delete runs left by sorts that were not read to the end.
export
releaseSorts : SortEnv -> DB ()
releaseSorts env = do
  pending <- readIORef env.cleanups
  writeIORef env.cleanups []
  sequence_ pending

flipOrdering : Ordering -> Ordering
flipOrdering LT = GT
flipOrdering GT = LT
flipOrdering EQ = EQ

||| Compare sort keys column by column. With DESC the comparison is
||| reversed, which also puts NULL last.
export
compareKeys : (ks : List SqlType) -> List SortDir -> Row ks -> Row ks -> Ordering
compareKeys [] _ [] [] = EQ
compareKeys (t :: ts) dirs (x :: xs) (y :: ys) =
  let o = compareCell t x y
      o' = if isDesc dirs then flipOrdering o else o
  in case o' of
       EQ => compareKeys ts (drop 1 dirs) xs ys
       other => other
  where
    isDesc : List SortDir -> Bool
    isDesc (Desc :: _) = True
    isDesc _ = False

record Run where
  constructor MkRun
  path : String
  handle : File
  lenBuf : Buffer
  rowBuf : IORef Buffer

writeRun : SortEnv -> (ts : List SqlType) -> List (Row ts) -> DB String
writeRun env ts rows = do
  n <- readIORef env.counter
  writeIORef env.counter (n + 1)
  let path = env.tmpDir ++ "/sort-" ++ show n
  bd <- newBuilder 65536
  for_ rows $ \row => do
    bytes <- encodeRow ts row
    putU32 bd (size bytes)
    putBytes bd bytes
  out <- finish bd
  let (buf, off, len) = rawParts out
  lg <- createLog env.st path
  finally (appendLog env.st lg buf off len >> ignore (flushLog lg)) (liftIO (closeLog lg))
  modifyIORef env.runsWritten (+ 1)
  pure path

openRun : String -> DB Run
openRun path = do
  Just h <- openForRead path
    | Nothing => throw (IOFailure ("sort run " ++ path ++ " disappeared"))
  pure (MkRun path h !(alloc 4) !(newIORef !(alloc 4096)))

readRun : (ts : List SqlType) -> Run -> DB (Maybe (Row ts))
readRun ts run = do
  n <- readSome run.handle run.lenBuf 4
  if n == 0 then pure Nothing
    else do
      when' (n < 4) (IOFailure ("sort run " ++ run.path ++ " is truncated"))
      len <- liftIO (rdU32 run.lenBuf 0)
      buf <- readIORef run.rowBuf
      cap <- rawSize buf
      buf <- if len <= cap then pure buf
             else do bigger <- alloc (len * 2)
                     writeIORef run.rowBuf bigger
                     pure bigger
      m <- readSome run.handle buf len
      when' (m < len) (IOFailure ("sort run " ++ run.path ++ " is truncated"))
      bytes <- fromBuffer buf 0 len
      map Just (decodeRow ts bytes)

||| Sort `input` by its key rows. Returns a source of the rows in order.
export
sortRows : SortEnv -> (ks : List SqlType) -> (dirs : List SortDir) -> (ctx : List SqlType) ->
           (input : DB (Maybe (Row ks, Row ctx))) -> DB (DB (Maybe (Row ctx)))
sortRows env ks dirs ctx input = do
  paths <- newIORef (the (List String) [])
  rest <- fill paths 0 []
  written <- readIORef paths
  case written of
    [] => do
      pending <- newIORef (map snd (sortBy order rest))
      pure $ do
        (r :: more) <- readIORef pending | [] => pure Nothing
        writeIORef pending more
        pure (Just r)
    _ => do
      when (not (isNil rest)) (spill paths rest)
      files <- readIORef paths
      runs <- traverse openRun files
      let release = do
            traverse_ (\r => liftIO (closeRead r.handle)) runs
            traverse_ (removePath env.st) files
      modifyIORef env.cleanups (release ::)
      heads <- traverse (\r => map (\h => (h, r)) (readRun (ks ++ ctx) r)) runs
      state <- newIORef (mapMaybe (\(h, r) => map (\row => (splitRow ks row, r)) h) heads)
      pure (mergeNext state)
  where
    order : (Row ks, Row ctx) -> (Row ks, Row ctx) -> Ordering
    order a b = compareKeys ks dirs (fst a) (fst b)

    spill : IORef (List String) -> List (Row ks, Row ctx) -> DB ()
    spill paths chunk = do
      path <- writeRun env (ks ++ ctx) (map (\(k, r) => k ++ r) (sortBy order chunk))
      modifyIORef paths (path ::)

    fill : IORef (List String) -> Nat -> List (Row ks, Row ctx) -> DB (List (Row ks, Row ctx))
    fill paths n acc = do
      Just item <- input | Nothing => pure acc
      if S n >= env.memoryRows
        then do spill paths (item :: acc)
                fill paths 0 []
        else fill paths (S n) (item :: acc)

    -- Split the heads into the smallest and the others.
    least : ((Row ks, Row ctx), Run) -> List ((Row ks, Row ctx), Run) ->
            (((Row ks, Row ctx), Run), List ((Row ks, Row ctx), Run))
    least best [] = (best, [])
    least best (h :: hs) =
      if order (fst h) (fst best) == LT
        then let (m, others) = least h hs in (m, best :: others)
        else let (m, others) = least best hs in (m, h :: others)

    mergeNext : IORef (List ((Row ks, Row ctx), Run)) -> DB (Maybe (Row ctx))
    mergeNext state = do
      (h :: hs) <- readIORef state | [] => pure Nothing
      let ((item, run), others) = least h hs
      more <- readRun (ks ++ ctx) run
      writeIORef state (case more of
                          Nothing => others
                          Just row => (splitRow ks row, run) :: others)
      pure (Just (snd item))
