module Tests.Server

import Data.List
import Data.Maybe
import Data.String
import IdrisQL.Server.Http
import IdrisQL.Types
import Tests.Harness

-- The pure half of the HTTP server. The server itself is exercised over
-- real sockets by tests/server/run.sh.

bytes : String -> List Bits8
bytes = map (cast . ord) . unpack

export
serverTests : List Test
serverTests =
  [ pureTest "the header block ends at the first blank line" $ do
      checkEq "split" (splitHead (bytes "GET / HTTP/1.1\r\nA: b\r\n\r\nbody\r\n\r\nmore"))
        (Just (bytes "GET / HTTP/1.1\r\nA: b", bytes "body\r\n\r\nmore"))
      checkEq "incomplete" (splitHead (bytes "GET / HTTP/1.1\r\nA: b\r\n")) Nothing
      checkEq "empty" (splitHead []) Nothing

  , pureTest "request line and headers are parsed" $ do
      let Just req = parseHead (bytes "POST /query?x=1 HTTP/1.1\r\nHost: db\r\nContent-Length:  12 \r\nAUTHORIZATION: Bearer t")
        | Nothing => Left "a well-formed request was rejected"
      checkEq "method" req.method "POST"
      checkEq "path without the query string" req.path "/query"
      checkEq "header value is trimmed" (header "content-length" req) (Just "12")
      checkEq "header names are case-insensitive" (header "Authorization" req) (Just "Bearer t")
      checkEq "missing header" (header "x-none" req) Nothing

  , pureTest "malformed request lines are rejected" $ do
      check (isNothing (parseHead (bytes "GET /"))) "two words were accepted"
      check (isNothing (parseHead (bytes "GET / FTP/1.1"))) "a non-HTTP version was accepted"
      check (isNothing (parseHead [])) "an empty request was accepted"
      check (isNothing (parseHead (bytes "\r\n\r\n"))) "a blank request line was accepted"

  , pureTest "UTF-8 validation" $ do
      check (validUtf8 (bytes "plain ascii")) "ASCII"
      check (validUtf8 [0xC3, 0xBC]) "two-byte sequence"
      check (validUtf8 [0xE2, 0x82, 0xAC]) "three-byte sequence"
      check (validUtf8 [0xF0, 0x9F, 0x98, 0x80]) "four-byte sequence"
      check (not (validUtf8 [0xC3])) "truncated sequence"
      check (not (validUtf8 [0x80])) "stray continuation byte"
      check (not (validUtf8 [0xC0, 0xAF])) "overlong two-byte form"
      check (not (validUtf8 [0xE0, 0x80, 0xAF])) "overlong three-byte form"
      check (not (validUtf8 [0xED, 0xA0, 0x80])) "surrogate"
      check (not (validUtf8 [0xF4, 0x90, 0x80, 0x80])) "above U+10FFFF"
      check (not (validUtf8 [0xFF])) "invalid lead byte"

  , pureTest "Content-Length is digits only and never wraps" $ do
      checkEq "plain" (contentLength "12") (Just 12)
      checkEq "zero" (contentLength "0") (Just 0)
      checkEq "past 64 bits" (contentLength "18446744073709551615") Nothing
      checkEq "signed" (contentLength "+5") Nothing
      checkEq "negative" (contentLength "-1") Nothing
      checkEq "empty" (contentLength "") Nothing
      checkEq "not a number" (contentLength "12a") Nothing

  , pureTest "a listen address is four numbers from 0 to 255" $ do
      checkEq "loopback" (validIPv4 "127.0.0.1") True
      checkEq "any" (validIPv4 "0.0.0.0") True
      checkEq "a name" (validIPv4 "localhost") False
      checkEq "a letter in an octet" (validIPv4 "10.0.0.x") False
      checkEq "an octet over 255" (validIPv4 "10.0.0.256") False
      checkEq "three octets" (validIPv4 "10.0.0") False
      checkEq "an empty octet" (validIPv4 "10..0.1") False

  , pureTest "JSON strings escape quotes, backslashes and control characters" $ do
      checkEq "plain" (jsonString "abc") "\"abc\""
      checkEq "quote and backslash" (jsonString "a\"b\\c") "\"a\\\"b\\\\c\""
      checkEq "newline and tab" (jsonString "a\nb\tc") "\"a\\nb\\tc\""
      checkEq "NUL and escape" (jsonString (pack ['\0', chr 27])) "\"\\u0000\\u001b\""
      checkEq "non-ASCII is passed through" (jsonString "ü€") "\"ü€\""

  , pureTest "JSON values" $ do
      checkEq "null" (jsonValue VNull) "null"
      checkEq "integer" (jsonValue (VInt (-9223372036854775808))) "-9223372036854775808"
      checkEq "real" (jsonValue (VReal 1.5)) "1.5"
      checkEq "infinity" (jsonValue (VReal (1.0 / 0.0))) "\"Infinity\""
      checkEq "negative infinity" (jsonValue (VReal (-1.0 / 0.0))) "\"-Infinity\""
      checkEq "text" (jsonValue (VText "x")) "\"x\""
      checkEq "blob" (jsonValue (VBlob [0, 255])) "{\"blob\":\"00FF\"}"
      checkEq "booleans" (jsonValue (VBool True) ++ jsonValue (VBool False)) "truefalse"
      checkEq "array" (jsonArray ["1", "2"]) "[1,2]"
      checkEq "empty array" (jsonArray []) "[]"
      checkEq "object" (jsonObject [("a", "1"), ("b", "[]")]) "{\"a\":1,\"b\":[]}"

  , pureTest "response head carries the status and the body length" $ do
      checkEq "head" (responseHead 404 17)
        "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 17\r\nConnection: close\r\n\r\n"
  ]
