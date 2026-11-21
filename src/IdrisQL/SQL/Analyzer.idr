module IdrisQL.SQL.Analyzer

import Data.Either
import Data.List
import Data.List.Elem
import Data.Maybe
import Data.String
import Decidable.Equality
import IdrisQL.Catalog.Schema
import IdrisQL.Error
import IdrisQL.Query.Algebra
import IdrisQL.SQL.AST
import IdrisQL.SQL.Typed
import IdrisQL.Types

-- Name resolution and type checking: unresolved `Expr` in, `TExpr` out.
-- Everything that can be wrong with a statement short of its data (unknown
-- or ambiguous names, type mismatches, misplaced aggregates) is reported
-- here, before any row is read.

export
err : Pos -> String -> DbError
err p msg = SemanticError (msg ++ " (at " ++ show p ++ ")")

||| The columns visible to an expression, in row order.
public export
data Scope : List SqlType -> Type where
  Empty : Scope []
  Bind  : (qualifier : Maybe String) -> (name : String) -> (t : SqlType) -> Scope ts -> Scope (t :: ts)

export
scopeAppend : Scope xs -> Scope ys -> Scope (xs ++ ys)
scopeAppend Empty s = s
scopeAppend (Bind q n t rest) s = Bind q n t (scopeAppend rest s)

export
tableScope : (label : String) -> (cols : List ColumnDef) -> Scope (map (.type) cols)
tableScope label [] = Empty
tableScope label (c :: cs) = Bind (Just label) c.name c.type (tableScope label cs)

||| A scope with no names; no column reference resolves in it.
export
anonymous : (ts : List SqlType) -> Scope ts
anonymous [] = Empty
anonymous (t :: ts) = Bind Nothing "" t (anonymous ts)

export
scopeColumns : Scope ts -> List (Maybe String, String)
scopeColumns Empty = []
scopeColumns (Bind q n _ rest) = (q, n) :: scopeColumns rest

||| A column position together with its type.
public export
data Found : List SqlType -> Type where
  MkFound : (t : SqlType) -> Elem t ctx -> Found ctx

shift : Found ts -> Found (t :: ts)
shift (MkFound u i) = MkFound u (There i)

findCols : Scope ctx -> (qualifier : Maybe String) -> (name : String) -> List (Found ctx)
findCols Empty _ _ = []
findCols (Bind q n t rest) qual name =
  let more = map shift (findCols rest qual name)
      nameOk = n /= "" && norm n == norm name
      qualOk = case qual of
                 Nothing => True
                 Just want => map norm q == Just (norm want)
  in if nameOk && qualOk then MkFound t Here :: more else more

||| The position of an unqualified column name, when exactly one matches.
export
resolveColumn : Scope ctx -> (name : String) -> Maybe (Found ctx)
resolveColumn scope name = case findCols scope Nothing name of
  [found] => Just found
  _ => Nothing

export
nthElem : (ts : List SqlType) -> Nat -> Maybe (Found ts)
nthElem [] _ = Nothing
nthElem (t :: ts) Z = Just (MkFound t Here)
nthElem (t :: ts) (S k) = map shift (nthElem ts k)

||| An expression of some type.
public export
data Typed : List SqlType -> Type where
  MkTyped : (t : SqlType) -> TExpr ctx t -> Typed ctx

public export
record Env (ctx : List SqlType) where
  constructor MkEnv
  scope : Scope ctx
  ||| Consulted for every node before the ordinary rules. Grouped queries
  ||| use it to turn grouping expressions and aggregate calls into
  ||| references to the aggregate operator's output.
  hook : Expr -> Maybe (Either DbError (Typed ctx))

export
plainEnv : Scope ctx -> Env ctx
plainEnv s = MkEnv s (\_ => Nothing)

export
isAggName : String -> Bool
isAggName n = n `elem` ["COUNT", "SUM", "AVG", "MIN", "MAX"]

-- NULL and parameters have no type of their own; they take the type their
-- context requires.
flexible : Expr -> Bool
flexible (ELit _ LNull) = True
flexible (EParam _ _) = True
flexible _ = False

