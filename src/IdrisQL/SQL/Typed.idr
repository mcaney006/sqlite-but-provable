module IdrisQL.SQL.Typed

import Data.List
import Data.List.Elem
import Data.Maybe
import Data.String
import IdrisQL.Error
import IdrisQL.Types

%default total

-- The checked representation of SQL expressions. A `TExpr ctx t` is an
-- expression over rows of shape `ctx` whose value has type `t`. Column
-- references are positions proven to exist in `ctx` with the right type,
-- so evaluation cannot meet an unknown column or a value of the wrong
-- type: those cases are not representable. What can still fail at run time
-- is listed in `eval`.

public export
data ArithOp = Add | Sub | Mul | Div | Mod

public export
data CmpOp = Eq | Ne | Lt | Le | Gt | Ge

public export
data IsNumeric : SqlType -> Type where
  NumInt  : IsNumeric TInt
  NumReal : IsNumeric TReal

public export
data TExpr : (ctx : List SqlType) -> (t : SqlType) -> Type where
  Lit      : (t : SqlType) -> Cell t -> TExpr ctx t
  Col      : (t : SqlType) -> Elem t ctx -> TExpr ctx t
  ||| A bound parameter, with the type its context requires.
  Param    : (t : SqlType) -> (index : Nat) -> TExpr ctx t
  Arith    : IsNumeric t -> ArithOp -> TExpr ctx t -> TExpr ctx t -> TExpr ctx t
  Neg      : IsNumeric t -> TExpr ctx t -> TExpr ctx t
  ToReal   : TExpr ctx TInt -> TExpr ctx TReal
  Concat   : TExpr ctx TText -> TExpr ctx TText -> TExpr ctx TText
  Cmp      : (t : SqlType) -> CmpOp -> TExpr ctx t -> TExpr ctx t -> TExpr ctx TBool
  And      : TExpr ctx TBool -> TExpr ctx TBool -> TExpr ctx TBool
  Or       : TExpr ctx TBool -> TExpr ctx TBool -> TExpr ctx TBool
  Not      : TExpr ctx TBool -> TExpr ctx TBool
  IsNull   : (t : SqlType) -> TExpr ctx t -> TExpr ctx TBool
  InList   : (t : SqlType) -> TExpr ctx t -> List (TExpr ctx t) -> TExpr ctx TBool
  Like     : TExpr ctx TText -> (pattern : TExpr ctx TText) -> TExpr ctx TBool
  Cast     : (from : SqlType) -> (to : SqlType) -> TExpr ctx from -> TExpr ctx to
  Length   : TExpr ctx TText -> TExpr ctx TInt
  Upper    : TExpr ctx TText -> TExpr ctx TText
  Lower    : TExpr ctx TText -> TExpr ctx TText
  Abs      : IsNumeric t -> TExpr ctx t -> TExpr ctx t
  Coalesce : (t : SqlType) -> List (TExpr ctx t) -> TExpr ctx t

||| A list of expressions over `ctx` whose types are `out`: a projection.
public export
data Exprs : (ctx : List SqlType) -> (out : List SqlType) -> Type where
  Nil  : Exprs ctx []
  (::) : TExpr ctx t -> Exprs ctx ts -> Exprs ctx (t :: ts)

public export
data Agg : (ctx : List SqlType) -> (res : SqlType) -> Type where
  CountStar : Agg ctx TInt
  Count     : (distinct : Bool) -> (t : SqlType) -> TExpr ctx t -> Agg ctx TInt
  Sum       : IsNumeric t -> (distinct : Bool) -> TExpr ctx t -> Agg ctx t
  Avg       : IsNumeric t -> (distinct : Bool) -> TExpr ctx t -> Agg ctx TReal
  Min       : (t : SqlType) -> TExpr ctx t -> Agg ctx t
  Max       : (t : SqlType) -> TExpr ctx t -> Agg ctx t

public export
data Aggs : (ctx : List SqlType) -> (out : List SqlType) -> Type where
  ANil  : Aggs ctx []
  ACons : Agg ctx t -> Aggs ctx ts -> Aggs ctx (t :: ts)

