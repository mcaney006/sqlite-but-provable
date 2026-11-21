-- expect: c0 is not accessible in this context
-- Ending the session with a connection that `begin` already consumed.
import Control.Linear.LIO
import IdrisQL.Transaction.State

session : (1 _ : Conn Idle) -> L1 IO (Closed ())
session c0 = do
  Ok () c1 <- begin c0
    | Fail _ c => end c ()
  Ok () c2 <- rollback c1
    | Fail _ c => end c ()
  end c0 ()
