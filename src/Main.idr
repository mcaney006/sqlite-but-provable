module Main

import Data.List
import Data.Maybe
import Data.String
import System
import System.File
import IdrisQL.CLI.Shell
import IdrisQL.Engine
import IdrisQL.Error
import IdrisQL.Storage.Pager

usage : String
usage = """
  usage: idrisql DATABASE [options]

    DATABASE            database directory; created if it does not exist

  options:
    --execute SQL       run the statements in SQL and exit
    --file PATH         run the statements in a file and exit
    --mode list|table   output format (default: table on a terminal, list otherwise)
    --cache PAGES       buffer pool size in 4 KiB pages (default 256)
    --break-lock        take over a lock left by a dead process
    --help              this text
    --version           print the version

  With neither --execute nor --file, statements are read from standard input.
  """

record Args where
  constructor MkArgs
  database : Maybe String
  execute : Maybe String
  file : Maybe String
  mode : Maybe OutputMode
  options : Options

parseArgs : List String -> Args -> Either String Args
parseArgs [] a = Right a
parseArgs ("--execute" :: sql :: rest) a = parseArgs rest ({ execute := Just sql } a)
parseArgs ("--file" :: path :: rest) a = parseArgs rest ({ file := Just path } a)
parseArgs ("--mode" :: "list" :: rest) a = parseArgs rest ({ mode := Just ListMode } a)
parseArgs ("--mode" :: "table" :: rest) a = parseArgs rest ({ mode := Just TableMode } a)
parseArgs ("--cache" :: n :: rest) a = case parsePositive {a = Int} n of
  Just pages => parseArgs rest ({ options := { cachePages := pages } a.options } a)
  Nothing => Left ("--cache needs a number of pages, got " ++ n)
parseArgs ("--break-lock" :: rest) a = parseArgs rest ({ options := { breakLock := True } a.options } a)
parseArgs (arg :: rest) a =
  if isPrefixOf "--" arg then Left ("unknown or incomplete option " ++ arg)
  else case a.database of
    Nothing => parseArgs rest ({ database := Just arg } a)
    Just _ => Left ("unexpected argument " ++ arg)

fail : String -> IO a
fail msg = do
  _ <- fPutStrLn stderr msg
  exitWith (ExitFailure 2)

main : IO ()
main = do
  args <- getArgs
  let given = drop 1 args
  when ("--help" `elem` given) (putStr usage >> exitSuccess)
  when ("--version" `elem` given) (putStrLn "idrisql 0.1.0 (file format 1)" >> exitSuccess)
  Right parsed <- pure (parseArgs given (MkArgs Nothing Nothing Nothing Nothing defaultOptions))
    | Left msg => fail (msg ++ "\n" ++ usage)
  Just path <- pure parsed.database
    | Nothing => fail usage
  Right eng <- runDB (openEngine path parsed.options)
    | Left e => fail ("Error: " ++ show e)
  maybe (pure ()) (\n => ignore (fPutStrLn stderr n)) (recoveryNotice eng)
  tty <- isTTY stdin
  let scripted = isJust parsed.execute || isJust parsed.file
  let cfg = MkShellConfig (fromMaybe (if tty && not scripted then TableMode else ListMode) parsed.mode)
                          (tty && not scripted)
  ok <- case (parsed.execute, parsed.file) of
    (Just sql, _) => runText eng cfg sql
    (Nothing, Just file) => do
      Right h <- openFile file Read
        | Left e => fail ("cannot read " ++ file ++ ": " ++ show e)
      r <- runInput eng cfg h
      closeFile h
      pure r
    (Nothing, Nothing) => runInput eng cfg stdin
  Right () <- runDB (closeEngine eng)
    | Left e => fail ("Error while closing: " ++ show e)
  if ok then exitSuccess else exitWith (ExitFailure 1)