||| A runtime copy of a type index.
public export
data Sing : SqlType -> Type where
  MkSing : (t : SqlType) -> Sing t

export
numType : IsNumeric t -> Sing t
numType NumInt = MkSing TInt
numType NumReal = MkSing TReal

export
typeOf : TExpr ctx t -> Sing t
typeOf (Lit t _) = MkSing t
typeOf (Col t _) = MkSing t
typeOf (Param t _) = MkSing t
typeOf (Arith w _ _ _) = numType w
typeOf (Neg w _) = numType w
typeOf (ToReal _) = MkSing TReal
typeOf (Concat _ _) = MkSing TText
typeOf (Cmp _ _ _ _) = MkSing TBool
typeOf (And _ _) = MkSing TBool
typeOf (Or _ _) = MkSing TBool
typeOf (Not _) = MkSing TBool
typeOf (IsNull _ _) = MkSing TBool
typeOf (InList _ _ _) = MkSing TBool
typeOf (Like _ _) = MkSing TBool
typeOf (Cast _ to _) = MkSing to
typeOf (Length _) = MkSing TInt
typeOf (Upper _) = MkSing TText
typeOf (Lower _) = MkSing TText
typeOf (Abs w _) = numType w
typeOf (Coalesce t _) = MkSing t

-- Evaluation.

minInt : Integer
minInt = -9223372036854775808

maxInt : Integer
maxInt = 9223372036854775807

export
toInt64 : Integer -> Either DbError Int64
toInt64 x = if x >= minInt && x <= maxInt then Right (cast x)
            else Left (RuntimeError "integer overflow")

-- Division truncates toward zero and the remainder takes the sign of the
-- dividend, as in SQLite and C.
truncDiv : Integer -> Integer -> Integer
truncDiv a b = let q = abs a `div` abs b in if (a < 0) /= (b < 0) then negate q else q

arithInt : ArithOp -> Int64 -> Int64 -> Either DbError (Maybe Int64)
arithInt Add a b = map Just (toInt64 (cast a + cast b))
arithInt Sub a b = map Just (toInt64 (cast a - cast b))
arithInt Mul a b = map Just (toInt64 (cast a * cast b))
arithInt Div a b = if b == 0 then Right Nothing else map Just (toInt64 (truncDiv (cast a) (cast b)))
arithInt Mod a b = if b == 0 then Right Nothing
                   else map Just (toInt64 (cast a - cast b * truncDiv (cast a) (cast b)))

-- A REAL result that is NaN becomes NULL.
notNaN : Double -> Maybe Double
notNaN d = if d == d then Just d else Nothing

truncReal : Double -> Double
truncReal d = if d < 0 then ceiling d else floor d

arithReal : ArithOp -> Double -> Double -> Maybe Double
arithReal Add a b = notNaN (a + b)
arithReal Sub a b = notNaN (a - b)
arithReal Mul a b = notNaN (a * b)
arithReal Div a b = if b == 0 then Nothing else notNaN (a / b)
arithReal Mod a b = if b == 0 then Nothing else notNaN (a - b * truncReal (a / b))

arith : IsNumeric t -> ArithOp -> Val t -> Val t -> Either DbError (Cell t)
arith NumInt op a b = arithInt op a b
arith NumReal op a b = Right (arithReal op a b)

negate' : IsNumeric t -> Val t -> Either DbError (Cell t)
negate' NumInt a = map Just (toInt64 (negate (cast a)))
negate' NumReal a = Right (Just (negate a))

abs' : IsNumeric t -> Val t -> Either DbError (Cell t)
abs' NumInt a = map Just (toInt64 (abs (cast a)))
abs' NumReal a = Right (Just (abs a))

export
cmpHolds : CmpOp -> Ordering -> Bool
cmpHolds Eq o = o == EQ
cmpHolds Ne o = o /= EQ
cmpHolds Lt o = o == LT
cmpHolds Le o = o /= GT
cmpHolds Gt o = o == GT
cmpHolds Ge o = o /= LT

