module IdrisQL.Query.Algebra

import Data.List
import IdrisQL.Catalog.Schema
import IdrisQL.SQL.AST
import IdrisQL.SQL.Typed
import IdrisQL.Types

%default total

-- Relational algebra over typed rows. A `LPlan ctx` produces rows of shape
-- `ctx`; every operator states how it changes the shape, so a rewrite that
-- type-checks cannot change a query's result columns.

public export
record SortKey (ctx : List SqlType) where
  constructor MkSortKey
  type : SqlType
  expr : TExpr ctx type
  dir : SortDir

public export
data LPlan : List SqlType -> Type where
  ||| Every row of a table. `label` is the name the query uses for it.
  LScan      : (tbl : TableDef) -> (label : String) -> LPlan (tableCtx tbl)
  ||| One empty row: the input of a SELECT without FROM.
  LOneRow    : LPlan []
  ||| Selection: rows on which the predicate is TRUE.
  LFilter    : TExpr ctx TBool -> LPlan ctx -> LPlan ctx
  LProject   : {ctx : List SqlType} -> Exprs ctx out -> LPlan ctx -> LPlan out
  LJoin      : {a, b : List SqlType} -> JoinKind -> LPlan a -> LPlan b ->
               (on : Maybe (TExpr (a ++ b) TBool)) -> LPlan (a ++ b)
  ||| Grouping columns followed by aggregate results.
  LAggregate : {ctx, gs : List SqlType} -> Exprs ctx gs -> Aggs ctx rs -> LPlan ctx -> LPlan (gs ++ rs)
  LSort      : List (SortKey ctx) -> LPlan ctx -> LPlan ctx
  LDistinct  : LPlan ctx -> LPlan ctx
  LLimit     : (limit : Maybe (TExpr [] TInt)) -> (offset : Maybe (TExpr [] TInt)) ->
               LPlan ctx -> LPlan ctx

||| A checked SELECT: its result shape, column names, and logical plan.
public export
record Query where
  constructor MkQuery
  shape : List SqlType
  names : List String
  plan : LPlan shape

export
sortKeyParams : SortKey ctx -> List (Nat, SqlType)
sortKeyParams k = paramsOf k.expr

aggsParams : Aggs ctx rs -> List (Nat, SqlType)
aggsParams ANil = []
aggsParams (ACons a as') = aggInput a ++ aggsParams as'

||| Every parameter a plan reads, with the type its position requires.
export
planParams : LPlan ctx -> List (Nat, SqlType)
planParams (LScan _ _) = []
planParams LOneRow = []
planParams (LFilter e p) = paramsOf e ++ planParams p
planParams (LProject es p) = paramsOfExprs es ++ planParams p
planParams (LJoin _ l r on) = planParams l ++ planParams r ++ maybe [] paramsOf on
planParams (LAggregate ks as' p) = paramsOfExprs ks ++ aggsParams as' ++ planParams p
planParams (LSort ks p) = concatMap sortKeyParams ks ++ planParams p
planParams (LDistinct p) = planParams p
planParams (LLimit l o p) = maybe [] paramsOf l ++ maybe [] paramsOf o ++ planParams p
