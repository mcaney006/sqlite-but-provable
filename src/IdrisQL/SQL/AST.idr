module IdrisQL.SQL.AST

import Data.List
import Data.String
import IdrisQL.Error
import IdrisQL.Types

%default total

-- The syntax tree produced by the parser. Nothing here has been checked
-- against a schema: names are unresolved and expressions are untyped. The
-- analyzer turns this into the typed representation in IdrisQL.SQL.Typed.

public export
data Literal = LNull | LInt Integer | LReal Double | LText String | LBlob (List Bits8) | LBool Bool

public export
Eq Literal where
  LNull == LNull = True
  LInt a == LInt b = a == b
  LReal a == LReal b = a == b
  LText a == LText b = a == b
  LBlob a == LBlob b = a == b
  LBool a == LBool b = a == b
  _ == _ = False

public export
data BinOp = OAdd | OSub | OMul | ODiv | OMod | OConcat
           | OEq | ONe | OLt | OLe | OGt | OGe | OAnd | OOr

public export
Eq BinOp where
  OAdd == OAdd = True
  OSub == OSub = True
  OMul == OMul = True
  ODiv == ODiv = True
  OMod == OMod = True
  OConcat == OConcat = True
  OEq == OEq = True
  ONe == ONe = True
  OLt == OLt = True
  OLe == OLe = True
  OGt == OGt = True
  OGe == OGe = True
  OAnd == OAnd = True
  OOr == OOr = True
  _ == _ = False

||| An unresolved expression. Every node carries the position of its first
||| token for error messages.
public export
data Expr : Type where
  ELit       : Pos -> Literal -> Expr
  ECol       : Pos -> (qualifier : Maybe String) -> (name : String) -> Expr
  ||| A bound parameter. `?` is numbered from 0 in order of appearance;
  ||| `?N` (N >= 1) has index N-1.
  EParam     : Pos -> (index : Nat) -> Expr
  EBin       : Pos -> BinOp -> Expr -> Expr -> Expr
  ENeg       : Pos -> Expr -> Expr
  ENot       : Pos -> Expr -> Expr
  EIsNull    : Pos -> (negated : Bool) -> Expr -> Expr
  EIn        : Pos -> (negated : Bool) -> Expr -> List Expr -> Expr
  EBetween   : Pos -> (negated : Bool) -> Expr -> (lo : Expr) -> (hi : Expr) -> Expr
  ELike      : Pos -> (negated : Bool) -> Expr -> (pattern : Expr) -> Expr
  ECast      : Pos -> Expr -> SqlType -> Expr
  ||| A function call. `fname` is upper-cased by the parser.
  ECall      : Pos -> (fname : String) -> (distinct : Bool) -> (args : List Expr) -> Expr
  ECountStar : Pos -> Expr

export
exprPos : Expr -> Pos
exprPos (ELit p _) = p
exprPos (ECol p _ _) = p
exprPos (EParam p _) = p
exprPos (EBin p _ _ _) = p
exprPos (ENeg p _) = p
exprPos (ENot p _) = p
exprPos (EIsNull p _ _) = p
exprPos (EIn p _ _ _) = p
exprPos (EBetween p _ _ _ _) = p
exprPos (ELike p _ _ _) = p
exprPos (ECast p _ _) = p
exprPos (ECall p _ _ _) = p
exprPos (ECountStar p) = p

