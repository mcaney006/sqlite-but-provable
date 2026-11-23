module IdrisQL.Server.Http

import Data.List
import Data.List1
import Data.Maybe
import Data.String
import IdrisQL.Types

%default total

-- The pure half of the HTTP server: request parsing and JSON rendering.
-- Nothing here does I/O, and every function is total, so a malformed
-- request cannot make the server loop or crash.

public export
record Request where
  constructor MkRequest
  method : String
  path : String
  ||| Header names in lower case.
  headers : List (String, String)

export
header : String -> Request -> Maybe String
header name req = lookup (toLower name) req.headers

||| The bytes before the blank line that ends the header block, and the
||| bytes after it. `Nothing` while the blank line has not arrived.
export
splitHead : List Bits8 -> Maybe (List Bits8, List Bits8)
splitHead = go []
  where
    go : List Bits8 -> List Bits8 -> Maybe (List Bits8, List Bits8)
    go acc (13 :: 10 :: 13 :: 10 :: rest) = Just (reverse acc, rest)
    go acc (b :: bs) = go (b :: acc) bs
    go acc [] = Nothing

ascii : List Bits8 -> String
ascii = pack . map (chr . cast)

headerLine : String -> Maybe (String, String)
headerLine line =
  let (name, rest) = break (== ':') line
  in case strUncons rest of
       Just (':', value) => Just (toLower (trim name), trim value)
       _ => Nothing

||| Parse a request line and headers. `Nothing` when the request line is
||| not `METHOD SP PATH SP HTTP/1.x`.
export
parseHead : List Bits8 -> Maybe Request
parseHead bytes =
  case lines (pack (filter (/= '\r') (unpack (ascii bytes)))) of
    [] => Nothing
    (first :: rest) => case words first of
      [method, target, version] =>
        if isPrefixOf "HTTP/1." version
          then Just (MkRequest method (pack (takeWhile (/= '?') (unpack target))) (mapMaybe headerLine rest))
          else Nothing
      _ => Nothing

||| The value of a Content-Length header: decimal digits and nothing else.
||| Eighteen digits is far past any size the server accepts and still fits
||| every integer type, so a longer value is refused, not wrapped.
export
contentLength : String -> Maybe Integer
contentLength s =
  let cs = unpack s
  in if cs /= [] && length cs <= 18 && all isDigit cs then parseInteger s else Nothing

||| True for an IPv4 address written as four decimal numbers, each 0 to 255.
||| A host name is not accepted: the socket library does not resolve names
||| reliably, and a bind that silently lands elsewhere is worse than a
||| refusal.
export
validIPv4 : String -> Bool
validIPv4 s =
  let parts = forget (split (== '.') s)
  in length parts == 4 && all octet parts
  where
    octet : String -> Bool
    octet p = p /= "" && length p <= 3 && all isDigit (unpack p)
              && maybe False (<= 255) (parsePositive {a = Integer} p)

||| True when the bytes are well-formed UTF-8: no truncated or overlong
||| sequence, no surrogate, nothing above U+10FFFF.
export
validUtf8 : List Bits8 -> Bool
validUtf8 [] = True
validUtf8 (b :: bs) =
  if b < 0x80 then validUtf8 bs
  else if b >= 0xC2 && b <= 0xDF then continuation 1 0x80 0xBF bs
  else if b == 0xE0 then continuation 2 0xA0 0xBF bs
  else if b == 0xED then continuation 2 0x80 0x9F bs
  else if b >= 0xE1 && b <= 0xEF then continuation 2 0x80 0xBF bs
  else if b == 0xF0 then continuation 3 0x90 0xBF bs
  else if b >= 0xF1 && b <= 0xF3 then continuation 3 0x80 0xBF bs
  else if b == 0xF4 then continuation 3 0x80 0x8F bs
  else False
  where
    -- `n` continuation bytes; the first must lie in [lo, hi].
    continuation : Nat -> Bits8 -> Bits8 -> List Bits8 -> Bool
    continuation Z _ _ rest = validUtf8 rest
    continuation (S k) lo hi [] = False
    continuation (S k) lo hi (c :: rest) = c >= lo && c <= hi && continuation k 0x80 0xBF rest

-- JSON. Results can hold many rows, so strings are joined with
-- `fastConcat`, which is linear; `concat` on a long list is quadratic.

hexDigit : Int -> Char
hexDigit d = if d < 10 then chr (d + 48) else chr (d + 87)

escape : Char -> List Char
escape '"' = ['\\', '"']
escape '\\' = ['\\', '\\']
escape '\n' = ['\\', 'n']
escape '\r' = ['\\', 'r']
escape '\t' = ['\\', 't']
escape c =
  let n = ord c
  in if n < 32 then ['\\', 'u', '0', '0', hexDigit (n `div` 16), hexDigit (n `mod` 16)] else [c]

export
jsonString : String -> String
jsonString s = pack ('"' :: concatMap escape (unpack s) ++ ['"'])

||| A value as JSON. INTEGER and REAL are numbers, TEXT a string, BOOLEAN
||| true or false, NULL null. A BLOB is `{"blob":"<hex>"}` and an infinite
||| REAL the string "Infinity" or "-Infinity", which JSON has no number for.
export
jsonValue : Value -> String
jsonValue VNull = "null"
jsonValue (VInt i) = show i
jsonValue (VReal d) =
  if d == d && d - d == 0.0 then show d
  else if d > 0.0 then "\"Infinity\"" else "\"-Infinity\""
jsonValue (VText s) = jsonString s
jsonValue (VBlob bytes) = "{\"blob\":\"" ++ concatMap hexByte bytes ++ "\"}"
jsonValue (VBool b) = if b then "true" else "false"

export
jsonArray : List String -> String
jsonArray xs = fastConcat ("[" :: intersperse "," xs ++ ["]"])

export
jsonObject : List (String, String) -> String
jsonObject fields =
  fastConcat ("{" :: intersperse "," (map (\(k, v) => fastConcat [jsonString k, ":", v]) fields) ++ ["}"])

export
reason : Int -> String
reason 200 = "OK"
reason 400 = "Bad Request"
reason 401 = "Unauthorized"
reason 403 = "Forbidden"
reason 404 = "Not Found"
reason 405 = "Method Not Allowed"
reason 411 = "Length Required"
reason 413 = "Content Too Large"
reason 431 = "Request Header Fields Too Large"
reason 500 = "Internal Server Error"
reason _ = "Error"

||| The status line and headers of a response whose body is `length` bytes
||| of JSON. The connection closes after every response.
export
responseHead : (status : Int) -> (length : Int) -> String
responseHead status len =
  "HTTP/1.1 " ++ show status ++ " " ++ reason status ++ "\r\n"
    ++ "Content-Type: application/json\r\n"
    ++ "Content-Length: " ++ show len ++ "\r\n"
    ++ "Connection: close\r\n\r\n"