isLiteral : Expr -> Bool
isLiteral (ELit _ _) = True
isLiteral (ENeg _ (ELit _ _)) = True
isLiteral _ = False

intLit : Pos -> Integer -> Either DbError Int64
intLit p i = case toInt64 i of
  Right v => Right v
  Left _ => Left (err p ("integer literal " ++ show i ++ " is outside the 64-bit range"))

numeric : Pos -> (t : SqlType) -> Either DbError (IsNumeric t)
numeric p TInt = Right NumInt
numeric p TReal = Right NumReal
numeric p t = Left (err p ("expected a number but found " ++ show t))

coerce : Pos -> (t : SqlType) -> Typed ctx -> Either DbError (TExpr ctx t)
coerce p TReal (MkTyped TInt x) = Right (ToReal x)
coerce p t (MkTyped u x) = case decEq u t of
  Yes Refl => Right x
  No _ => Left (err p ("expected " ++ show t ++ " but found " ++ show u))

-- Give two operands a common type; INTEGER widens to REAL.
promote : Pos -> (what : String) -> (ta : SqlType) -> TExpr ctx ta -> (tb : SqlType) -> TExpr ctx tb ->
          Either DbError (t : SqlType ** (TExpr ctx t, TExpr ctx t))
promote p what TInt x TReal y = Right (TReal ** (ToReal x, y))
promote p what TReal x TInt y = Right (TReal ** (x, ToReal y))
promote p what ta x tb y = case decEq ta tb of
  Yes Refl => Right (ta ** (x, y))
  No _ => Left (err p ("cannot " ++ what ++ " " ++ show ta ++ " and " ++ show tb))

arithOp : BinOp -> Maybe ArithOp
arithOp OAdd = Just Add
arithOp OSub = Just Sub
arithOp OMul = Just Mul
arithOp ODiv = Just Div
arithOp OMod = Just Mod
arithOp _ = Nothing

cmpOp : BinOp -> Maybe CmpOp
cmpOp OEq = Just Eq
cmpOp ONe = Just Ne
cmpOp OLt = Just Lt
cmpOp OLe = Just Le
cmpOp OGt = Just Gt
cmpOp OGe = Just Ge
cmpOp _ = Nothing

realMod : ArithOp -> IsNumeric t -> Bool
realMod Mod NumReal = True
realMod _ _ = False

showCol : Maybe String -> String -> String
showCol Nothing n = n
showCol (Just q) n = q ++ "." ++ n

