module IdrisQL.Storage.Page

import Data.Bits
import Data.Buffer
import Data.So
import IdrisQL.Error
import IdrisQL.Storage.Codec
import IdrisQL.Storage.Format

||| A buffer of exactly `PageSize` bytes. The constructor is private, so the
||| only way to get a `Page` is `newPage`, which allocates that size.
export
record Page where
  constructor MkPage
  buf : Buffer

export
newPage : DB Page
newPage = map MkPage (alloc PageSize)

||| The underlying buffer, for whole-page file I/O.
export
rawBuffer : Page -> Buffer
rawBuffer p = p.buf

-- Accessors. Each demands an erased proof that its byte range is inside the
-- page. For literal offsets the compiler finds the proof by evaluation; for
-- offsets read from disk the `read*`/`write*` wrappers below obtain it from
-- `checkRange` and report corruption when it does not exist.

export
getU8 : Page -> (off : Int) -> {auto 0 ok : InPage off 1} -> IO Int
getU8 p off = rdU8 p.buf off

export
getU16 : Page -> (off : Int) -> {auto 0 ok : InPage off 2} -> IO Int
getU16 p off = rdU16 p.buf off

export
getU32 : Page -> (off : Int) -> {auto 0 ok : InPage off 4} -> IO Int
getU32 p off = rdU32 p.buf off

export
getBits64 : Page -> (off : Int) -> {auto 0 ok : InPage off 8} -> IO Bits64
getBits64 p off = rdBits64 p.buf off

export
setU8 : Page -> (off : Int) -> {auto 0 ok : InPage off 1} -> Int -> IO ()
setU8 p off v = wrU8 p.buf off v

export
setU16 : Page -> (off : Int) -> {auto 0 ok : InPage off 2} -> Int -> IO ()
setU16 p off v = wrU16 p.buf off v

export
setU32 : Page -> (off : Int) -> {auto 0 ok : InPage off 4} -> Int -> IO ()
setU32 p off v = wrU32 p.buf off v

export
setBits64 : Page -> (off : Int) -> {auto 0 ok : InPage off 8} -> Bits64 -> IO ()
setBits64 p off v = wrBits64 p.buf off v

outOfPage : Int -> Int -> DbError
outOfPage off len =
  Corrupt ("byte range " ++ show off ++ "+" ++ show len ++ " is outside the page")

export
readU8 : Page -> Int -> DB Int
readU8 p off = case checkRange off 1 of
  Just ok => liftIO (getU8 p off)
  Nothing => throw (outOfPage off 1)

export
readU16 : Page -> Int -> DB Int
readU16 p off = case checkRange off 2 of
  Just ok => liftIO (getU16 p off)
  Nothing => throw (outOfPage off 2)

export
readU32 : Page -> Int -> DB Int
readU32 p off = case checkRange off 4 of
  Just ok => liftIO (getU32 p off)
  Nothing => throw (outOfPage off 4)

export
writeU16 : Page -> Int -> Int -> DB ()
writeU16 p off v = case checkRange off 2 of
  Just ok => liftIO (setU16 p off v)
  Nothing => throw (outOfPage off 2)

export
writeU32 : Page -> Int -> Int -> DB ()
writeU32 p off v = case checkRange off 4 of
  Just ok => liftIO (setU32 p off v)
  Nothing => throw (outOfPage off 4)

||| Copy `b` into the page at `off`.
export
writeAt : Page -> (off : Int) -> Bytes -> DB ()
writeAt p off b = case checkRange off (size b) of
  Just ok => liftIO (copyInto b p.buf off)
  Nothing => throw (outOfPage off (size b))

||| Copy `len` bytes at `off` out of the page.
export
readAt : Page -> (off : Int) -> (len : Int) -> DB Bytes
readAt p off len = case checkRange off len of
  Just ok => copyOut p.buf off len
  Nothing => throw (outOfPage off len)

-- Move `len` bytes inside one page. The ranges may overlap.
moveWithin : Page -> (from : Int) -> (to : Int) -> (len : Int) -> DB ()
moveWithin p from to len =
  if len <= 0 then pure ()
  else case (checkRange from len, checkRange to len) of
    (Just _, Just _) => copyData p.buf from len p.buf to
    _ => throw (outOfPage (max from to) len)

