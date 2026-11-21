module Tests.SqlFrontend

import Data.List
import Data.Maybe
import Data.String
import IdrisQL.Error
import IdrisQL.SQL.AST
import IdrisQL.SQL.Lexer
import IdrisQL.SQL.Parser
import IdrisQL.Types
import Tests.Harness

p0 : Pos
p0 = MkPos 0 0

num : Integer -> Expr
num n = ELit p0 (LInt n)

column : String -> Expr
column = ECol p0 Nothing

bin : BinOp -> Expr -> Expr -> Expr
bin = EBin p0

-- Both texts parse to the same tree.
sameAs : String -> String -> Either String ()
sameAs a b =
  case (parseExpr a, parseExpr b) of
    (Right x, Right y) =>
      check (sameExpr x y) (a ++ " should parse like " ++ b ++ " but is " ++ renderExpr x)
    (Left e, _) => Left (a ++ ": " ++ show e)
    (_, Left e) => Left (b ++ ": " ++ show e)

treeIs : String -> Expr -> Either String ()
treeIs src want =
  case parseExpr src of
    Right got => check (sameExpr got want) (src ++ " parsed as " ++ renderExpr got)
    Left e => Left (src ++ ": " ++ show e)

roundTrip : String -> Either String ()
roundTrip src =
  case parseExpr src of
    Left e => Left (src ++ ": " ++ show e)
    Right x =>
      let text = renderExpr x in
      case parseExpr text of
        Left e => Left ("rendered form " ++ text ++ " does not parse: " ++ show e)
        Right y => check (sameExpr x y) (src ++ " rendered as " ++ text ++ " reparses differently")

statementOf : String -> Either String Stmt
statementOf src =
  case parseStatement src of
    Right s => Right s
    Left e => Left (src ++ ": " ++ show e)

parses : String -> Either String ()
parses src = map (const ()) (statementOf src)

-- The statement is rejected with a syntax error at the given position.
errorAt : String -> (line : Nat) -> (col : Nat) -> Either String ()
errorAt src l c =
  case parseStatement src of
    Left (SyntaxError p msg) =>
      check (p.line == l && p.col == c)
            (show src ++ ": expected an error at " ++ show l ++ ":" ++ show c
               ++ ", got " ++ show p ++ " (" ++ msg ++ ")")
    Left e => Left (show src ++ ": expected a syntax error, got " ++ show e)
    Right _ => Left (show src ++ ": expected a syntax error, but it parsed")

-- The script is rejected with a syntax error whose message contains `needle`.
rejects : String -> (needle : String) -> Either String ()
rejects src needle =
  case parseStatements src of
    Left (SyntaxError _ msg) =>
      check (isInfixOf needle msg) (show src ++ ": message was " ++ show msg)
    Left e => Left (show src ++ ": expected a syntax error, got " ++ show e)
    Right _ => Left (show src ++ ": expected a syntax error, but it parsed")

params : Expr -> List Nat
params (EParam _ i) = [i]
params (EBin _ _ a b) = params a ++ params b
params (ENeg _ a) = params a
params (ENot _ a) = params a
params (EIsNull _ _ a) = params a
params (EIn _ _ a xs) = params a ++ concatMap (\x => params x) xs
params (EBetween _ _ a l h) = params a ++ params l ++ params h
params (ELike _ _ a p) = params a ++ params p
params (ECast _ a _) = params a
params (ECall _ _ _ xs) = concatMap (\x => params x) xs
params _ = []

paramsOf : String -> List Nat -> Either String ()
paramsOf src want =
  case parseExpr src of
    Right e => checkEq ("parameters of " ++ src) (params e) want
    Left e => Left (src ++ ": " ++ show e)