mutual
  ||| The type of an expression and its checked form.
  export
  infer : Env ctx -> Expr -> Either DbError (Typed ctx)
  infer env e = case env.hook e of
    Just r => r
    Nothing => inferNode env e

  ||| Check an expression against a required type.
  export
  check : Env ctx -> (t : SqlType) -> Expr -> Either DbError (TExpr ctx t)
  check env t e = case env.hook e of
    Just r => r >>= coerce (exprPos e) t
    Nothing => checkNode env t e

  checkNode : Env ctx -> (t : SqlType) -> Expr -> Either DbError (TExpr ctx t)
  checkNode env t (ELit _ LNull) = Right (Lit t Nothing)
  checkNode env t (EParam _ i) = Right (Param t i)
  -- 0 and 1 are accepted where a BOOLEAN is required, as in SQLite.
  checkNode env TBool (ELit _ (LInt 0)) = Right (Lit TBool (Just False))
  checkNode env TBool (ELit _ (LInt 1)) = Right (Lit TBool (Just True))
  checkNode env t e = inferNode env e >>= coerce (exprPos e) t

  checkAll : Env ctx -> (t : SqlType) -> List Expr -> Either DbError (List (TExpr ctx t))
  checkAll env t [] = Right []
  checkAll env t (e :: es) = [| check env t e :: checkAll env t es |]

  -- The type of `a`, taken from the first typed expression in `others`
  -- when `a` itself has none.
  inferWith : Env ctx -> Expr -> (others : List Expr) -> Either DbError (Typed ctx)
  inferWith env a [] = infer env a
  inferWith env a (x :: xs) =
    if flexible a
      then if flexible x then inferWith env a xs
           else do MkTyped t _ <- infer env x
                   y <- check env t a
                   Right (MkTyped t y)
      else infer env a

  operands : Env ctx -> Pos -> (what : String) -> Expr -> Expr ->
             Either DbError (t : SqlType ** (TExpr ctx t, TExpr ctx t))
  operands env p what a b =
    if flexible a || (isLiteral a && not (isLiteral b))
      then do
        MkTyped t y <- infer env b
        case check env t a of
          Right x => Right (t ** (x, y))
          Left _ => do MkTyped ta x <- infer env a
                       promote p what ta x t y
      else do
        MkTyped t x <- infer env a
        case check env t b of
          Right y => Right (t ** (x, y))
          Left e => if flexible b then Left e
                    else do MkTyped tb y <- infer env b
                            promote p what t x tb y

  binary : Env ctx -> Pos -> BinOp -> Expr -> Expr -> Either DbError (Typed ctx)
  binary env p OAnd a b = do
    x <- check env TBool a
    y <- check env TBool b
    Right (MkTyped TBool (And x y))
  binary env p OOr a b = do
    x <- check env TBool a
    y <- check env TBool b
    Right (MkTyped TBool (Or x y))
  binary env p OConcat a b = do
    x <- check env TText a
    y <- check env TText b
    Right (MkTyped TText (Concat x y))
  binary env p op a b = case arithOp op of
    Just aop => do
      (t ** (x, y)) <- operands env p "combine" a b
      w <- numeric p t
      if realMod aop w then Left (err p "% needs INTEGER operands")
        else Right (MkTyped t (Arith w aop x y))
    Nothing => case cmpOp op of
      Just cop => do
        (t ** (x, y)) <- operands env p "compare" a b
        Right (MkTyped TBool (Cmp t cop x y))
      Nothing => Left (err p "unsupported operator")

  call : Env ctx -> Pos -> (name : String) -> List Expr -> Either DbError (Typed ctx)
  call env p "LENGTH" [a] = do
    x <- check env TText a
    Right (MkTyped TInt (Length x))
  call env p "UPPER" [a] = do
    x <- check env TText a
    Right (MkTyped TText (Upper x))
  call env p "LOWER" [a] = do
    x <- check env TText a
    Right (MkTyped TText (Lower x))
  call env p "ABS" [a] = do
    MkTyped t x <- infer env a
    w <- numeric p t
    Right (MkTyped t (Abs w x))
  call env p "COALESCE" (a :: rest) = do
    MkTyped t x <- inferWith env a rest
    ys <- checkAll env t rest
    Right (MkTyped t (Coalesce t (x :: ys)))
  call env p name _ =
    if name `elem` ["LENGTH", "UPPER", "LOWER", "ABS", "COALESCE"]
      then Left (err p ("wrong number of arguments to " ++ name))
      else Left (err p ("no such function: " ++ name))

  inferNode : Env ctx -> Expr -> Either DbError (Typed ctx)
  inferNode env (ELit p LNull) = Right (MkTyped TInt (Lit TInt Nothing))
  inferNode env (ELit p (LInt i)) = do
    v <- intLit p i
    Right (MkTyped TInt (Lit TInt (Just v)))
  inferNode env (ELit p (LReal d)) = Right (MkTyped TReal (Lit TReal (Just d)))
  inferNode env (ELit p (LText s)) = Right (MkTyped TText (Lit TText (Just s)))
  inferNode env (ELit p (LBlob b)) = Right (MkTyped TBlob (Lit TBlob (Just b)))
  inferNode env (ELit p (LBool b)) = Right (MkTyped TBool (Lit TBool (Just b)))
  inferNode env (ECol p q n) = case findCols env.scope q n of
    [MkFound t i] => Right (MkTyped t (Col t i))
    [] => Left (err p ("no such column: " ++ showCol q n))
    _ => Left (err p ("ambiguous column name: " ++ showCol q n))
  inferNode env (EParam p i) =
    Left (err p ("cannot tell the type of parameter ?" ++ show (S i) ++ "; write CAST(? AS type)"))
  -- -9223372036854775808 lexes as the negation of an out-of-range literal.
  inferNode env (ENeg p (ELit _ (LInt i))) = do
    v <- intLit p (negate i)
    Right (MkTyped TInt (Lit TInt (Just v)))
  inferNode env (ENeg p a) = do
    MkTyped t x <- infer env a
    w <- numeric p t
    Right (MkTyped t (Neg w x))
  inferNode env (ENot p a) = do
    x <- check env TBool a
    Right (MkTyped TBool (Not x))
  inferNode env (EBin p op a b) = binary env p op a b
  inferNode env (EIsNull p neg a) = do
    MkTyped t x <- infer env a
    let e = IsNull t x
    Right (MkTyped TBool (if neg then Not e else e))
  inferNode env (EIn p neg a xs) = do
    MkTyped t x <- inferWith env a xs
    ys <- checkAll env t xs
    let e = InList t x ys
    Right (MkTyped TBool (if neg then Not e else e))
  inferNode env (EBetween p neg a lo hi) = do
    (t1 ** (x1, l)) <- operands env p "compare" a lo
    (t2 ** (x2, h)) <- operands env p "compare" a hi
    let e = And (Cmp t1 Ge x1 l) (Cmp t2 Le x2 h)
    Right (MkTyped TBool (if neg then Not e else e))
  inferNode env (ELike p neg a pat) = do
    x <- check env TText a
    y <- check env TText pat
    let e = Like x y
    Right (MkTyped TBool (if neg then Not e else e))
  inferNode env (ECast p a to) =
    if flexible a then map (MkTyped to) (check env to a)
    else do
      MkTyped from x <- infer env a
      if castable from to then Right (MkTyped to (Cast from to x))
        else Left (err p ("cannot cast " ++ show from ++ " to " ++ show to))
  inferNode env (ECall p name distinct args) =
    if isAggName name then Left (err p ("aggregate function " ++ name ++ " is not allowed here"))
    else if distinct then Left (err p "DISTINCT is only valid inside an aggregate function")
    else call env p name args
  inferNode env (ECountStar p) = Left (err p "aggregate function COUNT is not allowed here")

