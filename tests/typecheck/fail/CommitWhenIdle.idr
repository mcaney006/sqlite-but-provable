-- expect: Mismatch between: Idle and Active
-- Committing with no transaction open.
import Control.Linear.LIO
import IdrisQL.Transaction.State

session : (1 _ : Conn Idle) -> L1 IO (Closed ())
session c0 = do
  Ok () c1 <- commit c0
    | Fail _ c => end c ()
  end c1 ()
