module IdrisQL.Index.BPlusTree

import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedSet
import IdrisQL.Error
import IdrisQL.Index.Node
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Codec
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page
import IdrisQL.Storage.Pager

-- A B+ tree over byte-string keys compared bytewise. Values live in the
-- leaves; leaves are linked left to right. The root page id never changes:
-- when the root splits its contents move to a new page, and when it is left
-- with a single child that child's contents move into it.
--
-- Internal node with keys k0..k(n-1) and children c0..cn: child ci holds
-- the keys in [k(i-1), ki). Cell i stores (ki, ci); cn is the page's right
-- pointer.

Usable : Int
Usable = PageSize - HeaderSize

-- A node below this many used bytes tries to merge with or borrow from a
-- sibling. A quarter rather than a half keeps variable-length cells from
-- bouncing between split and merge.
MinFill : Int
MinFill = Usable `div` 4

MaxDepth : Int
MaxDepth = 64

weight : Bytes -> Nat
weight c = cast (size c + 2)

totalWeight : List Bytes -> Int
totalWeight = foldl (\acc, c => acc + size c + 2) 0

-- 0 .. n-1. (`[0 .. n - 1]` counts down when n is 0.)
indices : Int -> List Int
indices n = if n <= 0 then [] else [0 .. n - 1]

tooDeep : Int -> DB ()
tooDeep depth = when' (depth > MaxDepth) (Corrupt "B+ tree is deeper than 64 levels")

notANode : Int -> Int -> DbError
notANode pageId t = Corrupt ("page " ++ show pageId ++ " of type " ++ show t ++ " is not a tree node")

||| Index of the first slot whose key is >= `key`, and whether it is equal.
export
searchPage : Page -> (key : Bytes) -> DB (Int, Bool)
searchPage p key = do
  n <- liftIO (slotCount p)
  go 0 n
  where
    go : Int -> Int -> DB (Int, Bool)
    go lo hi =
      if lo >= hi then pure (lo, False)
      else do
        let mid = (lo + hi) `div` 2
        o <- compareSlotKey p mid key
        case o of
          LT => go (mid + 1) hi
          EQ => pure (mid, True)
          GT => go lo mid

||| Child `j` of an internal page, where `j` equal to the slot count means
||| the rightmost child.
export
childAt : Page -> (j : Int) -> DB Int
childAt p j = do
  n <- liftIO (slotCount p)
  if j < n then internalChild p j else liftIO (rightPointer p)

||| Index and page id of the child whose range contains `key`.
export
childFor : Page -> (key : Bytes) -> DB (Int, Int)
childFor p key = do
  (i, exact) <- searchPage p key
  let j = if exact then i + 1 else i
  c <- childAt p j
  pure (j, c)

-- Overflow chains.

writeChain : Pager -> Bytes -> (off : Int) -> DB Int
writeChain pg val off =
  if off >= size val then pure 0
  else do
    next <- writeChain pg val (off + OverflowCapacity)
    chunk <- sub val off (min OverflowCapacity (size val - off))
    pageId <- allocPage pg ptOverflow
    withPageMut (pagerPool pg) pageId (\p => writeOverflow p chunk next)
    pure pageId

readChain : Pager -> (first : Int) -> (full : Int) -> DB Bytes
readChain pg first full = do
  bd <- newBuilder full
  go bd first (full `div` OverflowCapacity + 2)
  out <- finish bd
  when' (size out /= full)
    (Corrupt ("overflow chain holds " ++ show (size out) ++ " bytes, expected " ++ show full))
  pure out
  where
    go : Builder -> Int -> Int -> DB ()
    go bd pageId fuel =
      if pageId == 0 then pure ()
      else do
        when' (fuel <= 0) (Corrupt "overflow chain is longer than its recorded length")
        (chunk, next) <- withPage (pagerPool pg) pageId readOverflow
        putBytes bd chunk
        go bd next (fuel - 1)

