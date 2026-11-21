module IdrisQL.Engine

import Data.IORef
import Data.List
import Data.List.Elem
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.String
import IdrisQL.Catalog.Catalog
import IdrisQL.Catalog.Record
import IdrisQL.Catalog.Schema
import IdrisQL.Error
import IdrisQL.Index.BPlusTree
import IdrisQL.Index.Cursor
import IdrisQL.Index.KeyCodec
import IdrisQL.Query.Algebra
import IdrisQL.Query.Executor
import IdrisQL.Query.Planner
import IdrisQL.Query.Sorter
import IdrisQL.Query.Statement
import IdrisQL.SQL.AST
import IdrisQL.SQL.Parser
import IdrisQL.SQL.Typed
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Codec
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Format
import IdrisQL.Storage.Pager
import IdrisQL.Storage.Recovery
import IdrisQL.Types

-- Statement execution: DDL, DML with constraint enforcement and index
-- maintenance, and transaction control.
--
-- Transactions. Outside BEGIN .. COMMIT every writing statement is its own
-- transaction. A writing statement that fails while it runs rolls back the
-- transaction it is in, including an explicit one. That covers constraint
-- violations and the name checks of schema statements, which happen at run
-- time. Errors found when a statement is compiled (syntax, and the names
-- and types of queries and data changes) and errors in queries change
-- nothing and leave an explicit transaction open.
--
-- Isolation. One connection per database, enforced by the lock directory,
-- so transactions are serial. A transaction reads its own writes.

export
record Engine where
  constructor MkEngine
  pager : Pager
  schemaRef : IORef Schema
  explicitTxn : IORef Bool
  ||| The open transaction changed the catalog.
  schemaChanged : IORef Bool
  ||| Counts schema changes and rollbacks; cached plans are tied to it.
  generation : IORef Int
  ||| Largest rowid in each table, by table id, while it is known.
  lastRowids : IORef (SortedMap Int Int64)
  ||| Counts statements run. A query's rows can be read only while its
  ||| statement is the latest.
  statementSeq : IORef Int
  sorter : SortEnv

public export
data Result
  = ||| Column names, column types, and a source of rows.
    Rows (List String) (List SqlType) (DB (Maybe (List Value)))
  | ||| Rows inserted, updated or deleted.
    Changed Nat
  | ||| A statement with no rows and no count; the text names what ran.
    Done String

export
enginePager : Engine -> Pager
enginePager eng = eng.pager

export
currentSchema : Engine -> IO Schema
currentSchema eng = readIORef eng.schemaRef

||| True between BEGIN and COMMIT or ROLLBACK.
export
inTransaction : Engine -> IO Bool
inTransaction eng = readIORef eng.explicitTxn

-- Rows by column position.

intAt : (ts : List SqlType) -> Row ts -> Nat -> Maybe (Cell TInt)
intAt [] [] _ = Nothing
intAt (TInt :: ts) (x :: xs) Z = Just x
intAt (_ :: ts) (x :: xs) Z = Nothing
intAt (_ :: ts) (_ :: xs) (S k) = intAt ts xs k

setIntAt : (ts : List SqlType) -> Nat -> Int64 -> Row ts -> Row ts
setIntAt [] _ _ [] = []
setIntAt (TInt :: ts) Z v (_ :: xs) = Just v :: xs
setIntAt (_ :: ts) Z v row = row
setIntAt (_ :: ts) (S k) v (x :: xs) = x :: setIntAt ts k v xs

nullAt : (ts : List SqlType) -> Row ts -> Nat -> Bool
nullAt [] [] _ = False
nullAt (_ :: ts) (x :: xs) Z = isNothing x
nullAt (_ :: ts) (_ :: xs) (S k) = nullAt ts xs k

setAt : Elem t ts -> Cell t -> Row ts -> Row ts
setAt Here v (_ :: xs) = v :: xs
setAt (There el) v (x :: xs) = x :: setAt el v xs

||| A row of some shape: the indexed columns of a table row.
data SomeRow : Type where
  MkSomeRow : (ks : List SqlType) -> Row ks -> SomeRow

