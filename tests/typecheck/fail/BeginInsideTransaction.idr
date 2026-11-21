-- expect: Mismatch between: Active and Idle
-- Starting a transaction inside another.
import Control.Linear.LIO
import IdrisQL.Transaction.State

session : (1 _ : Conn Idle) -> L1 IO (Closed ())
session c0 = do
  Ok () c1 <- begin c0
    | Fail _ c => end c ()
  Ok () c2 <- begin c1
    | Fail _ c => end c ()
  Ok () c3 <- commit c2
    | Fail _ c => end c ()
  end c3 ()
