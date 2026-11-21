module IdrisQL.Transaction.State

import Control.Linear.LIO
import IdrisQL.Engine
import IdrisQL.SQL.AST
import IdrisQL.SQL.Parser

import public IdrisQL.Error
import public IdrisQL.Options
import public IdrisQL.Types

-- A connection whose type says whether a transaction is open, held
-- linearly inside a session. The compiler rejects a session that:
--
--   commits or rolls back when no transaction is open,
--   begins a transaction inside another,
--   ends with a transaction still open,
--   uses a connection again after an operation has consumed it, or
--   ends without handing its connection back.
--
-- The last point does not rest on the linearity checker alone. A session
-- returns a `Closed`, and the only way to make one is `end`, which takes
-- the idle connection. tests/typecheck holds a program for each rejected
-- case; docs/PROOFS.md says what each guarantee rests on.

public export
data TxState = Idle | Active

||| A database connection in transaction state `s`. It cannot be copied or
||| discarded: every function that takes one returns its successor.
export
data Conn : TxState -> Type where
  MkConn : Engine -> Conn s

||| The result of an operation, together with the connection in the state
||| the operation left it in. A failure always leaves it idle: if a
||| transaction was open, it has been rolled back.
public export
data Outcome : (ok : TxState) -> Type -> Type where
  Ok   : (value : a) -> (1 conn : Conn ok) -> Outcome ok a
  Fail : (error : DbError) -> (1 conn : Conn Idle) -> Outcome ok a

public export
data Reply
  = ||| Column names and all rows of a query.
    Table (List String) (List (List Value))
  | ||| Rows changed by INSERT, UPDATE or DELETE.
    Count Nat
  | Finished

||| What a session returns: its result, and proof that it gave back an
||| idle connection. `end` is the only way to make one.
export
data Closed : Type -> Type where
  MkClosed : (result : a) -> (1 conn : Conn Idle) -> Closed a

||| End the session. Only an idle connection can end it, so a session
||| cannot finish with a transaction open.
export
end : (1 conn : Conn Idle) -> (result : a) -> L1 IO (Closed a)
end conn result = pure1 (MkClosed result conn)

||| Open the database at `path`, run `session` on its connection, and close
||| it. The result is `Left` when the database cannot be opened or closed.
export
withDatabase : (path : String) -> Options -> (session : (1 conn : Conn Idle) -> L1 IO (Closed a)) ->
               IO (Either DbError a)
withDatabase path opts session = do
  Right eng <- runDB (openEngine path opts)
    | Left e => pure (Left e)
  run $ do
    MkClosed result (MkConn used) <- session (MkConn eng)
    closed <- liftIO1 (runDB (closeEngine used))
    pure (map (const result) closed)

-- Roll back the transaction a failed operation may have left open.
settle : Engine -> IO ()
settle eng = do
  active <- inTransaction eng
  when active (ignore (runDB (Engine.execute eng "ROLLBACK" [])))

-- Run a transaction-control statement and move to `next` on success.
control : Engine -> (sql : String) -> L1 IO (Outcome next ())
control eng sql = do
  r <- liftIO1 (runDB (Engine.execute eng sql []))
  case r of
    Right _ => pure1 (Ok () (MkConn eng))
    Left e => do
      () <- liftIO1 (settle eng)
      pure1 (Fail e (MkConn eng))

export
begin : (1 conn : Conn Idle) -> L1 IO (Outcome Active ())
begin (MkConn eng) = control eng "BEGIN"

export
commit : (1 conn : Conn Active) -> L1 IO (Outcome Idle ())
commit (MkConn eng) = control eng "COMMIT"

export
rollback : (1 conn : Conn Active) -> L1 IO (Outcome Idle ())
rollback (MkConn eng) = control eng "ROLLBACK"

isControl : Stmt -> Bool
isControl SBegin = True
isControl SCommit = True
isControl SRollback = True
isControl _ = False

drain : DB (Maybe (List Value)) -> List (List Value) -> DB (List (List Value))
drain source acc = do
  Just row <- source | Nothing => pure (reverse acc)
  drain source (row :: acc)

runSql : Engine -> String -> List Value -> DB Reply
runSql eng sql params = do
  stmt <- liftE (parseStatement sql)
  when' (isControl stmt)
    (TxError "use begin, commit and rollback; transaction statements would bypass the connection's type")
  r <- Engine.execute eng sql params
  case r of
    Rows names _ source => map (Table names) (drain source [])
    Changed n => pure (Count n)
    Done _ => pure Finished

||| Run one statement. It keeps the transaction state it was called in. If
||| it fails inside a transaction, the transaction is rolled back and the
||| connection comes back idle.
export
execute : (1 conn : Conn s) -> (sql : String) -> (params : List Value) -> L1 IO (Outcome s Reply)
execute (MkConn eng) sql params = do
  r <- liftIO1 (runDB (runSql eng sql params))
  case r of
    Right reply => pure1 (Ok reply (MkConn eng))
    Left e => do
      () <- liftIO1 (settle eng)
      pure1 (Fail e (MkConn eng))
