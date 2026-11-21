module Tests.Harness

import Data.List
import Data.String
import System.Directory
import System.File
import IdrisQL.Error

public export
record Test where
  constructor MkTest
  name : String
  ||| `Left reason` on failure.
  run : IO (Either String ())

export
pass : Either String ()
pass = Right ()

export
check : Bool -> Lazy String -> Either String ()
check True _ = Right ()
check False msg = Left msg

export
checkEq : (Eq a, Show a) => (what : String) -> (actual : a) -> (expected : a) -> Either String ()
checkEq what actual expected =
  if actual == expected then Right ()
  else Left (what ++ ": expected " ++ show expected ++ ", got " ++ show actual)

||| A test with no I/O.
export
pureTest : String -> Lazy (Either String ()) -> Test
pureTest name r = MkTest name (pure r)

||| Run every test, print one line per failure and a summary, and return
||| the number of failures.
export
runSuite : String -> List Test -> IO Nat
runSuite suite tests = go 0 0 tests
  where
    go : Nat -> Nat -> List Test -> IO Nat
    go passed failed [] = do
      putStrLn (suite ++ ": " ++ show passed ++ " passed, " ++ show failed ++ " failed")
      pure failed
    go passed failed (t :: ts) = do
      Right () <- t.run
        | Left why => do putStrLn ("FAIL " ++ suite ++ " / " ++ t.name ++ ": " ++ why)
                         go passed (S failed) ts
      go (S passed) failed ts

||| A test that runs in the engine's error monad; any `DbError` fails it.
export
dbTest : String -> DB () -> Test
dbTest name act = MkTest name $ do
  Right () <- runDB act | Left e => pure (Left (show e))
  pure (Right ())

||| Fail the surrounding `dbTest` with a message.
export
failWith : String -> DB a
failWith msg = throw (RuntimeError msg)

export
expect : Bool -> Lazy String -> DB ()
expect True _ = pure ()
expect False msg = failWith msg

||| `act` must fail; the error is passed to `judge`.
export
expectError : (what : String) -> DB a -> (judge : DbError -> Bool) -> DB ()
expectError what act judge = do
  r <- liftIO (runDB act)
  case r of
    Right _ => failWith (what ++ ": expected an error")
    Left e => expect (judge e) (what ++ ": unexpected error: " ++ show e)

||| Delete a file or a directory tree. Missing paths are ignored.
export
removeTree : String -> IO ()
removeTree path = do
  Right names <- listDir path
    | Left _ => ignore (removeFile path)
  traverse_ (\n => removeTree (path ++ "/" ++ n)) (filter (\n => n /= "." && n /= "..") names)
  removeDir path

||| A path under build/test-tmp that does not exist yet.
export
freshPath : String -> IO String
freshPath name = do
  _ <- createDir "build"
  _ <- createDir "build/test-tmp"
  let path = "build/test-tmp/" ++ name
  removeTree path
  pure path

||| Linear congruential generator; deterministic across runs and hosts.
export
nextRandom : Int -> Int
nextRandom s = (s * 1103515245 + 12345) `mod` 2147483648
