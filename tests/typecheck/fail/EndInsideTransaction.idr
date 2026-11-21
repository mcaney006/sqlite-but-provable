-- expect: Mismatch between: Active and Idle
-- Ending the session with a transaction still open.
import Control.Linear.LIO
import IdrisQL.Transaction.State

session : (1 _ : Conn Idle) -> L1 IO (Closed ())
session c0 = do
  Ok () c1 <- begin c0
    | Fail _ c => end c ()
  end c1 ()