precedencePairs : List (String, String)
precedencePairs =
  [ ("1 + 2 * 3", "1 + (2 * 3)")
  , ("1 * 2 + 3", "(1 * 2) + 3")
  , ("1 - 2 - 3", "(1 - 2) - 3")
  , ("8 / 4 / 2", "(8 / 4) / 2")
  , ("a % b * c", "(a % b) * c")
  , ("a OR b AND c", "a OR (b AND c)")
  , ("a AND b OR c", "(a AND b) OR c")
  , ("NOT a AND b", "(NOT a) AND b")
  , ("NOT a = b", "NOT (a = b)")
  , ("NOT NOT a", "NOT (NOT a)")
  , ("a = b OR c = d", "(a = b) OR (c = d)")
  , ("a = 1 AND b = 2 OR c = 3 AND d = 4", "((a = 1) AND (b = 2)) OR ((c = 3) AND (d = 4))")
  , ("a + b = c - d", "(a + b) = (c - d)")
  , ("a < b = c", "(a < b) = c")
  , ("a || b || c", "(a || b) || c")
  , ("a * b || c", "a * (b || c)")
  , ("-a * b", "(-a) * b")
  , ("- - a", "-(-a)")
  , ("+a", "a")
  , ("a - -b", "a - (-b)")
  , ("a BETWEEN 1 AND 2 AND b", "(a BETWEEN 1 AND 2) AND b")
  , ("a BETWEEN 1 + 1 AND 2 * 3", "a BETWEEN (1 + 1) AND (2 * 3)")
  , ("a NOT BETWEEN 1 AND 2 OR b", "(a NOT BETWEEN 1 AND 2) OR b")
  , ("a NOT IN (1, 2) OR b", "(a NOT IN (1, 2)) OR b")
  , ("a IS NULL AND b IS NOT NULL", "(a IS NULL) AND (b IS NOT NULL)")
  , ("a LIKE 'x' || 'y'", "a LIKE ('x' || 'y')")
  , ("a + 1 IN (2, 3)", "(a + 1) IN (2, 3)")
  , ("a == b", "a = b")
  , ("a != b", "a <> b")
  , ("A.B = a.b", "a.b = A.B")
  ]

roundTripInputs : List String
roundTripInputs =
  [ "1 + 2 * 3 - 4 / 5 % 6"
  , "a AND (b OR NOT c)"
  , "t.x >= 10 AND t.y <= 2.5"
  , "name LIKE 'A%' OR name NOT LIKE '%z'"
  , "x IN (1, 2, 3) AND y NOT IN ('a', 'b')"
  , "x IN ()"
  , "age BETWEEN 18 AND 65"
  , "age NOT BETWEEN ?1 AND ?2"
  , "email IS NOT NULL AND phone IS NULL"
  , "'it''s' || \"odd \"\"name\"\"\" || X'00FF'"
  , "CAST(total AS INTEGER) + CAST('3' AS REAL)"
  , "COUNT(*) > 0 AND SUM(DISTINCT o.total) < 1e3"
  , "coalesce(a, b, 0) = -1"
  , "TRUE AND NOT FALSE OR NULL"
  , "? + ? * ?5"
  , "length(upper(name)) <> 0"
  , "now() = now()"
  , "-(-x) - -3"
  , "1.5e10 * 0.001 + .5"
  ]

demoCreate : String
demoCreate =
  "CREATE TABLE users (\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n"
    ++ "    email TEXT NOT NULL UNIQUE,\n    age INTEGER CHECK (age >= 0)\n);"

demoSelect : String
demoSelect =
  "SELECT\n    u.name,\n    COUNT(o.id) AS order_count,\n    SUM(o.total) AS lifetime_value\n"
    ++ "FROM users AS u\nINNER JOIN orders AS o\n    ON u.id = o.user_id\n"
    ++ "GROUP BY u.id, u.name\nHAVING COUNT(o.id) > 0\nORDER BY lifetime_value DESC;"