-- Three-valued logic: Nothing is UNKNOWN.
and3 : Maybe Bool -> Maybe Bool -> Maybe Bool
and3 (Just False) _ = Just False
and3 _ (Just False) = Just False
and3 (Just True) (Just True) = Just True
and3 _ _ = Nothing

or3 : Maybe Bool -> Maybe Bool -> Maybe Bool
or3 (Just True) _ = Just True
or3 _ (Just True) = Just True
or3 (Just False) (Just False) = Just False
or3 _ _ = Nothing

-- x IN (v1, ..): TRUE if some vi equals x, otherwise UNKNOWN if some vi is
-- NULL, otherwise FALSE.
inList : (t : SqlType) -> Val t -> List (Cell t) -> Maybe Bool
inList t a vs =
  if any (\v => case v of
                  Just b => compareVal t a b == EQ
                  Nothing => False) vs then Just True
  else if any isNothing vs then Nothing
  else Just False

||| LIKE: `%` matches any run of characters, `_` exactly one. Letters match
||| without regard to ASCII case.
export
likeMatch : (pattern : List Char) -> (text : List Char) -> Bool
likeMatch [] [] = True
likeMatch [] (_ :: _) = False
likeMatch pat@('%' :: ps) [] = likeMatch ps []
likeMatch pat@('%' :: ps) txt@(_ :: ts) = likeMatch ps txt || likeMatch pat ts
likeMatch ('_' :: ps) [] = False
likeMatch ('_' :: ps) (_ :: ts) = likeMatch ps ts
likeMatch (p :: ps) [] = False
likeMatch (p :: ps) (t :: ts) = toLower p == toLower t && likeMatch ps ts

||| The conversions CAST accepts.
export
castable : (from : SqlType) -> (to : SqlType) -> Bool
castable from to = from == to || case (from, to) of
  (TInt, TReal) => True
  (TInt, TText) => True
  (TInt, TBool) => True
  (TReal, TInt) => True
  (TReal, TText) => True
  (TText, TInt) => True
  (TText, TReal) => True
  (TBool, TInt) => True
  (TBool, TText) => True
  _ => False

castVal : (from : SqlType) -> (to : SqlType) -> Val from -> Either DbError (Cell to)
castVal TInt TInt x = Right (Just x)
castVal TInt TReal x = Right (Just (cast x))
castVal TInt TText x = Right (Just (show x))
castVal TInt TBool x = Right (Just (x /= 0))
castVal TReal TReal x = Right (Just x)
castVal TReal TInt x = if x == x then map Just (toInt64 (cast (truncReal x))) else Right Nothing
castVal TReal TText x = Right (Just (show x))
castVal TText TText x = Right (Just x)
castVal TText TInt x = case parseInteger {a = Integer} (trim x) of
  Just i => map Just (toInt64 i)
  Nothing => Left (RuntimeError ("cannot cast " ++ show x ++ " to INTEGER"))
castVal TText TReal x = case parseDouble (trim x) of
  Just d => Right (Just d)
  Nothing => Left (RuntimeError ("cannot cast " ++ show x ++ " to REAL"))
castVal TBool TBool x = Right (Just x)
castVal TBool TInt x = Right (Just (if x then 1 else 0))
castVal TBool TText x = Right (Just (if x then "TRUE" else "FALSE"))
castVal TBlob TBlob x = Right (Just x)
castVal from to _ = Left (RuntimeError ("cannot cast " ++ show from ++ " to " ++ show to))

