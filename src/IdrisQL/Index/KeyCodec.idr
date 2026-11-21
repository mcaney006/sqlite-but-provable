module IdrisQL.Index.KeyCodec

import Data.Bits
import IdrisQL.Error
import IdrisQL.Storage.Codec
import IdrisQL.Types

-- Order-preserving key encoding: comparing two encoded keys bytewise gives
-- the same result as comparing the values they encode, column by column,
-- with NULL first. Each column is a tag byte followed by:
--
--   NULL     0x05  nothing
--   BOOLEAN  0x10  one byte, 0 or 1
--   INTEGER  0x20  8 bytes big-endian with the sign bit flipped
--   REAL     0x30  8 bytes big-endian: sign bit flipped for values >= 0,
--                  all bits flipped for negative values
--   TEXT     0x40  UTF-8 with 0x00 written as 0x00 0xFF, ended by 0x00 0x00
--   BLOB     0x50  same escaping as TEXT
--
-- UTF-8 byte order equals code point order, which is the order `compare`
-- gives on String, so TEXT keys agree with ORDER BY.

signBit : Bits64
signBit = 0x8000000000000000

||| First tag byte that sorts after NULL. A scan that must skip NULLs starts
||| at a key ending in this byte.
export
tagAfterNull : Int
tagAfterNull = 0x06

putEscaped : Builder -> Bytes -> DB ()
putEscaped bd b = go 0
  where
    go : Int -> DB ()
    go i =
      if i >= size b then putU8 bd 0 >> putU8 bd 0
      else do
        x <- liftIO (byteAt b i)
        putU8 bd x
        when (x == 0) (putU8 bd 0xFF)
        go (i + 1)

export
putKeyCell : Builder -> (t : SqlType) -> Cell t -> DB ()
putKeyCell bd _ Nothing = putU8 bd 0x05
putKeyCell bd TBool (Just b) = putU8 bd 0x10 >> putU8 bd (if b then 1 else 0)
putKeyCell bd TInt (Just x) = putU8 bd 0x20 >> putBE64 bd (cast x `xor` signBit)
putKeyCell bd TReal (Just d) = do
  putU8 bd 0x30
  -- -0.0 and 0.0 are equal in SQL, so they share one encoding.
  bits <- doubleBits (if d == 0.0 then 0.0 else d)
  putBE64 bd (if bits .&. signBit == 0 then bits `xor` signBit else complement bits)
putKeyCell bd TText (Just s) = do
  putU8 bd 0x40
  b <- stringBytes s
  putEscaped bd b
putKeyCell bd TBlob (Just xs) = do
  putU8 bd 0x50
  b <- packBytes xs
  putEscaped bd b

export
putKeyRow : Builder -> (ts : List SqlType) -> Row ts -> DB ()
putKeyRow bd [] [] = pure ()
putKeyRow bd (t :: ts) (x :: xs) = putKeyCell bd t x >> putKeyRow bd ts xs

||| The key of a table row: its rowid, ordered numerically.
export
rowidKey : Int64 -> DB Bytes
rowidKey rowid = do
  bd <- newBuilder 8
  putBE64 bd (cast rowid `xor` signBit)
  finish bd

||| The rowid in the last 8 bytes of a table key or an index key.
export
keyRowid : Bytes -> DB Int64
keyRowid key = do
  when' (size key < 8) (Corrupt "key too short to hold a rowid")
  let at = size key - 8
  bs <- liftIO (traverse (\i => byteAt key (at + i)) [0, 1, 2, 3, 4, 5, 6, 7])
  let bits = foldl (\acc, b => (acc `shiftL` 8) .|. cast b) (the Bits64 0) bs
  pure (cast (bits `xor` signBit))

||| An index key: the encoded column values followed by the rowid, which
||| makes every key unique even when the column values repeat.
export
indexKey : (ts : List SqlType) -> Row ts -> (rowid : Int64) -> DB Bytes
indexKey ts row rowid = do
  bd <- newBuilder 32
  putKeyRow bd ts row
  putBE64 bd (cast rowid `xor` signBit)
  finish bd

||| The encoded column values alone: the common prefix of every index key
||| with those values.
export
keyPrefix : (ts : List SqlType) -> Row ts -> DB Bytes
keyPrefix ts row = do
  bd <- newBuilder 32
  putKeyRow bd ts row
  finish bd