cellAt : (ts : List SqlType) -> Row ts -> Nat -> Maybe SomeRow
cellAt [] [] _ = Nothing
cellAt (t :: ts) (x :: xs) Z = Just (MkSomeRow [t] [x])
cellAt (_ :: ts) (_ :: xs) (S k) = cellAt ts xs k

pick : (ts : List SqlType) -> Row ts -> List Nat -> Maybe SomeRow
pick ts row [] = Just (MkSomeRow [] [])
pick ts row (c :: cs) = do
  MkSomeRow a x <- cellAt ts row c
  MkSomeRow b y <- pick ts row cs
  Just (MkSomeRow (a ++ b) (x ++ y))

anyNull : (ts : List SqlType) -> Row ts -> Bool
anyNull [] [] = False
anyNull (_ :: ts) (x :: xs) = isNothing x || anyNull ts xs

-- Index entries.

indexEntry : (tbl : TableDef) -> IndexDef -> Row (tableCtx tbl) -> DB SomeRow
indexEntry tbl idx row = case pick (tableCtx tbl) row idx.columns of
  Just e => pure e
  Nothing => throw (Corrupt ("index " ++ idx.name ++ " names a column that " ++ tbl.name ++ " lacks"))

entryKey : SomeRow -> (rowid : Int64) -> DB Bytes
entryKey (MkSomeRow ks row) rowid = indexKey ks row rowid

-- The row that already holds these column values in a unique index. SQL
-- lets any number of rows be NULL in a unique column, so an entry with a
-- NULL never has an owner.
uniqueOwner : Engine -> IndexDef -> SomeRow -> DB (Maybe Int64)
uniqueOwner eng idx (MkSomeRow ks row) =
  if anyNull ks row then pure Nothing
  else do
    pre <- keyPrefix ks row
    c <- seek eng.pager idx.root (Just pre)
    Just key <- nextKey c | Nothing => pure Nothing
    same <- liftIO (hasPrefix pre key)
    if same && size key == size pre + 8 then map Just (keyRowid key) else pure Nothing

columnNames : TableDef -> List Nat -> String
columnNames tbl cols =
  concat (intersperse ", " (map (\i => tbl.name ++ "." ++ maybe "?" (.name) (getAt i tbl.columns)) cols))

uniqueViolation : TableDef -> List Nat -> DbError
uniqueViolation tbl cols = ConstraintViolation ("UNIQUE constraint failed: " ++ columnNames tbl cols)

-- Rowids.

maxRowid : Int64
maxRowid = 9223372036854775807

lastRowid : Engine -> TableDef -> DB Int64
lastRowid eng tbl = do
  known <- readIORef eng.lastRowids
  case lookup tbl.id known of
    Just v => pure v
    Nothing => do
      Just k <- lastKey eng.pager tbl.root | Nothing => pure 0
      keyRowid k

-- The next unused rowid: one more than the largest in use, and at least 1.
freshRowid : Engine -> TableDef -> DB Int64
freshRowid eng tbl = do
  last <- lastRowid eng tbl
  when' (last == maxRowid) (RuntimeError ("table " ++ tbl.name ++ " has used its last rowid"))
  let v = max 1 (last + 1)
  modifyIORef eng.lastRowids (insert tbl.id v)
  pure v

noteRowid : Engine -> TableDef -> Int64 -> DB ()
noteRowid eng tbl v = do
  last <- lastRowid eng tbl
  modifyIORef eng.lastRowids (insert tbl.id (max last v))

rowExists : Engine -> TableDef -> Int64 -> DB Bool
rowExists eng tbl rowid = map isJust (lookup eng.pager tbl.root !(rowidKey rowid))

-- Constraints.

checkNotNull : (tbl : TableDef) -> Row (tableCtx tbl) -> DB ()
checkNotNull tbl row = go 0 tbl.columns
  where
    go : Nat -> List ColumnDef -> DB ()
    go _ [] = pure ()
    go i (c :: cs) = do
      when' (c.notNull && nullAt (tableCtx tbl) row i)
        (ConstraintViolation ("NOT NULL constraint failed: " ++ tbl.name ++ "." ++ c.name))
      go (S i) cs

