module IdrisQL.SQL.Lexer

import Data.List
import Data.SnocList
import Data.String
import IdrisQL.Error
import IdrisQL.SQL.Token

%default total

step : Pos -> Char -> Pos
step p '\n' = MkPos (S p.line) 1
step p _ = MkPos p.line (S p.col)

addCol : Pos -> Nat -> Pos
addCol p n = MkPos p.line (p.col + n)

isIdentStart : Char -> Bool
isIdentStart c = isAlpha c || c == '_'

isIdentChar : Char -> Bool
isIdentChar c = isAlphaNum c || c == '_'

digitsToInteger : List Char -> Integer
digitsToInteger = foldl (\acc, c => acc * 10 + cast (ord c - ord '0')) 0

hexVal : Char -> Bits8
hexVal c = if isDigit c then cast (ord c - ord '0') else cast (ord (toUpper c) - ord 'A' + 10)

hexPairs : List Char -> List Bits8
hexPairs (a :: b :: rest) = (hexVal a * 16 + hexVal b) :: hexPairs rest
hexPairs _ = []

-- One lexing step: the token (none for whitespace and comments), the
-- position after it, and the remaining input.
Lexed : Type
Lexed = Either DbError (Maybe TokKind, Pos, List Char)

tok : TokKind -> Pos -> List Char -> Lexed
tok k p rest = Right (Just k, p, rest)

-- Body of a quoted token after its opening quote. A doubled quote stands
-- for one quote character. `Nothing` when the closing quote is missing.
quotedBody : (q : Char) -> Pos -> List Char -> SnocList Char -> Maybe (String, Pos, List Char)
quotedBody q p (c :: d :: cs) acc =
  if c == q
    then if d == q
           then quotedBody q (addCol p 2) cs (acc :< q)
           else Just (pack (acc <>> []), addCol p 1, d :: cs)
    else quotedBody q (step p c) (d :: cs) (acc :< c)
quotedBody q p [c] acc = if c == q then Just (pack (acc <>> []), addCol p 1, []) else Nothing
quotedBody q p [] acc = Nothing

blockComment : Pos -> List Char -> Maybe (Pos, List Char)
blockComment p ('*' :: '/' :: cs) = Just (addCol p 2, cs)
blockComment p (c :: cs) = blockComment (step p c) cs
blockComment p [] = Nothing

-- An exponent such as `e-5`: its normalised text, the number of characters
-- it spans, and the input after it. Spans nothing unless digits follow.
exponentPart : List Char -> (String, Nat, List Char)
exponentPart [] = ("", 0, [])
exponentPart cs@(e :: after) =
  if e == 'e' || e == 'E'
    then
      let (sign, signLen, ds) = the (String, Nat, List Char) $ case after of
            ('-' :: r) => ("-", 1, r)
            ('+' :: r) => ("", 1, r)
            _ => ("", 0, after)
          (digits, rest) = span isDigit ds
      in if null digits
           then ("", 0, cs)
           else ("e" ++ sign ++ pack digits, 1 + signLen + length digits, rest)
    else ("", 0, cs)

lexNumber : Pos -> List Char -> Lexed
lexNumber p cs =
  let (intPart, r1) = span isDigit cs
      (fracPart, dotLen, r2) = the (List Char, Nat, List Char) $ case r1 of
        ('.' :: r) => let (f, r') = span isDigit r in (f, 1 + length f, r')
        _ => ([], 0, r1)
      (expText, expLen, r3) = exponentPart r2
      text = (if null intPart then "0" else pack intPart) ++ "."
          ++ (if null fracPart then "0" else pack fracPart) ++ expText
      kind = if dotLen > 0 || expLen > 0
               then RealTok (cast text)
               else IntTok (digitsToInteger intPart)
  in if startsIdent r3
       then Left (SyntaxError p "malformed numeric literal")
       else tok kind (addCol p (length intPart + dotLen + expLen)) r3
  where
    startsIdent : List Char -> Bool
    startsIdent (c :: _) = isIdentStart c
    startsIdent [] = False

evenLength : List a -> Bool
evenLength (_ :: _ :: rest) = evenLength rest
evenLength [] = True
evenLength [_] = False

lexBlob : Pos -> List Char -> Lexed
lexBlob p body =
  let (hex, r) = span isHexDigit body in
  case r of
    ('\'' :: rest) =>
      if evenLength hex
        then tok (BlobTok (hexPairs hex)) (addCol p (3 + length hex)) rest
        else Left (SyntaxError p "blob literal needs an even number of hex digits")
    _ => Left (SyntaxError p "malformed blob literal")

lexWord : Pos -> Char -> List Char -> Lexed
lexWord p c rest =
  let (more, r) = span isIdentChar rest
      word = pack (c :: more)
      upper = toUpper word
  in tok (if isReserved upper then KwTok upper else IdentTok word) (addCol p (S (length more))) r

symbol2 : Char -> Char -> Maybe String
symbol2 '|' '|' = Just "||"
symbol2 '=' '=' = Just "=="
symbol2 '!' '=' = Just "!="
symbol2 '<' '>' = Just "<>"
symbol2 '<' '=' = Just "<="
symbol2 '>' '=' = Just ">="
symbol2 _ _ = Nothing

