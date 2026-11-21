module IdrisQL.Catalog.Catalog

import Data.SortedMap
import IdrisQL.Catalog.Schema
import IdrisQL.Error
import IdrisQL.Index.BPlusTree
import IdrisQL.Index.Cursor
import IdrisQL.Storage.Codec
import IdrisQL.Storage.Format
import IdrisQL.Storage.Pager

-- The persistent catalog: a B+ tree rooted at the page named in the header.
-- The in-memory `Schema` is a cache of it, reloaded after a rollback that
-- touched it.

catalogRoot : Pager -> DB Int
catalogRoot pg = metaU32 pg offCatalogRoot

||| Read every catalog entry.
export
loadSchema : Pager -> DB Schema
loadSchema pg = do
  root <- catalogRoot pg
  c <- seek pg root Nothing
  go c emptySchema
  where
    go : Cursor -> Schema -> DB Schema
    go c s = do
      Just (_, val) <- next c | Nothing => pure s
      entry <- decodeEntry val
      go c (case entry of
              TableEntry t => { tables $= insert (norm t.name) t } s
              IndexEntry i => { indexes $= insert (norm i.name) i } s)

export
saveTable : Pager -> TableDef -> DB ()
saveTable pg t = do
  root <- catalogRoot pg
  ignore (put pg root !(tableKey t.name) !(encodeTable t))

export
saveIndex : Pager -> IndexDef -> DB ()
saveIndex pg i = do
  root <- catalogRoot pg
  ignore (put pg root !(indexKeyName i.name) !(encodeIndex i))

export
removeTable : Pager -> (name : String) -> DB ()
removeTable pg name = do
  root <- catalogRoot pg
  ignore (delete pg root !(tableKey name))

export
removeIndex : Pager -> (name : String) -> DB ()
removeIndex pg name = do
  root <- catalogRoot pg
  ignore (delete pg root !(indexKeyName name))

||| A fresh id for a table or index.
export
nextObjectId : Pager -> DB Int
nextObjectId pg = do
  n <- metaU32 pg offNextObjectId
  setMetaU32 pg offNextObjectId (n + 1)
  pure n

||| Record that the schema changed, so cached plans are rebuilt.
export
bumpSchemaCookie : Pager -> DB ()
bumpSchemaCookie pg = do
  c <- metaBits64 pg offSchemaCookie
  setMetaBits64 pg offSchemaCookie (c + 1)

export
schemaCookie : Pager -> DB Bits64
schemaCookie pg = metaBits64 pg offSchemaCookie
