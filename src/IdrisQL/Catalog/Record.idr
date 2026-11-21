module IdrisQL.Catalog.Record

import IdrisQL.Error
import IdrisQL.Storage.Codec
import IdrisQL.Types

-- Row format: u16 column count, then per column a tag byte and a payload.
--
--   0 NULL                      4 BLOB  u32 length, bytes
--   1 INTEGER  8 bytes LE       5 BOOLEAN false
--   2 REAL     8 bytes LE       6 BOOLEAN true
--   3 TEXT     u32 length, UTF-8
--
-- Decoding is driven by the table's column types: a tag that does not match
-- the declared type is corruption, so a decoded `Row ts` always has the
-- shape its type says.

putCell : Builder -> (t : SqlType) -> Cell t -> DB ()
putCell bd _ Nothing = putU8 bd 0
putCell bd TInt (Just x) = putU8 bd 1 >> putI64 bd x
putCell bd TReal (Just x) = putU8 bd 2 >> putDouble bd x
putCell bd TText (Just s) = putU8 bd 3 >> putString bd s
putCell bd TBlob (Just xs) = do
  putU8 bd 4
  b <- packBytes xs
  putU32 bd (size b)
  putBytes bd b
putCell bd TBool (Just b) = putU8 bd (if b then 6 else 5)

putCells : Builder -> (ts : List SqlType) -> Row ts -> DB ()
putCells bd [] [] = pure ()
putCells bd (t :: ts) (x :: xs) = putCell bd t x >> putCells bd ts xs

export
encodeRow : (ts : List SqlType) -> Row ts -> DB Bytes
encodeRow ts row = do
  bd <- newBuilder 64
  putU16 bd (cast (length ts))
  putCells bd ts row
  finish bd

mismatch : SqlType -> Int -> DbError
mismatch t tag = Corrupt ("row holds tag " ++ show tag ++ " in a column of type " ++ show t)

takeCell : Decoder -> (t : SqlType) -> DB (Cell t)
takeCell d t = do
  tag <- takeU8 d
  if tag == 0 then pure Nothing else body t tag
  where
    body : (t : SqlType) -> Int -> DB (Cell t)
    body TInt 1 = map Just (takeI64 d)
    body TReal 2 = map Just (takeDouble d)
    body TText 3 = map Just (takeString d)
    body TBlob 4 = do
      n <- takeU32 d
      b <- takeBytes d n
      map Just (liftIO (unpackBytes b))
    body TBool 5 = pure (Just False)
    body TBool 6 = pure (Just True)
    body t tag = throw (mismatch t tag)

-- Step over a cell without building its value.
skipCell : Decoder -> (t : SqlType) -> DB ()
skipCell d t = do
  tag <- takeU8 d
  case tag of
    0 => pure ()
    1 => ignore (takeBits64 d)
    2 => ignore (takeBits64 d)
    3 => do n <- takeU32 d
            ignore (takeBytes d n)
    4 => do n <- takeU32 d
            ignore (takeBytes d n)
    5 => pure ()
    6 => pure ()
    _ => throw (mismatch t tag)

-- An exhausted mask means "decode everything that is left".
splitMask : List Bool -> (Bool, List Bool)
splitMask [] = (True, [])
splitMask (w :: ws) = (w, ws)

takeCells : Decoder -> (ts : List SqlType) -> (needed : List Bool) -> DB (Row ts)
takeCells d [] _ = pure []
takeCells d (t :: ts) needed = do
  let (want, rest) = splitMask needed
  x <- if want then takeCell d t else skipCell d t >> pure Nothing
  xs <- takeCells d ts rest
  pure (x :: xs)

||| Decode a stored row. Columns whose `needed` flag is False are skipped
||| and returned as NULL; an empty `needed` means every column.
export
decodeRowMasked : (ts : List SqlType) -> (needed : List Bool) -> Bytes -> DB (Row ts)
decodeRowMasked ts needed bytes = do
  d <- newDecoder bytes
  n <- takeU16 d
  when' (n /= cast (length ts))
    (Corrupt ("row has " ++ show n ++ " columns, table has " ++ show (length ts)))
  takeCells d ts needed

export
decodeRow : (ts : List SqlType) -> Bytes -> DB (Row ts)
decodeRow ts = decodeRowMasked ts []