-- A CHECK fails only when it is FALSE; UNKNOWN passes, as the standard says.
checkChecks : List Value -> List (Check ctx) -> Row ctx -> DB ()
checkChecks params checks row = for_ checks $ \c => do
  v <- liftE (eval params row c.expr)
  when' (v == Just False) (ConstraintViolation ("CHECK constraint failed: " ++ c.sql))

-- Row operations.

insertRow : Engine -> (tbl : TableDef) -> List (Check (tableCtx tbl)) -> List IndexDef ->
            Row (tableCtx tbl) -> DB ()
insertRow eng tbl checks indexes given = do
  (rowid, row) <- case tbl.rowidColumn of
    Nothing => do v <- freshRowid eng tbl
                  pure (v, given)
    Just c => case intAt (tableCtx tbl) given c of
      Just (Just v) => do
        taken <- rowExists eng tbl v
        when' taken (uniqueViolation tbl [c])
        noteRowid eng tbl v
        pure (v, given)
      _ => do v <- freshRowid eng tbl
              pure (v, setIntAt (tableCtx tbl) c v given)
  checkNotNull tbl row
  checkChecks [] checks row
  entries <- traverse (\idx => map (\e => (idx, e)) (indexEntry tbl idx row)) indexes
  for_ entries $ \(idx, e) => when idx.unique $ do
    owner <- uniqueOwner eng idx e
    when' (isJust owner) (uniqueViolation tbl idx.columns)
  _ <- put eng.pager tbl.root !(rowidKey rowid) !(encodeRow (tableCtx tbl) row)
  none <- emptyBytes
  for_ entries $ \(idx, e) => put eng.pager idx.root !(entryKey e rowid) none

applyAssignments : List Value -> (old : Row ctx) -> List (Assignment ctx) -> Row ctx -> Either DbError (Row ctx)
applyAssignments params old [] row = Right row
applyAssignments params old (MkAssignment t el e :: rest) row = do
  v <- eval params old e
  applyAssignments params old rest (setAt el v row)

updateRow : Engine -> (tbl : TableDef) -> List (Assignment (tableCtx tbl)) -> List (Check (tableCtx tbl)) ->
            List IndexDef -> List Value -> (rowid : Int64) -> DB Bool
updateRow eng tbl assigns checks indexes params rowid = do
  oldKey <- rowidKey rowid
  Just bytes <- lookup eng.pager tbl.root oldKey | Nothing => pure False
  old <- decodeRow (tableCtx tbl) bytes
  new <- liftE (applyAssignments params old assigns old)
  newRowid <- case tbl.rowidColumn of
    Nothing => pure rowid
    Just c => case intAt (tableCtx tbl) new c of
      Just (Just v) => pure v
      _ => throw (ConstraintViolation ("NOT NULL constraint failed: " ++ columnNames tbl [c]))
  when (newRowid /= rowid) $ do
    taken <- rowExists eng tbl newRowid
    when' taken (uniqueViolation tbl (toList tbl.rowidColumn))
    noteRowid eng tbl newRowid
  checkNotNull tbl new
  checkChecks params checks new
  none <- emptyBytes
  for_ indexes $ \idx => do
    before <- indexEntry tbl idx old
    after <- indexEntry tbl idx new
    was <- entryKey before rowid
    now <- entryKey after newRowid
    moved <- map (/= EQ) (liftIO (compareBytes was now))
    when moved $ do
      when idx.unique $ do
        owner <- uniqueOwner eng idx after
        when' (isJust owner && owner /= Just rowid) (uniqueViolation tbl idx.columns)
      _ <- delete eng.pager idx.root was
      ignore (put eng.pager idx.root now none)
  when (newRowid /= rowid) $ do
    _ <- delete eng.pager tbl.root oldKey
    -- The row that moved may have held the largest rowid.
    modifyIORef eng.lastRowids (delete tbl.id)
  _ <- put eng.pager tbl.root !(rowidKey newRowid) !(encodeRow (tableCtx tbl) new)
  pure True

