module IdrisQL.CLI.Shell

import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.String
import System.File
import IdrisQL.Catalog.Schema
import IdrisQL.Engine
import IdrisQL.Error
import IdrisQL.Query.Statement
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Pager
import IdrisQL.Storage.Recovery
import IdrisQL.Types

public export
data OutputMode = ListMode | TableMode

public export
record ShellConfig where
  constructor MkShellConfig
  mode : OutputMode
  ||| Print prompts and acknowledgements, and keep going after an error.
  interactive : Bool

-- Statement splitting. A statement ends at a `;` that is outside string
-- literals, quoted identifiers and comments.

data Lex = Code | InString | InIdent | LineComment | BlockComment

-- Returns the complete statements and the unfinished remainder.
splitStatements : String -> (List String, String)
splitStatements text = go Code [] [] (unpack text)
  where
    emit : List Char -> List String -> List String
    emit acc done = let s = pack (reverse acc) in if trim s == "" then done else s :: done

    go : Lex -> (acc : List Char) -> (done : List String) -> List Char -> (List String, String)
    go _ acc done [] = (reverse done, pack (reverse acc))
    go Code acc done (';' :: cs) = go Code [] (emit acc done) cs
    go Code acc done ('\'' :: cs) = go InString ('\'' :: acc) done cs
    go Code acc done ('"' :: cs) = go InIdent ('"' :: acc) done cs
    go Code acc done ('-' :: '-' :: cs) = go LineComment ('-' :: '-' :: acc) done cs
    go Code acc done ('/' :: '*' :: cs) = go BlockComment ('*' :: '/' :: acc) done cs
    go Code acc done (c :: cs) = go Code (c :: acc) done cs
    go InString acc done ('\'' :: cs) = go Code ('\'' :: acc) done cs
    go InString acc done (c :: cs) = go InString (c :: acc) done cs
    go InIdent acc done ('"' :: cs) = go Code ('"' :: acc) done cs
    go InIdent acc done (c :: cs) = go InIdent (c :: acc) done cs
    go LineComment acc done ('\n' :: cs) = go Code ('\n' :: acc) done cs
    go LineComment acc done (c :: cs) = go LineComment (c :: acc) done cs
    go BlockComment acc done ('*' :: '/' :: cs) = go Code ('/' :: '*' :: acc) done cs
    go BlockComment acc done (c :: cs) = go BlockComment (c :: acc) done cs

-- Output.

pad : Nat -> String -> String
pad w s = s ++ pack (replicate (w `minus` length s) ' ')