mutual
  ||| Evaluate against one row. The only failures are: INTEGER overflow, a
  ||| CAST from text that does not parse, and a parameter that was not
  ||| bound or was bound with the wrong type (`bind` rules the last one out
  ||| before execution starts). Division by zero yields NULL.
  export
  eval : (params : List Value) -> Row ctx -> TExpr ctx t -> Either DbError (Cell t)
  eval ps row (Lit _ v) = Right v
  eval ps row (Col _ i) = Right (index i row)
  eval ps row (Param t i) = case getAt i ps of
    Nothing => Left (RuntimeError ("parameter ?" ++ show (S i) ++ " is not bound"))
    Just v => case fromValue t v of
      Just c => Right c
      Nothing => Left (RuntimeError ("parameter ?" ++ show (S i) ++ " is not of type " ++ show t))
  eval ps row (Arith w op a b) = do
    x <- eval ps row a
    y <- eval ps row b
    case (x, y) of
      (Just x', Just y') => arith w op x' y'
      _ => Right Nothing
  eval ps row (Neg w a) = do
    Just x <- eval ps row a | Nothing => Right Nothing
    negate' w x
  eval ps row (ToReal a) = map (map cast) (eval ps row a)
  eval ps row (Concat a b) = do
    x <- eval ps row a
    y <- eval ps row b
    Right [| x ++ y |]
  eval ps row (Cmp t op a b) = do
    x <- eval ps row a
    y <- eval ps row b
    case (x, y) of
      (Just x', Just y') => Right (Just (cmpHolds op (compareVal t x' y')))
      _ => Right Nothing
  eval ps row (And a b) = do
    x <- eval ps row a
    case x of
      Just False => Right (Just False)
      _ => map (and3 x) (eval ps row b)
  eval ps row (Or a b) = do
    x <- eval ps row a
    case x of
      Just True => Right (Just True)
      _ => map (or3 x) (eval ps row b)
  eval ps row (Not a) = map (map not) (eval ps row a)
  eval ps row (IsNull _ a) = map (Just . isNothing) (eval ps row a)
  eval ps row (InList t a xs) = do
    Just x <- eval ps row a | Nothing => Right Nothing
    vs <- evalAll ps row xs
    Right (inList t x vs)
  eval ps row (Like a p) = do
    x <- eval ps row a
    y <- eval ps row p
    Right [| likeMatch (map unpack y) (map unpack x) |]
  eval ps row (Cast from to a) = do
    Just x <- eval ps row a | Nothing => Right Nothing
    castVal from to x
  eval ps row (Length a) = map (map (cast . length)) (eval ps row a)
  eval ps row (Upper a) = map (map toUpper) (eval ps row a)
  eval ps row (Lower a) = map (map toLower) (eval ps row a)
  eval ps row (Abs w a) = do
    Just x <- eval ps row a | Nothing => Right Nothing
    abs' w x
  eval ps row (Coalesce _ xs) = do
    vs <- evalAll ps row xs
    Right (join (find isJust vs))

  evalAll : (params : List Value) -> Row ctx -> List (TExpr ctx t) -> Either DbError (List (Cell t))
  evalAll ps row [] = Right []
  evalAll ps row (x :: xs) = [| eval ps row x :: evalAll ps row xs |]

export
evalRow : (params : List Value) -> Row ctx -> Exprs ctx out -> Either DbError (Row out)
evalRow ps row [] = Right []
evalRow ps row (e :: es) = [| eval ps row e :: evalRow ps row es |]

-- Structural helpers used by the optimizer and planner.

mutual
  ||| Move an expression to another context by mapping its column
  ||| references. `Nothing` when some reference has no image.
  export
  rename : ({0 u : SqlType} -> Elem u a -> Maybe (Elem u b)) -> TExpr a t -> Maybe (TExpr b t)
  rename f (Lit t v) = Just (Lit t v)
  rename f (Col t i) = map (Col t) (f i)
  rename f (Param t i) = Just (Param t i)
  rename f (Arith w op x y) = do
    x' <- rename f x
    y' <- rename f y
    Just (Arith w op x' y')
  rename f (Neg w x) = map (Neg w) (rename f x)
  rename f (ToReal x) = map ToReal (rename f x)
  rename f (Concat x y) = [| Concat (rename f x) (rename f y) |]
  rename f (Cmp t op x y) = do
    x' <- rename f x
    y' <- rename f y
    Just (Cmp t op x' y')
  rename f (And x y) = [| And (rename f x) (rename f y) |]
  rename f (Or x y) = [| Or (rename f x) (rename f y) |]
  rename f (Not x) = map Not (rename f x)
  rename f (IsNull t x) = map (IsNull t) (rename f x)
  rename f (InList t x xs) = do
    x' <- rename f x
    xs' <- renameAll f xs
    Just (InList t x' xs')
  rename f (Like x p) = [| Like (rename f x) (rename f p) |]
  rename f (Cast from to x) = map (Cast from to) (rename f x)
  rename f (Length x) = map Length (rename f x)
  rename f (Upper x) = map Upper (rename f x)
  rename f (Lower x) = map Lower (rename f x)
  rename f (Abs w x) = map (Abs w) (rename f x)
  rename f (Coalesce t xs) = map (Coalesce t) (renameAll f xs)

  renameAll : ({0 u : SqlType} -> Elem u a -> Maybe (Elem u b)) -> List (TExpr a t) -> Maybe (List (TExpr b t))
  renameAll f [] = Just []
  renameAll f (x :: xs) = [| rename f x :: renameAll f xs |]