deleteRow : Engine -> (tbl : TableDef) -> List IndexDef -> (rowid : Int64) -> DB Bool
deleteRow eng tbl indexes rowid = do
  key <- rowidKey rowid
  Just bytes <- lookup eng.pager tbl.root key | Nothing => pure False
  row <- decodeRow (tableCtx tbl) bytes
  for_ indexes $ \idx => do
    e <- indexEntry tbl idx row
    found <- delete eng.pager idx.root !(entryKey e rowid)
    when' (not found) (Corrupt ("index " ++ idx.name ++ " has no entry for rowid " ++ show rowid))
  known <- readIORef eng.lastRowids
  when (lookup tbl.id known == Just rowid) (modifyIORef eng.lastRowids (delete tbl.id))
  delete eng.pager tbl.root key

-- The rowids a statement applies to, collected before anything is written
-- so that the statement never sees its own changes.
matching : Engine -> List Value -> (tbl : TableDef) -> Maybe (TExpr (tableCtx tbl) TBool) -> Access [] ->
           DB (List Int64)
matching eng params tbl pred access = do
  rows <- tableRows (MkExec eng.pager params eng.sorter) tbl [] access []
  collect rows []
  where
    collect : DB (Maybe (Int64, Row (tableCtx tbl))) -> List Int64 -> DB (List Int64)
    collect rows acc = do
      Just (rowid, row) <- rows | Nothing => pure (reverse acc)
      keep <- case pred of
                Nothing => pure True
                Just e => map (== Just True) (liftE (eval params row e))
      collect rows (if keep then rowid :: acc else acc)

countTrue : List Bool -> Nat
countTrue = length . filter id

-- Schema changes.

setSchema : Engine -> (Schema -> Schema) -> DB ()
setSchema eng f = do
  modifyIORef eng.schemaRef f
  writeIORef eng.schemaChanged True
  modifyIORef eng.generation (+ 1)
  bumpSchemaCookie eng.pager

nameTaken : Schema -> String -> Bool
nameTaken schema name = isJust (findTable schema name) || isJust (findIndex schema name)

createTable : Engine -> (ifNotExists : Bool) -> String -> List ColumnSpec -> List TableConstraint -> DB Result
createTable eng ifNotExists name specs cons = do
  schema <- readIORef eng.schemaRef
  if isJust (findTable schema name) && ifNotExists then pure (Done "CREATE TABLE")
    else do
      when' (nameTaken schema name) (SemanticError ("there is already a table or index named " ++ name))
      (draft, drafts) <- liftE (planCreateTable name specs cons)
      for_ drafts $ \i => when' (nameTaken schema i.name)
        (SemanticError ("constraint index name " ++ i.name ++ " is already in use"))
      tbl <- pure ({ id := !(nextObjectId eng.pager), root := !(createTree eng.pager) } draft)
      saveTable eng.pager tbl
      indexes <- traverse (\i => do
                   idx <- pure ({ id := !(nextObjectId eng.pager), root := !(createTree eng.pager) } i)
                   saveIndex eng.pager idx
                   pure idx) drafts
      setSchema eng $ \s =>
        { tables $= insert (norm tbl.name) tbl
        , indexes $= \m => foldl (\acc, i => insert (norm i.name) i acc) m indexes } s
      pure (Done "CREATE TABLE")

dropTable : Engine -> (ifExists : Bool) -> String -> DB Result
dropTable eng ifExists name = do
  schema <- readIORef eng.schemaRef
  case findTable schema name of
    Nothing => if ifExists then pure (Done "DROP TABLE")
               else throw (SemanticError ("no such table: " ++ name))
    Just tbl => do
      let indexes = tableIndexes schema tbl.name
      for_ indexes $ \i => do
        destroyTree eng.pager i.root
        removeIndex eng.pager i.name
      destroyTree eng.pager tbl.root
      removeTable eng.pager tbl.name
      modifyIORef eng.lastRowids (delete tbl.id)
      setSchema eng $ \s =>
        { tables $= delete (norm tbl.name)
        , indexes $= \m => foldl (\acc, i => delete (norm i.name) acc) m indexes } s
      pure (Done "DROP TABLE")

