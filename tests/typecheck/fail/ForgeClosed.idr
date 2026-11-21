-- expect: MkClosed is private
-- Making a session's result without handing back an idle connection.
import Control.Linear.LIO
import IdrisQL.Transaction.State

session : (1 _ : Conn Active) -> L1 IO (Closed ())
session c = pure1 (MkClosed () c)