mutual
  ||| Structural equality that ignores source positions.
  export
  sameExpr : Expr -> Expr -> Bool
  sameExpr (ELit _ a) (ELit _ b) = a == b
  sameExpr (ECol _ q n) (ECol _ q' n') = map toLower q == map toLower q' && toLower n == toLower n'
  sameExpr (EParam _ i) (EParam _ j) = i == j
  sameExpr (EBin _ o a b) (EBin _ o' a' b') = o == o' && sameExpr a a' && sameExpr b b'
  sameExpr (ENeg _ a) (ENeg _ b) = sameExpr a b
  sameExpr (ENot _ a) (ENot _ b) = sameExpr a b
  sameExpr (EIsNull _ n a) (EIsNull _ n' b) = n == n' && sameExpr a b
  sameExpr (EIn _ n a xs) (EIn _ n' b ys) = n == n' && sameExpr a b && sameExprs xs ys
  sameExpr (EBetween _ n a l h) (EBetween _ n' b l' h') =
    n == n' && sameExpr a b && sameExpr l l' && sameExpr h h'
  sameExpr (ELike _ n a p) (ELike _ n' b p') = n == n' && sameExpr a b && sameExpr p p'
  sameExpr (ECast _ a t) (ECast _ b t') = t == t' && sameExpr a b
  sameExpr (ECall _ f d xs) (ECall _ f' d' ys) = f == f' && d == d' && sameExprs xs ys
  sameExpr (ECountStar _) (ECountStar _) = True
  sameExpr _ _ = False

  export
  sameExprs : List Expr -> List Expr -> Bool
  sameExprs [] [] = True
  sameExprs (x :: xs) (y :: ys) = sameExpr x y && sameExprs xs ys
  sameExprs _ _ = False

quoteText : String -> String
quoteText s = "'" ++ concatMap (\c => if c == '\'' then "''" else singleton c) (unpack s) ++ "'"

||| Quote an identifier so that it lexes back to the same name.
export
quoteIdent : String -> String
quoteIdent s = "\"" ++ concatMap (\c => if c == '"' then "\"\"" else singleton c) (unpack s) ++ "\""

export
renderLiteral : Literal -> String
renderLiteral LNull = "NULL"
renderLiteral (LInt i) = show i
renderLiteral (LReal d) = show d
renderLiteral (LText s) = quoteText s
renderLiteral (LBlob b) = "X'" ++ concatMap hexByte b ++ "'"
renderLiteral (LBool b) = if b then "TRUE" else "FALSE"

binOpText : BinOp -> String
binOpText OAdd = "+"
binOpText OSub = "-"
binOpText OMul = "*"
binOpText ODiv = "/"
binOpText OMod = "%"
binOpText OConcat = "||"
binOpText OEq = "="
binOpText ONe = "<>"
binOpText OLt = "<"
binOpText OLe = "<="
binOpText OGt = ">"
binOpText OGe = ">="
binOpText OAnd = "AND"
binOpText OOr = "OR"

mutual
  ||| Render an expression as SQL that parses back to an equal tree
  ||| (`sameExpr`). Every compound node is parenthesised, so the output
  ||| does not depend on operator precedence. The catalog stores CHECK and
  ||| DEFAULT expressions in this form.
  export
  renderExpr : Expr -> String
  renderExpr (ELit _ l) = renderLiteral l
  renderExpr (ECol _ Nothing n) = quoteIdent n
  renderExpr (ECol _ (Just q) n) = quoteIdent q ++ "." ++ quoteIdent n
  renderExpr (EParam _ i) = "?" ++ show (S i)
  renderExpr (EBin _ o a b) = "(" ++ renderExpr a ++ " " ++ binOpText o ++ " " ++ renderExpr b ++ ")"
  renderExpr (ENeg _ a) = "(-" ++ renderExpr a ++ ")"
  renderExpr (ENot _ a) = "(NOT " ++ renderExpr a ++ ")"
  renderExpr (EIsNull _ n a) = "(" ++ renderExpr a ++ (if n then " IS NOT NULL)" else " IS NULL)")
  renderExpr (EIn _ n a xs) =
    "(" ++ renderExpr a ++ (if n then " NOT IN (" else " IN (") ++ renderExprs xs ++ "))"
  renderExpr (EBetween _ n a l h) =
    "(" ++ renderExpr a ++ (if n then " NOT BETWEEN " else " BETWEEN ")
        ++ renderExpr l ++ " AND " ++ renderExpr h ++ ")"
  renderExpr (ELike _ n a p) =
    "(" ++ renderExpr a ++ (if n then " NOT LIKE " else " LIKE ") ++ renderExpr p ++ ")"
  renderExpr (ECast _ a t) = "CAST(" ++ renderExpr a ++ " AS " ++ show t ++ ")"
  renderExpr (ECall _ f d xs) = f ++ "(" ++ (if d then "DISTINCT " else "") ++ renderExprs xs ++ ")"
  renderExpr (ECountStar _) = "COUNT(*)"

  export
  renderExprs : List Expr -> String
  renderExprs [] = ""
  renderExprs [x] = renderExpr x
  renderExprs (x :: xs@(_ :: _)) = renderExpr x ++ ", " ++ renderExprs xs

public export
data ColConstraint : Type where
  CPrimaryKey : ColConstraint
  CNotNull    : ColConstraint
  CUnique     : ColConstraint
  CDefault    : Expr -> ColConstraint
  CCheck      : Expr -> ColConstraint
  ||| Parsed and recorded in the catalog; referential actions are not enforced.
  CReferences : (table : String) -> (cols : List String) -> ColConstraint

public export
record ColumnSpec where
  constructor MkColumnSpec
  name : String
  type : SqlType
  constraints : List ColConstraint

public export
data TableConstraint : Type where
  TCPrimaryKey : List String -> TableConstraint
  TCUnique     : List String -> TableConstraint
  TCCheck      : Expr -> TableConstraint
  TCForeignKey : (cols : List String) -> (table : String) -> (refCols : List String) -> TableConstraint

public export
data SelectItem : Type where
  SelStar      : SelectItem
  SelTableStar : (table : String) -> SelectItem
  SelExpr      : Expr -> (alias : Maybe String) -> SelectItem

public export
data JoinKind = JInner | JLeft

public export
Eq JoinKind where
  JInner == JInner = True
  JLeft == JLeft = True
  _ == _ = False

public export
record TableRef where
  constructor MkTableRef
  pos : Pos
  table : String
  alias : Maybe String

public export
record Join where
  constructor MkJoin
  kind : JoinKind
  ref : TableRef
  ||| `Nothing` for CROSS JOIN and comma joins.
  on : Maybe Expr

public export
data SortDir = Asc | Desc

public export
Eq SortDir where
  Asc == Asc = True
  Desc == Desc = True
  _ == _ = False

public export
record SelectStmt where
  constructor MkSelect
  distinct : Bool
  items : List SelectItem
  from : Maybe (TableRef, List Join)
  whereClause : Maybe Expr
  groupBy : List Expr
  having : Maybe Expr
  orderBy : List (Expr, SortDir)
  limit : Maybe Expr
  offset : Maybe Expr

public export
data Stmt : Type where
  SCreateTable : Pos -> (ifNotExists : Bool) -> (name : String) ->
                 List ColumnSpec -> List TableConstraint -> Stmt
  SDropTable   : Pos -> (ifExists : Bool) -> (name : String) -> Stmt
  SCreateIndex : Pos -> (unique : Bool) -> (ifNotExists : Bool) -> (name : String) ->
                 (table : String) -> (cols : List String) -> Stmt
  SDropIndex   : Pos -> (ifExists : Bool) -> (name : String) -> Stmt
  SInsert      : Pos -> (table : String) -> (cols : Maybe (List String)) ->
                 (rows : List (List Expr)) -> Stmt
  SSelect      : SelectStmt -> Stmt
  SUpdate      : Pos -> (table : String) -> (sets : List (String, Expr)) ->
                 (whereClause : Maybe Expr) -> Stmt
  SDelete      : Pos -> (table : String) -> (whereClause : Maybe Expr) -> Stmt
  SBegin       : Stmt
  SCommit      : Stmt
  SRollback    : Stmt
  SExplain     : (queryPlan : Bool) -> Stmt -> Stmt
  SAnalyze     : Stmt