statementForms : List String
statementForms =
  [ demoCreate
  , demoSelect
  , "CREATE TABLE IF NOT EXISTS t (a INT, b BIGINT, c SMALLINT, d DOUBLE PRECISION, e FLOAT, "
      ++ "f VARCHAR(20), g CHAR(1), h STRING, i BLOB, j BOOL, k BOOLEAN, l REAL, m TEXT)"
  , "CREATE TABLE t (a INTEGER DEFAULT 0, b REAL DEFAULT -1.5, c TEXT DEFAULT 'x', "
      ++ "d INTEGER DEFAULT (1 + 2), e BOOLEAN DEFAULT TRUE, f BLOB DEFAULT NULL, g INTEGER DEFAULT +7)"
  , "CREATE TABLE t (a INTEGER, b INTEGER, c TEXT, PRIMARY KEY (a, b), UNIQUE (c), "
      ++ "CHECK (a < b), FOREIGN KEY (b) REFERENCES u (id))"
  , "CREATE TABLE t (a INTEGER CONSTRAINT pk PRIMARY KEY, b INTEGER CONSTRAINT fk REFERENCES u, "
      ++ "CONSTRAINT positive CHECK (a > 0))"
  , "CREATE TABLE \"my table\" (\"select\" INTEGER, key TEXT, plan TEXT, query TEXT)"
  , "DROP TABLE users"
  , "DROP TABLE IF EXISTS users"
  , "CREATE INDEX idx_orders_user ON orders(user_id)"
  , "CREATE UNIQUE INDEX IF NOT EXISTS u ON t (a, b)"
  , "DROP INDEX idx"
  , "DROP INDEX IF EXISTS idx"
  , "INSERT INTO users VALUES (1, 'Alice', 'alice@example.com', 27)"
  , "INSERT INTO t (a, b) VALUES (1, 2), (3, 4), (?, ?)"
  , "SELECT 1"
  , "SELECT DISTINCT a, b FROM t"
  , "SELECT ALL * FROM t"
  , "SELECT t.*, u.name n FROM t, u WHERE t.id = u.id"
  , "SELECT * FROM a CROSS JOIN b"
  , "SELECT * FROM a JOIN b ON a.x = b.x LEFT OUTER JOIN c ON b.y = c.y LEFT JOIN d ON 1 = 1"
  , "SELECT a FROM t WHERE a > 1 GROUP BY a HAVING COUNT(*) > 1 ORDER BY a ASC, b DESC, c LIMIT 10 OFFSET 5"
  , "SELECT name FROM users WHERE id = 42"
  , "UPDATE users SET age = 28 WHERE id = 1"
  , "UPDATE t SET a = a + 1, b = NULL"
  , "DELETE FROM t"
  , "DELETE FROM t WHERE a IS NULL"
  , "BEGIN"
  , "BEGIN TRANSACTION;"
  , "COMMIT"
  , "COMMIT TRANSACTION"
  , "END"
  , "ROLLBACK"
  , "ROLLBACK TRANSACTION"
  , "EXPLAIN SELECT 1"
  , "EXPLAIN QUERY PLAN SELECT * FROM orders WHERE user_id = 1"
  , "ANALYZE"
  , "select a from t where b like 'x%' order by a desc limit 1"
  ]

conTag : ColConstraint -> String
conTag CPrimaryKey = "pk"
conTag CNotNull = "notnull"
conTag CUnique = "unique"
conTag (CDefault _) = "default"
conTag (CCheck _) = "check"
conTag (CReferences _ _) = "references"