||| Check a constant expression: one that reads no column.
export
checkConstant : (t : SqlType) -> Expr -> Either DbError (TExpr [] t)
checkConstant t e = check (plainEnv Empty) t e

-- Aggregates.

mutual
  -- The outermost aggregate calls inside an expression.
  aggCalls : Expr -> List Expr
  aggCalls e@(ECountStar _) = [e]
  aggCalls e@(ECall _ name _ args) = if isAggName name then [e] else aggCallsAll args
  aggCalls (EBin _ _ a b) = aggCalls a ++ aggCalls b
  aggCalls (ENeg _ a) = aggCalls a
  aggCalls (ENot _ a) = aggCalls a
  aggCalls (EIsNull _ _ a) = aggCalls a
  aggCalls (EIn _ _ a xs) = aggCalls a ++ aggCallsAll xs
  aggCalls (EBetween _ _ a lo hi) = aggCalls a ++ aggCalls lo ++ aggCalls hi
  aggCalls (ELike _ _ a p) = aggCalls a ++ aggCalls p
  aggCalls (ECast _ a _) = aggCalls a
  aggCalls _ = []

  aggCallsAll : List Expr -> List Expr
  aggCallsAll [] = []
  aggCallsAll (x :: xs) = aggCalls x ++ aggCallsAll xs

dedupe : List Expr -> List Expr
dedupe = nubBy sameExpr

data TypedAgg : List SqlType -> Type where
  MkTypedAgg : (t : SqlType) -> Agg ctx t -> TypedAgg ctx

typeAgg : Env ctx -> Expr -> Either DbError (TypedAgg ctx)
typeAgg env (ECountStar _) = Right (MkTypedAgg TInt CountStar)
typeAgg env (ECall p "COUNT" d [a]) = do
  MkTyped t x <- infer env a
  Right (MkTypedAgg TInt (Count d t x))
typeAgg env (ECall p "SUM" d [a]) = do
  MkTyped t x <- infer env a
  w <- numeric p t
  Right (MkTypedAgg t (Sum w d x))
