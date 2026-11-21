module IdrisQL.SQL.Token

import Data.List
import IdrisQL.Error

%default total

public export
data TokKind : Type where
  ||| A reserved word, upper-cased.
  KwTok     : String -> TokKind
  ||| An unquoted identifier in its written case. Never a reserved word.
  IdentTok  : String -> TokKind
  QuotedTok : String -> TokKind
  IntTok    : Integer -> TokKind
  RealTok   : Double -> TokKind
  StrTok    : String -> TokKind
  BlobTok   : List Bits8 -> TokKind
  ||| An operator or punctuation mark, as written.
  SymTok    : String -> TokKind
  ||| `?` is `Nothing`; `?N` is `Just N` with N >= 1.
  ParamTok  : Maybe Nat -> TokKind
  EOFTok    : TokKind

public export
record Token where
  constructor MkToken
  ||| Position of the token's first character. For `EOFTok`, the position
  ||| just past the last character of the input.
  pos : Pos
  kind : TokKind

-- Words that cannot be used as identifiers unless double-quoted. Words the
-- grammar only recognises in one place (KEY, IF, QUERY, PLAN, TRANSACTION,
-- ANALYZE, OVER, PRECISION, RELEASE, and the type names) stay identifiers.
reservedWords : List String
reservedWords =
  [ "ALL", "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CAST"
  , "CHECK", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "DEFAULT", "DELETE"
  , "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXCEPT", "EXISTS", "EXPLAIN"
  , "FALSE", "FOREIGN", "FROM", "FULL", "GROUP", "HAVING", "IN", "INDEX", "INNER"
  , "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT"
  , "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES"
  , "RIGHT", "ROLLBACK", "SAVEPOINT", "SELECT", "SET", "TABLE", "THEN", "TRUE"
  , "UNION", "UNIQUE", "UPDATE", "VALUES", "WHEN", "WHERE"
  ]

||| Whether an upper-cased word is reserved.
export
isReserved : String -> Bool
isReserved w = elem w reservedWords

||| How a token is named in an error message.
export
describe : TokKind -> String
describe (KwTok k) = "'" ++ k ++ "'"
describe (IdentTok s) = "'" ++ s ++ "'"
describe (QuotedTok s) = "'\"" ++ s ++ "\"'"
describe (IntTok n) = "'" ++ show n ++ "'"
describe (RealTok d) = "'" ++ show d ++ "'"
describe (StrTok _) = "a string literal"
describe (BlobTok _) = "a blob literal"
describe (SymTok s) = "'" ++ s ++ "'"
describe (ParamTok Nothing) = "'?'"
describe (ParamTok (Just n)) = "'?" ++ show n ++ "'"
describe EOFTok = "end of input"
