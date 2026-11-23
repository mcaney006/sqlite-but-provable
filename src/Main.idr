module Main

import Data.List
import Data.Maybe
import Data.String
import System
import System.File
import IdrisQL.CLI.Shell
import IdrisQL.Engine
import IdrisQL.Server.Http
import IdrisQL.Server.Serve
import IdrisQL.Error
import IdrisQL.Storage.Pager

usage : String
usage = """
  usage: idrisql DATABASE [options]

    DATABASE            database directory; created if it does not exist

  options:
    --execute SQL       run the statements in SQL and exit
    --file PATH         run the statements in a file and exit
    --serve PORT        answer SQL over HTTP on PORT until told to stop
    --host ADDRESS      IPv4 address to serve on (default 127.0.0.1)
    --max-rows N        largest result a served statement may return (default 100000)
    --mode list|table   output format (default: table on a terminal, list otherwise)
    --cache PAGES       buffer pool size in 4 KiB pages (default 2048)
    --checkpoint BYTES  log size that triggers a checkpoint (default 4194304)
    --break-lock        take over a lock left by a dead process
    --help              this text
    --version           print the version

  With none of --execute, --file and --serve, statements are read from
  standard input. When serving, the environment variable IDRISQL_TOKEN, if
  set, is the bearer token POST /query requires.
  """

record Args where
  constructor MkArgs
  database : Maybe String
  execute : Maybe String
  file : Maybe String
  mode : Maybe OutputMode
  serve : Maybe Int
  host : String
  maxRows : Nat
  options : Options

parseArgs : List String -> Args -> Either String Args
parseArgs [] a = Right a
parseArgs ("--execute" :: sql :: rest) a = parseArgs rest ({ execute := Just sql } a)
parseArgs ("--file" :: path :: rest) a = parseArgs rest ({ file := Just path } a)
parseArgs ("--serve" :: n :: rest) a = case parsePositive {a = Int} n of
  Just port =>
    if port >= 1 && port <= 65535 then parseArgs rest ({ serve := Just port } a)
      else Left ("--serve needs a port from 1 to 65535, got " ++ n)
  Nothing => Left ("--serve needs a port number, got " ++ n)
parseArgs ("--host" :: addr :: rest) a =
  if validIPv4 addr then parseArgs rest ({ host := addr } a)
    else Left ("--host needs an IPv4 address such as 127.0.0.1, got " ++ addr)
parseArgs ("--max-rows" :: n :: rest) a = case parsePositive {a = Nat} n of
  Just rows => parseArgs rest ({ maxRows := rows } a)
  Nothing => Left ("--max-rows needs a number, got " ++ n)
parseArgs ("--mode" :: "list" :: rest) a = parseArgs rest ({ mode := Just ListMode } a)
parseArgs ("--mode" :: "table" :: rest) a = parseArgs rest ({ mode := Just TableMode } a)
parseArgs ("--cache" :: n :: rest) a = case parsePositive {a = Int} n of
  Just pages => parseArgs rest ({ options := { cachePages := pages } a.options } a)
  Nothing => Left ("--cache needs a number of pages, got " ++ n)
parseArgs ("--checkpoint" :: n :: rest) a = case parsePositive {a = Int} n of
  Just bytes => parseArgs rest ({ options := { checkpointBytes := bytes } a.options } a)
  Nothing => Left ("--checkpoint needs a number of bytes, got " ++ n)
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
  Right parsed <- pure (parseArgs given (MkArgs Nothing Nothing Nothing Nothing Nothing "127.0.0.1" 100000 defaultOptions))
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
  ok <- case (parsed.serve, parsed.execute, parsed.file) of
    (Just port, _, _) => do
      token <- getEnv "IDRISQL_TOKEN"
      -- 1 MiB is the largest request body. It is read as a list of bytes,
      -- which takes 16 times its size in memory.
      r <- serve eng (MkServerConfig parsed.host port token parsed.maxRows 1048576)
      case r of
        Right () => pure True
        Left why => do
          _ <- fPutStrLn stderr ("Error: " ++ why)
          pure False
    (Nothing, Just sql, _) => runText eng cfg sql
    (Nothing, Nothing, Just file) => do
      Right h <- openFile file Read
        | Left e => fail ("cannot read " ++ file ++ ": " ++ show e)
      r <- runInput eng cfg h
      closeFile h
      pure r
    (Nothing, Nothing, Nothing) => runInput eng cfg stdin
  Right () <- runDB (closeEngine eng)
    | Left e => fail ("Error while closing: " ++ show e)
  if ok then exitSuccess else exitWith (ExitFailure 1)