freeChain : Pager -> (first : Int) -> (fuel : Int) -> DB ()
freeChain pg pageId fuel =
  if pageId == 0 then pure ()
  else do
    when' (fuel <= 0) (Corrupt "overflow chain is cyclic")
    (_, next) <- withPage (pagerPool pg) pageId readOverflow
    freePage pg pageId
    freeChain pg next (fuel - 1)

dropOverflow : Pager -> Maybe (Int, Int) -> DB ()
dropOverflow pg Nothing = pure ()
dropOverflow pg (Just (first, full)) = freeChain pg first (full `div` OverflowCapacity + 2)

||| The value of a leaf cell, following its overflow chain if it has one.
export
cellValue : Pager -> LeafCell -> DB Bytes
cellValue pg c = case c.overflow of
  Nothing => pure c.inline
  Just (first, full) => readChain pg first full

makeCell : Pager -> (key : Bytes) -> (val : Bytes) -> DB Bytes
makeCell pg key val =
  if size key + size val <= MaxInlinePayload
    then mkLeafCell key val Nothing
    else do
      first <- writeChain pg val 0
      none <- emptyBytes
      mkLeafCell key none (Just (first, size val))

-- Whole-node helpers used by splits, merges and redistribution.

allCells : Page -> DB (List Bytes)
allCells p = do
  n <- liftIO (slotCount p)
  go (n - 1) []
  where
    go : Int -> List Bytes -> DB (List Bytes)
    go i acc = if i < 0 then pure acc else do
      c <- cellCopy p i
      go (i - 1) (c :: acc)

nodeContents : Page -> DB (Int, List Bytes, Int)
nodeContents p = do
  t <- liftIO (pageType p)
  cells <- allCells p
  right <- liftIO (rightPointer p)
  pure (t, cells, right)

rebuild : Page -> (ptype : Int) -> List Bytes -> (right : Int) -> DB ()
rebuild p ptype cells right = do
  liftIO $ do
    initPage p ptype
    setRightPointer p right
  go 0 cells
  where
    go : Int -> List Bytes -> DB ()
    go _ [] = pure ()
    go i (c :: cs) = do
      ok <- insertCell p i c
      when' (not ok) (RuntimeError "internal: cells do not fit the page they were assigned to")
      go (i + 1) cs

cellKeyOf : (ptype : Int) -> (cell : Bytes) -> DB Bytes
cellKeyOf ptype c = do
  klen <- peekU16 c 0
  sub c (if ptype == ptLeaf then 5 else 6) klen

cellChildOf : (cell : Bytes) -> DB Int
cellChildOf c = peekU32 c 2

-- Insertion.

data Split = NoSplit | DidSplit Bytes Int

splitLeaf : Pager -> (pageId : Int) -> (slot : Int) -> (cell : Bytes) -> DB Split
splitLeaf pg pageId slot cell = do
  let pool = pagerPool pg
  cells <- withPage pool pageId allCells
  let merged = insertAt (cast slot) cell cells
  let c = cutAt weight (cast (totalWeight merged `div` 2)) merged
  case c.right of
    [] => throw (RuntimeError "internal: leaf split left nothing for the new page")
    (firstRight :: _) => do
      sep <- cellKeyOf ptLeaf firstRight
      rightId <- allocPage pg ptLeaf
      oldNext <- withPageMut pool pageId $ \p => do
        oldNext <- liftIO (rightPointer p)
        rebuild p ptLeaf c.left rightId
        pure oldNext
      withPageMut pool rightId (\p => rebuild p ptLeaf c.right oldNext)
      pure (DidSplit sep rightId)

