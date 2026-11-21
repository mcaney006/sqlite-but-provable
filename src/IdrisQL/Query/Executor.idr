module IdrisQL.Query.Executor

import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedSet
import IdrisQL.Catalog.Record
import IdrisQL.Catalog.Schema
import IdrisQL.Error
import IdrisQL.Index.BPlusTree
import IdrisQL.Index.Cursor
import IdrisQL.Index.KeyCodec
import IdrisQL.Query.Algebra
import IdrisQL.Query.Planner
import IdrisQL.Query.Sorter
import IdrisQL.SQL.AST
import IdrisQL.SQL.Typed
import IdrisQL.Storage.Codec
import IdrisQL.Storage.Pager
import IdrisQL.Types

-- Pull-based execution. Every operator is a `RowSource`: an action that
-- returns the next row or Nothing. Rows flow one at a time; only sorting
-- (and the grouping and DISTINCT built on it) holds more than one row, and
-- the sorter bounds that with run files.

public export
record Exec where
  constructor MkExec
  pager : Pager
  params : List Value
  sorter : SortEnv

public export
RowSource : List SqlType -> Type
RowSource ctx = DB (Maybe (Row ctx))

evalIn : Exec -> Row ctx -> TExpr ctx t -> DB (Cell t)
evalIn ex row e = liftE (eval ex.params row e)

holds : Exec -> Row ctx -> TExpr ctx TBool -> DB Bool
holds ex row e = map (== Just True) (evalIn ex row e)

-- Table access.

-- Encode the equality columns of an index search. Nothing when a value is
-- NULL, which no row can equal.
equalityPrefix : Exec -> Row o -> List (KeyExpr o) -> DB (Maybe Bytes)
equalityPrefix ex outer eqs = do
  bd <- newBuilder 32
  ok <- go bd eqs
  if ok then map Just (finish bd) else pure Nothing
  where
    go : Builder -> List (KeyExpr o) -> DB Bool
    go bd [] = pure True
    go bd (MkKeyExpr t e :: rest) = do
      Just v <- evalIn ex outer e | Nothing => pure False
      putKeyCell bd t (Just v)
      go bd rest

extend : Bytes -> (t : SqlType) -> Val t -> DB Bytes
extend pre t v = do
  bd <- newBuilder (size pre + 16)
  putBytes bd pre
  putKeyCell bd t (Just v)
  finish bd

extendTag : Bytes -> Int -> DB Bytes
extendTag pre tag = do
  bd <- newBuilder (size pre + 1)
  putBytes bd pre
  putU8 bd tag
  finish bd

fetchRow : Exec -> (tbl : TableDef) -> (needed : List Bool) -> Int64 -> DB (Maybe (Row (tableCtx tbl)))
fetchRow ex tbl needed rowid = do
  key <- rowidKey rowid
  Just bytes <- lookup ex.pager tbl.root key | Nothing => pure Nothing
  map Just (decodeRowMasked (tableCtx tbl) needed bytes)

-- A bound whose expression is NULL matches nothing.
data Edge a = Open | Never | At a Bool

edge : Exec -> Row o -> Maybe (TExpr o t, Bool) -> DB (Edge (Val t))
edge ex outer Nothing = pure Open
edge ex outer (Just (e, incl)) = do
  Just v <- evalIn ex outer e | Nothing => pure Never
  pure (At v incl)

isNever : Edge a -> Bool
isNever Never = True
isNever _ = False

-- Where an index range scan starts, and the key prefix to skip when the
-- lower bound is exclusive. Without a lower bound the scan starts after
-- the NULLs: a comparison with NULL is never TRUE.
lowerKey : (pre : Bytes) -> (t : SqlType) -> Edge (Val t) -> DB (Bytes, Maybe Bytes)
lowerKey pre t (At v incl) = do
  k <- extend pre t v
  pure (k, if incl then Nothing else Just k)
lowerKey pre t _ = do
  k <- extendTag pre tagAfterNull
  pure (k, Nothing)

