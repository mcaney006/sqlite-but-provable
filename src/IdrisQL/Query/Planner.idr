module IdrisQL.Query.Planner

import Data.List
import Data.List.Elem
import Data.Maybe
import Data.SortedSet
import Data.String
import Decidable.Equality
import IdrisQL.Catalog.Schema
import IdrisQL.Query.Algebra
import IdrisQL.Query.Optimizer
import IdrisQL.SQL.AST
import IdrisQL.SQL.Typed
import IdrisQL.Types

-- Physical planning: choose an access path for every table, a method for
-- every join, and where sorting is needed. The executor runs the `PPlan`
-- this module returns and EXPLAIN prints that same value, so the reported
-- plan is the executed plan.

||| One key column of an index search, computed from the outer row `o`.
public export
data KeyExpr : List SqlType -> Type where
  MkKeyExpr : (t : SqlType) -> TExpr o t -> KeyExpr o

||| Bounds on the index column that follows the equality columns. The Bool
||| says whether the bound itself is included.
public export
record KeyRange (o : List SqlType) where
  constructor MkKeyRange
  type : SqlType
  lo : Maybe (TExpr o type, Bool)
  hi : Maybe (TExpr o type, Bool)

||| How rows of one table are found. `o` is the row the search values are
||| computed from: empty for a plain scan, the outer row for an index join.
public export
data Access : (o : List SqlType) -> Type where
  FullScan   : Access o
  RowidEq    : TExpr o TInt -> Access o
  RowidRange : (lo : Maybe (TExpr o TInt, Bool)) -> (hi : Maybe (TExpr o TInt, Bool)) -> Access o
  IndexScan  : (idx : IndexDef) -> (eqs : List (KeyExpr o)) -> (range : Maybe (KeyRange o)) -> Access o

public export
data PPlan : List SqlType -> Type where
  ||| `needed` marks the columns to decode; the rest are returned as NULL
  ||| and never read by any operator above.
  PScan       : (tbl : TableDef) -> (label : String) -> (needed : List Bool) -> Access [] ->
                PPlan (tableCtx tbl)
  POneRow     : PPlan []
  PFilter     : TExpr ctx TBool -> PPlan ctx -> PPlan ctx
  PProject    : {ctx : List SqlType} -> Exprs ctx out -> PPlan ctx -> PPlan out
  PNestedLoop : {a, b : List SqlType} -> JoinKind -> PPlan a -> PPlan b ->
                (on : Maybe (TExpr (a ++ b) TBool)) -> PPlan (a ++ b)
  ||| For each outer row, search `tbl` with values taken from that row.
  PIndexJoin  : {a : List SqlType} -> JoinKind -> PPlan a -> (tbl : TableDef) -> (label : String) ->
                (needed : List Bool) -> Access a ->
                (on : Maybe (TExpr (a ++ tableCtx tbl) TBool)) -> PPlan (a ++ tableCtx tbl)
  ||| Input must arrive grouped: sorted on the grouping expressions.
  PAggregate  : {ctx, gs : List SqlType} -> Exprs ctx gs -> Aggs ctx rs -> PPlan ctx -> PPlan (gs ++ rs)
  PSort       : List (SortKey ctx) -> PPlan ctx -> PPlan ctx
  ||| Drop each row equal to the one before it.
  PDedup      : PPlan ctx -> PPlan ctx
  PLimit      : (limit : Maybe (TExpr [] TInt)) -> (offset : Maybe (TExpr [] TInt)) ->
                PPlan ctx -> PPlan ctx

-- Search arguments: conjuncts of the form `column op value`, where the
-- value does not depend on the table being searched.

record Sarg (o : List SqlType) where
  constructor MkSarg
  column : Nat
  type : SqlType
  op : CmpOp
  value : TExpr o type

flipOp : CmpOp -> CmpOp
flipOp Lt = Gt
flipOp Le = Ge
flipOp Gt = Lt
flipOp Ge = Le
flipOp op = op

sargOf : (colOf : {0 u : SqlType} -> TExpr ctx u -> Maybe Nat) ->
         (outer : {0 u : SqlType} -> TExpr ctx u -> Maybe (TExpr o u)) ->
         TExpr ctx TBool -> Maybe (Sarg o)
sargOf colOf outer (Cmp t op x y) =
  case (colOf x, outer y) of
    (Just c, Just v) => Just (MkSarg c t op v)
    _ => case (colOf y, outer x) of
      (Just c, Just v) => Just (MkSarg c t (flipOp op) v)
      _ => Nothing
