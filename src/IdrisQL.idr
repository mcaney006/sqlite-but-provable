||| The IdrisQL library API.
|||
||| ```idris
||| main : IO ()
||| main = do
|||   Right () <- runDB $ do
|||       db <- openDatabase "shop.idb" defaultOptions
|||       _ <- execute db "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)" []
|||       _ <- execute db "INSERT INTO item (name) VALUES (?)" [VText "kettle"]
|||       rows <- query db "SELECT id, name FROM item WHERE name = ?" [VText "kettle"]
|||       all <- fetchAll rows
|||       printLn all
|||       closeDatabase db
|||     | Left e => putStrLn ("failed: " ++ show e)
|||   pure ()
||| ```
|||
||| Every operation runs in `DB`, which is `IO` with a `DbError` on failure.
||| `IdrisQL.Transaction.State` offers the same engine through a connection
||| type that tracks the transaction state at compile time.
module IdrisQL

import Data.SortedMap
import IdrisQL.Engine

import public IdrisQL.Catalog.Schema
import public IdrisQL.Error
import public IdrisQL.Options
import public IdrisQL.Types

||| An open database. One process can hold a database at a time.
export
data Database : Type where
  MkDatabase : Engine -> Database

||| The rows of a query. `next` yields one row per call and `Nothing` at
||| the end. The result is invalidated by the next statement run on the
||| same database.
public export
record ResultSet where
  constructor MkResultSet
  columns : List String
  types : List SqlType
  next : DB (Maybe (List Value))

||| A statement checked once and run many times with different parameters.
export
data Prepared : Type where
  MkPrepared : Statement -> Prepared

||| Open the database directory at `path`, creating it if needed. Opening
||| replays the write-ahead log if the previous process did not close
||| cleanly.
export
openDatabase : (path : String) -> Options -> DB Database
openDatabase path opts = map MkDatabase (openEngine path opts)

||| Roll back any open transaction, checkpoint, and release the database.
export
closeDatabase : Database -> DB ()
closeDatabase (MkDatabase eng) = closeEngine eng

toResultSet : Result -> ResultSet
toResultSet (Rows names types source) = MkResultSet names types source
toResultSet _ = MkResultSet [] [] (pure Nothing)

changed : Result -> Nat
changed (Changed n) = n
changed _ = 0

||| Run a statement and return the number of rows it inserted, updated or
||| deleted (zero for other statements). `params` supplies the values of
||| `?` placeholders in order; they are never interpreted as SQL.
export
execute : Database -> (sql : String) -> (params : List Value) -> DB Nat
execute (MkDatabase eng) sql params = map changed (Engine.execute eng sql params)

||| Run a query and return its rows as a stream.
export
query : Database -> (sql : String) -> (params : List Value) -> DB ResultSet
query (MkDatabase eng) sql params = map toResultSet (Engine.execute eng sql params)

||| Read every remaining row. Use `next` directly for results too large to
||| hold in memory.
export
fetchAll : ResultSet -> DB (List (List Value))
fetchAll rs = go []
  where
    go : List (List Value) -> DB (List (List Value))
    go acc = do
      Just row <- rs.next | Nothing => pure (reverse acc)
      go (row :: acc)

||| Call `f` on each remaining row and return how many there were.
export
forRows : ResultSet -> (f : List Value -> DB ()) -> DB Nat
forRows rs f = go 0
  where
    go : Nat -> DB Nat
    go n = do
      Just row <- rs.next | Nothing => pure n
      f row
      go (S n)

||| Parse and check a statement. Syntax, name and type errors are reported
||| here rather than at the first run.
export
prepare : Database -> (sql : String) -> DB Prepared
prepare (MkDatabase eng) sql = map MkPrepared (Engine.prepare eng sql)

||| The SQL type each parameter must have, by zero-based parameter index.
export
parameterTypes : Prepared -> DB (List (Nat, SqlType))
parameterTypes (MkPrepared st) = Engine.parameterTypes st

||| Run a prepared statement; returns the number of rows changed.
export
run : Prepared -> (params : List Value) -> DB Nat
run (MkPrepared st) params = map changed (runStatement st params)

||| Run a prepared query.
export
runQuery : Prepared -> (params : List Value) -> DB ResultSet
runQuery (MkPrepared st) params = map toResultSet (runStatement st params)

||| Start a transaction. Fails if one is already open.
export
begin : Database -> DB ()
begin (MkDatabase eng) = ignore (Engine.execute eng "BEGIN" [])

||| Commit the open transaction. When this returns the transaction will
||| survive the death of this process; see `Durability` for what it does
||| not survive.
export
commit : Database -> DB ()
commit (MkDatabase eng) = ignore (Engine.execute eng "COMMIT" [])

export
rollback : Database -> DB ()
rollback (MkDatabase eng) = ignore (Engine.execute eng "ROLLBACK" [])

||| True between `begin` and `commit` or `rollback`.
export
inTransaction : Database -> IO Bool
inTransaction (MkDatabase eng) = Engine.inTransaction eng

||| Run `body` in a transaction: commit if it succeeds, roll back if it
||| fails.
export
withTransaction : Database -> (body : DB a) -> DB a
withTransaction db body = do
  begin db
  r <- catchDB body $ \e => do
    active <- liftIO (inTransaction db)
    when active (catchDB (rollback db) (\_ => pure ()))
    throw e
  commit db
  pure r

||| The tables of the database.
export
tables : Database -> IO (List TableDef)
tables (MkDatabase eng) = map (\s => values s.tables) (currentSchema eng)

||| The indexes of the database.
export
indexes : Database -> IO (List IndexDef)
indexes (MkDatabase eng) = map (\s => values s.indexes) (currentSchema eng)

||| Verify every on-disk structure. An empty list means no problem found.
export
integrityCheck : Database -> DB (List String)
integrityCheck (MkDatabase eng) = Engine.integrityCheck eng

||| What a successful `commit` guarantees on this build.
export
durability : Database -> Durability
durability _ = FlushedToOS

||| What opening the database had to repair.
export
recovery : Database -> RecoveryInfo
recovery (MkDatabase eng) = recoveryInfo eng