copyBetween : (src : Page) -> (srcOff : Int) -> (dst : Page) -> (dstOff : Int) -> (len : Int) -> DB ()
copyBetween src srcOff dst dstOff len =
  if len <= 0 then pure ()
  else case (checkRange srcOff len, checkRange dstOff len) of
    (Just _, Just _) => copyData src.buf srcOff len dst.buf dstOff
    _ => throw (outOfPage (max srcOff dstOff) len)

export
copyPage : (src : Page) -> (dst : Page) -> IO ()
copyPage src dst = copyData src.buf 0 PageSize dst.buf 0

-- Header fields.

export
pageType : Page -> IO Int
pageType p = getU8 p offType

export
slotCount : Page -> IO Int
slotCount p = getU16 p offNSlots

export
rightPointer : Page -> IO Int
rightPointer p = getU32 p offRight

export
setRightPointer : Page -> Int -> IO ()
setRightPointer p v = setU32 p offRight v

export
setPageLsn : Page -> Bits64 -> IO ()
setPageLsn p v = setBits64 p offLsn v

||| Zero the page and give it an empty slot directory.
export
initPage : Page -> (ptype : Int) -> IO ()
initPage p ptype = do
  zero 0
  setU8 p offType ptype
  setU16 p offCellStart PageSize
  where
    zero : Int -> IO ()
    zero o = if o >= PageSize then pure () else do
      Data.Buffer.setBits64 p.buf o 0
      zero (o + 8)

export
pageChecksum : (hostLittle : Bool) -> Page -> IO Bits32
pageChecksum hostLittle p = do
  h <- hashWords hostLittle p.buf 4 (PageSize - 4) hashSeed
  pure (hashFinish h)

||| Store the checksum of the current contents.
export
sealPage : (hostLittle : Bool) -> Page -> IO ()
sealPage hostLittle p = do
  c <- pageChecksum hostLittle p
  setU32 p offChecksum (cast c)

export
verifyPage : (hostLittle : Bool) -> Page -> IO Bool
verifyPage hostLittle p = do
  stored <- getU32 p offChecksum
  c <- pageChecksum hostLittle p
  pure (stored == cast c)

-- Slotted layout. The slot directory grows up from the header; cells grow
-- down from the end of the page. Slot i holds the offset of cell i, and
-- cells are kept in key order by slot.

slotPos : Int -> Int
slotPos i = HeaderSize + 2 * i

export
slotOffset : Page -> (slot : Int) -> DB Int
slotOffset p i = do
  n <- liftIO (slotCount p)
  when' (i < 0 || i >= n) (Corrupt ("slot " ++ show i ++ " of " ++ show n))
  off <- readU16 p (slotPos i)
  when' (off < slotPos n || off >= PageSize)
    (Corrupt ("slot " ++ show i ++ " points at offset " ++ show off))
  pure off

||| Size in bytes of the cell at `off`, validated to end inside the page.
export
cellSize : Page -> (off : Int) -> DB Int
cellSize p off = do
  t <- liftIO (pageType p)
  klen <- readU16 p off
  sz <- if t == ptLeaf
          then do vlen <- readU16 p (off + 2)
                  flags <- readU8 p (off + 4)
                  pure (5 + klen + vlen + (if flags `mod` 2 == 1 then 8 else 0))
        else if t == ptInternal then pure (6 + klen)
        else throw (Corrupt ("page type " ++ show t ++ " has no cells"))
  case checkRange off sz of
    Just _ => pure sz
    Nothing => throw (Corrupt ("cell at " ++ show off ++ " runs past the page end"))

||| Bytes available for new cells and their slots, counting fragments.
export
freeBytes : Page -> IO Int
freeBytes p = do
  n <- slotCount p
  cs <- getU16 p offCellStart
  fr <- getU16 p offFrag
  pure (cs - slotPos n + fr)

||| Bytes occupied by cells and their slots.
export
usedBytes : Page -> IO Int
usedBytes p = do
  f <- freeBytes p
  pure (PageSize - HeaderSize - f)