splitInternal : Pager -> (pageId : Int) -> (slot : Int) -> (cell : Bytes) -> (newRight : Int) -> DB Split
splitInternal pg pageId slot cell newRight = do
  let pool = pagerPool pg
  (_, cells, oldRight) <- withPage pool pageId nodeContents
  let inserted = insertAt (cast slot) cell cells
  -- The pointer that followed the insertion point now leads to `newRight`.
  (fixed, right) <- if slot + 1 >= cast (length inserted)
                      then pure (inserted, newRight)
                      else do cs <- repoint (slot + 1) inserted
                              pure (cs, oldRight)
  case cutMiddle weight (cast (totalWeight fixed `div` 2)) fixed of
    Nothing => throw (RuntimeError "internal: internal split with fewer than two cells")
    Just c => do
      sep <- cellKeyOf ptInternal c.mid
      midChild <- cellChildOf c.mid
      newId <- allocPage pg ptInternal
      withPageMut pool pageId (\p => rebuild p ptInternal c.left midChild)
      withPageMut pool newId (\p => rebuild p ptInternal c.right right)
      pure (DidSplit sep newId)
  where
    repoint : Int -> List Bytes -> DB (List Bytes)
    repoint _ [] = pure []
    repoint i (c :: cs) =
      if i == 0
        then do k <- cellKeyOf ptInternal c
                c' <- mkInternalCell k newRight
                pure (c' :: cs)
        else map (c ::) (repoint (i - 1) cs)

-- Returns whether an existing key was replaced, and a split to apply above.
insertInto : Pager -> (depth : Int) -> (pageId : Int) -> (key : Bytes) -> (val : Bytes) -> DB (Bool, Split)
insertInto pg depth pageId key val = do
  tooDeep depth
  let pool = pagerPool pg
  t <- withPage pool pageId (\p => liftIO (pageType p))
  if t == ptLeaf
    then do
      cell <- makeCell pg key val
      (slot, replaced, old, ok) <- the (DB (Int, Bool, Maybe (Int, Int), Bool)) $ withPageMut pool pageId $ \p => do
        (i, exact) <- searchPage p key
        old <- if exact
                 then do c <- readLeafCell p i
                         deleteCell p i
                         pure c.overflow
                 else pure Nothing
        ok <- insertCell p i cell
        pure (i, exact, old, ok)
      dropOverflow pg old
      if ok then pure (replaced, NoSplit)
        else do sp <- splitLeaf pg pageId slot cell
                pure (replaced, sp)
    else if t == ptInternal
    then do
      (j, child) <- withPage pool pageId (\p => childFor p key)
      (replaced, sp) <- insertInto pg (depth + 1) child key val
      case sp of
        NoSplit => pure (replaced, NoSplit)
        DidSplit sep rightId => do
          cell <- mkInternalCell sep child
          ok <- withPageMut pool pageId $ \p => do
            n <- liftIO (slotCount p)
            ok <- insertCell p j cell
            when ok $
              if j < n then setInternalChild p (j + 1) rightId
                       else liftIO (setRightPointer p rightId)
            pure ok
          if ok then pure (replaced, NoSplit)
            else do sp' <- splitInternal pg pageId j cell rightId
                    pure (replaced, sp')
    else throw (notANode pageId t)

||| Insert or replace. Returns True when the key is new.
export
put : Pager -> (root : Int) -> (key : Bytes) -> (val : Bytes) -> DB Bool
put pg root key val = do
  when' (size key > MaxKeySize)
    (RuntimeError ("index key of " ++ show (size key) ++ " bytes exceeds the limit of "
                   ++ show MaxKeySize))
  (replaced, sp) <- insertInto pg 0 root key val
  case sp of
    NoSplit => pure ()
    DidSplit sep rightId => do
      let pool = pagerPool pg
      t <- withPage pool root (\p => liftIO (pageType p))
      leftId <- allocPage pg t
      withPage pool root $ \src =>
        withPageMut pool leftId (\dst => liftIO (copyPage src dst))
      cell <- mkInternalCell sep leftId
      withPageMut pool root (\p => rebuild p ptInternal [cell] rightId)
  pure (not replaced)

-- Deletion.

-- After the two children around separator `li` were merged into `leftId`:
-- remove the separator and point its successor at the surviving child.
dropSeparator : Pager -> (parentId : Int) -> (li : Int) -> (leftId : Int) -> DB ()
dropSeparator pg parentId li leftId =
  withPageMut (pagerPool pg) parentId $ \p => do
    deleteCell p li
    n <- liftIO (slotCount p)
    if li < n then setInternalChild p li leftId else liftIO (setRightPointer p leftId)

-- Replace separator `li`. False, with nothing changed, when the new key does
-- not fit in the parent.
replaceSeparator : Pager -> (parentId : Int) -> (li : Int) -> (old : Bytes) -> (new : Bytes) -> (leftId : Int) -> DB Bool
replaceSeparator pg parentId li old new leftId =
  withPageMut (pagerPool pg) parentId $ \p => do
    free <- liftIO (freeBytes p)
    if size new - size old > free then pure False
      else do
        deleteCell p li
        cell <- mkInternalCell new leftId
        ok <- insertCell p li cell
        when' (not ok) (RuntimeError "internal: separator does not fit where its predecessor was")
        pure True

-- Child `j` of `parentId` is underfull: merge it with a sibling if both fit
-- in one page, otherwise even the two out.
rebalance : Pager -> (parentId : Int) -> (j : Int) -> DB ()
rebalance pg parentId j = do
  let pool = pagerPool pg
  n <- withPage pool parentId (\p => liftIO (slotCount p))
  if n == 0 then pure () else do
    let li = if j < n then j else j - 1
    (leftId, rightId, sep) <- withPage pool parentId $ \p => do
      l <- childAt p li
      r <- childAt p (li + 1)
      k <- slotKey p li
      pure (l, r, k)
    (lt, lcells, lright) <- withPage pool leftId nodeContents
    (rt, rcells, rright) <- withPage pool rightId nodeContents
    when' (lt /= rt) (Corrupt ("pages " ++ show leftId ++ " and " ++ show rightId
                               ++ " are siblings of different kinds"))
    if lt == ptLeaf
      then do
        let combined = lcells ++ rcells
        if totalWeight combined <= Usable
          then do
            withPageMut pool leftId (\p => rebuild p ptLeaf combined rright)
            freePage pg rightId
            dropSeparator pg parentId li leftId
          else do
            let c = cutAt weight (cast (totalWeight combined `div` 2)) combined
            case c.right of
              [] => pure ()
              (firstRight :: _) => do
                newSep <- cellKeyOf ptLeaf firstRight
                ok <- replaceSeparator pg parentId li sep newSep leftId
                when ok $ do
                  withPageMut pool leftId (\p => rebuild p ptLeaf c.left rightId)
                  withPageMut pool rightId (\p => rebuild p ptLeaf c.right rright)
      else do
        down <- mkInternalCell sep lright
        let combined = lcells ++ (down :: rcells)
        if totalWeight combined <= Usable
          then do
            withPageMut pool leftId (\p => rebuild p ptInternal combined rright)
            freePage pg rightId
            dropSeparator pg parentId li leftId
          else case cutMiddle weight (cast (totalWeight combined `div` 2)) combined of
            Nothing => pure ()
            Just c => do
              newSep <- cellKeyOf ptInternal c.mid
              midChild <- cellChildOf c.mid
              ok <- replaceSeparator pg parentId li sep newSep leftId
              when ok $ do
                withPageMut pool leftId (\p => rebuild p ptInternal c.left midChild)
                withPageMut pool rightId (\p => rebuild p ptInternal c.right rright)

