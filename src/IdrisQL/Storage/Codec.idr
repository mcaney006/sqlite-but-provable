module IdrisQL.Storage.Codec

import Data.Bits
import Data.Buffer
import Data.IORef
import IdrisQL.Error

-- Byte-level encoding. Every multi-byte integer on disk is little-endian and
-- is assembled from single bytes here, because Data.Buffer's wider accessors
-- use the host byte order (see docs/PLATFORM_CONSTRAINTS.md).

export
alloc : Int -> DB Buffer
alloc n = do
  Just b <- newBuffer (max 0 n)
    | Nothing => throw (IOFailure ("cannot allocate " ++ show n ++ " bytes"))
  pure b

-- Raw accessors. They do no bounds checking; callers are Page (which demands
-- an `InPage` proof), and Bytes/Builder/Decoder below (which check ranges).

export %inline
rdU8 : Buffer -> Int -> IO Int
rdU8 b o = do
  x <- getBits8 b o
  pure (cast x)

export
rdU16 : Buffer -> Int -> IO Int
rdU16 b o = do
  lo <- getBits8 b o
  hi <- getBits8 b (o + 1)
  pure (cast lo + cast hi * 256)

export
rdU32 : Buffer -> Int -> IO Int
rdU32 b o = do
  b0 <- getBits8 b o
  b1 <- getBits8 b (o + 1)
  b2 <- getBits8 b (o + 2)
  b3 <- getBits8 b (o + 3)
  pure (cast b0 + cast b1 * 256 + cast b2 * 65536 + cast b3 * 16777216)

export
rdBits64 : Buffer -> Int -> IO Bits64
rdBits64 b o = do
  lo <- rdU32 b o
  hi <- rdU32 b (o + 4)
  pure (cast lo .|. (cast hi `shiftL` 32))

export %inline
wrU8 : Buffer -> Int -> Int -> IO ()
wrU8 b o v = setBits8 b o (cast v)

export
wrU16 : Buffer -> Int -> Int -> IO ()
wrU16 b o v = do
  setBits8 b o (cast v)
  setBits8 b (o + 1) (cast (v `div` 256))

export
wrU32 : Buffer -> Int -> Int -> IO ()
wrU32 b o v = do
  setBits8 b o (cast v)
  setBits8 b (o + 1) (cast (v `div` 256))
  setBits8 b (o + 2) (cast (v `div` 65536))
  setBits8 b (o + 3) (cast (v `div` 16777216))

export
wrBits64 : Buffer -> Int -> Bits64 -> IO ()
wrBits64 b o v = do
  wrU32 b o (cast (v .&. 0xFFFFFFFF))
  wrU32 b (o + 4) (cast (v `shiftR` 32))

||| True when Data.Buffer's multi-byte accessors are little-endian on this
||| host. The page checksum uses it to read whole words on the fast path.
export
hostLittleEndian : DB Bool
hostLittleEndian = do
  s <- alloc 2
  setBits16 s 0 0x0102
  b0 <- getBits8 s 0
  pure (b0 == 2)

-- Checksum: a 32-bit multiplicative hash over little-endian 32-bit words. It
-- detects torn and bit-rotted data. It is not a CRC and gives no protection
-- against deliberate tampering.

mix : Bits32 -> Bits32 -> Bits32
mix h w = (((h `shiftL` 5) .|. (h `shiftR` 27)) `xor` w) * 0x9E3779B1

export
hashSeed : Bits32
hashSeed = 0x811C9DC5

||| Fold the words of `buf[off, off + len)` into `h`. `len` must be a
||| multiple of 4; the range is the caller's responsibility.
export
hashWords : (hostLittle : Bool) -> Buffer -> (off : Int) -> (len : Int) -> (h : Bits32) -> IO Bits32
hashWords hostLittle buf off len h0 = go off h0
  where
    stop : Int
    stop = off + len
    go : Int -> Bits32 -> IO Bits32
    go o h =
      if o >= stop then pure h
      else do
        w <- if hostLittle then getBits32 buf o else map cast (rdU32 buf o)
        go (o + 4) (mix h w)

export
hashFinish : Bits32 -> Bits32
hashFinish h = h `xor` (h `shiftR` 15)

||| An immutable view of `len` bytes starting at `off`. The constructor is
||| private to this module, so every `Bytes` in the program was range-checked
||| against its buffer when it was made.
export
record Bytes where
  constructor MkBytes
  buf : Buffer
  off : Int
  len : Int

export %inline
size : Bytes -> Int
size b = b.len

export
fromBuffer : Buffer -> (off : Int) -> (len : Int) -> DB Bytes
fromBuffer buf off len = do
  cap <- rawSize buf
  if off >= 0 && len >= 0 && len <= cap && off <= cap - len
    then pure (MkBytes buf off len)
    else throw (Corrupt ("byte range " ++ show off ++ "+" ++ show len
                          ++ " outside buffer of " ++ show cap))

export
emptyBytes : DB Bytes
emptyBytes = do
  b <- alloc 0
  pure (MkBytes b 0 0)