shapeTests : List Test
shapeTests =
  [ pureTest "shape: demo CREATE TABLE" $ do
      SCreateTable _ False "users" cols [] <- statementOf demoCreate
        | _ => Left "not the expected CREATE TABLE"
      checkEq "column names" (map (.name) cols) ["id", "name", "email", "age"]
      checkEq "column types" (map (.type) cols) [TInt, TText, TText, TInt]
      checkEq "constraints" (map (map conTag . (.constraints)) cols)
              [["pk"], ["notnull"], ["notnull", "unique"], ["check"]]
  , pureTest "shape: demo SELECT" $ do
      SSelect s <- statementOf demoSelect | _ => Left "not a SELECT"
      checkEq "distinct" s.distinct False
      checkEq "item count" (length s.items) 3
      Just (ref, [j]) <- pure s.from | _ => Left "expected one join"
      checkEq "table" ref.table "users"
      checkEq "alias" ref.alias (Just "u")
      check (j.kind == JInner) "join kind"
      checkEq "join alias" j.ref.alias (Just "o")
      check (isJust j.on) "join has no ON"
      checkEq "group by count" (length s.groupBy) 2
      check (isJust s.having) "HAVING missing"
      checkEq "descending" (map (\o => snd o == Desc) s.orderBy) [True]
      check (isNothing s.limit && isNothing s.offset) "unexpected LIMIT"
  , pureTest "shape: select items and aliases" $ do
      SSelect s <- statementOf "SELECT *, t.*, a AS x, b y, c FROM t" | _ => Left "not a SELECT"
      let tag : SelectItem -> String
          tag SelStar = "*"
          tag (SelTableStar t) = t ++ ".*"
          tag (SelExpr _ a) = fromMaybe "-" a
      checkEq "items" (map tag s.items) ["*", "t.*", "x", "y", "-"]
  , pureTest "shape: join kinds" $ do
      SSelect s <- statementOf "SELECT * FROM a, b CROSS JOIN c LEFT OUTER JOIN d ON a.x = d.x JOIN e ON 1 = 1"
        | _ => Left "not a SELECT"
      Just (_, js) <- pure s.from | _ => Left "no FROM"
      checkEq "left joins" (map (\j => j.kind == JLeft) js) [False, False, True, False]
      checkEq "ON present" (map (isJust . (.on)) js) [False, False, True, True]
      checkEq "tables" (map (\j => j.ref.table) js) ["b", "c", "d", "e"]
  , pureTest "shape: order, limit, offset" $ do
      SSelect s <- statementOf "SELECT a FROM t ORDER BY a, b DESC, c ASC LIMIT 10 OFFSET 5"
        | _ => Left "not a SELECT"
      checkEq "descending" (map (\o => snd o == Desc) s.orderBy) [False, True, False]
      check (isJust s.limit && isJust s.offset) "LIMIT or OFFSET missing"
  , pureTest "shape: multi-row INSERT" $ do
      SInsert _ "t" (Just ["a", "b"]) rows <- statementOf "INSERT INTO t (a, b) VALUES (1, 2), (3, 4), (5, 6)"
        | _ => Left "not the expected INSERT"
      checkEq "row widths" (map length rows) [2, 2, 2]
  , pureTest "shape: INSERT without column list" $ do
      SInsert _ "users" Nothing [row] <- statementOf "INSERT INTO users VALUES (1, 'Alice', 'a@b.c', 27)"
        | _ => Left "not the expected INSERT"
      checkEq "width" (length row) 4
  , pureTest "shape: UPDATE" $ do
      SUpdate _ "t" sets (Just _) <- statementOf "UPDATE t SET a = 1, b = b + 1 WHERE c"
        | _ => Left "not the expected UPDATE"
      checkEq "targets" (map fst sets) ["a", "b"]
  , pureTest "shape: DELETE" $ do
      SDelete _ "t" Nothing <- statementOf "DELETE FROM t" | _ => Left "not the expected DELETE"
      SDelete _ "t" (Just _) <- statementOf "DELETE FROM t WHERE a = 1" | _ => Left "WHERE lost"
      pass
  , pureTest "shape: DROP flags" $ do
      SDropTable _ True "t" <- statementOf "DROP TABLE IF EXISTS t" | _ => Left "DROP TABLE IF EXISTS"
      SDropTable _ False "t" <- statementOf "DROP TABLE t" | _ => Left "DROP TABLE"
      SDropIndex _ True "i" <- statementOf "DROP INDEX IF EXISTS i" | _ => Left "DROP INDEX IF EXISTS"
      pass
  , pureTest "shape: CREATE INDEX flags" $ do
      SCreateIndex _ True True "u" "t" ["a", "b"] <- statementOf "CREATE UNIQUE INDEX IF NOT EXISTS u ON t (a, b)"
        | _ => Left "unique index"
      SCreateIndex _ False False "i" "t" ["a"] <- statementOf "CREATE INDEX i ON t(a)"
        | _ => Left "plain index"
      pass
  , pureTest "shape: table constraints" $ do
      SCreateTable _ _ _ cols cons <- statementOf
          "CREATE TABLE t (a INTEGER, b INTEGER, PRIMARY KEY (a, b), UNIQUE (b), CHECK (a < b), FOREIGN KEY (b) REFERENCES u (id))"
        | _ => Left "not a CREATE TABLE"
      checkEq "columns" (length cols) 2
      [TCPrimaryKey ["a", "b"], TCUnique ["b"], TCCheck _, TCForeignKey ["b"] "u" ["id"]] <- pure cons
        | _ => Left "table constraints differ"
      pass
  , pureTest "shape: DEFAULT forms" $ do
      SCreateTable _ _ _ cols _ <- statementOf
          "CREATE TABLE t (a INTEGER DEFAULT -1, b TEXT DEFAULT 'x', c INTEGER DEFAULT (1 + 2), d REAL DEFAULT +2.5)"
        | _ => Left "not a CREATE TABLE"
      [[CDefault a], [CDefault b], [CDefault c], [CDefault d]] <- pure (map (.constraints) cols)
        | _ => Left "expected one DEFAULT per column"
      check (sameExpr a (ENeg p0 (num 1))) "DEFAULT -1"
      check (sameExpr b (ELit p0 (LText "x"))) "DEFAULT 'x'"
      check (sameExpr c (bin OAdd (num 1) (num 2))) "DEFAULT (1 + 2)"
      check (sameExpr d (ELit p0 (LReal 2.5))) "DEFAULT +2.5"
  , pureTest "shape: type names" $ do
      SCreateTable _ True _ cols _ <- statementOf
          ("CREATE TABLE IF NOT EXISTS t (a INT, b BIGINT, c SMALLINT, d DOUBLE PRECISION, e FLOAT, "
             ++ "f VARCHAR(20), g CHAR(1), h STRING, i BLOB, j BOOL, k BOOLEAN, l REAL, m TEXT, n double)")
        | _ => Left "not a CREATE TABLE"
      checkEq "types" (map (.type) cols)
              [TInt, TInt, TInt, TReal, TReal, TText, TText, TText, TBlob, TBool, TBool, TReal, TText, TReal]
  , pureTest "shape: EXPLAIN" $ do
      SExplain True (SSelect _) <- statementOf "EXPLAIN QUERY PLAN SELECT 1" | _ => Left "EXPLAIN QUERY PLAN"
      SExplain False (SDelete _ _ _) <- statementOf "explain delete from t" | _ => Left "EXPLAIN"
      pass
  , pureTest "shape: transaction statements" $ do
      SBegin <- statementOf "BEGIN TRANSACTION" | _ => Left "BEGIN"
      SCommit <- statementOf "END" | _ => Left "END"
      SCommit <- statementOf "COMMIT TRANSACTION;" | _ => Left "COMMIT"
      SRollback <- statementOf "ROLLBACK" | _ => Left "ROLLBACK"
      SAnalyze <- statementOf "analyze;" | _ => Left "ANALYZE"
      pass
  , pureTest "shape: script splitting" $ do
      Right stmts <- pure (parseStatements ";;SELECT 1;; SELECT 2 ; -- trailing\n")
        | Left e => Left (show e)
      checkEq "statement count" (length stmts) 2
      Right none <- pure (parseStatements "  -- nothing here\n") | Left e => Left (show e)
      checkEq "empty script" (length none) 0
  , pureTest "shape: parameters restart in each statement" $ do
      Right [SSelect a, SSelect b] <- pure (parseStatements "SELECT ?, ?; SELECT ?")
        | _ => Left "expected two SELECTs"
      let indices : SelectStmt -> List Nat
          indices s = concatMap (\i => case i of
                                          SelExpr e _ => params e
                                          _ => []) s.items
      checkEq "first statement" (indices a) [0, 1]
      checkEq "second statement" (indices b) [0]
  ]

