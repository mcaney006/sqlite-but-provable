module Tests.Typed

import Control.Linear.LIO
import IdrisQL.Transaction.State
import Tests.Harness

-- A session written against the typed connection API. That it compiles is
-- half of the test: the connection is threaded through every operation in
-- the state that operation requires and handed back idle at the end.

opts : Options
opts = MkOptions 32 4194304 False 200

session : (1 _ : Conn Idle) -> L1 IO (Closed (Either String ()))
session c0 = do
  Ok _ c1 <- execute c0 "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT UNIQUE)" []
    | Fail e c => end c (Left ("create: " ++ show e))
  Ok () c2 <- begin c1
    | Fail e c => end c (Left ("begin: " ++ show e))
  Ok _ c3 <- execute c2 "INSERT INTO t VALUES (1, 'a')" []
    | Fail e c => end c (Left ("insert: " ++ show e))
  Ok () c4 <- commit c3
    | Fail e c => end c (Left ("commit: " ++ show e))
  Ok () c5 <- begin c4
    | Fail e c => end c (Left ("second begin: " ++ show e))
  -- A statement that fails inside a transaction hands back an idle
  -- connection: the transaction is gone, and the type says so.
  Fail _ c6 <- execute c5 "INSERT INTO t VALUES (2, 'a')" []
    | Ok _ c => do
        Ok () c' <- rollback c
          | Fail _ c' => end c' (Left "rollback failed")
        end c' (Left "a duplicate insert succeeded")
  Ok reply c7 <- execute c6 "SELECT COUNT(*) FROM t" []
    | Fail e c => end c (Left ("count: " ++ show e))
  case reply of
    Table _ [[VInt 1]] => end c7 (Right ())
    _ => end c7 (Left "the table does not hold exactly the committed row")

export
typedTests : List Test
typedTests =
  [ MkTest "a typed session threads its transaction state" $ do
      path <- freshPath "typed.idb"
      r <- withDatabase path opts session
      pure $ case r of
        Left e => Left (show e)
        Right verdict => verdict
  ]