sargOf _ _ _ = Nothing

isEq : CmpOp -> Bool
isEq Eq = True
isEq _ = False

isLower : CmpOp -> Bool
isLower Gt = True
isLower Ge = True
isLower _ = False

isUpper : CmpOp -> Bool
isUpper Lt = True
isUpper Le = True
isUpper _ = False

inclusive : CmpOp -> Bool
inclusive Ge = True
inclusive Le = True
inclusive _ = False

-- The value of a search argument at a required type.
valueAt : (t : SqlType) -> Sarg o -> Maybe (TExpr o t)
valueAt t s = case decEq s.type t of
  Yes Refl => Just s.value
  No _ => Nothing

boundAt : (t : SqlType) -> (CmpOp -> Bool) -> (column : Nat) -> List (Sarg o) -> Maybe (TExpr o t, Bool)
boundAt t side column sargs = do
  s <- find (\s => s.column == column && side s.op) sargs
  v <- valueAt t s
  Just (v, inclusive s.op)

||| An access path with the planner's estimate of the rows it returns and
||| the columns its output is ordered by.
record Choice (o : List SqlType) where
  constructor MkChoice
  access : Access o
  rows : Double
  cost : Double
  order : List Nat

export
tableRows : TableDef -> Double
tableRows tbl = if tbl.rowEstimate >= 0 then max 1 (cast tbl.rowEstimate) else 1000

rowidOrder : TableDef -> List Nat
rowidOrder tbl = toList tbl.rowidColumn

-- A lookup through an index costs a table fetch per row found.
indexFetchCost : Double
indexFetchCost = 3

rowidChoice : (tbl : TableDef) -> List (Sarg o) -> Maybe (Choice o)
rowidChoice tbl sargs = do
  c <- tbl.rowidColumn
  case find (\s => s.column == c && isEq s.op) sargs >>= valueAt TInt of
    Just v => Just (MkChoice (RowidEq v) 1 1 [c])
    Nothing =>
      let lo = boundAt TInt isLower c sargs
          hi = boundAt TInt isUpper c sargs
          rows = max 1 (tableRows tbl * 0.3)
      in if isNothing lo && isNothing hi then Nothing
         else Just (MkChoice (RowidRange lo hi) rows rows [c])

eqPrefix : List Nat -> List (Sarg o) -> List (KeyExpr o)
eqPrefix [] sargs = []
eqPrefix (c :: cs) sargs = case find (\s => s.column == c && isEq s.op) sargs of
  Nothing => []
  Just s => MkKeyExpr s.type s.value :: eqPrefix cs sargs

rangeOn : (column : Nat) -> List (Sarg o) -> Maybe (KeyRange o)
rangeOn column sargs = do
  s <- find (\s => s.column == column && (isLower s.op || isUpper s.op)) sargs
  let r = MkKeyRange s.type (boundAt s.type isLower column sargs) (boundAt s.type isUpper column sargs)
  Just r

power : Double -> Nat -> Double
power x Z = 1
power x (S k) = x * power x k

indexChoice : (tbl : TableDef) -> List (Sarg o) -> IndexDef -> Maybe (Choice o)
indexChoice tbl sargs idx =
  let eqs = eqPrefix idx.columns sargs
      matched = length eqs
      range = case drop matched idx.columns of
                [] => Nothing
                (c :: _) => rangeOn c sargs
      total' = tableRows tbl
      full = matched == length idx.columns
      perKey = if full && idx.unique then 1
               else if full && idx.distinctEstimate > 0 then total' / cast idx.distinctEstimate
               else total' * power 0.1 matched
      rows = max 1 (if isJust range then perKey * 0.3 else perKey)
  in if matched == 0 && isNothing range then Nothing
     else Just (MkChoice (IndexScan idx eqs range) rows (rows * indexFetchCost + 1)
                         (drop matched idx.columns ++ rowidOrder tbl))

cheapest : Choice o -> List (Choice o) -> Choice o
cheapest best [] = best
cheapest best (c :: cs) = cheapest (if c.cost < best.cost then c else best) cs

||| The cheapest way to find the rows that satisfy the search arguments.
pickAccess : (tbl : TableDef) -> List IndexDef -> List (Sarg o) -> Choice o
pickAccess tbl indexes sargs =
  let rows = tableRows tbl
      scan = MkChoice FullScan rows rows (rowidOrder tbl)
  in cheapest scan (toList (rowidChoice tbl sargs) ++ mapMaybe (indexChoice tbl sargs) indexes)