lexicalTests : List Test
lexicalTests =
  [ pureTest "tree: 1 + 2 * 3" $
      treeIs "1 + 2 * 3" (bin OAdd (num 1) (bin OMul (num 2) (num 3)))
  , pureTest "tree: a OR b AND NOT c" $
      treeIs "a OR b AND NOT c" (bin OOr (column "a") (bin OAnd (column "b") (ENot p0 (column "c"))))
  , pureTest "tree: BETWEEN and IN" $
      treeIs "x NOT BETWEEN 1 AND 2 AND y IN (3)"
             (bin OAnd (EBetween p0 True (column "x") (num 1) (num 2)) (EIn p0 False (column "y") [num 3]))
  , pureTest "tree: unary minus stays a node" $
      treeIs "-5" (ENeg p0 (num 5))
  , pureTest "tree: qualified column" $
      treeIs "u.name" (ECol p0 (Just "u") "name")
  , pureTest "tree: function names are upper-cased" $
      treeIs "sum(distinct x) + Count(*)"
             (bin OAdd (ECall p0 "SUM" True [column "x"]) (ECountStar p0))
  , pureTest "tree: CAST" $
      treeIs "cast(x as varchar(10))" (ECast p0 (column "x") TText)
  , pureTest "lexical: keywords are case-insensitive" $
      parses "sElEcT a FrOm t wHeRe a iS nOt NuLl"
  , pureTest "lexical: quoted identifiers" $ do
      treeIs "\"my col\"" (column "my col")
      treeIs "\"a\"\"b\"" (column "a\"b")
      treeIs "\"select\" + \"t\".\"from\"" (bin OAdd (column "select") (ECol p0 (Just "t") "from"))
  , pureTest "lexical: string escapes" $ do
      treeIs "'it''s'" (ELit p0 (LText "it's"))
      treeIs "''" (ELit p0 (LText ""))
      treeIs "''''" (ELit p0 (LText "'"))
      treeIs "'a\nb'" (ELit p0 (LText "a\nb"))
  , pureTest "lexical: blob literals" $ do
      treeIs "X'0AFF'" (ELit p0 (LBlob [10, 255]))
      treeIs "x'deadBEEF'" (ELit p0 (LBlob [222, 173, 190, 239]))
      treeIs "X''" (ELit p0 (LBlob []))
  , pureTest "lexical: numbers" $ do
      treeIs "9223372036854775808" (num 9223372036854775808)
      treeIs "007" (num 7)
      treeIs "1.5" (ELit p0 (LReal 1.5))
      treeIs ".5" (ELit p0 (LReal 0.5))
      treeIs "2." (ELit p0 (LReal 2.0))
      treeIs "1e3" (ELit p0 (LReal 1000.0))
      treeIs "2.5E-1" (ELit p0 (LReal 0.25))
      treeIs "1E+2" (ELit p0 (LReal 100.0))
  , pureTest "lexical: comments" $ do
      sameAs "1 -- one\n + 2" "1 + 2"
      sameAs "1 /* a\n ; b */ + 2" "1 + 2"
      sameAs "1 - -2" "1 - (-2)"
      parses "SELECT 1 -- trailing comment"
      parses "/* leading */ SELECT 1"
  , pureTest "lexical: literals TRUE, FALSE, NULL" $ do
      treeIs "true" (ELit p0 (LBool True))
      treeIs "False" (ELit p0 (LBool False))
      treeIs "null" (ELit p0 LNull)
  , pureTest "params: bare ? counts from 0" $ paramsOf "? + ? + ?" [0, 1, 2]
  , pureTest "params: ?N is index N-1" $ paramsOf "?3 + ?1" [2, 0]
  , pureTest "params: bare ? follows the largest index" $ paramsOf "?3 + ? + ?" [2, 3, 4]
  , pureTest "params: inside IN and calls" $ paramsOf "f(?, ?) IN (?, ?2)" [0, 1, 2, 1]
  ]