export
sub : Bytes -> (off : Int) -> (len : Int) -> DB Bytes
sub b off len =
  if off >= 0 && len >= 0 && len <= b.len && off <= b.len - len
    then pure (MkBytes b.buf (b.off + off) len)
    else throw (Corrupt ("slice " ++ show off ++ "+" ++ show len
                          ++ " outside " ++ show b.len ++ " bytes"))

||| The buffer, offset and length behind a view, for handing to file I/O.
export
rawParts : Bytes -> (Buffer, Int, Int)
rawParts b = (b.buf, b.off, b.len)

||| Copy the bytes into `dst` at `dstOff`. The destination range is the
||| caller's responsibility.
export
copyInto : Bytes -> (dst : Buffer) -> (dstOff : Int) -> IO ()
copyInto b dst dstOff =
  if b.len == 0 then pure () else copyData b.buf b.off b.len dst dstOff

export
compareBytes : Bytes -> Bytes -> IO Ordering
compareBytes a b = go 0
  where
    n : Int
    n = min a.len b.len
    go : Int -> IO Ordering
    go i =
      if i >= n then pure (compare a.len b.len)
      else do
        x <- getBits8 a.buf (a.off + i)
        y <- getBits8 b.buf (b.off + i)
        if x == y then go (i + 1) else pure (compare x y)

||| Compare `len` bytes of `buf` at `off` with `b`. The range in `buf` is the
||| caller's responsibility.
export
compareRaw : Buffer -> (off : Int) -> (len : Int) -> Bytes -> IO Ordering
compareRaw buf off len b = compareBytes (MkBytes buf off len) b

||| Copy `len` bytes of `buf` at `off` into a fresh `Bytes`. The source range
||| is the caller's responsibility.
export
copyOut : Buffer -> (off : Int) -> (len : Int) -> DB Bytes
copyOut buf off len = do
  dst <- alloc len
  when (len > 0) (copyData buf off len dst 0)
  pure (MkBytes dst 0 (max 0 len))

export
hasPrefix : (pre : Bytes) -> Bytes -> IO Bool
hasPrefix p b =
  if p.len > b.len then pure False
  else do
    o <- compareBytes p (MkBytes b.buf b.off p.len)
    pure (o == EQ)

export
unpackBytes : Bytes -> IO (List Bits8)
unpackBytes b = go (b.len - 1) []
  where
    go : Int -> List Bits8 -> IO (List Bits8)
    go i acc =
      if i < 0 then pure acc
      else do
        x <- getBits8 b.buf (b.off + i)
        go (i - 1) (x :: acc)

export
packBytes : List Bits8 -> DB Bytes
packBytes xs = do
  let n = cast {to = Int} (length xs)
  buf <- alloc n
  liftIO (fill buf 0 xs)
  pure (MkBytes buf 0 n)
  where
    fill : Buffer -> Int -> List Bits8 -> IO ()
    fill _ _ [] = pure ()
    fill buf i (y :: ys) = setBits8 buf i y >> fill buf (i + 1) ys

||| The byte at index `i`, or 0 when `i` is out of range.
export
byteAt : Bytes -> Int -> IO Int
byteAt b i = if i >= 0 && i < b.len then rdU8 b.buf (b.off + i) else pure 0

export
peekU16 : Bytes -> (off : Int) -> DB Int
peekU16 b off =
  if off >= 0 && off <= b.len - 2 then liftIO (rdU16 b.buf (b.off + off))
  else throw (Corrupt ("read of 2 bytes at " ++ show off ++ " in " ++ show b.len ++ " bytes"))

export
peekU32 : Bytes -> (off : Int) -> DB Int
peekU32 b off =
  if off >= 0 && off <= b.len - 4 then liftIO (rdU32 b.buf (b.off + off))
  else throw (Corrupt ("read of 4 bytes at " ++ show off ++ " in " ++ show b.len ++ " bytes"))

export
stringBytes : String -> DB Bytes
stringBytes s = do
  let n = stringByteLength s
  buf <- alloc n
  setString buf 0 s
  pure (MkBytes buf 0 n)

export
bytesString : Bytes -> IO String
bytesString b = if b.len == 0 then pure "" else getString b.buf b.off b.len

||| An append-only byte buffer that grows as needed.
export
record Builder where
  constructor MkBuilder
  bufRef : IORef Buffer
  lenRef : IORef Int

export
newBuilder : (capacity : Int) -> DB Builder
newBuilder cap = do
  b <- alloc (max 16 cap)
  bufRef <- newIORef b
  lenRef <- newIORef 0
  pure (MkBuilder bufRef lenRef)

-- Reserve `n` bytes and return the buffer and the offset to write at.
reserve : Builder -> Int -> DB (Buffer, Int)
reserve bd n = do
  buf <- readIORef bd.bufRef
  len <- readIORef bd.lenRef
  cap <- rawSize buf
  writeIORef bd.lenRef (len + n)
  if len + n <= cap then pure (buf, len)
    else do
      Just bigger <- resizeBuffer buf (max (len + n) (cap * 2))
        | Nothing => throw (IOFailure "cannot grow byte buffer")
      writeIORef bd.bufRef bigger
      pure (bigger, len)

