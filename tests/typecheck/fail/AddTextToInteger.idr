-- expect: Mismatch between: TText and TInt
-- Arithmetic between an INTEGER column and a TEXT literal.
import Data.List.Elem
import IdrisQL.SQL.Typed
import IdrisQL.Types

bad : TExpr [TInt] TInt
bad = Arith NumInt Add (Col TInt Here) (Lit TText (Just "1"))