closed : TExpr ctx u -> Maybe (TExpr [] u)
closed = rename (\_ => Nothing)

ownColumn : TExpr ctx u -> Maybe Nat
ownColumn (Col _ el) = Just (elemToNat el)
ownColumn _ = Nothing

||| Access path for a single-table statement with the given predicate.
export
accessFor : Schema -> (tbl : TableDef) -> Maybe (TExpr (tableCtx tbl) TBool) -> Access []
accessFor schema tbl pred =
  let sargs = mapMaybe (sargOf ownColumn closed) (maybe [] conjuncts pred)
  in (pickAccess tbl (tableIndexes schema tbl.name) sargs).access

-- Column pruning.

mask : (n : Nat) -> (from : Nat) -> SortedSet Nat -> List Bool
mask Z _ _ = []
mask (S k) i s = contains i s :: mask k (S i) s

upTo : Nat -> List Nat
upTo Z = []
upTo (S k) = upTo k ++ [k]

allOf : List SqlType -> SortedSet Nat
allOf ts = fromList (upTo (length ts))

addCols : List Nat -> SortedSet Nat -> SortedSet Nat
addCols cs s = foldl (flip insert) s cs

exprsCols : Exprs ctx out -> List Nat
exprsCols [] = []
exprsCols (e :: es) = colsUsed e ++ exprsCols es

aggsCols : Aggs ctx rs -> List Nat
aggsCols ANil = []
aggsCols (ACons a rest) = aggCols a ++ aggsCols rest

-- Estimates.

selectivity : TExpr ctx TBool -> Double
selectivity (Cmp _ Eq _ _) = 0.1
selectivity (Cmp _ Ne _ _) = 0.9
selectivity (Cmp _ _ _ _) = 0.3
selectivity (And a b) = selectivity a * selectivity b
selectivity _ = 0.5

estimate : LPlan ctx -> Double
estimate (LScan tbl _) = tableRows tbl
estimate LOneRow = 1
estimate (LFilter p c) = max 1 (estimate c * selectivity p)
estimate (LProject _ c) = estimate c
estimate (LJoin _ l r on) = case on of
  Nothing => estimate l * estimate r
  Just _ => max (estimate l) (estimate r)
estimate (LAggregate ks _ c) = case ks of
  [] => 1
  _ => max 1 (estimate c / 10)
estimate (LSort _ c) = estimate c
estimate (LDistinct c) = estimate c
estimate (LLimit _ _ c) = estimate c

-- Ordering.

keyColumns : List (SortKey ctx) -> Maybe (List Nat)
keyColumns [] = Just []
keyColumns (k :: ks) = case (k.dir, k.expr) of
  (Asc, Col _ el) => map (elemToNat el ::) (keyColumns ks)
  _ => Nothing

accessOrder : (tbl : TableDef) -> Access o -> List Nat
accessOrder tbl (IndexScan idx eqs _) = drop (length eqs) idx.columns ++ rowidOrder tbl
accessOrder tbl _ = rowidOrder tbl

-- The inner column that output column `i` of a projection copies, if it
-- is a plain column.
copiedColumn : Exprs ctx out -> (i : Nat) -> Maybe Nat
copiedColumn [] _ = Nothing
copiedColumn (Col _ el :: _) Z = Just (elemToNat el)
copiedColumn (_ :: _) Z = Nothing
copiedColumn (_ :: es) (S i) = copiedColumn es i

-- The output position of a projection that copies inner column `c`.
copyOf : Exprs ctx out -> (c : Nat) -> (at : Nat) -> Maybe Nat
copyOf [] _ _ = Nothing
copyOf (Col _ el :: es) c at = if elemToNat el == c then Just at else copyOf es c (S at)
copyOf (_ :: es) c at = copyOf es c (S at)

-- An ordering of the input, restated in output columns. It ends at the
-- first ordering column the projection drops.
throughProject : Exprs ctx out -> List Nat -> List Nat
throughProject es [] = []
throughProject es (c :: cs) = case copyOf es c 0 of
  Just i => i :: throughProject es cs
  Nothing => []