typeAgg env (ECall p "AVG" d [a]) = do
  MkTyped t x <- infer env a
  w <- numeric p t
  Right (MkTypedAgg TReal (Avg w d x))
typeAgg env (ECall p "MIN" _ [a]) = do
  MkTyped t x <- infer env a
  Right (MkTypedAgg t (Min t x))
typeAgg env (ECall p "MAX" _ [a]) = do
  MkTyped t x <- infer env a
  Right (MkTypedAgg t (Max t x))
typeAgg env (ECall p name _ _) = Left (err p (name ++ " takes exactly one argument"))
typeAgg env e = Left (err (exprPos e) "not an aggregate function")

data SomeAggs : List SqlType -> Type where
  MkSomeAggs : (rs : List SqlType) -> Aggs ctx rs -> SomeAggs ctx

typeAggs : Env ctx -> List Expr -> Either DbError (SomeAggs ctx)
typeAggs env [] = Right (MkSomeAggs [] ANil)
typeAggs env (e :: es) = do
  MkTypedAgg t a <- typeAgg env e
  MkSomeAggs ts rest <- typeAggs env es
  Right (MkSomeAggs (t :: ts) (ACons a rest))

public export
data SomeExprs : List SqlType -> Type where
  MkSomeExprs : (out : List SqlType) -> Exprs ctx out -> SomeExprs ctx

export
inferAll : Env ctx -> List Expr -> Either DbError (SomeExprs ctx)
inferAll env [] = Right (MkSomeExprs [] [])
inferAll env (e :: es) = do
  MkTyped t x <- infer env e
  MkSomeExprs ts xs <- inferAll env es
  Right (MkSomeExprs (t :: ts) (x :: xs))

indexWhere : (a -> Bool) -> List a -> Maybe Nat
indexWhere f xs = go 0 xs
  where
    go : Nat -> List a -> Maybe Nat
    go _ [] = Nothing
    go i (y :: ys) = if f y then Just i else go (S i) ys

-- The position a plain column reference resolves to.
colPos : Scope ctx -> Expr -> Maybe Nat
colPos scope (ECol _ q n) = case findCols scope q n of
  [MkFound _ el] => Just (elemToNat el)
  _ => Nothing
colPos _ _ = Nothing

-- The environment above an aggregate operator. Its row is the grouping
-- values followed by the aggregate results; an expression may use a
-- grouping expression, an aggregate call, or constants, and nothing else.
groupedEnv : Scope ctx -> (keys : List Expr) -> (aggs : List Expr) ->
             (gs : List SqlType) -> (rs : List SqlType) -> Env (gs ++ rs)
groupedEnv scope keys aggs gs rs = MkEnv (anonymous (gs ++ rs)) hook
  where
    slot : Nat -> Maybe (Either DbError (Typed (gs ++ rs)))
    slot i = map (\(MkFound t el) => Right (MkTyped t (Col t el))) (nthElem (gs ++ rs) i)

    hook : Expr -> Maybe (Either DbError (Typed (gs ++ rs)))
    hook e = case indexWhere (sameExpr e) keys of
      Just i => slot i
      Nothing => case indexWhere (sameExpr e) aggs of
        Just j => slot (length keys + j)
        Nothing => case e of
          ECol p q n => case colPos scope e of
            Nothing => Nothing
            Just pos => case indexWhere (\k => colPos scope k == Just pos) keys of
              Just i => slot i
              Nothing => Just (Left (err p ("column " ++ showCol q n
                           ++ " must appear in GROUP BY or inside an aggregate function")))
          _ => Nothing

-- FROM clause.

data Source : Type where
  MkSource : (ctx : List SqlType) -> Scope ctx -> (labels : List String) -> LPlan ctx -> Source

tableSource : Schema -> TableRef -> Either DbError Source
tableSource schema ref = case findTable schema ref.table of
  Nothing => Left (err ref.pos ("no such table: " ++ ref.table))
  Just tbl =>
    let label = fromMaybe tbl.name ref.alias
    in Right (MkSource (tableCtx tbl) (tableScope label tbl.columns) [norm label] (LScan tbl label))