export
renameExprs : ({0 u : SqlType} -> Elem u a -> Maybe (Elem u b)) -> Exprs a out -> Maybe (Exprs b out)
renameExprs f [] = Just []
renameExprs f (e :: es) = [| rename f e :: renameExprs f es |]

mutual
  ||| Positions of the columns an expression reads.
  export
  colsUsed : TExpr ctx t -> List Nat
  colsUsed (Lit _ _) = []
  colsUsed (Col _ i) = [elemToNat i]
  colsUsed (Param _ _) = []
  colsUsed (Arith _ _ x y) = colsUsed x ++ colsUsed y
  colsUsed (Neg _ x) = colsUsed x
  colsUsed (ToReal x) = colsUsed x
  colsUsed (Concat x y) = colsUsed x ++ colsUsed y
  colsUsed (Cmp _ _ x y) = colsUsed x ++ colsUsed y
  colsUsed (And x y) = colsUsed x ++ colsUsed y
  colsUsed (Or x y) = colsUsed x ++ colsUsed y
  colsUsed (Not x) = colsUsed x
  colsUsed (IsNull _ x) = colsUsed x
  colsUsed (InList _ x xs) = colsUsed x ++ colsUsedAll xs
  colsUsed (Like x p) = colsUsed x ++ colsUsed p
  colsUsed (Cast _ _ x) = colsUsed x
  colsUsed (Length x) = colsUsed x
  colsUsed (Upper x) = colsUsed x
  colsUsed (Lower x) = colsUsed x
  colsUsed (Abs _ x) = colsUsed x
  colsUsed (Coalesce _ xs) = colsUsedAll xs

  colsUsedAll : List (TExpr ctx t) -> List Nat
  colsUsedAll [] = []
  colsUsedAll (x :: xs) = colsUsed x ++ colsUsedAll xs

mutual
  ||| Index and required type of every parameter in an expression.
  export
  paramsOf : TExpr ctx t -> List (Nat, SqlType)
  paramsOf (Lit _ _) = []
  paramsOf (Col _ _) = []
  paramsOf (Param t i) = [(i, t)]
  paramsOf (Arith _ _ x y) = paramsOf x ++ paramsOf y
  paramsOf (Neg _ x) = paramsOf x
  paramsOf (ToReal x) = paramsOf x
  paramsOf (Concat x y) = paramsOf x ++ paramsOf y
  paramsOf (Cmp _ _ x y) = paramsOf x ++ paramsOf y
  paramsOf (And x y) = paramsOf x ++ paramsOf y
  paramsOf (Or x y) = paramsOf x ++ paramsOf y
  paramsOf (Not x) = paramsOf x
  paramsOf (IsNull _ x) = paramsOf x
  paramsOf (InList _ x xs) = paramsOf x ++ paramsOfAll xs
  paramsOf (Like x p) = paramsOf x ++ paramsOf p
  paramsOf (Cast _ _ x) = paramsOf x
  paramsOf (Length x) = paramsOf x
  paramsOf (Upper x) = paramsOf x
  paramsOf (Lower x) = paramsOf x
  paramsOf (Abs _ x) = paramsOf x
  paramsOf (Coalesce _ xs) = paramsOfAll xs

  paramsOfAll : List (TExpr ctx t) -> List (Nat, SqlType)
  paramsOfAll [] = []
  paramsOfAll (x :: xs) = paramsOf x ++ paramsOfAll xs