errorTests : List Test
errorTests =
  [ pureTest "error: missing select list" $ errorAt "SELECT FROM t" 1 8
  , pureTest "error: end of input after FROM" $ errorAt "SELECT a FROM" 1 14
  , pureTest "error: position on a later line" $ errorAt "SELECT a\nFROM t\nWHERE" 3 6
  , pureTest "error: unbalanced parenthesis" $ errorAt "SELECT (1 + 2 FROM t" 1 15
  , pureTest "error: unterminated string" $ errorAt "SELECT 'abc" 1 8
  , pureTest "error: unterminated quoted identifier" $ errorAt "SELECT \"abc" 1 8
  , pureTest "error: unterminated block comment" $ errorAt "SELECT 1 /* never closed" 1 10
  , pureTest "error: unexpected character" $ errorAt "SELECT 1 $ 2" 1 10
  , pureTest "error: unknown type" $ errorAt "CREATE TABLE t (a INTEGER,\n  b FOO)" 2 5
  , pureTest "error: VALUES without rows" $ errorAt "INSERT INTO t VALUES" 1 21
  , pureTest "error: not a statement" $ errorAt "SELEC 1" 1 1
  , pureTest "error: two statements where one is expected" $ errorAt "SELECT 1; SELECT 2" 1 11
  , pureTest "error: statement without separator" $ errorAt "SELECT 1 SELECT 2" 1 10
  , pureTest "error: empty input" $ errorAt "" 1 1
  , pureTest "error: comment only" $ errorAt "-- nothing\n" 2 1
  , pureTest "error: odd blob" $ errorAt "SELECT X'ABC'" 1 8
  , pureTest "error: malformed number" $ errorAt "SELECT 12abc" 1 8
  , pureTest "error: ?0" $ errorAt "SELECT ?0" 1 8
  , pureTest "error: reserved word as a column name" $ errorAt "CREATE TABLE t (select INTEGER)" 1 17
  , pureTest "error: table without columns" $ errorAt "CREATE TABLE t (PRIMARY KEY (a))" 1 1
  , pureTest "error: JOIN without ON" $ errorAt "SELECT * FROM a JOIN b WHERE 1" 1 24
  , pureTest "error: dangling NOT" $ errorAt "SELECT a NOT 1" 1 10
  , pureTest "error: * outside COUNT" $ errorAt "SELECT sum(*) FROM t" 1 12
  , pureTest "error: message names what was expected and found" $
      rejects "SELECT (1 + 2 FROM t" "expected ')' but found 'FROM'"
  , pureTest "error: message at end of input" $
      rejects "UPDATE t SET a =" "expected an expression but found end of input"
  , pureTest "error: expression parser rejects trailing tokens" $
      case parseExpr "1 + 2 3" of
        Left (SyntaxError p _) => checkEq "position" (p.line, p.col) (1, 7)
        _ => Left "expected a syntax error"
  ]