addJoins : Schema -> Source -> List Join -> Either DbError Source
addJoins schema src [] = Right src
addJoins schema (MkSource a sa labels pa) (j :: js) = do
  MkSource b sb [label] pb <- tableSource schema j.ref
    | _ => Left (err j.ref.pos "internal: a table reference produced several labels")
  when (label `elem` labels)
    (Left (err j.ref.pos ("table name " ++ label ++ " is used twice; give one an alias")))
  let scope = scopeAppend sa sb
  on <- case j.on of
          Nothing => Right Nothing
          Just e => map Just (check (plainEnv scope) TBool e)
  addJoins schema (MkSource (a ++ b) scope (label :: labels) (LJoin j.kind pa pb on)) js

-- Select list.

mutual
  -- A readable label for a result column that has no alias.
  labelOf : Expr -> String
  labelOf (ELit _ l) = renderLiteral l
  labelOf (ECol _ q n) = n
  labelOf (EParam _ i) = "?" ++ show (S i)
  labelOf (EBin _ op a b) = labelOf a ++ " " ++ opText op ++ " " ++ labelOf b
  labelOf (ENeg _ a) = "-" ++ labelOf a
  labelOf (ENot _ a) = "NOT " ++ labelOf a
  labelOf (EIsNull _ n a) = labelOf a ++ (if n then " IS NOT NULL" else " IS NULL")
  labelOf (EIn _ n a xs) = labelOf a ++ (if n then " NOT IN (" else " IN (") ++ labelsOf xs ++ ")"
  labelOf (EBetween _ n a lo hi) =
    labelOf a ++ (if n then " NOT BETWEEN " else " BETWEEN ") ++ labelOf lo ++ " AND " ++ labelOf hi
  labelOf (ELike _ n a p) = labelOf a ++ (if n then " NOT LIKE " else " LIKE ") ++ labelOf p
  labelOf (ECast _ a t) = "CAST(" ++ labelOf a ++ " AS " ++ show t ++ ")"
  labelOf (ECall _ f d xs) = f ++ "(" ++ (if d then "DISTINCT " else "") ++ labelsOf xs ++ ")"
  labelOf (ECountStar _) = "COUNT(*)"

  labelsOf : List Expr -> String
  labelsOf [] = ""
  labelsOf [x] = labelOf x
  labelsOf (x :: xs@(_ :: _)) = labelOf x ++ ", " ++ labelsOf xs

  opText : BinOp -> String
  opText OAdd = "+"
  opText OSub = "-"
  opText OMul = "*"
  opText ODiv = "/"
  opText OMod = "%"
  opText OConcat = "||"
  opText OEq = "="
  opText ONe = "<>"
  opText OLt = "<"
  opText OLe = "<="
  opText OGt = ">"
  opText OGe = ">="
  opText OAnd = "AND"
  opText OOr = "OR"

origin : Pos
origin = MkPos 1 1

expandItems : Scope ctx -> List SelectItem -> Either DbError (List (Expr, String))
expandItems scope [] = Right []
expandItems scope (SelStar :: rest) = do
  more <- expandItems scope rest
  Right (map (\(q, n) => (ECol origin q n, n)) (scopeColumns scope) ++ more)
expandItems scope (SelTableStar t :: rest) = do
  let cols = filter (\(q, _) => map norm q == Just (norm t)) (scopeColumns scope)
  when (isNil cols) (Left (SemanticError ("no such table: " ++ t)))
  more <- expandItems scope rest
  Right (map (\(q, n) => (ECol origin q n, n)) cols ++ more)
expandItems scope (SelExpr e alias :: rest) = do
  more <- expandItems scope rest
  Right ((e, fromMaybe (labelOf e) alias) :: more)

nthExpr : Exprs ctx out -> Nat -> Maybe (Typed ctx)
nthExpr [] _ = Nothing
nthExpr (e :: es) Z = let MkSing t = typeOf e in Just (MkTyped t e)
nthExpr (e :: es) (S k) = nthExpr es k