-- Returns whether the key was found, and whether this node is now underfull.
deleteFrom : Pager -> (depth : Int) -> (pageId : Int) -> (key : Bytes) -> DB (Bool, Bool)
deleteFrom pg depth pageId key = do
  tooDeep depth
  let pool = pagerPool pg
  t <- withPage pool pageId (\p => liftIO (pageType p))
  if t == ptLeaf
    then do
      (i, exact) <- withPage pool pageId (\p => searchPage p key)
      if not exact then pure (False, False)
        else do
          (old, used) <- withPageMut pool pageId $ \p => do
            c <- readLeafCell p i
            deleteCell p i
            used <- liftIO (usedBytes p)
            pure (c.overflow, used)
          dropOverflow pg old
          pure (True, used < MinFill)
    else if t == ptInternal
    then do
      (j, child) <- withPage pool pageId (\p => childFor p key)
      (found, under) <- deleteFrom pg (depth + 1) child key
      if not under then pure (found, False)
        else do
          rebalance pg pageId j
          used <- withPage pool pageId (\p => liftIO (usedBytes p))
          pure (found, used < MinFill)
    else throw (notANode pageId t)

-- While the root is an internal page with one child, pull the child up.
contractRoot : Pager -> (root : Int) -> (fuel : Int) -> DB ()
contractRoot pg root fuel = do
  let pool = pagerPool pg
  (t, n, child) <- withPage pool root $ \p => liftIO $ do
    t <- pageType p
    n <- slotCount p
    c <- rightPointer p
    pure (t, n, c)
  when (t == ptInternal && n == 0 && fuel > 0) $ do
    withPage pool child $ \src =>
      withPageMut pool root (\dst => liftIO (copyPage src dst))
    freePage pg child
    contractRoot pg root (fuel - 1)