-- The columns a plan's output is already ordered by, ascending.
planOrder : PPlan ctx -> List Nat
planOrder (PScan tbl _ _ access) = accessOrder tbl access
planOrder (PFilter _ p) = planOrder p
planOrder (PLimit _ _ p) = planOrder p
planOrder (PProject es p) = throughProject es (planOrder p)
planOrder _ = []

sortedAlready : List (SortKey ctx) -> PPlan ctx -> Bool
sortedAlready keys p = case keyColumns keys of
  Nothing => False
  Just cols => not (isNil cols) && isPrefixOf cols (planOrder p)

-- When rows are wanted in the order of an index and only a few of them
-- (a LIMIT is present), walk the index instead of sorting the table.
orderedScan : Schema -> (cols : List Nat) -> PPlan ctx -> Maybe (PPlan ctx)
orderedScan schema cols (PScan tbl label needed FullScan) = do
  idx <- find (\i => not (isNil cols) && isPrefixOf cols i.columns) (tableIndexes schema tbl.name)
  Just (PScan tbl label needed (IndexScan idx [] Nothing))
orderedScan schema cols (PProject es p) = do
  inner <- traverse (copiedColumn es) cols
  map (PProject es) (orderedScan schema inner p)
orderedScan schema cols _ = Nothing

-- The input column a projection copies into output position `el`.
copiedElem : Exprs inner mid -> Elem t mid -> Maybe (Elem t inner)
copiedElem (Col _ el :: _) Here = Just el
copiedElem (_ :: _) Here = Nothing
copiedElem (_ :: es) (There el) = copiedElem es el

-- A projection. Over a projection that only copies columns, the two are
-- merged, so a join whose sides were swapped costs no extra row copy.
project : {mid : List SqlType} -> Exprs mid out -> PPlan mid -> PPlan out
project es (PProject cs p) = case renameExprs (copiedElem cs) es of
  Just direct => PProject direct p
  Nothing => PProject es (PProject cs p)
project es p = PProject es p

exprKeys : Exprs ctx gs -> List (SortKey ctx)
exprKeys [] = []
exprKeys (e :: es) = let MkSing t = typeOf e in MkSortKey t e Asc :: exprKeys es

columnKeys : (ts : List SqlType) -> ({0 u : SqlType} -> Elem u ts -> Elem u ctx) -> List (SortKey ctx)
columnKeys [] f = []
columnKeys (t :: ts) f = MkSortKey t (Col t (f Here)) Asc :: columnKeys ts (\el => f (There el))

-- Joins.

||| A table scan with an optional filter: the shape an index join can use
||| as its inner side.
data BaseScan : List SqlType -> Type where
  MkBaseScan : (tbl : TableDef) -> (label : String) -> (pred : Maybe (TExpr (tableCtx tbl) TBool)) ->
               BaseScan (tableCtx tbl)

baseScan : LPlan b -> Maybe (BaseScan b)
baseScan (LScan tbl label) = Just (MkBaseScan tbl label Nothing)
baseScan (LFilter pred (LScan tbl label)) = Just (MkBaseScan tbl label (Just pred))
baseScan _ = Nothing

columnExprs : (ts : List SqlType) -> ({0 u : SqlType} -> Elem u ts -> Elem u ctx) -> Exprs ctx ts
columnExprs [] f = []
columnExprs (t :: ts) f = Col t (f Here) :: columnExprs ts (\el => f (There el))

appendExprs : Exprs ctx xs -> Exprs ctx ys -> Exprs ctx (xs ++ ys)
appendExprs [] ys = ys
appendExprs (x :: xs) ys = x :: appendExprs xs ys

swapElem : (a : List SqlType) -> (b : List SqlType) -> Elem t (a ++ b) -> Elem t (b ++ a)
swapElem a b el = case splitElem a el of
  Left l => inRight b l
  Right r => inLeft r

||| The columns of `a ++ b` read from a row of shape `b ++ a`.
swapColumns : (a : List SqlType) -> (b : List SqlType) -> Exprs (b ++ a) (a ++ b)
swapColumns a b = appendExprs (columnExprs a (\el => inRight b el)) (columnExprs b (\el => inLeft el))

rightColumn : (a : List SqlType) -> {0 b : List SqlType} -> TExpr (a ++ b) u -> Maybe Nat
rightColumn a (Col _ el) = case splitElem a {b} el of
  Left _ => Nothing
  Right r => Just (elemToNat r)
rightColumn a _ = Nothing