export
paramsOfExprs : Exprs ctx out -> List (Nat, SqlType)
paramsOfExprs [] = []
paramsOfExprs (e :: es) = paramsOf e ++ paramsOfExprs es

export
aggInput : Agg ctx t -> List (Nat, SqlType)
aggInput CountStar = []
aggInput (Count _ _ e) = paramsOf e
aggInput (Sum _ _ e) = paramsOf e
aggInput (Avg _ _ e) = paramsOf e
aggInput (Min _ e) = paramsOf e
aggInput (Max _ e) = paramsOf e

export
aggCols : Agg ctx t -> List Nat
aggCols CountStar = []
aggCols (Count _ _ e) = colsUsed e
aggCols (Sum _ _ e) = colsUsed e
aggCols (Avg _ _ e) = colsUsed e
aggCols (Min _ e) = colsUsed e
aggCols (Max _ e) = colsUsed e

||| The conjuncts of a predicate, left to right.
export
conjuncts : TExpr ctx TBool -> List (TExpr ctx TBool)
conjuncts (And a b) = conjuncts a ++ conjuncts b
conjuncts e = [e]

export
conjoin : List (TExpr ctx TBool) -> Maybe (TExpr ctx TBool)
conjoin [] = Nothing
conjoin (e :: es) = Just (foldl And e es)

-- Constant folding and Boolean simplification.

||| The value of an expression that reads no column and no parameter.
export
constant : TExpr ctx t -> Maybe (Cell t)
constant e =
  if not (isNil (paramsOf e)) then Nothing
  else case rename {b = []} (\_ => Nothing) e of
    Nothing => Nothing
    Just closed => case eval [] [] closed of
      Right v => Just v
      Left _ => Nothing

fold : TExpr ctx t -> TExpr ctx t
fold e@(Lit _ _) = e
fold e = case constant e of
  Nothing => e
  Just v => let MkSing t = typeOf e in Lit t v

mutual
  ||| Evaluate constant subexpressions once and remove Boolean identities.
  ||| The result has the same type and the same value on every row; a
  ||| subexpression whose evaluation would fail is left in place so the
  ||| failure still happens at run time.
  export
  simplify : TExpr ctx t -> TExpr ctx t
  simplify (Arith w op x y) = fold (Arith w op (simplify x) (simplify y))
  simplify (Neg w x) = fold (Neg w (simplify x))
  simplify (ToReal x) = fold (ToReal (simplify x))
  simplify (Concat x y) = fold (Concat (simplify x) (simplify y))
  simplify (Cmp t op x y) = fold (Cmp t op (simplify x) (simplify y))
  simplify (And x y) = case (simplify x, simplify y) of
    (Lit TBool (Just True), b) => b
    (a, Lit TBool (Just True)) => a
    (Lit TBool (Just False), _) => Lit TBool (Just False)
    (_, Lit TBool (Just False)) => Lit TBool (Just False)
    (a, b) => fold (And a b)
  simplify (Or x y) = case (simplify x, simplify y) of
    (Lit TBool (Just False), b) => b
    (a, Lit TBool (Just False)) => a
    (Lit TBool (Just True), _) => Lit TBool (Just True)
    (_, Lit TBool (Just True)) => Lit TBool (Just True)
    (a, b) => fold (Or a b)
  simplify (Not x) = case simplify x of
    Not y => y
    a => fold (Not a)
  simplify (IsNull t x) = fold (IsNull t (simplify x))
  simplify (InList t x xs) = fold (InList t (simplify x) (simplifyAll xs))
  simplify (Like x p) = fold (Like (simplify x) (simplify p))
  simplify (Cast from to x) = fold (Cast from to (simplify x))
  simplify (Length x) = fold (Length (simplify x))
  simplify (Upper x) = fold (Upper (simplify x))
  simplify (Lower x) = fold (Lower (simplify x))
  simplify (Abs w x) = fold (Abs w (simplify x))
  simplify (Coalesce t xs) = fold (Coalesce t (simplifyAll xs))
  simplify e = e

  simplifyAll : List (TExpr ctx t) -> List (TExpr ctx t)
  simplifyAll [] = []
  simplifyAll (x :: xs) = simplify x :: simplifyAll xs