createIndex : Engine -> (unique : Bool) -> (ifNotExists : Bool) -> String -> String -> List String -> DB Result
createIndex eng unique ifNotExists name table cols = do
  schema <- readIORef eng.schemaRef
  if isJust (findIndex schema name) && ifNotExists then pure (Done "CREATE INDEX")
    else do
      when' (nameTaken schema name) (SemanticError ("there is already a table or index named " ++ name))
      Just tbl <- pure (findTable schema table)
        | Nothing => throw (SemanticError ("no such table: " ++ table))
      positions <- traverse (\c => case columnIndex tbl c of
                     Just i => pure i
                     Nothing => throw (SemanticError ("table " ++ tbl.name ++ " has no column named " ++ c))) cols
      when' (isNil positions) (SemanticError "an index needs at least one column")
      when' (length (nub positions) /= length positions) (SemanticError "an index column is listed twice")
      idx <- pure (MkIndexDef !(nextObjectId eng.pager) name tbl.name !(createTree eng.pager)
                     positions unique False (-1))
      rows <- tableRows (MkExec eng.pager [] eng.sorter) tbl [] FullScan []
      none <- emptyBytes
      fill tbl idx none rows
      saveIndex eng.pager idx
      setSchema eng ({ indexes $= insert (norm idx.name) idx })
      pure (Done "CREATE INDEX")
  where
    fill : (tbl : TableDef) -> IndexDef -> Bytes -> DB (Maybe (Int64, Row (tableCtx tbl))) -> DB ()
    fill tbl idx none rows = do
      Just (rowid, row) <- rows | Nothing => pure ()
      e <- indexEntry tbl idx row
      when idx.unique $ do
        owner <- uniqueOwner eng idx e
        when' (isJust owner) (uniqueViolation tbl idx.columns)
      _ <- put eng.pager idx.root !(entryKey e rowid) none
      fill tbl idx none rows

dropIndex : Engine -> (ifExists : Bool) -> String -> DB Result
dropIndex eng ifExists name = do
  schema <- readIORef eng.schemaRef
  case findIndex schema name of
    Nothing => if ifExists then pure (Done "DROP INDEX")
               else throw (SemanticError ("no such index: " ++ name))
    Just idx => do
      when' idx.constraintOwned
        (SemanticError ("index " ++ idx.name ++ " enforces a constraint of table " ++ idx.table
                        ++ " and is dropped with it"))
      destroyTree eng.pager idx.root
      removeIndex eng.pager idx.name
      setSchema eng ({ indexes $= delete (norm idx.name) })
      pure (Done "DROP INDEX")

countKeys : Pager -> (root : Int) -> DB Int
countKeys pg root = do
  c <- seek pg root Nothing
  go c 0
  where
    go : Cursor -> Int -> DB Int
    go c n = do
      Just _ <- nextKey c | Nothing => pure n
      go c (n + 1)

-- Distinct column-value combinations in an index: keys that differ before
-- their trailing rowid.
countDistinct : Pager -> (root : Int) -> DB Int
countDistinct pg root = do
  c <- seek pg root Nothing
  go c Nothing 0
  where
    go : Cursor -> Maybe Bytes -> Int -> DB Int
    go c prev n = do
      Just key <- nextKey c | Nothing => pure n
      pre <- sub key 0 (size key - 8)
      same <- case prev of
                Nothing => pure False
                Just p => map (== EQ) (liftIO (compareBytes p pre))
      go c (Just pre) (if same then n else n + 1)