-- An index join with `inner` as the searched table, if the join condition
-- gives an index something to search on. Returns the plan and its cost.
indexJoin : Schema -> (a : List SqlType) -> JoinKind -> PPlan a -> (outerRows : Double) ->
            BaseScan b -> (needed : SortedSet Nat) -> Maybe (TExpr (a ++ b) TBool) ->
            Maybe (PPlan (a ++ b), Double)
indexJoin schema a kind outer outerRows (MkBaseScan tbl label pred) needed on =
  let conj = maybe [] conjuncts on
      sargs = mapMaybe (sargOf (rightColumn a {b = tableCtx tbl}) (leftOnly a {b = tableCtx tbl})) conj
      choice = pickAccess tbl (tableIndexes schema tbl.name) sargs
      own : Maybe (List (TExpr (a ++ tableCtx tbl) TBool))
          = case pred of
              Nothing => Just []
              Just p => map conjuncts (rename (\el => Just (inRight a el)) p)
      cols = mask (length tbl.columns) 0 (addCols (maybe [] colsUsed pred) needed)
  in case own of
       Nothing => Nothing
       Just mine => case choice.access of
         FullScan => Nothing
         access => Just (PIndexJoin kind outer tbl label cols access (conjoin (conj ++ mine)),
                         outerRows * choice.cost)

splitNeeded : (leftWidth : Nat) -> SortedSet Nat -> (SortedSet Nat, SortedSet Nat)
splitNeeded w s =
  let xs = Prelude.toList s
  in (fromList (filter (< w) xs), fromList (map (`minus` w) (filter (>= w) xs)))

mutual
  ||| Translate a logical plan. `needed` holds the output columns some
  ||| operator above will read; `fewRows` is True under a LIMIT.
  export
  plan : Schema -> (ctx : List SqlType) -> (needed : SortedSet Nat) -> (fewRows : Bool) ->
         LPlan ctx -> PPlan ctx
  plan schema _ needed few (LScan tbl label) =
    PScan tbl label (mask (length tbl.columns) 0 needed) FullScan
  plan schema _ needed few LOneRow = POneRow
  plan schema _ needed few (LFilter pred (LScan tbl label)) =
    PFilter pred (PScan tbl label (mask (length tbl.columns) 0 (addCols (colsUsed pred) needed))
                        (accessFor schema tbl (Just pred)))
  plan schema ctx needed few (LFilter pred child) =
    PFilter pred (plan schema ctx (addCols (colsUsed pred) needed) few child)
  plan schema _ needed few (LProject {ctx = inner} es child) =
    project es (plan schema inner (fromList (exprsCols es)) few child)
  plan schema _ needed few (LJoin {a} {b} kind l r on) =
    join schema a b (addCols (maybe [] colsUsed on) needed) kind l r on
  plan schema _ needed few (LAggregate {ctx = inner} keys aggs child) =
    let input = plan schema inner (fromList (exprsCols keys ++ aggsCols aggs)) False child
        groupKeys = exprKeys keys
    in PAggregate keys aggs
         (if isNil groupKeys || sortedAlready groupKeys input then input else PSort groupKeys input)
  plan schema ctx needed few (LSort keys child) =
    let input = plan schema ctx (addCols (concatMap (\k => colsUsed k.expr) keys) needed) False child
    in if sortedAlready keys input then input
       else case (if few then keyColumns keys >>= \cols => orderedScan schema cols input else Nothing) of
              Just walk => walk
              Nothing => PSort keys input
  plan schema ctx needed few (LDistinct child) =
    PDedup (PSort (columnKeys ctx (\el => el)) (plan schema ctx (allOf ctx) False child))
  plan schema ctx needed few (LLimit l o child) = PLimit l o (plan schema ctx needed True child)

  -- Join method and order. Candidates: a nested loop; an index join that
  -- searches the right table; and, for an inner join, an index join that
  -- searches the left table with the right one as the outer side (its
  -- columns are then put back in the declared order).
  join : Schema -> (a : List SqlType) -> (b : List SqlType) -> (needed : SortedSet Nat) -> JoinKind ->
         LPlan a -> LPlan b -> Maybe (TExpr (a ++ b) TBool) -> PPlan (a ++ b)
  join schema a b needed kind l r on =
    let (needL, needR) = splitNeeded (length a) needed
        left = plan schema a needL False l
        right = plan schema b needR False r
        lrows = estimate l
        rrows = estimate r
        nested = (PNestedLoop kind left right on, lrows * rrows)
        viaRight = baseScan r >>= \inner => indexJoin schema a kind left lrows inner needR on
        viaLeft = if kind /= JInner then Nothing
                  else do inner <- baseScan l
                          on' <- traverse (rename (\el => Just (swapElem a b el))) on
                          (p, cost) <- indexJoin schema b JInner right rrows inner needL on'
                          Just (PProject (swapColumns a b) p, cost)
    in fst (foldl (\best, c => if snd c < snd best then c else best) nested
                  (toList viaRight ++ toList viaLeft))

