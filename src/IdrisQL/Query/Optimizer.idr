module IdrisQL.Query.Optimizer

import Data.List
import Data.List.Elem
import Data.Maybe
import IdrisQL.Catalog.Schema
import IdrisQL.Query.Algebra
import IdrisQL.SQL.AST
import IdrisQL.SQL.Typed
import IdrisQL.Types

%default total

-- Logical rewrites. Each has type `LPlan ctx -> LPlan ctx`, so the type
-- checker has verified that it keeps the result shape. That it also keeps
-- the result rows is argued in comments and covered by tests, not proved.

-- Moving expressions between a join's row and its two sides.

export
splitElem : (a : List SqlType) -> Elem t (a ++ b) -> Either (Elem t a) (Elem t b)
splitElem [] el = Right el
splitElem (x :: xs) Here = Left Here
splitElem (x :: xs) (There el) = case splitElem xs el of
  Left l => Left (There l)
  Right r => Right r

export
inLeft : Elem t a -> Elem t (a ++ b)
inLeft Here = Here
inLeft (There el) = There (inLeft el)

export
inRight : (a : List SqlType) -> Elem t b -> Elem t (a ++ b)
inRight [] el = el
inRight (x :: xs) el = There (inRight xs el)

||| The expression over the left input alone, if it reads no right column.
export
leftOnly : (a : List SqlType) -> {0 b : List SqlType} -> TExpr (a ++ b) t -> Maybe (TExpr a t)
leftOnly a = rename (\el => case splitElem a el of
                              Left l => Just l
                              Right _ => Nothing)

||| The expression over the right input alone, if it reads no left column.
export
rightOnly : (a : List SqlType) -> {0 b : List SqlType} -> TExpr (a ++ b) t -> Maybe (TExpr b t)
rightOnly a = rename (\el => case splitElem a el of
                               Left _ => Nothing
                               Right r => Just r)

-- Filter placement.

andAll : List (TExpr ctx TBool) -> LPlan ctx -> LPlan ctx
andAll cs p = case conjoin cs of
  Nothing => p
  Just e => LFilter e p

record Routed (a : List SqlType) (b : List SqlType) where
  constructor MkRouted
  toLeft : List (TExpr a TBool)
  toRight : List (TExpr b TBool)
  stay : List (TExpr (a ++ b) TBool)

-- Send each conjunct to the deepest place it can be evaluated. `leftOk` and
-- `rightOk` say whether the join kind allows a move to that side.
route : (a : List SqlType) -> {0 b : List SqlType} -> (leftOk : Bool) -> (rightOk : Bool) ->
        List (TExpr (a ++ b) TBool) -> Routed a b
route a leftOk rightOk [] = MkRouted [] [] []
route a {b} leftOk rightOk (c :: cs) =
  let MkRouted ls rs ss = route a {b} leftOk rightOk cs
      l : Maybe (TExpr a TBool) = if leftOk then leftOnly a {b} c else Nothing
      r : Maybe (TExpr b TBool) = if rightOk then rightOnly a {b} c else Nothing
  in case l of
       Just x => MkRouted (x :: ls) rs ss
       Nothing => case r of
         Just y => MkRouted ls (y :: rs) ss
         Nothing => MkRouted ls rs (c :: ss)

mutual
  ||| Predicate pushdown.
  |||
  ||| A WHERE conjunct that reads only one side of a join moves below it.
  ||| Through an inner join both sides are valid targets. Through a left
  ||| join only the left side is: a conjunct on the right side would have
  ||| to see the NULL-extended rows, which exist only above the join.
  ||| Conjuncts of an inner join that read both sides become the join
  ||| condition, which lets the planner use an index for the join.
  |||
  ||| An ON conjunct of a left join that reads only the right side moves
  ||| into the right input (it limits which right rows can match); one
  ||| that reads only the left side stays, because it does not remove
  ||| left rows.
  export
  pushDown : LPlan ctx -> LPlan ctx
  pushDown (LFilter pred child) = place (conjuncts pred) child
  pushDown (LProject es p) = LProject es (pushDown p)
  pushDown (LJoin {a} {b} kind l r on) =
    let routed = route a {b} (kind == JInner) True (maybe [] conjuncts on)
    in LJoin kind (place routed.toLeft l) (place routed.toRight r) (conjoin routed.stay)
  pushDown (LAggregate ks as' p) = LAggregate ks as' (pushDown p)
  pushDown (LSort ks p) = LSort ks (pushDown p)
  pushDown (LDistinct p) = LDistinct (pushDown p)
  pushDown (LLimit l o p) = LLimit l o (pushDown p)
  pushDown p = p

  -- Place conjuncts as low as possible above `child`.
  place : List (TExpr ctx TBool) -> LPlan ctx -> LPlan ctx
  place cs (LFilter pred child) = place (cs ++ conjuncts pred) child
  place cs (LSort ks child) = LSort ks (place cs child)
  place cs (LJoin {a} {b} JInner l r on) =
    let routed = route a {b} True True (cs ++ maybe [] conjuncts on)
    in LJoin JInner (place routed.toLeft l) (place routed.toRight r) (conjoin routed.stay)
  place cs (LJoin {a} {b} JLeft l r on) =
    let above = route a {b} True False cs
        within = route a {b} False True (maybe [] conjuncts on)
    in andAll above.stay
         (LJoin JLeft (place above.toLeft l) (place within.toRight r) (conjoin within.stay))
  place cs child = andAll cs (pushDown child)

simplifyKey : SortKey ctx -> SortKey ctx
simplifyKey k = { expr $= simplify } k

isTrue : TExpr ctx TBool -> Bool
isTrue (Lit TBool (Just True)) = True
isTrue _ = False

||| Constant folding and filter simplification: constant subexpressions are
||| evaluated once, Boolean identities are removed, and a filter that is
||| always TRUE disappears.
export
simplifyPlan : LPlan ctx -> LPlan ctx
simplifyPlan (LFilter pred p) =
  let pred' = simplify pred
  in if isTrue pred' then simplifyPlan p else LFilter pred' (simplifyPlan p)
simplifyPlan (LProject es p) = LProject (simplifyExprs es) (simplifyPlan p)
simplifyPlan (LJoin kind l r on) =
  LJoin kind (simplifyPlan l) (simplifyPlan r)
        (case map simplify on of
           Just e => if isTrue e then Nothing else Just e
           Nothing => Nothing)
simplifyPlan (LAggregate ks as' p) = LAggregate (simplifyExprs ks) as' (simplifyPlan p)
simplifyPlan (LSort ks p) = LSort (map simplifyKey ks) (simplifyPlan p)
simplifyPlan (LDistinct p) = LDistinct (simplifyPlan p)
simplifyPlan (LLimit l o p) = LLimit (map simplify l) (map simplify o) (simplifyPlan p)
simplifyPlan p = p

export
optimize : LPlan ctx -> LPlan ctx
optimize = pushDown . simplifyPlan