||| Record row counts and index cardinalities for the planner.
analyze : Engine -> DB Result
analyze eng = do
  schema <- readIORef eng.schemaRef
  tables <- traverse (\t => do
              n <- countKeys eng.pager t.root
              let t' = { rowEstimate := n } t
              saveTable eng.pager t'
              pure t') (values schema.tables)
  indexes <- traverse (\i => do
               n <- countDistinct eng.pager i.root
               let i' = { distinctEstimate := n } i
               saveIndex eng.pager i'
               pure i') (values schema.indexes)
  setSchema eng $ \s =>
    { tables := fromList (map (\t => (norm t.name, t)) tables)
    , indexes := fromList (map (\i => (norm i.name, i)) indexes) } s
  pure (Done "ANALYZE")

-- Transactions.

-- Undo the open transaction and everything cached from it.
abort : Engine -> DB ()
abort eng = do
  -- The engine's own state first, so that it is right even if the pager's
  -- rollback fails.
  writeIORef eng.explicitTxn False
  writeIORef eng.lastRowids empty
  modifyIORef eng.generation (+ 1)
  active <- liftIO (inTxn eng.pager)
  when active (rollbackTxn eng.pager)
  changed <- readIORef eng.schemaChanged
  when changed $ do
    schema <- loadSchema eng.pager
    writeIORef eng.schemaRef schema
    writeIORef eng.schemaChanged False

bail : Engine -> DbError -> DB a
bail eng e = catchDB (abort eng) (\_ => pure ()) >> throw e

-- Commit the pager's transaction. A failure before the commit point rolls
-- back; one after it leaves the transaction committed, so the schema the
-- engine holds is already the right one.
commitNow : Engine -> DB ()
commitNow eng = catchDB (commitTxn eng.pager) $ \e => case e of
  CommittedThenFailed _ => do
    writeIORef eng.explicitTxn False
    writeIORef eng.schemaChanged False
    throw e
  _ => bail eng e

-- Run a writing statement in the open transaction, or in one of its own.
writing : Engine -> DB a -> DB a
writing eng body = do
  explicit <- readIORef eng.explicitTxn
  if explicit then catchDB body (bail eng)
    else do
      beginTxn eng.pager
      r <- catchDB body (bail eng)
      commitNow eng
      writeIORef eng.schemaChanged False
      pure r

begin : Engine -> DB Result
begin eng = do
  explicit <- readIORef eng.explicitTxn
  when' explicit (TxError "a transaction is already open")
  beginTxn eng.pager
  writeIORef eng.explicitTxn True
  pure (Done "BEGIN")

commit : Engine -> DB Result
commit eng = do
  explicit <- readIORef eng.explicitTxn
  when' (not explicit) (TxError "no transaction is open")
  commitNow eng
  writeIORef eng.explicitTxn False
  writeIORef eng.schemaChanged False
  pure (Done "COMMIT")

rollback : Engine -> DB Result
rollback eng = do
  explicit <- readIORef eng.explicitTxn
  when' (not explicit) (TxError "no transaction is open")
  abort eng
  pure (Done "ROLLBACK")

-- Dispatch.

listSource : List (List Value) -> DB (DB (Maybe (List Value)))
listSource rows = do
  pending <- newIORef rows
  pure $ do
    (r :: rest) <- readIORef pending | [] => pure Nothing
    writeIORef pending rest
    pure (Just r)

direct : Engine -> Stmt -> DB Result
direct eng SBegin = begin eng
direct eng SCommit = commit eng
direct eng SRollback = rollback eng
direct eng (SCreateTable _ ifNotExists name specs cons) = writing eng (createTable eng ifNotExists name specs cons)
direct eng (SDropTable _ ifExists name) = writing eng (dropTable eng ifExists name)
direct eng (SCreateIndex _ unique ifNotExists name table cols) =
  writing eng (createIndex eng unique ifNotExists name table cols)
direct eng (SDropIndex _ ifExists name) = writing eng (dropIndex eng ifExists name)
direct eng SAnalyze = writing eng (analyze eng)
direct eng _ = throw (Unsupported "this statement cannot be executed")

||| Run a checked statement with the given parameter values.
export
-- A row source that refuses to be read once a later statement has run: the
-- pages under its cursors may have changed, and its sort runs are gone.
current : Engine -> (mine : Int) -> DB (Maybe a) -> DB (Maybe a)
current eng mine source = do
  now <- readIORef eng.statementSeq
  when' (now /= mine)
    (RuntimeError "this result was ended by a later statement on the same connection")
  source

runCompiled : Engine -> Compiled -> (params : List Value) -> DB Result
runCompiled eng c params = do
  ensureUsable eng.pager
  liftE (checkParams (compiledParams c) params)
  modifyIORef eng.statementSeq (+ 1)
  mine <- readIORef eng.statementSeq
  releaseSorts eng.sorter
  case c of
    CSelect q plan => do
      rows <- run (MkExec eng.pager params eng.sorter) q.shape plan
      pure (Rows q.names q.shape (current eng mine (map (map (rowValues q.shape)) rows)))
    CInsert tbl rows checks indexes => writing eng $ do
      for_ rows $ \exprs => do
        row <- liftE (evalRow params [] exprs)
        insertRow eng tbl checks indexes row
      pure (Changed (length rows))
    CUpdate tbl assigns pred access checks indexes => writing eng $ do
      ids <- matching eng params tbl pred access
      done <- traverse (updateRow eng tbl assigns checks indexes params) ids
      pure (Changed (countTrue done))
    CDelete tbl pred access indexes => writing eng $ do
      ids <- matching eng params tbl pred access
      done <- traverse (deleteRow eng tbl indexes) ids
      pure (Changed (countTrue done))
    CExplain ls => do
      rows <- listSource (map (\l => [VText l]) ls)
      pure (Rows ["plan"] [TText] rows)
    CDirect stmt => direct eng stmt

||| Parse, check and run one statement.
export
execute : Engine -> (sql : String) -> (params : List Value) -> DB Result
execute eng sql params = do
  stmt <- liftE (parseStatement sql)
  schema <- readIORef eng.schemaRef
  c <- liftE (compile schema stmt)
  runCompiled eng c params

||| A parsed statement that keeps its checked form between runs.
export
record Statement where
  constructor MkStatement
  engine : Engine
  ast : Stmt
  cache : IORef (Maybe (Int, Compiled))

-- The checked form for the current schema, rebuilt after any schema change.
compiled : Statement -> DB Compiled
compiled st = do
  gen <- readIORef st.engine.generation
  cached <- readIORef st.cache
  case cached of
    Just (g, c) => if g == gen then pure c else rebuild gen
    Nothing => rebuild gen
  where
    rebuild : Int -> DB Compiled
    rebuild gen = do
      schema <- readIORef st.engine.schemaRef
      c <- liftE (compile schema st.ast)
      writeIORef st.cache (Just (gen, c))
      pure c

||| Parse and check a statement once. Errors in it are reported here.
export
prepare : Engine -> (sql : String) -> DB Statement
prepare eng sql = do
  ast <- liftE (parseStatement sql)
  st <- pure (MkStatement eng ast !(newIORef Nothing))
  _ <- compiled st
  pure st

||| The type each parameter must have, by parameter index.
export
parameterTypes : Statement -> DB (List (Nat, SqlType))
parameterTypes st = map compiledParams (compiled st)

||| Run a prepared statement with values for its parameters. The values
||| are data: they are never parsed as SQL.
export
runStatement : Statement -> (params : List Value) -> DB Result
runStatement st params = do
  c <- compiled st
  runCompiled st.engine c params

-- Opening and closing.

export
openWith : Storage -> (path : String) -> Options -> DB Engine
openWith st path opts = do
  present <- liftIO (pathExists (storePath path 0))
  pg <- if present then openDatabase st path opts else createDatabase st path opts
  catchDB (setup pg) (\e => liftIO (abandonDatabase pg) >> throw e)
  where
    setup : Pager -> DB Engine
    setup pg = do
      let tmp = path ++ "/tmp"
      _ <- makeDir tmp
      leftovers <- listDirectory tmp
      for_ (filter (\n => n /= "." && n /= "..") leftovers) (\n => removePath st (tmp ++ "/" ++ n))
      schema <- loadSchema pg
      sorter <- liftIO (newSortEnv st tmp opts.sortMemoryRows)
      pure (MkEngine pg !(newIORef schema) !(newIORef False) !(newIORef False)
              !(newIORef 0) !(newIORef empty) !(newIORef 0) sorter)

||| Open the database directory at `path`, creating it if it does not exist.
export
openEngine : (path : String) -> Options -> DB Engine
openEngine path opts = do
  st <- liftIO newStorage
  openWith st path opts

||| Roll back any open transaction, checkpoint, and release the lock.
export
closeEngine : Engine -> DB ()
closeEngine eng = do
  catchDB (releaseSorts eng.sorter) (\_ => pure ())
  closeDatabase eng.pager

-- Integrity check.

||| Verify every structure in the database and return the problems found:
||| each tree's invariants, agreement between every table and its indexes,
||| the free list, and that every page belongs to exactly one of them.
export
integrityCheck : Engine -> DB (List String)
integrityCheck eng = do
  problems <- newIORef (the (List String) [])
  used <- newIORef (the (SortedSet Int) (fromList [0]))
  schema <- readIORef eng.schemaRef
  catalog <- metaU32 eng.pager offCatalogRoot
  _ <- tree problems used "the catalog" catalog
  for_ (values schema.tables) $ \tbl => do
    tinfo <- tree problems used ("table " ++ tbl.name) tbl.root
    for_ (tableIndexes schema tbl.name) $ \idx => do
      iinfo <- tree problems used ("index " ++ idx.name) idx.root
      agree problems tbl idx tinfo iinfo
  free <- catchDB (freeListPages eng.pager)
            (\e => report problems ("free list: " ++ show e) >> pure [])
  claim problems used "the free list" (fromList free)
  count <- metaU32 eng.pager offPageCount
  seen <- readIORef used
  let lost = filter (\p => not (contains p seen)) (if count <= 0 then [] else [0 .. count - 1])
  when (not (isNil lost))
    (report problems (show (length lost) ++ " pages belong to nothing: " ++ show (take 10 lost)))
  let beyond = filter (>= count) (Prelude.toList seen)
  when (not (isNil beyond))
    (report problems ("pages beyond the end of the database are in use: " ++ show (take 10 beyond)))
  map reverse (readIORef problems)
  where
    report : IORef (List String) -> String -> DB ()
    report problems msg = modifyIORef problems (msg ::)

    claim : IORef (List String) -> IORef (SortedSet Int) -> (what : String) -> SortedSet Int -> DB ()
    claim problems used what pages = do
      seen <- readIORef used
      for_ (Prelude.toList pages) $ \p =>
        when (contains p seen)
          (report problems ("page " ++ show p ++ " is used by " ++ what ++ " and by something else"))
      writeIORef used (union seen pages)

    tree : IORef (List String) -> IORef (SortedSet Int) -> (what : String) -> (root : Int) -> DB (Maybe TreeInfo)
    tree problems used what root = catchDB
      (do info <- validate eng.pager root
          claim problems used what info.pages
          pure (Just info))
      (\e => report problems (what ++ ": " ++ show e) >> pure Nothing)

    -- Rows whose index entry is absent.
    unindexed : (tbl : TableDef) -> IndexDef -> DB (Maybe (Int64, Row (tableCtx tbl))) -> Int -> DB Int
    unindexed tbl idx rows n = do
      Just (rowid, row) <- rows | Nothing => pure n
      e <- indexEntry tbl idx row
      found <- lookup eng.pager idx.root !(entryKey e rowid)
      unindexed tbl idx rows (if isJust found then n else n + 1)

    agree : IORef (List String) -> TableDef -> IndexDef -> Maybe TreeInfo -> Maybe TreeInfo -> DB ()
    agree problems tbl idx (Just t) (Just i) = do
      when (t.entries /= i.entries)
        (report problems ("index " ++ idx.name ++ " has " ++ show i.entries ++ " entries, table "
                          ++ tbl.name ++ " has " ++ show t.entries ++ " rows"))
      missing <- catchDB
        (do rows <- tableRows (MkExec eng.pager [] eng.sorter) tbl [] FullScan []
            unindexed tbl idx rows 0)
        (\e => report problems ("index " ++ idx.name ++ ": " ++ show e) >> pure 0)
      when (missing > 0)
        (report problems (show missing ++ " rows of " ++ tbl.name ++ " have no entry in index " ++ idx.name))
    agree _ _ _ _ _ = pure ()

export
engineStats : Engine -> DB PagerStats
engineStats eng = pagerStats eng.pager

export
recoveryInfo : Engine -> RecoveryInfo
recoveryInfo eng = pagerRecovery eng.pager

||| Write committed pages to their page files and truncate the log.
export
checkpointNow : Engine -> DB ()
checkpointNow eng = do
  active <- liftIO (inTxn eng.pager)
  when' active (TxError "cannot checkpoint inside a transaction")
  checkpoint eng.pager

||| Sort runs written to disk since the database was opened.
export
sortRunsWritten : Engine -> IO Int
sortRunsWritten eng = readIORef eng.sorter.runsWritten