||| Optimize and plan a checked query.
export
planQuery : Schema -> (q : Query) -> PPlan q.shape
planQuery schema q = plan schema q.shape (allOf q.shape) False (optimize q.plan)

-- EXPLAIN.

accessParams : Access o -> List (Nat, SqlType)
accessParams FullScan = []
accessParams (RowidEq e) = paramsOf e
accessParams (RowidRange lo hi) = maybe [] (paramsOf . fst) lo ++ maybe [] (paramsOf . fst) hi
accessParams (IndexScan _ eqs range) =
  concatMap (\(MkKeyExpr _ e) => paramsOf e) eqs
  ++ maybe [] (\r => maybe [] (paramsOf . fst) r.lo ++ maybe [] (paramsOf . fst) r.hi) range

nameAt : List String -> Nat -> String
nameAt names i = fromMaybe ("#" ++ show i) (getAt i names)

tableNames : TableDef -> String -> List String
tableNames tbl label = map (\c => label ++ "." ++ c.name) tbl.columns

columnName : TableDef -> Nat -> String
columnName tbl i = maybe ("#" ++ show i) (.name) (getAt i tbl.columns)

boundText : (outer : List String) -> (column : String) -> (lower : Bool) -> (TExpr o t, Bool) -> String
boundText outer column lower (e, incl) =
  column ++ (if lower then (if incl then " >= " else " > ") else (if incl then " <= " else " < "))
         ++ showExpr (nameAt outer) e

andText : List String -> String
andText = concat . intersperse " AND "

accessText : (tbl : TableDef) -> (label : String) -> (outer : List String) -> Access o -> String
accessText tbl label outer FullScan = "SCAN " ++ label
accessText tbl label outer (RowidEq e) =
  "SEARCH " ++ label ++ " USING ROWID ("
    ++ maybe "rowid" (columnName tbl) tbl.rowidColumn ++ " = " ++ showExpr (nameAt outer) e ++ ")"
accessText tbl label outer (RowidRange lo hi) =
  let col = maybe "rowid" (columnName tbl) tbl.rowidColumn
  in "SEARCH " ++ label ++ " USING ROWID ("
       ++ andText (toList (map (boundText outer col True) lo) ++ toList (map (boundText outer col False) hi)) ++ ")"
accessText tbl label outer (IndexScan idx eqs range) =
  let cols = map (columnName tbl) idx.columns
      eqText = zipWith (\c, (MkKeyExpr _ e) => c ++ " = " ++ showExpr (nameAt outer) e) cols eqs
      next = fromMaybe "?" (getAt (length eqs) cols)
      rangeText = case range of
                    Nothing => []
                    Just r => toList (map (boundText outer next True) r.lo)
                              ++ toList (map (boundText outer next False) r.hi)
      terms = eqText ++ rangeText
  in if isNil terms then "SCAN " ++ label ++ " USING INDEX " ++ idx.name ++ " (in index order)"
     else "SEARCH " ++ label ++ " USING INDEX " ++ idx.name ++ " (" ++ andText terms ++ ")"

||| How a single-table statement finds its rows, as EXPLAIN text.
export
explainAccess : (tbl : TableDef) -> Access [] -> String
explainAccess tbl access = accessText tbl tbl.name [] access

commaText : List String -> String
commaText = concat . intersperse ", "

exprsText : List String -> Exprs ctx out -> List String
exprsText names [] = []
exprsText names (e :: es) = showExpr (nameAt names) e :: exprsText names es

aggsText : List String -> Aggs ctx rs -> List String
aggsText names ANil = []
aggsText names (ACons a rest) = showAgg (nameAt names) a :: aggsText names rest

keyText : List String -> SortKey ctx -> String
keyText names k = showExpr (nameAt names) k.expr ++ (if k.dir == Desc then " DESC" else "")

joinWord : JoinKind -> String
joinWord JInner = "JOIN"
joinWord JLeft = "LEFT JOIN"