||| Remove a key. Returns False when it was not present.
export
delete : Pager -> (root : Int) -> (key : Bytes) -> DB Bool
delete pg root key = do
  (found, _) <- deleteFrom pg 0 root key
  when found (contractRoot pg root MaxDepth)
  pure found

-- Lookup.

||| The value stored under `key`.
export
lookup : Pager -> (root : Int) -> (key : Bytes) -> DB (Maybe Bytes)
lookup pg root key = go 0 root
  where
    go : Int -> Int -> DB (Maybe Bytes)
    go depth pageId = do
      tooDeep depth
      r <- the (DB (Either (Maybe LeafCell) Int)) $ withPage (pagerPool pg) pageId $ \p => do
        t <- liftIO (pageType p)
        if t == ptLeaf
          then do
            (i, exact) <- searchPage p key
            if exact then map (Left . Just) (readLeafCell p i) else pure (Left Nothing)
          else if t == ptInternal then map (Right . snd) (childFor p key)
          else throw (notANode pageId t)
      case r of
        Left Nothing => pure Nothing
        Left (Just cell) => map Just (cellValue pg cell)
        Right child => go (depth + 1) child

-- Creation and destruction.

||| Allocate an empty tree and return its root page.
export
createTree : Pager -> DB Int
createTree pg = allocPage pg ptLeaf

freeSubtree : Pager -> (depth : Int) -> (pageId : Int) -> DB ()
freeSubtree pg depth pageId = do
  tooDeep depth
  let pool = pagerPool pg
  t <- withPage pool pageId (\p => liftIO (pageType p))
  if t == ptLeaf
    then do
      chains <- withPage pool pageId $ \p => do
        n <- liftIO (slotCount p)
        traverse (\i => map (.overflow) (readLeafCell p i)) (indices n)
      traverse_ (dropOverflow pg) chains
    else if t == ptInternal
    then do
      (_, cells, right) <- withPage pool pageId nodeContents
      children <- traverse cellChildOf cells
      traverse_ (freeSubtree pg (depth + 1)) (children ++ [right])
    else throw (notANode pageId t)
  freePage pg pageId