printTable : (header : Maybe (List String)) -> List (List String) -> IO ()
printTable header rows = do
  let allRows = toList header ++ rows
  let widths = foldl (\ws, r => zipWith max ws (map length r ++ replicate (length ws `minus` length r) 0))
                     (replicate (maybe 0 length (head' allRows)) 0) allRows
  let line = \r => concat (intersperse " | " (zipWith pad widths r))
  case header of
    Nothing => pure ()
    Just h => do
      putStrLn (line h)
      putStrLn (concat (intersperse "-+-" (map (\w => pack (replicate w '-')) widths)))
  traverse_ (putStrLn . line) rows

-- Print rows as they arrive. Table mode sizes its columns from the first
-- thousand rows, so memory use does not grow with the result.
printRows : ShellConfig -> List String -> DB (Maybe (List Value)) -> DB Nat
printRows cfg names source = case cfg.mode of
  ListMode => do
    when cfg.interactive (putStrLn (concat (intersperse "|" names)))
    list 0
  TableMode => table True 0
  where
    list : Nat -> DB Nat
    list n = do
      Just row <- source | Nothing => pure n
      putStrLn (concat (intersperse "|" (map renderValue row)))
      list (S n)

    chunk : Nat -> List (List String) -> DB (List (List String))
    chunk Z acc = pure (reverse acc)
    chunk (S k) acc = do
      Just row <- source | Nothing => pure (reverse acc)
      chunk k (map renderValue row :: acc)

    table : Bool -> Nat -> DB Nat
    table first n = do
      rows <- chunk 1000 []
      if isNil rows && not first then pure n
        else do
          liftIO (printTable (if first then Just names else Nothing) rows)
          if length rows < 1000 then pure (n + length rows) else table False (n + length rows)

plural : Nat -> String -> String
plural 1 word = "1 " ++ word
plural n word = show n ++ " " ++ word ++ "s"

report : ShellConfig -> Result -> DB ()
report cfg (Rows names _ source) = do
  n <- printRows cfg names source
  when cfg.interactive (putStrLn ("(" ++ plural n "row" ++ ")"))
report cfg (Changed n) = when cfg.interactive (putStrLn (plural n "row" ++ " changed"))
report cfg (Done what) = when cfg.interactive (putStrLn what)

complain : String -> IO ()
complain msg = ignore (fPutStrLn stderr msg)

-- Dot commands.

helpText : String
helpText = """
  .help               this text
  .tables             list tables
  .schema [TABLE]     show CREATE statements
  .indexes [TABLE]    list indexes
  .check              verify every structure in the database
  .stats              page, cache and log counters
  .checkpoint         write committed pages to their files and truncate the log
  .mode list|table    output format
  .quit               leave the shell
  SQL statements end with a semicolon and may span lines.
  """

showStats : Engine -> DB ()
showStats eng = do
  s <- engineStats eng
  let lookups = s.pool.hits + s.pool.misses
  putStrLn ("pages:            " ++ show s.pageCount ++ " (" ++ show s.freePages ++ " free)")
  putStrLn ("buffer pool:      " ++ show s.pool.cached ++ " of " ++ show s.pool.capacity ++ " frames in use")
  putStrLn ("cache lookups:    " ++ show lookups ++ " (" ++ show s.pool.hits ++ " hits, "
            ++ show s.pool.misses ++ " misses)")
  putStrLn ("evictions:        " ++ show s.pool.evictions ++ " (" ++ show s.pool.spills ++ " spilled uncommitted)")
  putStrLn ("commits:          " ++ show s.commits)
  putStrLn ("checkpoints:      " ++ show s.checkpoints)
  putStrLn ("log size:         " ++ show s.walBytes ++ " bytes")
  putStrLn ("storage writes:   " ++ show s.storage.writeOps ++ " (" ++ show s.storage.writeBytes ++ " bytes)")
  putStrLn ("storage reads:    " ++ show s.storage.readOps)

dotCommand : Engine -> IORef ShellConfig -> String -> DB Bool
dotCommand eng cfgRef line = do
  schema <- liftIO (currentSchema eng)
  case words line of
    [".help"] => putStr helpText >> pure True
    [".quit"] => pure False
    [".exit"] => pure False
    [".tables"] => do
      traverse_ (putStrLn . (.name)) (values schema.tables)
      pure True
    [".schema"] => do
      for_ (values schema.tables) $ \t => traverse_ putStrLn (tableSql t (tableIndexes schema t.name))
      pure True
    [".schema", name] => do
      case findTable schema name of
        Nothing => liftIO (complain ("no such table: " ++ name))
        Just t => traverse_ putStrLn (tableSql t (tableIndexes schema t.name))
      pure True
    [".indexes"] => do
      for_ (values schema.indexes) $ \i => putStrLn (i.name ++ " on " ++ i.table)
      pure True
    [".indexes", name] => do
      for_ (tableIndexes schema name) $ \i => putStrLn (i.name ++ " on " ++ i.table)
      pure True
    [".check"] => do
      problems <- integrityCheck eng
      if isNil problems then putStrLn "ok" else traverse_ putStrLn problems
      pure True
    [".stats"] => showStats eng >> pure True
    [".checkpoint"] => checkpointNow eng >> pure True
    [".mode", "list"] => modifyIORef cfgRef ({ mode := ListMode }) >> pure True
    [".mode", "table"] => modifyIORef cfgRef ({ mode := TableMode }) >> pure True
    _ => do
      liftIO (complain ("unknown command: " ++ line ++ " (try .help)"))
      pure True

-- Run one statement and print its result. False when it failed.
runOne : Engine -> ShellConfig -> String -> IO Bool
runOne eng cfg sql = do
  before <- inTransaction eng
  r <- runDB (execute eng sql [] >>= report cfg)
  case r of
    Right () => pure True
    Left e => do
      complain ("Error: " ++ show e)
      after <- inTransaction eng
      when (before && not after) (complain "The open transaction was rolled back.")
      pure False

||| Run every statement in `text`, stopping at the first failure unless the
||| shell is interactive. Text that starts with a dot is one dot command.
||| Returns False when a statement failed.
export
runText : Engine -> ShellConfig -> String -> IO Bool
runText eng cfg text =
  if isPrefixOf "." (trim text)
    then do
      cfgRef <- newIORef cfg
      r <- runDB (dotCommand eng cfgRef (trim text))
      case r of
        Right _ => pure True
        Left e => complain ("Error: " ++ show e) >> pure False
    else let (stmts, rest) = splitStatements text
         in go (stmts ++ (if trim rest == "" then [] else [rest]))
  where
    go : List String -> IO Bool
    go [] = pure True
    go (s :: ss) = do
      ok <- runOne eng cfg s
      if ok || cfg.interactive then map (ok &&) (go ss) else pure False

||| Read statements from `input` until end of file or `.quit`. Statements
||| are executed as soon as their terminating semicolon arrives, so a
||| large script is never held in memory. Returns False if one failed.
export
runInput : Engine -> ShellConfig -> File -> IO Bool
runInput eng cfg input = do
  cfgRef <- newIORef cfg
  loop cfgRef "" True
  where
    prompt : String -> IO ()
    prompt pending = when cfg.interactive $ do
      putStr (if pending == "" then "idrisql> " else "    ...> ")
      fflush stdout

    loop : IORef ShellConfig -> (pending : String) -> (ok : Bool) -> IO Bool
    loop cfgRef pending ok = do
      prompt pending
      Right line <- fGetLine input | Left _ => pure ok
      eof <- fEOF input
      if eof && line == ""
        then if trim pending == "" then pure ok
             else do now <- readIORef cfgRef
                     map (ok &&) (runOne eng now pending)
        else if pending == "" && isPrefixOf "." (trim line)
        then do
          r <- runDB (dotCommand eng cfgRef (trim line))
          case r of
            Right True => loop cfgRef "" ok
            Right False => pure ok
            Left e => complain ("Error: " ++ show e) >> loop cfgRef "" ok
        else do
          let (stmts, rest) = splitStatements (pending ++ line)
          now <- readIORef cfgRef
          results <- traverse (runOne eng now) stmts
          let good = all id results
          if good || cfg.interactive
            then loop cfgRef (if trim rest == "" then "" else rest) (ok && good)
            else pure False

||| A line for the user when opening the database replayed the log.
export
recoveryNotice : Engine -> Maybe String
recoveryNotice eng =
  let info = recoveryInfo eng
  in if info.walFound && (info.pagesRedone > 0 || info.pagesDiscarded > 0 || info.tornTail)
       then Just ("recovered " ++ show info.committedTxns ++ " committed transactions ("
                  ++ show info.pagesRedone ++ " pages) from the write-ahead log"
                  ++ (if info.pagesDiscarded > 0
                        then "; discarded " ++ show info.pagesDiscarded ++ " pages of unfinished transactions"
                        else "")
                  ++ (if info.tornTail then "; the log ended in an incomplete record" else ""))
       else Nothing