indent : List String -> List String
indent = map ("  " ++)

||| Column labels of a plan's output, and the plan as indented lines.
describe : PPlan ctx -> (List String, List String)
describe (PScan tbl label _ access) = (tableNames tbl label, [accessText tbl label [] access])
describe POneRow = ([], ["CONSTANT ROW"])
describe (PFilter pred p) =
  let (names, ls) = describe p
  in (names, ("FILTER " ++ showExpr (nameAt names) pred) :: indent ls)
describe (PProject es p) =
  let (names, ls) = describe p
      out = exprsText names es
  in (out, ("PROJECT " ++ commaText out) :: indent ls)
describe (PNestedLoop kind l r on) =
  let (ln, ll) = describe l
      (rn, rl) = describe r
      names = ln ++ rn
      cond = maybe "" (\e => " ON " ++ showExpr (nameAt names) e) on
  in (names, ("NESTED LOOP " ++ joinWord kind ++ cond) :: indent (ll ++ rl))
describe (PIndexJoin kind outer tbl label _ access on) =
  let (on', ol) = describe outer
      names = on' ++ tableNames tbl label
      cond = maybe "" (\e => " ON " ++ showExpr (nameAt names) e) on
  in (names, ("INDEX " ++ joinWord kind ++ cond) :: indent (ol ++ [accessText tbl label on' access]))
describe (PAggregate keys aggs p) =
  let (names, ls) = describe p
      ks = exprsText names keys
      as' = aggsText names aggs
      line = "AGGREGATE " ++ commaText as' ++ (if isNil ks then "" else " GROUP BY " ++ commaText ks)
  in (ks ++ as', line :: indent ls)
describe (PSort keys p) =
  let (names, ls) = describe p
  in (names, ("SORT BY " ++ commaText (map (keyText names) keys)) :: indent ls)
describe (PDedup p) =
  let (names, ls) = describe p
  in (names, "DISTINCT" :: indent ls)
describe (PLimit l o p) =
  let (names, ls) = describe p
      lim = maybe "" (\e => "LIMIT " ++ showExpr (nameAt []) e) l
      off = maybe "" (\e => "OFFSET " ++ showExpr (nameAt []) e) o
  in (names, unwords (filter (/= "") [lim, off]) :: indent ls)

||| The physical plan as text, one operator per line, inputs indented.
export
explainPlan : PPlan ctx -> List String
explainPlan p = snd (describe p)

describeLogical : LPlan ctx -> (List String, List String)
describeLogical (LScan tbl label) = (tableNames tbl label, ["TABLE " ++ label])
describeLogical LOneRow = ([], ["CONSTANT ROW"])
describeLogical (LFilter pred p) =
  let (names, ls) = describeLogical p
  in (names, ("SELECT " ++ showExpr (nameAt names) pred) :: indent ls)
describeLogical (LProject es p) =
  let (names, ls) = describeLogical p
      out = exprsText names es
  in (out, ("PROJECT " ++ commaText out) :: indent ls)
describeLogical (LJoin kind l r on) =
  let (ln, ll) = describeLogical l
      (rn, rl) = describeLogical r
      names = ln ++ rn
      cond = maybe "" (\e => " ON " ++ showExpr (nameAt names) e) on
  in (names, (joinWord kind ++ cond) :: indent (ll ++ rl))
describeLogical (LAggregate keys aggs p) =
  let (names, ls) = describeLogical p
      ks = exprsText names keys
      as' = aggsText names aggs
      line = "AGGREGATE " ++ commaText as' ++ (if isNil ks then "" else " GROUP BY " ++ commaText ks)
  in (ks ++ as', line :: indent ls)
describeLogical (LSort keys p) =
  let (names, ls) = describeLogical p
  in (names, ("SORT BY " ++ commaText (map (keyText names) keys)) :: indent ls)
describeLogical (LDistinct p) =
  let (names, ls) = describeLogical p
  in (names, "DISTINCT" :: indent ls)
describeLogical (LLimit l o p) =
  let (names, ls) = describeLogical p
      lim = maybe "" (\e => "LIMIT " ++ showExpr (nameAt []) e) l
      off = maybe "" (\e => "OFFSET " ++ showExpr (nameAt []) e) o
  in (names, unwords (filter (/= "") [lim, off]) :: indent ls)

||| A logical plan as text.
export
explainLogical : LPlan ctx -> List String
explainLogical p = snd (describeLogical p)