||| Remove every entry, keeping the root page.
export
clearTree : Pager -> (root : Int) -> DB ()
clearTree pg root = do
  let pool = pagerPool pg
  t <- withPage pool root (\p => liftIO (pageType p))
  if t == ptInternal
    then do
      (_, cells, right) <- withPage pool root nodeContents
      children <- traverse cellChildOf cells
      traverse_ (freeSubtree pg 1) (children ++ [right])
    else do
      chains <- withPage pool root $ \p => do
        n <- liftIO (slotCount p)
        traverse (\i => map (.overflow) (readLeafCell p i)) (indices n)
      traverse_ (dropOverflow pg) chains
  withPageMut pool root (\p => liftIO (initPage p ptLeaf))

||| Free every page of the tree, including the root.
export
destroyTree : Pager -> (root : Int) -> DB ()
destroyTree pg root = clearTree pg root >> freePage pg root

-- Validation.

public export
record TreeInfo where
  constructor MkTreeInfo
  ||| Levels from root to leaf; a tree that is a single leaf has depth 1.
  depth : Int
  leaves : Int
  internals : Int
  overflowPages : Int
  entries : Int
  ||| Non-root leaves holding no entry.
  emptyLeaves : Int
  ||| Bytes of cells and slots over all nodes.
  usedBytes : Int
  ||| Every page of the tree, overflow pages included.
  pages : SortedSet Int

record NodeView where
  constructor MkNodeView
  ptype : Int
  slots : Int
  right : Int
  used : Int
  keys : List Bytes
  cellBytes : Int

record Acc where
  constructor MkAcc
  seen : IORef (SortedSet Int)
  leafDepth : IORef (Maybe Int)
  chain : IORef (List (Int, Int))
  leaves : IORef Int
  internals : IORef Int
  overflowPages : IORef Int
  entries : IORef Int
  emptyLeaves : IORef Int
  used : IORef Int

