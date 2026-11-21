module IdrisQL.Catalog.Schema

import Data.List
import Data.SortedMap
import Data.String
import IdrisQL.Error
import IdrisQL.Storage.Codec
import IdrisQL.Types

public export
record ColumnDef where
  constructor MkColumnDef
  name : String
  type : SqlType
  notNull : Bool
  ||| The DEFAULT expression as SQL text, in `renderExpr` form.
  defaultSql : Maybe String

||| A foreign key as declared. It is recorded so that a later version can
||| enforce it; this version does not.
public export
record ForeignKeyDef where
  constructor MkForeignKeyDef
  columns : List String
  refTable : String
  refColumns : List String

public export
record TableDef where
  constructor MkTableDef
  id : Int
  name : String
  ||| Root page of the table's B+ tree, keyed by rowid.
  root : Int
  columns : List ColumnDef
  ||| Position of the INTEGER PRIMARY KEY column, which is the rowid itself.
  rowidColumn : Maybe Nat
  ||| CHECK constraints as SQL text.
  checks : List String
  foreignKeys : List ForeignKeyDef
  ||| Row count recorded by ANALYZE, or -1.
  rowEstimate : Int

public export
record IndexDef where
  constructor MkIndexDef
  id : Int
  name : String
  table : String
  root : Int
  ||| Positions of the indexed columns in the table, in key order.
  columns : List Nat
  unique : Bool
  ||| Created for a PRIMARY KEY or UNIQUE constraint. It is dropped with
  ||| its table and cannot be dropped on its own.
  constraintOwned : Bool
  ||| Number of distinct column-value combinations recorded by ANALYZE, or -1.
  distinctEstimate : Int

||| The column types of a table: the shape of its rows.
public export
tableCtx : TableDef -> List SqlType
tableCtx t = map (.type) t.columns

||| Names compare case-insensitively.
public export
norm : String -> String
norm = toLower

public export
record Schema where
  constructor MkSchema
  tables : SortedMap String TableDef
  indexes : SortedMap String IndexDef

export
emptySchema : Schema
emptySchema = MkSchema empty empty

export
findTable : Schema -> String -> Maybe TableDef
findTable s name = lookup (norm name) s.tables

export
findIndex : Schema -> String -> Maybe IndexDef
findIndex s name = lookup (norm name) s.indexes

export
tableIndexes : Schema -> (table : String) -> List IndexDef
tableIndexes s table = filter (\i => norm i.table == norm table) (values s.indexes)

export
columnIndex : TableDef -> String -> Maybe Nat
columnIndex t name = go 0 t.columns
  where
    go : Nat -> List ColumnDef -> Maybe Nat
    go _ [] = Nothing
    go i (c :: cs) = if norm c.name == norm name then Just i else go (S i) cs

-- Catalog entries. The catalog is a B+ tree keyed by "t:<name>" or
-- "i:<name>" (lower case); the value is one of these encodings, which
-- start with a kind byte and a version byte.

typeCode : SqlType -> Int
typeCode TInt = 1
typeCode TReal = 2
typeCode TText = 3
typeCode TBlob = 4
typeCode TBool = 5

codeType : Int -> DB SqlType
codeType 1 = pure TInt
codeType 2 = pure TReal
codeType 3 = pure TText
codeType 4 = pure TBlob
codeType 5 = pure TBool
codeType n = throw (Corrupt ("unknown column type code " ++ show n))

putList : Builder -> (a -> DB ()) -> List a -> DB ()
putList bd f xs = do
  when' (length xs > 65535) (Unsupported "more than 65,535 entries in one catalog list")
  putU16 bd (cast (length xs))
  traverse_ f xs

takeList : Decoder -> DB a -> DB (List a)
takeList d f = do
  n <- takeU16 d
  go n []
  where
    go : Int -> List a -> DB (List a)
    go k acc = if k <= 0 then pure (reverse acc) else do
      x <- f
      go (k - 1) (x :: acc)

putBool : Builder -> Bool -> DB ()
putBool bd b = putU8 bd (if b then 1 else 0)

takeBool : Decoder -> DB Bool
takeBool d = map (/= 0) (takeU8 d)

export
tableKey : String -> DB Bytes
tableKey name = stringBytes ("t:" ++ norm name)

export
indexKeyName : String -> DB Bytes
indexKeyName name = stringBytes ("i:" ++ norm name)

export
encodeTable : TableDef -> DB Bytes
encodeTable t = do
  bd <- newBuilder 256
  putU8 bd 1
  putU8 bd 1
  putU32 bd t.id
  putString bd t.name
  putU32 bd t.root
  putList bd (\c => do putString bd c.name
                       putU8 bd (typeCode c.type)
                       putBool bd c.notNull
                       case c.defaultSql of
                         Nothing => putBool bd False
                         Just s => putBool bd True >> putString bd s) t.columns
  case t.rowidColumn of
    Nothing => putBool bd False
    Just i => putBool bd True >> putU16 bd (cast i)
  putList bd (putString bd) t.checks
  putList bd (\fk => do putList bd (putString bd) fk.columns
                        putString bd fk.refTable
                        putList bd (putString bd) fk.refColumns) t.foreignKeys
  putI64 bd (cast t.rowEstimate)
  finish bd

export
encodeIndex : IndexDef -> DB Bytes
encodeIndex i = do
  bd <- newBuilder 128
  putU8 bd 2
  putU8 bd 1
  putU32 bd i.id
  putString bd i.name
  putString bd i.table
  putU32 bd i.root
  putList bd (\c => putU16 bd (cast c)) i.columns
  putBool bd i.unique
  putBool bd i.constraintOwned
  putI64 bd (cast i.distinctEstimate)
  finish bd

public export
data CatalogEntry = TableEntry TableDef | IndexEntry IndexDef

export
decodeEntry : Bytes -> DB CatalogEntry
decodeEntry bytes = do
  d <- newDecoder bytes
  kind <- takeU8 d
  version <- takeU8 d
  when' (version /= 1) (Unsupported ("catalog entry version " ++ show version))
  case kind of
    1 => do
      id <- takeU32 d
      name <- takeString d
      root <- takeU32 d
      columns <- takeList d $ do
        cname <- takeString d
        ctype <- takeU8 d >>= codeType
        notNull <- takeBool d
        hasDefault <- takeBool d
        dflt <- if hasDefault then map Just (takeString d) else pure Nothing
        pure (MkColumnDef cname ctype notNull dflt)
      hasRowid <- takeBool d
      rowidColumn <- if hasRowid then map (Just . cast) (takeU16 d) else pure Nothing
      checks <- takeList d (takeString d)
      fks <- takeList d $ do
        cols <- takeList d (takeString d)
        ref <- takeString d
        refCols <- takeList d (takeString d)
        pure (MkForeignKeyDef cols ref refCols)
      rows <- takeI64 d
      pure (TableEntry (MkTableDef id name root columns rowidColumn checks fks (cast rows)))
    2 => do
      id <- takeU32 d
      name <- takeString d
      table <- takeString d
      root <- takeU32 d
      columns <- takeList d (map cast (takeU16 d))
      unique <- takeBool d
      owned <- takeBool d
      distinct <- takeI64 d
      pure (IndexEntry (MkIndexDef id name table root columns unique owned (cast distinct)))
    _ => throw (Corrupt ("unknown catalog entry kind " ++ show kind))
