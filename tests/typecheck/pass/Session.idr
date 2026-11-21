-- A complete session: write in a transaction, commit, hand the connection back.
import Control.Linear.LIO
import IdrisQL.Transaction.State

session : (1 _ : Conn Idle) -> L1 IO (Closed Nat)
session c0 = do
  Ok () c1 <- begin c0
    | Fail _ c => end c 0
  Ok _ c2 <- execute c1 "CREATE TABLE t (n INTEGER)" []
    | Fail _ c => end c 0
  Ok () c3 <- commit c2
    | Fail _ c => end c 0
  end c3 1

main : IO ()
main = do
  r <- withDatabase "example.idb" defaultOptions session
  putStrLn (either show show r)