||| Rewrite the cells contiguously at the end of the page.
export
compact : Page -> DB ()
compact p = do
  n <- liftIO (slotCount p)
  tmp <- newPage
  end <- pack tmp n 0 PageSize
  copyBetween tmp end p end (PageSize - end)
  copyBetween tmp (slotPos 0) p (slotPos 0) (2 * n)
  liftIO $ do
    setU16 p offCellStart end
    setU16 p offFrag 0
  where
    pack : Page -> Int -> Int -> Int -> DB Int
    pack tmp n i end =
      if i >= n then pure end
      else do
        off <- slotOffset p i
        sz <- cellSize p off
        let dst = end - sz
        when' (dst < slotPos n) (Corrupt "cells overlap the slot directory")
        copyBetween p off tmp dst sz
        writeU16 tmp (slotPos i) dst
        pack tmp n (i + 1) dst

||| Insert `cell` so that it becomes slot `slot`. Returns False, leaving the
||| page unchanged, when the page lacks room.
export
insertCell : Page -> (slot : Int) -> (cell : Bytes) -> DB Bool
insertCell p slot cell = do
  n <- liftIO (slotCount p)
  when' (slot < 0 || slot > n) (Corrupt ("insert at slot " ++ show slot ++ " of " ++ show n))
  cs <- liftIO (getU16 p offCellStart)
  fr <- liftIO (getU16 p offFrag)
  let gap = cs - slotPos n
  when' (gap < 0) (Corrupt "cell area overlaps the slot directory")
  let need = size cell + 2
  if need > gap + fr then pure False
    else do
      when (need > gap) (compact p)
      cs <- liftIO (getU16 p offCellStart)
      let at = cs - size cell
      writeAt p at cell
      moveWithin p (slotPos slot) (slotPos (slot + 1)) (2 * (n - slot))
      writeU16 p (slotPos slot) at
      liftIO $ do
        setU16 p offNSlots (n + 1)
        setU16 p offCellStart at
      pure True

export
deleteCell : Page -> (slot : Int) -> DB ()
deleteCell p slot = do
  n <- liftIO (slotCount p)
  off <- slotOffset p slot
  sz <- cellSize p off
  cs <- liftIO (getU16 p offCellStart)
  fr <- liftIO (getU16 p offFrag)
  moveWithin p (slotPos (slot + 1)) (slotPos slot) (2 * (n - slot - 1))
  liftIO $ do
    setU16 p offNSlots (n - 1)
    if n == 1
      then do setU16 p offCellStart PageSize
              setU16 p offFrag 0
      else if off == cs then setU16 p offCellStart (cs + sz)
      else setU16 p offFrag (fr + sz)

-- Cell formats.
--   leaf:     u16 keyLen, u16 inlineLen, u8 flags, key, inline value,
--             then if flags bit 0: u32 first overflow page, u32 full length
--   internal: u16 keyLen, u32 left child, key

public export
record LeafCell where
  constructor MkLeafCell
  key : Bytes
  inline : Bytes
  ||| First overflow page and full value length, when the value is not inline.
  overflow : Maybe (Int, Int)

export
mkLeafCell : (key : Bytes) -> (inline : Bytes) -> (overflow : Maybe (Int, Int)) -> DB Bytes
mkLeafCell key val ov = do
  bd <- newBuilder (13 + size key + size val)
  putU16 bd (size key)
  putU16 bd (size val)
  putU8 bd (case ov of
              Nothing => 0
              Just _ => 1)
  putBytes bd key
  putBytes bd val
  case ov of
    Nothing => pure ()
    Just (pg, full) => putU32 bd pg >> putU32 bd full
  finish bd

export
mkInternalCell : (key : Bytes) -> (child : Int) -> DB Bytes
mkInternalCell key child = do
  bd <- newBuilder (6 + size key)
  putU16 bd (size key)
  putU32 bd child
  putBytes bd key
  finish bd

-- Offset and length of the key of the cell in `slot`.
keyRange : Page -> (slot : Int) -> DB (Int, Int)
keyRange p slot = do
  off <- slotOffset p slot
  t <- liftIO (pageType p)
  klen <- readU16 p off
  if t == ptLeaf then pure (off + 5, klen)
    else if t == ptInternal then pure (off + 6, klen)
    else throw (Corrupt ("page type " ++ show t ++ " has no keys"))