export
putU8 : Builder -> Int -> DB ()
putU8 bd v = do
  (buf, o) <- reserve bd 1
  liftIO (wrU8 buf o v)

export
putU16 : Builder -> Int -> DB ()
putU16 bd v = do
  (buf, o) <- reserve bd 2
  liftIO (wrU16 buf o v)

export
putU32 : Builder -> Int -> DB ()
putU32 bd v = do
  (buf, o) <- reserve bd 4
  liftIO (wrU32 buf o v)

export
putBits64 : Builder -> Bits64 -> DB ()
putBits64 bd v = do
  (buf, o) <- reserve bd 8
  liftIO (wrBits64 buf o v)

export
putI64 : Builder -> Int64 -> DB ()
putI64 bd v = putBits64 bd (cast v)

||| IEEE-754 binary64, stored as its bit pattern in little-endian order.
export
putDouble : Builder -> Double -> DB ()
putDouble bd d = do
  (buf, o) <- reserve bd 8
  -- Write and read back with the same host-order accessors to get the bit
  -- pattern, then store it in the format's byte order.
  setDouble buf o d
  bits <- getBits64 buf o
  liftIO (wrBits64 buf o bits)

||| Eight bytes, most significant first. Used by order-preserving keys.
export
putBE64 : Builder -> Bits64 -> DB ()
putBE64 bd v = do
  (buf, o) <- reserve bd 8
  liftIO $ do
    wrU32 buf o (bswap (cast (v `shiftR` 32)))
    wrU32 buf (o + 4) (bswap (cast (v .&. 0xFFFFFFFF)))
  where
    bswap : Int -> Int
    bswap x = (x `div` 16777216) + ((x `div` 65536) `mod` 256) * 256
            + ((x `div` 256) `mod` 256) * 65536 + (x `mod` 256) * 16777216

||| The IEEE-754 bit pattern of a double.
export
doubleBits : Double -> DB Bits64
doubleBits d = do
  s <- alloc 8
  setDouble s 0 d
  getBits64 s 0

export
putBytes : Builder -> Bytes -> DB ()
putBytes bd b = do
  (buf, o) <- reserve bd b.len
  liftIO (copyInto b buf o)

||| A u32 byte length followed by the UTF-8 encoding.
export
putString : Builder -> String -> DB ()
putString bd s = do
  let n = stringByteLength s
  putU32 bd n
  (buf, o) <- reserve bd n
  setString buf o s

export
finish : Builder -> DB Bytes
finish bd = do
  buf <- readIORef bd.bufRef
  len <- readIORef bd.lenRef
  pure (MkBytes buf 0 len)

||| A cursor over a `Bytes`. Reading past the end is a `Corrupt` error.
export
record Decoder where
  constructor MkDecoder
  src : Bytes
  posRef : IORef Int
  scratch : Buffer

export
newDecoder : Bytes -> DB Decoder
newDecoder b = do
  posRef <- newIORef 0
  scratch <- alloc 8
  pure (MkDecoder b posRef scratch)

-- Advance by `n` and return the absolute buffer offset of the bytes consumed.
take : Decoder -> Int -> DB Int
take d n = do
  pos <- readIORef d.posRef
  if n >= 0 && n <= d.src.len - pos
    then do writeIORef d.posRef (pos + n)
            pure (d.src.off + pos)
    else throw (Corrupt ("record truncated: need " ++ show n ++ " bytes at offset "
                          ++ show pos ++ " of " ++ show d.src.len))

export
remaining : Decoder -> IO Int
remaining d = do
  pos <- readIORef d.posRef
  pure (d.src.len - pos)

export
takeU8 : Decoder -> DB Int
takeU8 d = do
  o <- take d 1
  liftIO (rdU8 d.src.buf o)

export
takeU16 : Decoder -> DB Int
takeU16 d = do
  o <- take d 2
  liftIO (rdU16 d.src.buf o)

export
takeU32 : Decoder -> DB Int
takeU32 d = do
  o <- take d 4
  liftIO (rdU32 d.src.buf o)

export
takeBits64 : Decoder -> DB Bits64
takeBits64 d = do
  o <- take d 8
  liftIO (rdBits64 d.src.buf o)

export
takeI64 : Decoder -> DB Int64
takeI64 d = map cast (takeBits64 d)

export
takeDouble : Decoder -> DB Double
takeDouble d = do
  bits <- takeBits64 d
  setBits64 d.scratch 0 bits
  getDouble d.scratch 0

export
takeBytes : Decoder -> Int -> DB Bytes
takeBytes d n = do
  o <- take d n
  pure (MkBytes d.src.buf o n)

export
takeString : Decoder -> DB String
takeString d = do
  n <- takeU32 d
  b <- takeBytes d n
  liftIO (bytesString b)