upperKey : (pre : Bytes) -> (t : SqlType) -> Edge (Val t) -> DB (Maybe (Bytes, Bool))
upperKey pre t (At v incl) = do
  k <- extend pre t v
  pure (Just (k, incl))
upperKey pre t _ = pure Nothing

nothing : DB (DB (Maybe a))
nothing = pure (pure Nothing)

||| The rows of `tbl` selected by an access path, with their rowids. The
||| search values are computed from `outer`.
export
tableRows : Exec -> (tbl : TableDef) -> (needed : List Bool) -> Access o -> Row o ->
            DB (DB (Maybe (Int64, Row (tableCtx tbl))))
tableRows ex tbl needed FullScan outer = do
  c <- seek ex.pager tbl.root Nothing
  pure $ do
    Just (k, v) <- next c | Nothing => pure Nothing
    rowid <- keyRowid k
    row <- decodeRowMasked (tableCtx tbl) needed v
    pure (Just (rowid, row))
tableRows ex tbl needed (RowidEq e) outer = do
  Just rowid <- evalIn ex outer e | Nothing => nothing
  done <- newIORef False
  pure $ do
    False <- readIORef done | True => pure Nothing
    writeIORef done True
    Just row <- fetchRow ex tbl needed rowid | Nothing => pure Nothing
    pure (Just (rowid, row))
tableRows ex tbl needed (RowidRange lo hi) outer = do
  lower <- edge ex outer lo
  upper <- edge ex outer hi
  if isNever lower || isNever upper then nothing
    else do
      from <- the (DB (Maybe Bytes)) $ case lower of
                At v _ => map Just (rowidKey v)
                _ => pure Nothing
      c <- seek ex.pager tbl.root from
      done <- newIORef False
      pure (step c done lower upper)
  where
    step : Cursor -> IORef Bool -> Edge Int64 -> Edge Int64 -> DB (Maybe (Int64, Row (tableCtx tbl)))
    step c done lower upper = do
      False <- readIORef done | True => pure Nothing
      Just (k, v) <- next c | Nothing => pure Nothing
      rowid <- keyRowid k
      let skip = case lower of
                   At l False => rowid == l
                   _ => False
      let past = case upper of
                   At h incl => rowid > h || (rowid == h && not incl)
                   _ => False
      if past then writeIORef done True >> pure Nothing
        else if skip then step c done lower upper
        else do row <- decodeRowMasked (tableCtx tbl) needed v
                pure (Just (rowid, row))
tableRows ex tbl needed (IndexScan idx eqs range) outer = do
  Just pre <- equalityPrefix ex outer eqs | Nothing => nothing
  case range of
    Nothing => do
      c <- seek ex.pager idx.root (Just pre)
      pure (step c pre Nothing Nothing)
    Just r => do
      lower <- edge ex outer r.lo
      upper <- edge ex outer r.hi
      if isNever lower || isNever upper then nothing
        else do
          (from, exclude) <- lowerKey pre r.type lower
          stop <- upperKey pre r.type upper
          c <- seek ex.pager idx.root (Just from)
          pure (step c pre exclude stop)
  where
    step : Cursor -> (pre : Bytes) -> (exclude : Maybe Bytes) -> (stop : Maybe (Bytes, Bool)) ->
           DB (Maybe (Int64, Row (tableCtx tbl)))
    step c pre exclude stop = do
      Just key <- nextKey c | Nothing => pure Nothing
      True <- liftIO (hasPrefix pre key) | False => pure Nothing
      skip <- case exclude of
                Nothing => pure False
                Just k => liftIO (hasPrefix k key)
      within <- case stop of
                  Nothing => pure True
                  Just (k, incl) => do
                    o <- liftIO (compareBytes key k)
                    same <- liftIO (hasPrefix k key)
                    pure (if same then incl else o == LT)
      if not within then pure Nothing
        else if skip then step c pre exclude stop
        else do
          rowid <- keyRowid key
          Just row <- fetchRow ex tbl needed rowid
            | Nothing => throw (Corrupt ("index " ++ idx.name ++ " has an entry for a missing row"))
          pure (Just (rowid, row))