data Found = At Int Bool | BadSlot Int

||| Index of the first slot whose key is >= `key`, and whether that key is
||| equal: a binary search over the slot directory. The descent of every
||| tree operation runs through here, so the loop reads raw bytes; each
||| offset is compared with the page bounds before it is used.
export
searchSlots : Page -> (key : Bytes) -> DB (Int, Bool)
searchSlots p key = do
  t <- liftIO (pageType p)
  n <- liftIO (slotCount p)
  when' (t /= ptLeaf && t /= ptInternal) (Corrupt ("page type " ++ show t ++ " has no keys"))
  when' (slotPos n > PageSize) (Corrupt ("slot directory of " ++ show n ++ " slots runs past the page end"))
  r <- liftIO (go (if t == ptLeaf then 5 else 6) (slotPos n) 0 n)
  case r of
    At i exact => pure (i, exact)
    BadSlot i => throw (Corrupt ("slot " ++ show i ++ " does not point at a cell inside the page"))
  where
    -- `keyAt` is the offset of the key within a cell; `cells` is where the
    -- cell area may begin. Slots lo..hi-1 lie inside the directory, which
    -- was checked to lie inside the page.
    go : (keyAt : Int) -> (cells : Int) -> (lo : Int) -> (hi : Int) -> IO Found
    go keyAt cells lo hi =
      if lo >= hi then pure (At lo False)
      else do
        let mid = (lo + hi) `div` 2
        off <- rdU16 p.buf (slotPos mid)
        if off < cells || off + keyAt > PageSize then pure (BadSlot mid)
          else do
            klen <- rdU16 p.buf off
            if off + keyAt + klen > PageSize then pure (BadSlot mid)
              else do
                o <- compareRaw p.buf (off + keyAt) klen key
                case o of
                  LT => go keyAt cells (mid + 1) hi
                  EQ => pure (At mid True)
                  GT => go keyAt cells lo mid

export
slotKey : Page -> (slot : Int) -> DB Bytes
slotKey p slot = do
  (koff, klen) <- keyRange p slot
  readAt p koff klen

||| The whole cell in `slot`, copied out.
export
cellCopy : Page -> (slot : Int) -> DB Bytes
cellCopy p slot = do
  off <- slotOffset p slot
  sz <- cellSize p off
  readAt p off sz

export
readLeafCell : Page -> (slot : Int) -> DB LeafCell
readLeafCell p slot = do
  off <- slotOffset p slot
  klen <- readU16 p off
  vlen <- readU16 p (off + 2)
  flags <- readU8 p (off + 4)
  key <- readAt p (off + 5) klen
  val <- readAt p (off + 5 + klen) vlen
  if flags `mod` 2 == 1
    then do pg <- readU32 p (off + 5 + klen + vlen)
            full <- readU32 p (off + 9 + klen + vlen)
            pure (MkLeafCell key val (Just (pg, full)))
    else pure (MkLeafCell key val Nothing)

export
internalChild : Page -> (slot : Int) -> DB Int
internalChild p slot = do
  off <- slotOffset p slot
  readU32 p (off + 2)

export
setInternalChild : Page -> (slot : Int) -> (child : Int) -> DB ()
setInternalChild p slot child = do
  off <- slotOffset p slot
  writeU32 p (off + 2) child

-- Overflow pages hold a run of value bytes after the header; the slot-count
-- field stores how many.

export
writeOverflow : Page -> (chunk : Bytes) -> (next : Int) -> DB ()
writeOverflow p chunk next = do
  when' (size chunk > OverflowCapacity) (Corrupt "overflow chunk larger than a page")
  liftIO $ do
    initPage p ptOverflow
    setU16 p offNSlots (size chunk)
    setRightPointer p next
  writeAt p HeaderSize chunk

export
readOverflow : Page -> DB (Bytes, Int)
readOverflow p = do
  t <- liftIO (pageType p)
  when' (t /= ptOverflow) (Corrupt ("expected an overflow page, found type " ++ show t))
  n <- liftIO (slotCount p)
  chunk <- readAt p HeaderSize n
  next <- liftIO (rightPointer p)
  pure (chunk, next)
