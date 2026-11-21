-- expect: Mismatch between
-- A reference to the second column of a one-column row.
import Data.List.Elem
import IdrisQL.SQL.Typed
import IdrisQL.Types

bad : TExpr [TInt] TInt
bad = Col TInt (There Here)