-- Aggregation.

record Runner (ctx : List SqlType) (t : SqlType) where
  constructor MkRunner
  step : Row ctx -> DB ()
  finish : DB (Cell t)

-- Values with the ordering of their SQL type, so they can live in a set.
record Keyed (t : SqlType) where
  constructor MkKeyed
  val : Val t

{t : SqlType} -> Eq (Keyed t) where
  a == b = compareVal t a.val b.val == EQ

{t : SqlType} -> Ord (Keyed t) where
  compare a b = compareVal t a.val b.val

-- Feed each non-NULL value of `e` to `use`, once per distinct value when
-- `distinct` is set.
feed : Exec -> (t : SqlType) -> (distinct : Bool) -> TExpr ctx t -> (use : Val t -> DB ()) ->
       DB (Row ctx -> DB ())
feed ex t distinct e use = do
  seen <- newIORef (the (SortedSet (Keyed t)) empty)
  pure $ \row => do
    Just v <- evalIn ex row e | Nothing => pure ()
    if not distinct then use v
      else do
        s <- readIORef seen
        if contains (MkKeyed v) s then pure ()
          else do writeIORef seen (insert (MkKeyed v) s)
                  use v

sumRunner : Exec -> IsNumeric t -> (distinct : Bool) -> TExpr ctx t -> DB (Runner ctx t)
sumRunner ex NumInt distinct e = do
  acc <- newIORef (the (Maybe Integer) Nothing)
  step <- feed ex TInt distinct e (\v => modifyIORef acc (\s => Just (fromMaybe 0 s + cast v)))
  pure (MkRunner step $ do
    Just s <- readIORef acc | Nothing => pure Nothing
    map Just (liftE (toInt64 s)))
sumRunner ex NumReal distinct e = do
  acc <- newIORef (the (Maybe Double) Nothing)
  step <- feed ex TReal distinct e (\v => modifyIORef acc (\s => Just (fromMaybe 0 s + v)))
  pure (MkRunner step (readIORef acc))

avgRunner : Exec -> IsNumeric t -> (distinct : Bool) -> TExpr ctx t -> DB (Runner ctx TReal)
avgRunner ex w distinct e = do
  acc <- newIORef (the (Double, Double) (0, 0))
  let MkSing t = numType w
  step <- feed ex t distinct e (\v => modifyIORef acc (\(s, n) => (s + widen w v, n + 1)))
  pure (MkRunner step $ do
    (s, n) <- readIORef acc
    pure (if n == 0 then Nothing else Just (s / n)))
  where
    widen : IsNumeric u -> Val u -> Double
    widen NumInt v = cast v
    widen NumReal v = v

extremeRunner : Exec -> (t : SqlType) -> (keep : Ordering) -> TExpr ctx t -> DB (Runner ctx t)
extremeRunner ex t keep e = do
  best <- newIORef (the (Cell t) Nothing)
  step <- feed ex t False e $ \v => do
    b <- readIORef best
    case b of
      Nothing => writeIORef best (Just v)
      Just old => when (compareVal t v old == keep) (writeIORef best (Just v))
  pure (MkRunner step (readIORef best))

runner : Exec -> Agg ctx t -> DB (Runner ctx t)
runner ex CountStar = do
  n <- newIORef (the Int64 0)
  pure (MkRunner (\_ => modifyIORef n (+ 1)) (map Just (readIORef n)))
runner ex (Count distinct t e) = do
  n <- newIORef (the Int64 0)
  step <- feed ex t distinct e (\_ => modifyIORef n (+ 1))
  pure (MkRunner step (map Just (readIORef n)))
runner ex (Sum w distinct e) = sumRunner ex w distinct e
runner ex (Avg w distinct e) = avgRunner ex w distinct e
runner ex (Min t e) = extremeRunner ex t LT e
runner ex (Max t e) = extremeRunner ex t GT e

