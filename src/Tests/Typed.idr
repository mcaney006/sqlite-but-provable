module Tests.Typed

import Control.Linear.LIO
import IdrisQL.Error
import IdrisQL.Options
import IdrisQL.Transaction.State
import IdrisQL.Types
import Tests.Harness

-- A session written against the typed connection API. That it compiles is
-- the first half of the test: every connection is threaded through and
-- closed exactly once, in the state its operations require.

opts : Options
opts = MkOptions 32 4194304 False 200

-- Close the connection and report a failure.
giveUp : (1 _ : Conn Idle) -> String -> L IO (Either String ())
giveUp c why = do
  _ <- disconnect c
  pure (Left why)

session : String -> L IO (Either String ())
session path = do
  Connected c0 <- connect path opts
    | Refused e => pure (Left ("connect: " ++ show e))
  Ok _ c1 <- execute c0 "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT UNIQUE)" []
    | Fail e c => giveUp c ("create: " ++ show e)
  Ok () c2 <- begin c1
    | Fail e c => giveUp c ("begin: " ++ show e)
  Ok _ c3 <- execute c2 "INSERT INTO t VALUES (1, 'a')" []
    | Fail e c => giveUp c ("insert: " ++ show e)
  Ok () c4 <- commit c3
    | Fail e c => giveUp c ("commit: " ++ show e)
  Ok () c5 <- begin c4
    | Fail e c => giveUp c ("second begin: " ++ show e)
  -- A statement that fails inside a transaction hands back an idle
  -- connection: the transaction is gone, and the type says so.
  Fail _ c6 <- execute c5 "INSERT INTO t VALUES (2, 'a')" []
    | Ok _ c => do
        Ok () c' <- rollback c
          | Fail _ c' => giveUp c' "rollback failed"
        giveUp c' "a duplicate insert succeeded"
  Ok reply c7 <- execute c6 "SELECT COUNT(*) FROM t" []
    | Fail e c => giveUp c ("count: " ++ show e)
  Right () <- disconnect c7
    | Left e => pure (Left ("disconnect: " ++ show e))
  case reply of
    Table _ [[VInt 1]] => pure (Right ())
    _ => pure (Left "the table does not hold exactly the committed row")

export
typedTests : List Test
typedTests =
  [ MkTest "a typed session threads its transaction state" $ do
      path <- freshPath "typed.idb"
      LIO.run (session path)
  ]
