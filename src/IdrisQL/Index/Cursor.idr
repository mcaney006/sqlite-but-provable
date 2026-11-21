module IdrisQL.Index.Cursor

import Data.IORef
import IdrisQL.Error
import IdrisQL.Index.BPlusTree
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Codec
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page
import IdrisQL.Storage.Pager

||| A forward position in the leaf chain. It holds a page id and a slot, not
||| a pinned page, so it costs no buffer-pool frame between calls. It is
||| invalidated by any write to the same tree.
export
record Cursor where
  constructor MkCursor
  pg : Pager
  leafRef : IORef Int
  slotRef : IORef Int

descend : Pager -> (depth : Int) -> (pageId : Int) -> (from : Maybe Bytes) -> DB (Int, Int)
descend pg depth pageId from = do
  when' (depth > 64) (Corrupt "B+ tree is deeper than 64 levels")
  r <- the (DB (Either (Int, Int) Int)) $ withPage (pagerPool pg) pageId $ \p => do
    t <- liftIO (pageType p)
    if t == ptLeaf
      then case from of
             Nothing => pure (Left (pageId, 0))
             Just key => do (i, _) <- searchPage p key
                            pure (Left (pageId, i))
      else if t == ptInternal
      then case from of
             Nothing => map Right (childAt p 0)
             Just key => map (Right . snd) (childFor p key)
      else throw (Corrupt ("page " ++ show pageId ++ " of type " ++ show t ++ " is not a tree node"))
  case r of
    Left pos => pure pos
    Right child => descend pg (depth + 1) child from

||| Position at the first entry whose key is >= `from`, or at the first
||| entry of the tree.
export
seek : Pager -> (root : Int) -> (from : Maybe Bytes) -> DB Cursor
seek pg root from = do
  (leaf, slot) <- descend pg 0 root from
  pure (MkCursor pg !(newIORef leaf) !(newIORef slot))

-- The cell under the cursor, advancing past it.
step : Cursor -> DB (Maybe LeafCell)
step c = do
  leaf <- readIORef c.leafRef
  if leaf == 0 then pure Nothing
    else do
      slot <- readIORef c.slotRef
      r <- the (DB (Either LeafCell Int)) $ withPage (pagerPool c.pg) leaf $ \p => do
        t <- liftIO (pageType p)
        when' (t /= ptLeaf) (Corrupt ("leaf chain reaches page " ++ show leaf ++ " of type " ++ show t))
        n <- liftIO (slotCount p)
        if slot < n then map Left (readLeafCell p slot)
                    else map Right (liftIO (rightPointer p))
      case r of
        Left cell => do
          writeIORef c.slotRef (slot + 1)
          pure (Just cell)
        Right nextLeaf => do
          writeIORef c.leafRef nextLeaf
          writeIORef c.slotRef 0
          step c

||| The next key and value in key order.
export
next : Cursor -> DB (Maybe (Bytes, Bytes))
next c = do
  Just cell <- step c | Nothing => pure Nothing
  val <- cellValue c.pg cell
  pure (Just (cell.key, val))

||| The next key, without reading its value.
export
nextKey : Cursor -> DB (Maybe Bytes)
nextKey c = map (map (.key)) (step c)

||| The greatest key in the tree.
export
lastKey : Pager -> (root : Int) -> DB (Maybe Bytes)
lastKey pg root = rightmost 0 root
  where
    scanAll : Cursor -> Maybe Bytes -> DB (Maybe Bytes)
    scanAll c best = do
      Just k <- nextKey c | Nothing => pure best
      scanAll c (Just k)

    rightmost : Int -> Int -> DB (Maybe Bytes)
    rightmost depth pageId = do
      when' (depth > 64) (Corrupt "B+ tree is deeper than 64 levels")
      r <- the (DB (Either (Maybe Bytes) Int)) $ withPage (pagerPool pg) pageId $ \p => do
        t <- liftIO (pageType p)
        n <- liftIO (slotCount p)
        if t == ptLeaf
          then if n > 0 then map (Left . Just) (slotKey p (n - 1)) else pure (Left Nothing)
          else map Right (liftIO (rightPointer p))
      case r of
        Left (Just k) => pure (Just k)
        -- The rightmost leaf can be empty after deletes that could not merge
        -- it; fall back to a full scan.
        Left Nothing => if pageId == root then pure Nothing
                        else do c <- seek pg root Nothing
                                scanAll c Nothing
        Right child => rightmost (depth + 1) child