data Runners : List SqlType -> List SqlType -> Type where
  RNil  : Runners ctx []
  RCons : Runner ctx t -> Runners ctx ts -> Runners ctx (t :: ts)

runners : Exec -> Aggs ctx rs -> DB (Runners ctx rs)
runners ex ANil = pure RNil
runners ex (ACons a rest) = [| RCons (runner ex a) (runners ex rest) |]

stepAll : Runners ctx rs -> Row ctx -> DB ()
stepAll RNil row = pure ()
stepAll (RCons r rest) row = r.step row >> stepAll rest row

finishAll : Runners ctx rs -> DB (Row rs)
finishAll RNil = pure []
finishAll (RCons r rest) = [| r.finish :: finishAll rest |]

-- Group consecutive input rows with equal keys. With no grouping columns
-- the whole input is one group, which exists even when the input is empty.
aggregate : Exec -> (gs : List SqlType) -> Exprs ctx gs -> Aggs ctx rs -> RowSource ctx ->
            DB (RowSource (gs ++ rs))
aggregate ex gs keys aggs input = do
  current <- newIORef (the (Maybe (Row gs, Runners ctx rs)) Nothing)
  finished <- newIORef False
  emitted <- newIORef False
  pure (pull current finished emitted)
  where
    close : Row gs -> Runners ctx rs -> DB (Maybe (Row (gs ++ rs)))
    close k rs' = do
      out <- finishAll rs'
      pure (Just (k ++ out))

    pull : IORef (Maybe (Row gs, Runners ctx rs)) -> IORef Bool -> IORef Bool -> DB (Maybe (Row (gs ++ rs)))
    pull current finished emitted = do
      False <- readIORef finished | True => pure Nothing
      r <- input
      cur <- readIORef current
      case r of
        Nothing => do
          writeIORef finished True
          case cur of
            Just (k, rs') => close k rs'
            Nothing => do
              any <- readIORef emitted
              if isNil gs && not any
                then do rs' <- runners ex aggs
                        out <- finishAll rs'
                        pure (Just (nullRow gs ++ out))
                else pure Nothing
        Just row => do
          k <- liftE (evalRow ex.params row keys)
          case cur of
            Nothing => do
              rs' <- runners ex aggs
              stepAll rs' row
              writeIORef current (Just (k, rs'))
              pull current finished emitted
            Just (k0, rs') =>
              if compareRow gs k0 k == EQ
                then stepAll rs' row >> pull current finished emitted
                else do
                  fresh <- runners ex aggs
                  stepAll fresh row
                  writeIORef current (Just (k, fresh))
                  writeIORef emitted True
                  close k0 rs'

-- Sorting.

data SomeKeys : List SqlType -> Type where
  MkSomeKeys : (ks : List SqlType) -> Exprs ctx ks -> List SortDir -> SomeKeys ctx

keysOf : List (SortKey ctx) -> SomeKeys ctx
keysOf [] = MkSomeKeys [] [] []
keysOf (k :: rest) =
  let MkSomeKeys ks es ds = keysOf rest
  in MkSomeKeys (k.type :: ks) (k.expr :: es) (k.dir :: ds)

constant : Exec -> Maybe (TExpr [] TInt) -> DB (Maybe Int64)
constant ex Nothing = pure Nothing
constant ex (Just e) = evalIn ex [] e

mutual
  ||| Start a plan and return its row source.
  export
  run : Exec -> (ctx : List SqlType) -> PPlan ctx -> DB (RowSource ctx)
  run ex _ (PScan tbl label needed access) = do
    rows <- tableRows ex tbl needed access []
    pure (map (map snd) rows)
  run ex _ POneRow = do
    done <- newIORef False
    pure $ do
      False <- readIORef done | True => pure Nothing
      writeIORef done True
      pure (Just [])
  run ex ctx (PFilter pred p) = do
    input <- run ex ctx p
    pure (filtered ex input pred)
  run ex _ (PProject {ctx = inner} es p) = do
    input <- run ex inner p
    pure $ do
      Just row <- input | Nothing => pure Nothing
      map Just (liftE (evalRow ex.params row es))
  run ex _ (PNestedLoop {a} {b} kind l r on) = do
    outer <- run ex a l
    joined ex a b kind outer (\_ => run ex b r) on
  run ex _ (PIndexJoin {a} kind l tbl label needed access on) = do
    outer <- run ex a l
    joined ex a (tableCtx tbl) kind outer
      (\row => map (map (map snd)) (tableRows ex tbl needed access row)) on
  run ex _ (PAggregate {ctx = inner} {gs} keys aggs p) = do
    input <- run ex inner p
    aggregate ex gs keys aggs input
  run ex ctx (PSort keys p) = do
    input <- run ex ctx p
    let MkSomeKeys ks es dirs = keysOf keys
    sortRows ex.sorter ks dirs ctx $ do
      Just row <- input | Nothing => pure Nothing
      k <- liftE (evalRow ex.params row es)
      pure (Just (k, row))
  run ex ctx (PDedup p) = do
    input <- run ex ctx p
    prev <- newIORef (the (Maybe (Row ctx)) Nothing)
    pure (distinct input prev)
    where
      distinct : RowSource ctx -> IORef (Maybe (Row ctx)) -> RowSource ctx
      distinct input prev = do
        Just row <- input | Nothing => pure Nothing
        last <- readIORef prev
        writeIORef prev (Just row)
        case last of
          Nothing => pure (Just row)
          Just old => if compareRow ctx old row == EQ then distinct input prev else pure (Just row)
  run ex ctx (PLimit l o p) = do
    limit <- constant ex l
    offset <- constant ex o
    input <- run ex ctx p
    toSkip <- newIORef (max 0 (fromMaybe 0 offset))
    -- A negative LIMIT means no limit, as in SQLite.
    left <- newIORef (case limit of
                        Just n => if n < 0 then Nothing else Just n
                        Nothing => Nothing)
    pure (limited input toSkip left)
    where
      limited : RowSource ctx -> IORef Int64 -> IORef (Maybe Int64) -> RowSource ctx
      limited input toSkip left = do
        remaining <- readIORef left
        if remaining == Just 0 then pure Nothing
          else do
            Just row <- input | Nothing => pure Nothing
            skip <- readIORef toSkip
            if skip > 0
              then writeIORef toSkip (skip - 1) >> limited input toSkip left
              else do writeIORef left (map (\n => n - 1) remaining)
                      pure (Just row)

  filtered : Exec -> RowSource ctx -> TExpr ctx TBool -> RowSource ctx
  filtered ex input pred = do
    Just row <- input | Nothing => pure Nothing
    True <- holds ex row pred | False => filtered ex input pred
    pure (Just row)

  -- Nested-loop join driver shared by both join methods: for each outer
  -- row, read the inner rows `inner` produces for it.
  joined : Exec -> (a : List SqlType) -> (b : List SqlType) -> JoinKind -> RowSource a ->
           (inner : Row a -> DB (RowSource b)) -> Maybe (TExpr (a ++ b) TBool) -> DB (RowSource (a ++ b))
  joined ex a b kind outer inner on = do
    state <- newIORef (the (Maybe (Row a, RowSource b, Bool)) Nothing)
    pure (pull state)
    where
      pull : IORef (Maybe (Row a, RowSource b, Bool)) -> RowSource (a ++ b)
      pull state = do
        cur <- readIORef state
        case cur of
          Nothing => do
            Just left <- outer | Nothing => pure Nothing
            rows <- inner left
            writeIORef state (Just (left, rows, False))
            pull state
          Just (left, rows, matched) => do
            r <- rows
            case r of
              Nothing => do
                writeIORef state Nothing
                if kind == JLeft && not matched
                  then pure (Just (left ++ nullRow b))
                  else pull state
              Just right => do
                let row = left ++ right
                ok <- case on of
                        Nothing => pure True
                        Just e => holds ex row e
                if ok then do writeIORef state (Just (left, rows, True))
                              pure (Just row)
                      else pull state