lexSymbol1 : Pos -> Char -> List Char -> Lexed
lexSymbol1 p c rest =
  if elem c (unpack "+-*/%=<>(),;.")
    then tok (SymTok (singleton c)) (addCol p 1) rest
    else Left (SyntaxError p ("unexpected character '" ++ singleton c ++ "'"))

lexSymbol : Pos -> Char -> List Char -> Lexed
lexSymbol p c [] = lexSymbol1 p c []
lexSymbol p c (d :: rest) =
  case symbol2 c d of
    Just s => tok (SymTok s) (addCol p 2) rest
    Nothing => lexSymbol1 p c (d :: rest)

startsWithDigit : List Char -> Bool
startsWithDigit (c :: _) = isDigit c
startsWithDigit [] = False

lexOne : Pos -> Char -> List Char -> Lexed
lexOne p '\'' rest =
  case quotedBody '\'' (addCol p 1) rest [<] of
    Nothing => Left (SyntaxError p "unterminated string literal")
    Just (s, p', r) => tok (StrTok s) p' r
lexOne p '"' rest =
  case quotedBody '"' (addCol p 1) rest [<] of
    Nothing => Left (SyntaxError p "unterminated quoted identifier")
    Just (s, p', r) =>
      if s == "" then Left (SyntaxError p "empty quoted identifier") else tok (QuotedTok s) p' r
lexOne p '-' ('-' :: rest) =
  let (comment, r) = break (== '\n') rest in
  Right (Nothing, addCol p (2 + length comment), r)
lexOne p '/' ('*' :: rest) =
  case blockComment (addCol p 2) rest of
    Nothing => Left (SyntaxError p "unterminated block comment")
    Just (p', r) => Right (Nothing, p', r)
lexOne p '?' rest =
  let (digits, r) = span isDigit rest in
  if null digits
    then tok (ParamTok Nothing) (addCol p 1) r
    else
      let n = digitsToInteger digits in
      if n < 1
        then Left (SyntaxError p "parameter numbers start at ?1")
        else tok (ParamTok (Just (cast n))) (addCol p (1 + length digits)) r
lexOne p c rest =
  if isSpace c then Right (Nothing, step p c, rest)
  else if (c == 'x' || c == 'X') && startsWithQuote rest then lexBlob p (drop 1 rest)
  else if isIdentStart c then lexWord p c rest
  else if isDigit c || (c == '.' && startsWithDigit rest) then lexNumber p (c :: rest)
  else lexSymbol p c rest
  where
    startsWithQuote : List Char -> Bool
    startsWithQuote ('\'' :: _) = True
    startsWithQuote _ = False

-- Every step consumes at least one character, so `length input + 1` steps
-- always suffice; the fuel only exists to make termination structural.
lexAll : (fuel : Nat) -> Pos -> List Char -> SnocList Token -> Either DbError (List Token)
lexAll _ p [] acc = Right (acc <>> [MkToken p EOFTok])
lexAll Z p (_ :: _) _ = Left (SyntaxError p "lexer ran out of fuel")
lexAll (S k) p (c :: rest) acc =
  case lexOne p c rest of
    Left e => Left e
    Right (Nothing, p', rest') => lexAll k p' rest' acc
    Right (Just kind, p', rest') => lexAll k p' rest' (acc :< MkToken p kind)

||| Split SQL text into tokens. The result always ends with one `EOFTok`.
export
tokenize : String -> Either DbError (List Token)
tokenize src = let cs = unpack src in lexAll (S (length cs)) (MkPos 1 1) cs [<]

data ScanMode = Normal | Quoted Char | LineComment | BlockComment

-- `content` records whether the statement being scanned has any text that
-- is not whitespace or a comment.
scan : ScanMode -> (content : Bool) -> List Char -> Bool
scan Normal _ [] = False
scan Normal content ('-' :: '-' :: cs) = scan LineComment content cs
scan Normal content ('/' :: '*' :: cs) = scan BlockComment content cs
scan Normal content (c :: cs) =
  if c == ';' then content || scan Normal False cs
  else if c == '\'' || c == '"' then scan (Quoted c) True cs
  else scan Normal (content || not (isSpace c)) cs
scan (Quoted _) _ [] = False
scan (Quoted q) content (c :: cs) =
  if c == q then scan Normal content cs else scan (Quoted q) content cs
scan LineComment _ [] = False
scan LineComment content ('\n' :: cs) = scan Normal content cs
scan LineComment content (_ :: cs) = scan LineComment content cs
scan BlockComment _ [] = False
scan BlockComment content ('*' :: '/' :: cs) = scan Normal content cs
scan BlockComment content (_ :: cs) = scan BlockComment content cs

||| Whether the text holds a `;` that ends a non-empty statement. A `;`
||| inside a string literal, a quoted identifier or a comment does not
||| count, and an unterminated string or comment gives `False`.
export
statementComplete : String -> Bool
statementComplete src = scan Normal False (unpack src)
