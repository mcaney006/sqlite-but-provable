module IdrisQL.Storage.Format

import public Data.So

%default total

-- On-disk constants. docs/FILE_FORMAT.md describes the layout; the numbers
-- here are the definition.

public export
PageSize : Int
PageSize = 4096

public export
FormatVersion : Int
FormatVersion = 1

||| Bytes of every page taken by the common header.
public export
HeaderSize : Int
HeaderSize = 24

-- Common page header.
public export
offChecksum : Int
offChecksum = 0

public export
offType : Int
offType = 4

public export
offFlags : Int
offFlags = 5

public export
offNSlots : Int
offNSlots = 6

public export
offCellStart : Int
offCellStart = 8

public export
offFrag : Int
offFrag = 10

||| Leaf: next sibling. Internal: rightmost child. Overflow and free pages:
||| next page in the chain. Zero means none.
public export
offRight : Int
offRight = 12

public export
offLsn : Int
offLsn = 16

-- Page types.
public export
ptMeta : Int
ptMeta = 1

public export
ptLeaf : Int
ptLeaf = 2

public export
ptInternal : Int
ptInternal = 3

public export
ptOverflow : Int
ptOverflow = 4

public export
ptFree : Int
ptFree = 5

-- Meta page (page 0) fields, after the common header.
public export
offMagic : Int
offMagic = 24

public export
offVersion : Int
offVersion = 32

public export
offPageSize : Int
offPageSize = 36

public export
offDbId : Int
offDbId = 40

public export
offPageCount : Int
offPageCount = 48

public export
offFreeHead : Int
offFreeHead = 52

public export
offFreeCount : Int
offFreeCount = 56

public export
offCatalogRoot : Int
offCatalogRoot = 60

public export
offLastTxn : Int
offLastTxn = 64

public export
offSchemaCookie : Int
offSchemaCookie = 72

public export
offNextObjectId : Int
offNextObjectId = 80

public export
offNextLsn : Int
offNextLsn = 88

||| "IDRISQL" followed by a zero byte.
public export
magicBytes : List Int
magicBytes = [73, 68, 82, 73, 83, 81, 76, 0]

||| Longest key a B+ tree accepts. Four maximal internal cells fit in a page.
public export
MaxKeySize : Int
MaxKeySize = 1000

||| A leaf cell whose key and value together exceed this many bytes stores
||| the value in an overflow chain.
public export
MaxInlinePayload : Int
MaxInlinePayload = 1000

||| Data bytes held by one overflow page.
public export
OverflowCapacity : Int
OverflowCapacity = PageSize - HeaderSize

||| Evidence that the byte range `[off, off + len)` lies inside a page. The
||| three conditions are phrased so that no intermediate sum can overflow.
public export
data InPage : (off : Int) -> (len : Int) -> Type where
  MkInPage : (0 offOk : So (0 <= off)) ->
             (0 lenOk : So (0 <= len && len <= PageSize)) ->
             (0 endOk : So (off <= PageSize - len)) ->
             InPage off len

||| The only way to obtain an `InPage` for offsets not known at compile time.
export
checkRange : (off : Int) -> (len : Int) -> Maybe (InPage off len)
checkRange off len =
  case choose (0 <= off) of
    Right _ => Nothing
    Left offOk => case choose (0 <= len && len <= PageSize) of
      Right _ => Nothing
      Left lenOk => case choose (off <= PageSize - len) of
        Right _ => Nothing
        Left endOk => Just (MkInPage offOk lenOk endOk)
