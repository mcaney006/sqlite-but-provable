module Bench.Micro

import System.Clock
import System.Directory
import IdrisQL.Catalog.Record
import IdrisQL.Engine
import IdrisQL.Error
import IdrisQL.Index.BPlusTree
import IdrisQL.Index.KeyCodec
import IdrisQL.Options
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Codec
import IdrisQL.Storage.Page
import IdrisQL.Storage.Pager
import IdrisQL.Types

-- Times the engine's inner operations with everything in memory, to show
-- where a statement's time goes. Run with `make microbench`; the numbers in
-- docs/BENCHMARKS.md come from this program.

timed : String -> (count : Int) -> DB a -> DB a
timed what count act = do
  t0 <- liftIO (clockTime Monotonic)
  r <- act
  t1 <- liftIO (clockTime Monotonic)
  let ns = (seconds t1 - seconds t0) * 1000000000 + (nanoseconds t1 - nanoseconds t0)
  let perOp = ns `div` cast count
  putStrLn (what ++ ": " ++ show (ns `div` 1000000) ++ " ms for " ++ show count
            ++ " (" ++ show (perOp `div` 1000) ++ "." ++ show ((perOp `mod` 1000) `div` 100) ++ " us each)")
  pure r

each : Int -> Int -> (Int -> DB ()) -> DB ()
each i n f = if i > n then pure () else f i >> each (i + 1) n f

bench : String -> DB ()
bench path = do
  -- A pool and a checkpoint threshold large enough that nothing is evicted
  -- or checkpointed while the clock runs.
  eng <- openEngine path (MkOptions 65536 1073741824 False 50000)
  let pg = enginePager eng
  let n = 100000
  beginTxn pg
  root <- createTree pg
  val <- stringBytes "some value of ordinary length, 40 bytes."
  timed "tree insert, ascending keys" n $ each 1 n $ \i => do
    k <- rowidKey (cast i)
    ignore (put pg root k val)
  timed "tree lookup" n $ each 1 n $ \i => do
    k <- rowidKey (cast i)
    ignore (lookup pg root k)
  timed "page pin and unpin" n $ each 1 n $ \_ => withPage (pagerPool pg) root (\_ => pure ())
  timed "row encode, 3 columns" n $ each 1 n $ \i =>
    ignore (encodeRow [TInt, TInt, TText] [Just (cast i), Just 5, Just "note 12345"])
  timed "commit of the whole tree" 1 $ commitTxn pg

  let m = 20000
  _ <- execute eng "CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER NOT NULL, b TEXT NOT NULL)" []
  _ <- execute eng "BEGIN" []
  timed "INSERT prepared from text, not run" m $ each 1 m $ \i =>
    ignore (prepare eng ("INSERT INTO t VALUES (" ++ show i ++ ", 5, 'note " ++ show i ++ "')"))
  timed "INSERT from text" m $ each 1 m $ \i =>
    ignore (execute eng ("INSERT INTO t VALUES (" ++ show i ++ ", 5, 'note " ++ show i ++ "')") [])
  ins <- prepare eng "INSERT INTO t VALUES (?, ?, ?)"
  timed "INSERT prepared once, bound each time" m $ each (m + 1) (2 * m) $ \i =>
    ignore (runStatement ins [VInt (cast i), VInt 5, VText "note"])
  sel <- prepare eng "SELECT a, b FROM t WHERE id = ?"
  timed "point SELECT, prepared" m $ each 1 m $ \i => do
    Rows _ _ source <- runStatement sel [VInt (cast i)] | _ => pure ()
    ignore source
  _ <- execute eng "COMMIT" []
  closeEngine eng

main : IO ()
main = do
  _ <- createDir "build"
  let path = "build/microbench.idb"
  Right () <- runDB (bench path)
    | Left e => putStrLn ("microbench failed: " ++ show e)
  pure ()