export
simplifyExprs : Exprs ctx out -> Exprs ctx out
simplifyExprs [] = []
simplifyExprs (e :: es) = simplify e :: simplifyExprs es

-- Rendering, for EXPLAIN.

arithText : ArithOp -> String
arithText Add = "+"
arithText Sub = "-"
arithText Mul = "*"
arithText Div = "/"
arithText Mod = "%"

export
cmpText : CmpOp -> String
cmpText Eq = "="
cmpText Ne = "<>"
cmpText Lt = "<"
cmpText Le = "<="
cmpText Gt = ">"
cmpText Ge = ">="

commas : List String -> String
commas = concat . intersperse ", "

mutual
  ||| SQL-like text of an expression; `name` gives the label of a column
  ||| position.
  export
  showExpr : (name : Nat -> String) -> TExpr ctx t -> String
  showExpr name (Lit t v) = case toValue t v of
    VText s => "'" ++ s ++ "'"
    other => renderValue other
  showExpr name (Col _ i) = name (elemToNat i)
  showExpr name (Param _ i) = "?" ++ show (S i)
  showExpr name (Arith _ op x y) = "(" ++ showExpr name x ++ " " ++ arithText op ++ " " ++ showExpr name y ++ ")"
  showExpr name (Neg _ x) = "-" ++ showExpr name x
  showExpr name (ToReal x) = showExpr name x
  showExpr name (Concat x y) = "(" ++ showExpr name x ++ " || " ++ showExpr name y ++ ")"
  showExpr name (Cmp _ op x y) = showExpr name x ++ " " ++ cmpText op ++ " " ++ showExpr name y
  showExpr name (And x y) = "(" ++ showExpr name x ++ " AND " ++ showExpr name y ++ ")"
  showExpr name (Or x y) = "(" ++ showExpr name x ++ " OR " ++ showExpr name y ++ ")"
  showExpr name (Not x) = "NOT (" ++ showExpr name x ++ ")"
  showExpr name (IsNull _ x) = showExpr name x ++ " IS NULL"
  showExpr name (InList _ x xs) = showExpr name x ++ " IN (" ++ commas (showAll name xs) ++ ")"
  showExpr name (Like x p) = showExpr name x ++ " LIKE " ++ showExpr name p
  showExpr name (Cast _ to x) = "CAST(" ++ showExpr name x ++ " AS " ++ show to ++ ")"
  showExpr name (Length x) = "LENGTH(" ++ showExpr name x ++ ")"
  showExpr name (Upper x) = "UPPER(" ++ showExpr name x ++ ")"
  showExpr name (Lower x) = "LOWER(" ++ showExpr name x ++ ")"
  showExpr name (Abs _ x) = "ABS(" ++ showExpr name x ++ ")"
  showExpr name (Coalesce _ xs) = "COALESCE(" ++ commas (showAll name xs) ++ ")"

  showAll : (name : Nat -> String) -> List (TExpr ctx t) -> List String
  showAll name [] = []
  showAll name (x :: xs) = showExpr name x :: showAll name xs

export
showAgg : (name : Nat -> String) -> Agg ctx t -> String
showAgg name CountStar = "COUNT(*)"
showAgg name (Count d _ e) = "COUNT(" ++ (if d then "DISTINCT " else "") ++ showExpr name e ++ ")"
showAgg name (Sum _ d e) = "SUM(" ++ (if d then "DISTINCT " else "") ++ showExpr name e ++ ")"
showAgg name (Avg _ d e) = "AVG(" ++ (if d then "DISTINCT " else "") ++ showExpr name e ++ ")"
showAgg name (Min _ e) = "MIN(" ++ showExpr name e ++ ")"
showAgg name (Max _ e) = "MAX(" ++ showExpr name e ++ ")"