unsupported : List (String, String)
unsupported =
  [ ("SELECT * FROM (SELECT 1)", "subqueries are not supported")
  , ("SELECT (SELECT 1)", "subqueries are not supported")
  , ("SELECT * FROM t WHERE a IN (SELECT b FROM u)", "subqueries are not supported")
  , ("SELECT * FROM t WHERE EXISTS (SELECT 1)", "subqueries are not supported")
  , ("SELECT * FROM t WHERE NOT EXISTS (SELECT 1)", "subqueries are not supported")
  , ("SELECT 1 UNION SELECT 2", "UNION is not supported")
  , ("SELECT 1 INTERSECT SELECT 2", "INTERSECT is not supported")
  , ("SELECT a FROM t EXCEPT SELECT a FROM u", "EXCEPT is not supported")
  , ("ALTER TABLE t ADD COLUMN x INTEGER", "ALTER TABLE is not supported")
  , ("SAVEPOINT s", "savepoints are not supported")
  , ("RELEASE s", "savepoints are not supported")
  , ("ROLLBACK TO s", "savepoints are not supported")
  , ("SELECT * FROM a RIGHT JOIN b ON 1 = 1", "RIGHT JOIN is not supported")
  , ("SELECT * FROM a FULL OUTER JOIN b ON 1 = 1", "FULL JOIN is not supported")
  , ("SELECT sum(x) OVER (PARTITION BY y) FROM t", "window functions are not supported")
  , ("SELECT count(*) OVER w FROM t", "window functions are not supported")
  , ("CREATE INDEX i ON t (a DESC)", "ASC and DESC on index columns are not supported")
  , ("INSERT INTO t SELECT * FROM u", "INSERT ... SELECT is not supported")
  , ("SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t", "CASE expressions are not supported")
  , ("CREATE TABLE t (a INTEGER REFERENCES u (id) ON DELETE CASCADE)", "referential actions")
  ]

completeCases : List (String, Bool)
completeCases =
  [ ("SELECT 1;", True)
  , ("SELECT 1", False)
  , ("", False)
  , (";", False)
  , ("  ;  ", False)
  , ("; SELECT 1;", True)
  , ("SELECT 1; SELECT 2", True)
  , ("SELECT ';'", False)
  , ("SELECT ';';", True)
  , ("SELECT 'it''s;' ", False)
  , ("SELECT 'a''b';", True)
  , ("SELECT \";\" FROM t", False)
  , ("SELECT \";\" FROM t;", True)
  , ("SELECT 1 -- ;", False)
  , ("SELECT 1 -- ;\n;", True)
  , ("SELECT 1 /* ; */", False)
  , ("SELECT 1 /* ; */ ;", True)
  , ("-- only a comment;\n", False)
  , ("/* ; */ ;", False)
  , ("SELECT 'unterminated;", False)
  , ("SELECT 1 /* unterminated ;", False)
  , ("CREATE TABLE t (\n  a INTEGER\n", False)
  , ("CREATE TABLE t (\n  a INTEGER\n);", True)
  ]

export
sqlFrontendTests : List Test
sqlFrontendTests =
  map (\(a, b) => pureTest ("precedence: " ++ a) (sameAs a b)) precedencePairs
    ++ map (\s => pureTest ("round trip: " ++ s) (roundTrip s)) roundTripInputs
    ++ map (\s => pureTest ("parses: " ++ s) (parses s)) statementForms
    ++ shapeTests
    ++ lexicalTests
    ++ errorTests
    ++ map (\(s, needle) => pureTest ("unsupported: " ++ s) (rejects s needle)) unsupported
    ++ map (\(s, want) => pureTest ("statementComplete: " ++ show s)
                                   (checkEq "result" (statementComplete s) want)) completeCases