-- What an ORDER BY term refers to: a result column, or an expression over
-- the rows before projection.
orderTarget : (items : List (Expr, String)) -> Expr -> Either DbError (Either Nat Expr)
orderTarget items (ELit p (LInt k)) =
  if k >= 1 && k <= cast (length items) then Right (Left (cast (k - 1)))
  else Left (err p ("ORDER BY position " ++ show k ++ " is not in the select list"))
orderTarget items e =
  let byName = case e of
                 ECol _ Nothing n => indexWhere (\it => norm (snd it) == norm n) items
                 _ => Nothing
  in case byName <|> indexWhere (\it => sameExpr e (fst it)) items of
       Just i => Right (Left i)
       Nothing => Right (Right e)

finish : SelectStmt -> (pre : List SqlType) -> Env pre -> LPlan pre -> List (Expr, String) ->
         Either DbError Query
finish sel pre env plan items = do
  MkSomeExprs out exprs <- inferAll env (map fst items)
  limit <- traverse (checkConstant TInt) sel.limit
  offset <- traverse (checkConstant TInt) sel.offset
  targets <- traverse (\(e, dir) => map (\t => (t, dir)) (orderTarget items e)) sel.orderBy
  let limited = \p => the (LPlan out) (if isNothing limit && isNothing offset then p else LLimit limit offset p)
  if all (isLeft . fst) targets
    then do
      keys <- traverse (outputKey out) targets
      let projected = LProject exprs plan
      let unique = if sel.distinct then LDistinct projected else projected
      Right (MkQuery out (map snd items) (limited (if isNil keys then unique else LSort keys unique)))
    else do
      when sel.distinct
        (Left (SemanticError "with SELECT DISTINCT, ORDER BY terms must appear in the select list"))
      keys <- traverse (inputKey exprs) targets
      Right (MkQuery out (map snd items) (limited (LProject exprs (LSort keys plan))))
  where
    outputKey : (out : List SqlType) -> (Either Nat Expr, SortDir) -> Either DbError (SortKey out)
    outputKey out (Left i, dir) = case nthElem out i of
      Just (MkFound t el) => Right (MkSortKey t (Col t el) dir)
      Nothing => Left (SemanticError "internal: ORDER BY column is out of range")
    outputKey out (Right e, _) = Left (err (exprPos e) "internal: unresolved ORDER BY term")

    inputKey : Exprs pre out' -> (Either Nat Expr, SortDir) -> Either DbError (SortKey pre)
    inputKey exprs (Left i, dir) = case nthExpr exprs i of
      Just (MkTyped t x) => Right (MkSortKey t x dir)
      Nothing => Left (SemanticError "internal: ORDER BY column is out of range")
    inputKey exprs (Right e, dir) = do
      MkTyped t x <- infer env e
      Right (MkSortKey t x dir)

||| Check a SELECT against the schema and build its logical plan.
export
analyzeSelect : Schema -> SelectStmt -> Either DbError Query
analyzeSelect schema sel = do
  MkSource ctx scope _ plan0 <- case sel.from of
    Nothing => Right (MkSource [] Empty [] LOneRow)
    Just (ref, joins) => tableSource schema ref >>= \src => addJoins schema src joins
  let base = plainEnv scope
  plan1 <- case sel.whereClause of
             Nothing => Right plan0
             Just e => map (\p => LFilter p plan0) (check base TBool e)
  items <- expandItems scope sel.items
  let exprs = map fst items ++ toList sel.having ++ map fst sel.orderBy
  let aggNodes = dedupe (concatMap aggCalls exprs)
  let grouped = not (isNil sel.groupBy) || not (isNil aggNodes)
  if grouped
    then do
      MkSomeExprs gs keys <- inferAll base sel.groupBy
      MkSomeAggs rs aggs <- typeAggs base aggNodes
      let env = groupedEnv scope sel.groupBy aggNodes gs rs
      let plan2 = LAggregate keys aggs plan1
      plan3 <- case sel.having of
                 Nothing => Right plan2
                 Just e => map (\p => LFilter p plan2) (check env TBool e)
      finish sel (gs ++ rs) env plan3 items
    else do
      when (isJust sel.having)
        (Left (SemanticError "HAVING needs GROUP BY or an aggregate function"))
      finish sel ctx base plan1 items