||| Walk the whole tree and fail with `Corrupt` on the first violation of:
||| keys strictly ascending inside a node and inside the range given by the
||| ancestors' separators; every leaf at the same depth; the leaf chain
||| visiting exactly the leaves, in key order; no page reachable twice; each
||| node's free-space accounting matching its cells; each overflow chain
||| matching its recorded length.
export
validate : Pager -> (root : Int) -> DB TreeInfo
validate pg root = do
  acc <- pure (MkAcc !(newIORef empty) !(newIORef Nothing) !(newIORef [])
                 !(newIORef 0) !(newIORef 0) !(newIORef 0) !(newIORef 0)
                 !(newIORef 0) !(newIORef 0))
  node acc 1 root Nothing Nothing
  links <- readIORef acc.chain
  checkChain (reverse links)
  depth <- readIORef acc.leafDepth
  pure (MkTreeInfo (fromMaybe 0 depth) !(readIORef acc.leaves) !(readIORef acc.internals)
          !(readIORef acc.overflowPages) !(readIORef acc.entries)
          !(readIORef acc.emptyLeaves) !(readIORef acc.used) !(readIORef acc.seen))
  where
    visit : Acc -> Int -> DB ()
    visit acc pageId = do
      s <- readIORef acc.seen
      when' (contains pageId s) (Corrupt ("page " ++ show pageId ++ " is reachable twice"))
      writeIORef acc.seen (insert pageId s)

    ascending : Int -> List Bytes -> DB ()
    ascending pageId (a :: rest@(b :: _)) = do
      o <- liftIO (compareBytes a b)
      when' (o /= LT) (Corrupt ("keys out of order in page " ++ show pageId))
      ascending pageId rest
    ascending _ _ = pure ()

    below : Int -> Bytes -> Maybe Bytes -> DB ()
    below _ _ Nothing = pure ()
    below pageId k (Just l) = do
      o <- liftIO (compareBytes k l)
      when' (o == LT) (Corrupt ("key below its range in page " ++ show pageId))

    above : Int -> Bytes -> Maybe Bytes -> DB ()
    above _ _ Nothing = pure ()
    above pageId k (Just h) = do
      o <- liftIO (compareBytes k h)
      when' (o /= LT) (Corrupt ("key above its range in page " ++ show pageId))

    overflow : Acc -> (pageId : Int) -> (remaining : Int) -> DB ()
    overflow acc pageId remaining =
      if pageId == 0
        then when' (remaining /= 0) (Corrupt "overflow chain shorter than its recorded length")
        else do
          visit acc pageId
          (chunk, next) <- withPage (pagerPool pg) pageId readOverflow
          when' (size chunk > remaining) (Corrupt "overflow chain longer than its recorded length")
          modifyIORef acc.overflowPages (+ 1)
          overflow acc next (remaining - size chunk)

    chainOf : Acc -> Maybe (Int, Int) -> DB ()
    chainOf _ Nothing = pure ()
    chainOf acc (Just (first, full)) = overflow acc first full

    bounds : (lo : Maybe Bytes) -> List Bytes -> (hi : Maybe Bytes) -> List (Maybe Bytes, Maybe Bytes)
    bounds lo [] hi = [(lo, hi)]
    bounds lo (k :: ks) hi = (lo, Just k) :: bounds (Just k) ks hi

    view : Int -> Page -> DB NodeView
    view pageId p = do
      t <- liftIO (pageType p)
      when' (t /= ptLeaf && t /= ptInternal) (notANode pageId t)
      n <- liftIO (slotCount p)
      right <- liftIO (rightPointer p)
      used <- liftIO (usedBytes p)
      keys <- traverse (slotKey p) (indices n)
      sizes <- traverse (\i => slotOffset p i >>= cellSize p) (indices n)
      pure (MkNodeView t n right used keys (sum sizes))

    node : Acc -> (depth : Int) -> (pageId : Int) -> (lo : Maybe Bytes) -> (hi : Maybe Bytes) -> DB ()
    node acc depth pageId lo hi = do
      tooDeep depth
      visit acc pageId
      let pool = pagerPool pg
      v <- withPage pool pageId (view pageId)
      when' (v.used /= v.cellBytes + 2 * v.slots)
        (Corrupt ("free-space accounting is wrong in page " ++ show pageId))
      ascending pageId v.keys
      traverse_ (\k => below pageId k lo >> above pageId k hi) v.keys
      modifyIORef acc.used (+ v.used)
      if v.ptype == ptLeaf
        then do
          known <- readIORef acc.leafDepth
          case known of
            Nothing => writeIORef acc.leafDepth (Just depth)
            Just d => when' (d /= depth)
                        (Corrupt ("leaf " ++ show pageId ++ " is at depth " ++ show depth
                                  ++ ", others at " ++ show d))
          modifyIORef acc.chain ((pageId, v.right) ::)
          chains <- withPage pool pageId $ \p =>
            traverse (\i => map (.overflow) (readLeafCell p i)) (indices v.slots)
          traverse_ (chainOf acc) chains
          modifyIORef acc.leaves (+ 1)
          modifyIORef acc.entries (+ v.slots)
          when (v.slots == 0 && pageId /= root) (modifyIORef acc.emptyLeaves (+ 1))
        else do
          children <- withPage pool pageId (\p => traverse (childAt p) (indices (v.slots + 1)))
          modifyIORef acc.internals (+ 1)
          traverse_ (\(child, range) => node acc (depth + 1) child (fst range) (snd range))
                    (zip children (bounds lo v.keys hi))

    checkChain : List (Int, Int) -> DB ()
    checkChain [] = pure ()
    checkChain [(pageId, right)] =
      when' (right /= 0) (Corrupt ("last leaf " ++ show pageId ++ " links to page " ++ show right))
    checkChain ((pageId, right) :: rest@((next, _) :: _)) = do
      when' (right /= next)
        (Corrupt ("leaf " ++ show pageId ++ " links to page " ++ show right
                  ++ " but the next leaf is " ++ show next))
      checkChain rest
