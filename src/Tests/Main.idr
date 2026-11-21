module Tests.Main

import Data.List
import System
import Tests.Harness
import Tests.SqlFrontend
import Tests.Storage

suites : List (String, List Test)
suites =
  [ ("sql-frontend", sqlFrontendTests)
  , ("storage", storageTests)
  ]

||| Run every suite, or only those named on the command line. Exits non-zero
||| when any test fails.
main : IO ()
main = do
  args <- getArgs
  let wanted = drop 1 args
  let chosen = if isNil wanted then suites else filter (\s => fst s `elem` wanted) suites
  failures <- traverse (\(name, tests) => runSuite name tests) chosen
  if sum failures == 0 then exitSuccess else exitFailure
