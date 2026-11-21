module IdrisQL.Types

import Data.List
import Data.List.Elem
import Data.String
import Decidable.Equality

%default total

||| Storage types of the IdrisQL dialect. NULL is not a type: a cell of any
||| type may be NULL (see `Cell`).
public export
data SqlType = TInt | TReal | TText | TBlob | TBool

public export
Eq SqlType where
  TInt == TInt = True
  TReal == TReal = True
  TText == TText = True
  TBlob == TBlob = True
  TBool == TBool = True
  _ == _ = False

public export
Show SqlType where
  show TInt = "INTEGER"
  show TReal = "REAL"
  show TText = "TEXT"
  show TBlob = "BLOB"
  show TBool = "BOOLEAN"

public export
DecEq SqlType where
  decEq TInt TInt = Yes Refl
  decEq TReal TReal = Yes Refl
  decEq TText TText = Yes Refl
  decEq TBlob TBlob = Yes Refl
  decEq TBool TBool = Yes Refl
  decEq TInt TReal = No (\case Refl impossible)
  decEq TInt TText = No (\case Refl impossible)
  decEq TInt TBlob = No (\case Refl impossible)
  decEq TInt TBool = No (\case Refl impossible)
  decEq TReal TInt = No (\case Refl impossible)
  decEq TReal TText = No (\case Refl impossible)
  decEq TReal TBlob = No (\case Refl impossible)
  decEq TReal TBool = No (\case Refl impossible)
  decEq TText TInt = No (\case Refl impossible)
  decEq TText TReal = No (\case Refl impossible)
  decEq TText TBlob = No (\case Refl impossible)
  decEq TText TBool = No (\case Refl impossible)
  decEq TBlob TInt = No (\case Refl impossible)
  decEq TBlob TReal = No (\case Refl impossible)
  decEq TBlob TText = No (\case Refl impossible)
  decEq TBlob TBool = No (\case Refl impossible)
  decEq TBool TInt = No (\case Refl impossible)
  decEq TBool TReal = No (\case Refl impossible)
  decEq TBool TText = No (\case Refl impossible)
  decEq TBool TBlob = No (\case Refl impossible)

||| The Idris type that represents a non-NULL value of a SQL type.
public export
Val : SqlType -> Type
Val TInt = Int64
Val TReal = Double
Val TText = String
Val TBlob = List Bits8
Val TBool = Bool

||| A possibly-NULL value.
public export
Cell : SqlType -> Type
Cell t = Maybe (Val t)

||| A row whose shape is fixed by a list of column types. A `Row ts` cannot
||| hold a value of the wrong type in any position.
public export
data Row : List SqlType -> Type where
  Nil  : Row []
  (::) : Cell t -> Row ts -> Row (t :: ts)

export
index : Elem t ts -> Row ts -> Cell t
index Here (x :: _) = x
index (There p) (_ :: xs) = index p xs

export
(++) : Row xs -> Row ys -> Row (xs ++ ys)
[] ++ r = r
(x :: l) ++ r = x :: (l ++ r)

export
splitRow : (xs : List SqlType) -> Row (xs ++ ys) -> (Row xs, Row ys)
splitRow [] r = ([], r)
splitRow (_ :: xs) (x :: r) = let (l, rest) = splitRow xs r in (x :: l, rest)

export
nullRow : (ts : List SqlType) -> Row ts
nullRow [] = []
nullRow (_ :: ts) = Nothing :: nullRow ts

||| A dynamically typed value, used at the API boundary (literals, bound
||| parameters, result cells).
public export
data Value = VNull | VInt Int64 | VReal Double | VText String | VBlob (List Bits8) | VBool Bool

public export
Eq Value where
  VNull == VNull = True
  VInt a == VInt b = a == b
  VReal a == VReal b = a == b
  VText a == VText b = a == b
  VBlob a == VBlob b = a == b
  VBool a == VBool b = a == b
  _ == _ = False

export
toValue : (t : SqlType) -> Cell t -> Value
toValue _ Nothing = VNull
toValue TInt (Just x) = VInt x
toValue TReal (Just x) = VReal x
toValue TText (Just x) = VText x
toValue TBlob (Just x) = VBlob x
toValue TBool (Just x) = VBool x

||| Convert a dynamic value to a cell of the requested type. INTEGER widens to
||| REAL; no other implicit conversion exists.
export
fromValue : (t : SqlType) -> Value -> Maybe (Cell t)
fromValue _ VNull = Just Nothing
fromValue TInt (VInt x) = Just (Just x)
fromValue TReal (VReal x) = Just (Just x)
fromValue TReal (VInt x) = Just (Just (cast x))
fromValue TText (VText x) = Just (Just x)
fromValue TBlob (VBlob x) = Just (Just x)
fromValue TBool (VBool x) = Just (Just x)
fromValue _ _ = Nothing

export
valueType : Value -> Maybe SqlType
valueType VNull = Nothing
valueType (VInt _) = Just TInt
valueType (VReal _) = Just TReal
valueType (VText _) = Just TText
valueType (VBlob _) = Just TBlob
valueType (VBool _) = Just TBool

export
compareVal : (t : SqlType) -> Val t -> Val t -> Ordering
compareVal TInt x y = compare x y
compareVal TReal x y = compare x y
compareVal TText x y = compare x y
compareVal TBlob x y = compare x y
compareVal TBool x y = compare x y

||| Total order used by ORDER BY, GROUP BY and DISTINCT: NULL sorts before
||| every non-NULL value and equals itself. This is not SQL `=`, which is
||| three-valued and lives in the expression evaluator.
export
compareCell : (t : SqlType) -> Cell t -> Cell t -> Ordering
compareCell _ Nothing Nothing = EQ
compareCell _ Nothing (Just _) = LT
compareCell _ (Just _) Nothing = GT
compareCell t (Just x) (Just y) = compareVal t x y

export
compareRow : (ts : List SqlType) -> Row ts -> Row ts -> Ordering
compareRow [] [] [] = EQ
compareRow (t :: ts) (x :: xs) (y :: ys) =
  case compareCell t x y of
    EQ => compareRow ts xs ys
    o => o

export
rowValues : (ts : List SqlType) -> Row ts -> List Value
rowValues [] [] = []
rowValues (t :: ts) (x :: xs) = toValue t x :: rowValues ts xs

hexDigit : Bits8 -> Char
hexDigit n = if n < 10 then chr (cast n + ord '0') else chr (cast n - 10 + ord 'A')

export
hexByte : Bits8 -> String
hexByte b = pack [hexDigit (b `div` 16), hexDigit (b `mod` 16)]

||| Text form used by the shell and by tests.
export
renderValue : Value -> String
renderValue VNull = "NULL"
renderValue (VInt i) = show i
renderValue (VReal d) = show d
renderValue (VText s) = s
renderValue (VBlob b) = "X'" ++ concatMap hexByte b ++ "'"
renderValue (VBool b) = if b then "TRUE" else "FALSE"

export
Show Value where
  show (VText s) = show s
  show v = renderValue v
