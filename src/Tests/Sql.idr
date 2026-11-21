module Tests.Sql

import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.String
import IdrisQL
import IdrisQL.Engine
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Pager
import Tests.Harness

-- SQL-level tests against the engine. Each test gets a fresh database and
-- ends with an integrity check, so a statement that returns the right rows
-- while damaging a tree still fails.

render : List Value -> String
render = concat . intersperse "|" . map renderValue

drain : DB (Maybe (List Value)) -> List String -> DB (List String)
drain source acc = do
  Just row <- source | Nothing => pure (reverse acc)
  drain source (render row :: acc)

rowsOf : Engine -> String -> DB (List String)
rowsOf eng sql = do
  Rows _ _ source <- execute eng sql [] | _ => pure []
  drain source []

exec : Engine -> String -> DB ()
exec eng sql = ignore (execute eng sql [])

execAll : Engine -> List String -> DB ()
execAll eng = traverse_ (exec eng)

changedBy : Engine -> String -> DB Nat
changedBy eng sql = do
  Changed n <- execute eng sql [] | _ => failWith ("no change count from: " ++ sql)
  pure n

expectRows : Engine -> String -> List String -> DB ()
expectRows eng sql want = do
  got <- rowsOf eng sql
  expect (got == want) (sql ++ "\n      expected " ++ show want ++ "\n      got      " ++ show got)

isSemantic : DbError -> Bool
isSemantic (SemanticError _) = True
isSemantic _ = False

isConstraint : DbError -> Bool
isConstraint (ConstraintViolation _) = True
isConstraint _ = False

isRuntime : DbError -> Bool
isRuntime (RuntimeError _) = True
isRuntime _ = False

isIO : DbError -> Bool
isIO (IOFailure _) = True
isIO _ = False

isTx : DbError -> Bool
isTx (TxError _) = True
isTx _ = False

-- A query's runtime errors surface when its rows are read, so read them.
rejects : Engine -> String -> (DbError -> Bool) -> DB ()
rejects eng sql judge = expectError sql (rowsOf eng sql) judge

-- Every structure on disk is sound and no page was left pinned.
checked : Engine -> DB ()
checked eng = do
  problems <- integrityCheck eng
  expect (isNil problems) ("integrity check: " ++ show problems)
  pinned <- pinnedFrames (pagerPool (enginePager eng))
  expect (pinned == 0) (show pinned ++ " pages are still pinned")

||| A 32-page pool and 200-row sort runs, so ordinary tests exercise
||| eviction and the external sort.
small : Options
small = MkOptions 32 4194304 False 200

sqlTest : String -> (Engine -> DB ()) -> Test
sqlTest name body = dbTest name $ do
  path <- liftIO (freshPath ("sql-" ++ pack (map (\c => if isAlphaNum c then c else '-') (unpack name)) ++ ".idb"))
  eng <- openEngine path small
  finally (body eng >> checked eng) (closeEngine eng)

people : List String
people =
  [ "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, city TEXT)"
  , "INSERT INTO person VALUES (1, 'Ada', 36, 'London'), (2, 'Brook', 28, 'Leeds'), (3, 'Cy', NULL, 'London'), (4, 'Dee', 41, NULL), (5, 'Eli', 28, 'Leeds')"
  ]

shop : List String
shop =
  [ "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, age INTEGER CHECK (age >= 0))"
  , "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, total REAL NOT NULL)"
  , "CREATE INDEX idx_orders_user ON orders(user_id)"
  , "INSERT INTO users VALUES (1, 'Alice', 'alice@example.com', 27), (2, 'Bob', 'bob@example.com', 31), (3, 'Cat', 'cat@example.com', NULL)"
  , "INSERT INTO orders VALUES (100, 1, 149.99), (101, 1, 89.50), (102, 2, 250.00)"
  ]

basicTests : List Test
basicTests =
  [ sqlTest "insert, select, update, delete" $ \eng => do
      execAll eng people
      expectRows eng "SELECT name, age FROM person WHERE id = 2" ["Brook|28"]
      n <- changedBy eng "UPDATE person SET age = age + 1 WHERE city = 'Leeds'"
      expect (n == 2) ("UPDATE changed " ++ show n)
      expectRows eng "SELECT id, age FROM person ORDER BY id" ["1|36", "2|29", "3|NULL", "4|41", "5|29"]
      d <- changedBy eng "DELETE FROM person WHERE age IS NULL OR age > 40"
      expect (d == 2) ("DELETE removed " ++ show d)
      expectRows eng "SELECT COUNT(*) FROM person" ["3"]
      all <- changedBy eng "DELETE FROM person"
      expect (all == 3) ("unqualified DELETE removed " ++ show all)
      expectRows eng "SELECT COUNT(*) FROM person" ["0"]

  , sqlTest "every type round-trips, also across a restart of the tree" $ \eng => do
      exec eng "CREATE TABLE v (i INTEGER, r REAL, t TEXT, b BLOB, f BOOLEAN)"
      exec eng "INSERT INTO v VALUES (9223372036854775807, 1.5, 'it''s \"quoted\"', X'00FF10', TRUE)"
      exec eng "INSERT INTO v VALUES (-9223372036854775808, -0.25, '', X'', FALSE)"
      exec eng "INSERT INTO v VALUES (NULL, NULL, NULL, NULL, NULL)"
      expectRows eng "SELECT * FROM v"
        [ "9223372036854775807|1.5|it's \"quoted\"|X'00FF10'|TRUE"
        , "-9223372036854775808|-0.25||X''|FALSE"
        , "NULL|NULL|NULL|NULL|NULL" ]
      expectRows eng "SELECT i FROM v WHERE f" ["9223372036854775807"]
      expectRows eng "SELECT COUNT(*) FROM v WHERE b = X'00FF10'" ["1"]

  , sqlTest "SELECT without FROM evaluates expressions" $ \eng => do
      expectRows eng "SELECT 1 + 2 * 3, (1 + 2) * 3, 7 / 2, -7 / 2, 7 % 3, -7 % 3" ["7|9|3|-3|1|-1"]
      expectRows eng "SELECT 1.5 + 1, 10 / 4.0, 'a' || 'b' || 'c'" ["2.5|2.5|abc"]
      expectRows eng "SELECT 1 / 0, 1.0 / 0, 5 % 0" ["NULL|NULL|NULL"]
      expectRows eng "SELECT LENGTH('h\233llo'), UPPER('abc'), LOWER('ABC'), ABS(-4), ABS(-2.5)" ["5|ABC|abc|4|2.5"]
      expectRows eng "SELECT COALESCE(NULL, NULL, 3), COALESCE(NULL, 'x')" ["3|x"]
      expectRows eng "SELECT CAST('42' AS INTEGER), CAST(3.9 AS INTEGER), CAST(-3.9 AS INTEGER), CAST(7 AS TEXT), CAST(2 AS REAL)"
        ["42|3|-3|7|2.0"]
      expectRows eng "SELECT 2 BETWEEN 1 AND 3, 5 NOT BETWEEN 1 AND 3, 2 IN (1, 2), 4 NOT IN (1, 2)" ["TRUE|TRUE|TRUE|TRUE"]
      expectRows eng "SELECT 'Hello' LIKE 'h%o', 'Hello' LIKE 'h_llo', 'Hello' LIKE 'h_o', 'abc' NOT LIKE '%d'" ["TRUE|TRUE|FALSE|TRUE"]

  , sqlTest "integer overflow is an error, not a wrong answer" $ \eng => do
      rejects eng "SELECT 9223372036854775807 + 1" isRuntime
      rejects eng "SELECT -9223372036854775808 - 1" isRuntime
      rejects eng "SELECT 4611686018427387904 * 2" isRuntime
      rejects eng "SELECT - (-9223372036854775808)" isRuntime
      rejects eng "SELECT 9223372036854775808" isSemantic
      rejects eng "SELECT CAST('twelve' AS INTEGER)" isRuntime
      expectRows eng "SELECT 9223372036854775807 + 0, -9223372036854775808" ["9223372036854775807|-9223372036854775808"]

  , sqlTest "three-valued logic" $ \eng => do
      expectRows eng "SELECT NULL = NULL, NULL <> 1, NOT NULL = 1, NULL IS NULL, 1 IS NOT NULL" ["NULL|NULL|NULL|TRUE|TRUE"]
      expectRows eng "SELECT NULL AND FALSE, NULL AND TRUE, NULL OR TRUE, NULL OR FALSE" ["FALSE|NULL|TRUE|NULL"]
      expectRows eng "SELECT 1 IN (2, NULL), 1 IN (1, NULL), 1 NOT IN (2, NULL), NULL IN (1)" ["NULL|TRUE|NULL|NULL"]
      expectRows eng "SELECT NULL + 1, NULL || 'a', NULL LIKE 'a', LENGTH(NULL)" ["NULL|NULL|NULL|NULL"]
      execAll eng people
      -- A row whose predicate is UNKNOWN is not selected, by = or by <>.
      expectRows eng "SELECT COUNT(*) FROM person WHERE age = NULL" ["0"]
      expectRows eng "SELECT COUNT(*) FROM person WHERE age <> 28" ["2"]
      expectRows eng "SELECT COUNT(*) FROM person WHERE NOT (age = 28)" ["2"]
      expectRows eng "SELECT COUNT(*) FROM person WHERE age = 28 OR age <> 28" ["4"]
      expectRows eng "SELECT name FROM person WHERE age IS NULL" ["Cy"]
      expectRows eng "SELECT name FROM person WHERE city IS NOT NULL AND age IS NULL" ["Cy"]

  , sqlTest "names are case-insensitive and quoting preserves odd names" $ \eng => do
      exec eng "CREATE TABLE \"Odd Name\" (\"select\" INTEGER, \"a \"\"b\" TEXT)"
      exec eng "INSERT INTO \"odd name\" VALUES (1, 'x')"
      expectRows eng "SELECT \"SELECT\", \"a \"\"b\" FROM \"ODD NAME\"" ["1|x"]
      execAll eng people
      expectRows eng "select NAME from PERSON where ID = 1" ["Ada"]

  , sqlTest "statements that cannot be right are rejected before running" $ \eng => do
      execAll eng people
      rejects eng "SELECT * FROM nowhere" isSemantic
      rejects eng "SELECT height FROM person" isSemantic
      rejects eng "SELECT person.name, p.name FROM person" isSemantic
      rejects eng "SELECT id FROM person AS a JOIN person AS b ON a.id = b.id" isSemantic
      rejects eng "SELECT name + 1 FROM person" isSemantic
      rejects eng "SELECT * FROM person WHERE name" isSemantic
      rejects eng "SELECT * FROM person WHERE COUNT(*) > 1" isSemantic
      rejects eng "SELECT name, COUNT(*) FROM person" isSemantic
      rejects eng "SELECT city, name FROM person GROUP BY city" isSemantic
      rejects eng "SELECT * FROM person HAVING id > 1" isSemantic
      rejects eng "SELECT NOSUCH(name) FROM person" isSemantic
      rejects eng "SELECT LENGTH(name, name) FROM person" isSemantic
      rejects eng "INSERT INTO person VALUES (9, 'x')" isSemantic
      rejects eng "INSERT INTO person (id, nope) VALUES (9, 'x')" isSemantic
      rejects eng "INSERT INTO person (id, id) VALUES (9, 9)" isSemantic
      rejects eng "INSERT INTO person VALUES ('nine', 'x', 1, 'y')" isSemantic
      rejects eng "UPDATE person SET nope = 1" isSemantic
      rejects eng "UPDATE person SET age = 'old'" isSemantic
      rejects eng "CREATE TABLE person (id INTEGER)" isSemantic
      rejects eng "CREATE TABLE t (a INTEGER, A TEXT)" isSemantic
      rejects eng "CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT PRIMARY KEY)" isSemantic
      rejects eng "CREATE TABLE t (a INTEGER DEFAULT 'x')" isSemantic
      rejects eng "CREATE TABLE t (a INTEGER CHECK (b > 0))" isSemantic
      rejects eng "CREATE INDEX i ON person (nope)" isSemantic
      rejects eng "DROP TABLE nowhere" isSemantic
      rejects eng "DROP INDEX nowhere" isSemantic
      rejects eng "SELECT ?" isSemantic
      exec eng "DROP TABLE IF EXISTS nowhere"
      exec eng "CREATE TABLE IF NOT EXISTS person (x INTEGER)"
      expectRows eng "SELECT COUNT(*) FROM person" ["5"]
  ]

constraintTests : List Test
constraintTests =
  [ sqlTest "NOT NULL, UNIQUE, CHECK and DEFAULT are enforced on insert" $ \eng => do
      exec eng "CREATE TABLE acct (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, balance INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0), note TEXT DEFAULT 'none')"
      exec eng "INSERT INTO acct (email) VALUES ('a@x')"
      expectRows eng "SELECT * FROM acct" ["1|a@x|0|none"]
      rejects eng "INSERT INTO acct (email) VALUES ('a@x')" isConstraint
      rejects eng "INSERT INTO acct (email) VALUES (NULL)" isConstraint
      rejects eng "INSERT INTO acct (email, balance) VALUES ('b@x', -1)" isConstraint
      rejects eng "INSERT INTO acct (id, email) VALUES (1, 'c@x')" isConstraint
      expectRows eng "SELECT COUNT(*) FROM acct" ["1"]

  , sqlTest "a failing multi-row insert inserts nothing" $ \eng => do
      exec eng "CREATE TABLE u (id INTEGER PRIMARY KEY, code TEXT UNIQUE)"
      exec eng "INSERT INTO u VALUES (1, 'a')"
      rejects eng "INSERT INTO u VALUES (2, 'b'), (3, 'c'), (4, 'a')" isConstraint
      expectRows eng "SELECT id FROM u ORDER BY id" ["1"]
      exec eng "INSERT INTO u VALUES (2, 'b')"
      expectRows eng "SELECT COUNT(*) FROM u" ["2"]

  , sqlTest "constraints are enforced on update" $ \eng => do
      exec eng "CREATE TABLE acct (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, balance INTEGER CHECK (balance >= 0))"
      exec eng "INSERT INTO acct VALUES (1, 'a@x', 10), (2, 'b@x', 20)"
      rejects eng "UPDATE acct SET email = 'a@x' WHERE id = 2" isConstraint
      rejects eng "UPDATE acct SET balance = balance - 50" isConstraint
      rejects eng "UPDATE acct SET email = NULL WHERE id = 1" isConstraint
      rejects eng "UPDATE acct SET id = 2 WHERE id = 1" isConstraint
      expectRows eng "SELECT * FROM acct ORDER BY id" ["1|a@x|10", "2|b@x|20"]
      -- Assigning a row its own unique value is not a conflict.
      exec eng "UPDATE acct SET email = 'a@x', balance = 11 WHERE id = 1"
      exec eng "UPDATE acct SET id = 7 WHERE id = 1"
      expectRows eng "SELECT * FROM acct ORDER BY id" ["2|b@x|20", "7|a@x|11"]
      expectRows eng "SELECT id FROM acct WHERE email = 'a@x'" ["7"]

  , sqlTest "a UNIQUE column accepts any number of NULLs" $ \eng => do
      exec eng "CREATE TABLE u (id INTEGER PRIMARY KEY, code TEXT UNIQUE)"
      exec eng "INSERT INTO u (code) VALUES (NULL), (NULL), ('x')"
      rejects eng "INSERT INTO u (code) VALUES ('x')" isConstraint
      expectRows eng "SELECT COUNT(*), COUNT(code) FROM u" ["3|1"]

  , sqlTest "a CHECK that evaluates to NULL passes" $ \eng => do
      exec eng "CREATE TABLE c (n INTEGER CHECK (n > 0))"
      exec eng "INSERT INTO c VALUES (NULL), (5)"
      rejects eng "INSERT INTO c VALUES (0)" isConstraint
      expectRows eng "SELECT COUNT(*) FROM c" ["2"]

  , sqlTest "composite and non-integer primary keys" $ \eng => do
      exec eng "CREATE TABLE pair (a INTEGER, b TEXT, v INTEGER, PRIMARY KEY (a, b))"
      exec eng "INSERT INTO pair VALUES (1, 'x', 10), (1, 'y', 11), (2, 'x', 12)"
      rejects eng "INSERT INTO pair VALUES (1, 'x', 99)" isConstraint
      rejects eng "INSERT INTO pair VALUES (NULL, 'z', 1)" isConstraint
      exec eng "CREATE TABLE tag (name TEXT PRIMARY KEY, n INTEGER)"
      exec eng "INSERT INTO tag VALUES ('a', 1), ('b', 2)"
      rejects eng "INSERT INTO tag VALUES ('a', 3)" isConstraint
      expectRows eng "EXPLAIN QUERY PLAN SELECT n FROM tag WHERE name = 'b'"
        ["PROJECT tag.n", "  FILTER tag.name = 'b'", "    SEARCH tag USING INDEX tag_pkey (name = 'b')"]
      expectRows eng "SELECT n FROM tag WHERE name = 'b'" ["2"]
      rejects eng "DROP INDEX tag_pkey" isSemantic

  , sqlTest "constraints whose generated index names collide are both enforced" $ \eng => do
      exec eng "CREATE TABLE t (a INTEGER, b INTEGER, a_b INTEGER UNIQUE, UNIQUE (a, b))"
      exec eng "INSERT INTO t VALUES (1, 1, 10), (1, 2, 20)"
      rejects eng "INSERT INTO t VALUES (2, 2, 10)" isConstraint
      rejects eng "INSERT INTO t VALUES (1, 2, 30)" isConstraint
      schema <- liftIO (currentSchema eng)
      expect (length (tableIndexes schema "t") == 2) "one of the two unique indexes is missing"

  , sqlTest "NaN in a bound parameter is stored as NULL" $ \eng => do
      exec eng "CREATE TABLE f (id INTEGER PRIMARY KEY, x REAL)"
      exec eng "CREATE INDEX f_x ON f (x)"
      _ <- execute eng "INSERT INTO f VALUES (1, ?)" [VReal (0.0 / 0.0)]
      expectRows eng "SELECT COUNT(*) FROM f WHERE x IS NULL" ["1"]

  , sqlTest "rowids: assigned, explicit, and never reused within a table" $ \eng => do
      exec eng "CREATE TABLE r (id INTEGER PRIMARY KEY, v TEXT)"
      exec eng "INSERT INTO r (v) VALUES ('a'), ('b')"
      exec eng "INSERT INTO r VALUES (10, 'c'), (NULL, 'd')"
      exec eng "INSERT INTO r VALUES (-5, 'e')"
      exec eng "INSERT INTO r (v) VALUES ('f')"
      expectRows eng "SELECT id, v FROM r ORDER BY id" ["-5|e", "1|a", "2|b", "10|c", "11|d", "12|f"]
      exec eng "CREATE TABLE plain (v TEXT)"
      exec eng "INSERT INTO plain VALUES ('x'), ('y')"
      expectRows eng "SELECT COUNT(*) FROM plain" ["2"]
      -- The next rowid is one more than the largest present, also after the
      -- largest row is deleted or renumbered.
      exec eng "DELETE FROM r WHERE id = 12"
      exec eng "INSERT INTO r (v) VALUES ('g')"
      expectRows eng "SELECT id FROM r WHERE v = 'g'" ["12"]
      exec eng "UPDATE r SET id = 5 WHERE id = 12"
      exec eng "INSERT INTO r (v) VALUES ('h')"
      expectRows eng "SELECT id FROM r WHERE v = 'h'" ["12"]
      exec eng "BEGIN"
      exec eng "INSERT INTO r (v) VALUES ('i')"
      exec eng "ROLLBACK"
      exec eng "INSERT INTO r (v) VALUES ('j')"
      expectRows eng "SELECT id FROM r WHERE v = 'j'" ["13"]

  , sqlTest "foreign keys are recorded and shown, not enforced" $ \eng => do
      exec eng "CREATE TABLE parent (id INTEGER PRIMARY KEY)"
      exec eng "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))"
      exec eng "INSERT INTO child VALUES (1, 999)"
      schema <- liftIO (currentSchema eng)
      case findTable schema "child" of
        Just t => expect (length t.foreignKeys == 1) "the foreign key was not recorded"
        Nothing => failWith "table child is missing"
  ]

queryTests : List Test
queryTests =
  [ sqlTest "inner, left and cross joins" $ \eng => do
      execAll eng shop
      expectRows eng "SELECT u.name, o.id FROM users AS u INNER JOIN orders AS o ON u.id = o.user_id ORDER BY o.id"
        ["Alice|100", "Alice|101", "Bob|102"]
      expectRows eng "SELECT u.name, o.id FROM users u LEFT JOIN orders o ON u.id = o.user_id ORDER BY u.id, o.id"
        ["Alice|100", "Alice|101", "Bob|102", "Cat|NULL"]
      expectRows eng "SELECT u.name FROM users u LEFT JOIN orders o ON u.id = o.user_id WHERE o.id IS NULL" ["Cat"]
      expectRows eng "SELECT u.name FROM users u LEFT JOIN orders o ON u.id = o.user_id AND o.total > 200 ORDER BY u.id"
        ["Alice", "Bob", "Cat"]
      expectRows eng "SELECT COUNT(*) FROM users CROSS JOIN orders" ["9"]
      expectRows eng "SELECT COUNT(*) FROM users, orders WHERE users.id = orders.user_id" ["3"]
      expectRows eng "SELECT a.name, b.name FROM users a JOIN users b ON a.id < b.id ORDER BY a.id, b.id"
        ["Alice|Bob", "Alice|Cat", "Bob|Cat"]

  , sqlTest "three-table join" $ \eng => do
      execAll eng shop
      exec eng "CREATE TABLE item (order_id INTEGER, sku TEXT)"
      exec eng "INSERT INTO item VALUES (100, 'kettle'), (100, 'cup'), (102, 'lamp')"
      expectRows eng "SELECT u.name, o.id, i.sku FROM users u JOIN orders o ON o.user_id = u.id JOIN item i ON i.order_id = o.id ORDER BY i.sku"
        ["Alice|100|cup", "Alice|100|kettle", "Bob|102|lamp"]

  , sqlTest "the required demonstration query" $ \eng => do
      execAll eng shop
      expectRows eng
        "SELECT u.name, COUNT(o.id) AS order_count, SUM(o.total) AS lifetime_value FROM users AS u INNER JOIN orders AS o ON u.id = o.user_id GROUP BY u.id, u.name HAVING COUNT(o.id) > 0 ORDER BY lifetime_value DESC"
        ["Bob|1|250.0", "Alice|2|239.49"]

  , sqlTest "aggregates" $ \eng => do
      execAll eng people
      expectRows eng "SELECT COUNT(*), COUNT(age), COUNT(DISTINCT age), SUM(age), MIN(age), MAX(age) FROM person" ["5|4|3|133|28|41"]
      expectRows eng "SELECT AVG(age) FROM person" ["33.25"]
      expectRows eng "SELECT city, COUNT(*), SUM(age) FROM person GROUP BY city ORDER BY city"
        ["NULL|1|41", "Leeds|2|56", "London|2|36"]
      expectRows eng "SELECT city, COUNT(*) AS n FROM person GROUP BY city HAVING COUNT(*) > 1 ORDER BY n DESC, city"
        ["Leeds|2", "London|2"]
      expectRows eng "SELECT age % 2, COUNT(*) FROM person WHERE age IS NOT NULL GROUP BY age % 2 ORDER BY 1" ["0|3", "1|1"]
      expectRows eng "SELECT MIN(name), MAX(name) FROM person" ["Ada|Eli"]
      expectRows eng "SELECT COUNT(*) + 1, MAX(age) - MIN(age) FROM person" ["6|13"]

  , sqlTest "aggregates over no rows" $ \eng => do
      exec eng "CREATE TABLE e (n INTEGER)"
      expectRows eng "SELECT COUNT(*), COUNT(n), SUM(n), AVG(n), MIN(n), MAX(n) FROM e" ["0|0|NULL|NULL|NULL|NULL"]
      expectRows eng "SELECT n, COUNT(*) FROM e GROUP BY n" []
      rejects eng "INSERT INTO e VALUES (9223372036854775807), (1); SELECT 1" (\_ => True)
      exec eng "INSERT INTO e VALUES (9223372036854775807), (1)"
      rejects eng "SELECT SUM(n) FROM e" isRuntime

  , sqlTest "ORDER BY, LIMIT, OFFSET and DISTINCT" $ \eng => do
      execAll eng people
      expectRows eng "SELECT name FROM person ORDER BY age DESC, name" ["Dee", "Ada", "Brook", "Eli", "Cy"]
      expectRows eng "SELECT name FROM person ORDER BY age, name" ["Cy", "Brook", "Eli", "Ada", "Dee"]
      expectRows eng "SELECT name, age * 2 AS double FROM person WHERE age IS NOT NULL ORDER BY double DESC LIMIT 2" ["Dee|82", "Ada|72"]
      expectRows eng "SELECT name FROM person ORDER BY 1 DESC LIMIT 2 OFFSET 1" ["Dee", "Cy"]
      expectRows eng "SELECT name FROM person ORDER BY LENGTH(name) DESC, name LIMIT 1" ["Brook"]
      expectRows eng "SELECT name FROM person ORDER BY id LIMIT 0" []
      expectRows eng "SELECT name FROM person ORDER BY id LIMIT 2 OFFSET 4" ["Eli"]
      expectRows eng "SELECT name FROM person ORDER BY id LIMIT -1 OFFSET 3" ["Dee", "Eli"]
      expectRows eng "SELECT DISTINCT age FROM person ORDER BY age" ["NULL", "28", "36", "41"]
      expectRows eng "SELECT DISTINCT city, age FROM person WHERE age = 28" ["Leeds|28"]
      rejects eng "SELECT DISTINCT city FROM person ORDER BY age" isSemantic
      rejects eng "SELECT name FROM person ORDER BY 9" isSemantic

  , sqlTest "a sort larger than its memory limit spills to disk and stays correct" $ \eng => do
      exec eng "CREATE TABLE n (id INTEGER PRIMARY KEY, k INTEGER, pad TEXT)"
      exec eng "BEGIN"
      for_ (the (List Int) [1 .. 3000]) $ \i =>
        exec eng ("INSERT INTO n VALUES (" ++ show i ++ ", " ++ show ((i * 7919) `mod` 3001) ++ ", 'row " ++ show i ++ "')")
      exec eng "COMMIT"
      got <- rowsOf eng "SELECT k FROM n ORDER BY k DESC"
      expect (got == map show (reverse (sort (map (\i => (i * 7919) `mod` 3001) (the (List Int) [1 .. 3000])))))
        "rows came back in the wrong order"
      runs <- liftIO (sortRunsWritten eng)
      expect (runs > 1) ("expected several sort runs on disk, saw " ++ show runs)
      expectRows eng "SELECT COUNT(DISTINCT k), COUNT(*) FROM n" ["3000|3000"]
      groups <- rowsOf eng "SELECT k % 10, COUNT(*) FROM n GROUP BY k % 10 ORDER BY 1"
      expect (length groups == 10) ("grouping through a spilled sort gave " ++ show (length groups) ++ " groups")
  ]

indexTests : List Test
indexTests =
  [ sqlTest "the planner reports the access path it uses" $ \eng => do
      execAll eng shop
      expectRows eng "EXPLAIN QUERY PLAN SELECT * FROM orders WHERE user_id = 1"
        [ "PROJECT orders.id, orders.user_id, orders.total"
        , "  FILTER orders.user_id = 1"
        , "    SEARCH orders USING INDEX idx_orders_user (user_id = 1)" ]
      expectRows eng "EXPLAIN QUERY PLAN SELECT name FROM users WHERE id = 42"
        ["PROJECT users.name", "  FILTER users.id = 42", "    SEARCH users USING ROWID (id = 42)"]
      expectRows eng "EXPLAIN QUERY PLAN SELECT name FROM users WHERE id > 1 AND id <= 3"
        [ "PROJECT users.name", "  FILTER (users.id > 1 AND users.id <= 3)"
        , "    SEARCH users USING ROWID (id > 1 AND id <= 3)" ]
      expectRows eng "EXPLAIN QUERY PLAN SELECT * FROM orders WHERE total > 100"
        ["PROJECT orders.id, orders.user_id, orders.total", "  FILTER orders.total > 100.0", "    SCAN orders"]
      expectRows eng "EXPLAIN QUERY PLAN SELECT name FROM users WHERE email = 'bob@example.com'"
        [ "PROJECT users.name", "  FILTER users.email = 'bob@example.com'"
        , "    SEARCH users USING INDEX users_email_key (email = 'bob@example.com')" ]
      exec eng "DROP INDEX idx_orders_user"
      expectRows eng "EXPLAIN QUERY PLAN SELECT * FROM orders WHERE user_id = 1"
        ["PROJECT orders.id, orders.user_id, orders.total", "  FILTER orders.user_id = 1", "    SCAN orders"]

  , sqlTest "joins use an index on the inner table, in either join order" $ \eng => do
      execAll eng shop
      -- An inner join may swap its sides: searching users by rowid costs
      -- less than searching orders through its index and then fetching rows.
      expectRows eng "EXPLAIN QUERY PLAN SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id"
        [ "PROJECT u.name, o.total"
        , "  INDEX JOIN ON u.id = o.user_id"
        , "    SCAN o"
        , "    SEARCH u USING ROWID (id = o.user_id)" ]
      -- A left join cannot swap, so it searches orders through the index.
      expectRows eng "EXPLAIN QUERY PLAN SELECT u.name, o.total FROM users u LEFT JOIN orders o ON u.id = o.user_id"
        [ "PROJECT u.name, o.total"
        , "  INDEX LEFT JOIN ON u.id = o.user_id"
        , "    SCAN u"
        , "    SEARCH o USING INDEX idx_orders_user (user_id = u.id)" ]
      expectRows eng "SELECT u.name, o.total FROM orders o JOIN users u ON u.id = o.user_id ORDER BY o.id"
        ["Alice|149.99", "Alice|89.5", "Bob|250.0"]
      expectRows eng "SELECT u.name, o.total FROM users u LEFT JOIN orders o ON u.id = o.user_id ORDER BY u.id, o.id"
        ["Alice|149.99", "Alice|89.5", "Bob|250.0", "Cat|NULL"]
      exec eng "DROP INDEX idx_orders_user"
      expectRows eng "SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id ORDER BY o.id"
        ["Alice|149.99", "Alice|89.5", "Bob|250.0"]

  , sqlTest "queries return the same rows with and without an index" $ \eng => do
      exec eng "CREATE TABLE m (id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c REAL)"
      exec eng "BEGIN"
      for_ (the (List Int) [1 .. 600]) $ \i =>
        exec eng ("INSERT INTO m VALUES (" ++ show i ++ ", " ++ (if i `mod` 17 == 0 then "NULL" else show (i `mod` 23))
                  ++ ", 'b" ++ show (i `mod` 7) ++ "', " ++ show (i `mod` 11) ++ ".5)")
      exec eng "COMMIT"
      let queries =
            [ "SELECT id FROM m WHERE a = 5 ORDER BY id"
            , "SELECT id FROM m WHERE a = 5 AND b = 'b3' ORDER BY id"
            , "SELECT id FROM m WHERE a > 20 ORDER BY id"
            , "SELECT id FROM m WHERE a >= 20 AND a < 22 ORDER BY id"
            , "SELECT id FROM m WHERE a < 2 ORDER BY id"
            , "SELECT id FROM m WHERE a <= 0 ORDER BY id"
            , "SELECT id FROM m WHERE a IS NULL ORDER BY id"
            , "SELECT id FROM m WHERE a = 5 AND c > 4.0 ORDER BY id"
            , "SELECT id FROM m WHERE b = 'b3' AND a BETWEEN 3 AND 9 ORDER BY id"
            , "SELECT a, COUNT(*) FROM m GROUP BY a ORDER BY a"
            , "SELECT id FROM m WHERE a = NULL"
            , "SELECT id FROM m WHERE 7 = a ORDER BY id"
            , "SELECT id FROM m WHERE 10 > a ORDER BY id"
            , "SELECT id FROM m ORDER BY a, id LIMIT 7" ]
      before <- traverse (rowsOf eng) queries
      exec eng "CREATE INDEX m_a ON m (a)"
      exec eng "CREATE INDEX m_ab ON m (a, b)"
      exec eng "CREATE INDEX m_b_c ON m (b, c)"
      after <- traverse (rowsOf eng) queries
      for_ (zip queries (zip before after)) $ \(q, (x, y)) =>
        expect (x == y) ("results changed after indexing: " ++ q)
      plan <- rowsOf eng "EXPLAIN QUERY PLAN SELECT id FROM m WHERE a = 5 AND b = 'b3' ORDER BY id"
      expect (any (isInfixOf "USING INDEX m_ab (a = 5 AND b = 'b3')") plan) ("composite index not used: " ++ show plan)
      exec eng "ANALYZE"
      analyzed <- traverse (rowsOf eng) queries
      expect (analyzed == before) "results changed after ANALYZE"

  , sqlTest "a unique index is refused when the data has duplicates" $ \eng => do
      exec eng "CREATE TABLE d (k INTEGER)"
      exec eng "INSERT INTO d VALUES (1), (2), (2)"
      rejects eng "CREATE UNIQUE INDEX d_k ON d (k)" isConstraint
      expectRows eng "SELECT COUNT(*) FROM d" ["3"]
      exec eng "DELETE FROM d WHERE k = 2"
      exec eng "CREATE UNIQUE INDEX d_k ON d (k)"
      rejects eng "INSERT INTO d VALUES (1)" isConstraint

  , sqlTest "ordered output can come straight from an index" $ \eng => do
      exec eng "CREATE TABLE s (id INTEGER PRIMARY KEY, k INTEGER)"
      exec eng "INSERT INTO s VALUES (1, 30), (2, 10), (3, 20), (4, NULL)"
      exec eng "CREATE INDEX s_k ON s (k)"
      expectRows eng "EXPLAIN QUERY PLAN SELECT id FROM s ORDER BY id" ["PROJECT s.id", "  SCAN s"]
      expectRows eng "EXPLAIN QUERY PLAN SELECT k FROM s ORDER BY k LIMIT 2"
        ["LIMIT 2", "  PROJECT s.k", "    SCAN s USING INDEX s_k (in index order)"]
      expectRows eng "SELECT k FROM s ORDER BY k LIMIT 3" ["NULL", "10", "20"]
      expectRows eng "SELECT k FROM s WHERE k > 5 ORDER BY k" ["10", "20", "30"]

  , sqlTest "indexes follow updates and deletes" $ \eng => do
      execAll eng shop
      exec eng "UPDATE orders SET user_id = 2 WHERE id = 100"
      expectRows eng "SELECT id FROM orders WHERE user_id = 2 ORDER BY id" ["100", "102"]
      expectRows eng "SELECT id FROM orders WHERE user_id = 1" ["101"]
      exec eng "DELETE FROM orders WHERE user_id = 2"
      expectRows eng "SELECT id FROM orders WHERE user_id = 2" []
      exec eng "DROP TABLE orders"
      rejects eng "SELECT * FROM orders" isSemantic
      schema <- liftIO (currentSchema eng)
      expect (isNothing (findIndex schema "idx_orders_user")) "the index outlived its table"
  ]

txnTests : List Test
txnTests =
  [ sqlTest "commit keeps and rollback discards" $ \eng => do
      execAll eng shop
      exec eng "BEGIN"
      exec eng "UPDATE users SET age = 28 WHERE id = 1"
      expectRows eng "SELECT age FROM users WHERE id = 1" ["28"]
      exec eng "ROLLBACK"
      expectRows eng "SELECT age FROM users WHERE id = 1" ["27"]
      exec eng "BEGIN"
      exec eng "INSERT INTO users VALUES (9, 'Zed', 'zed@example.com', 50)"
      exec eng "DELETE FROM orders WHERE user_id = 1"
      exec eng "COMMIT"
      expectRows eng "SELECT COUNT(*) FROM users" ["4"]
      expectRows eng "SELECT COUNT(*) FROM orders" ["1"]

  , sqlTest "rollback undoes schema changes" $ \eng => do
      execAll eng shop
      exec eng "BEGIN"
      exec eng "CREATE TABLE temp (x INTEGER)"
      exec eng "INSERT INTO temp VALUES (1)"
      exec eng "CREATE INDEX users_age ON users (age)"
      exec eng "DROP TABLE orders"
      exec eng "ROLLBACK"
      rejects eng "SELECT * FROM temp" isSemantic
      expectRows eng "SELECT COUNT(*) FROM orders" ["3"]
      expectRows eng "EXPLAIN QUERY PLAN SELECT id FROM users WHERE age = 27"
        ["PROJECT users.id", "  FILTER users.age = 27", "    SCAN users"]
      expectRows eng "SELECT id FROM orders WHERE user_id = 1 ORDER BY id" ["100", "101"]

  , sqlTest "a failed write inside a transaction rolls the transaction back" $ \eng => do
      execAll eng shop
      exec eng "BEGIN"
      exec eng "INSERT INTO users VALUES (9, 'Zed', 'zed@example.com', 50)"
      rejects eng "INSERT INTO users VALUES (10, 'Dup', 'alice@example.com', 1)" isConstraint
      active <- liftIO (inTransaction eng)
      expect (not active) "the transaction is still open after a failed write"
      expectRows eng "SELECT COUNT(*) FROM users" ["3"]
      rejects eng "COMMIT" isTx

  , sqlTest "a schema statement that fails inside a transaction rolls it back" $ \eng => do
      execAll eng shop
      exec eng "BEGIN"
      exec eng "INSERT INTO users VALUES (9, 'Zed', 'zed@example.com', 50)"
      -- Schema statements check their names when they run, so this counts
      -- as a failed write.
      rejects eng "DROP TABLE nowhere" isSemantic
      active <- liftIO (inTransaction eng)
      expect (not active) "the transaction is still open after a failed DROP TABLE"
      expectRows eng "SELECT COUNT(*) FROM users" ["3"]

  , sqlTest "errors found before execution leave the transaction open" $ \eng => do
      execAll eng shop
      exec eng "BEGIN"
      exec eng "INSERT INTO users VALUES (9, 'Zed', 'zed@example.com', 50)"
      rejects eng "SELEC * FROM users" (\e => case e of
                                                SyntaxError _ _ => True
                                                _ => False)
      rejects eng "SELECT nope FROM users" isSemantic
      rejects eng "SELECT 1 / (9223372036854775807 + 1)" isRuntime
      active <- liftIO (inTransaction eng)
      expect active "a rejected statement closed the transaction"
      exec eng "COMMIT"
      expectRows eng "SELECT COUNT(*) FROM users" ["4"]

  , sqlTest "transaction commands are checked against the current state" $ \eng => do
      rejects eng "COMMIT" isTx
      rejects eng "ROLLBACK" isTx
      exec eng "BEGIN"
      rejects eng "BEGIN" isTx
      exec eng "COMMIT"
      exec eng "BEGIN TRANSACTION"
      exec eng "END"
  ]

paramTests : List Test
paramTests =
  [ sqlTest "bound parameters are data, not SQL" $ \eng => do
      exec eng "CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT, score REAL, flag BOOLEAN)"
      ins <- prepare eng "INSERT INTO note (body, score, flag) VALUES (?, ?, ?)"
      let hostile = "x'); DROP TABLE note; --"
      _ <- runStatement ins [VText hostile, VReal 1.5, VBool True]
      _ <- runStatement ins [VText "plain", VInt 2, VNull]
      Rows _ _ source <- execute eng "SELECT body, score, flag FROM note WHERE body = ?" [VText hostile]
        | _ => failWith "the query returned no row source"
      got <- drain source []
      expect (got == [hostile ++ "|1.5|TRUE"]) ("parameter was not stored verbatim: " ++ show got)
      expectRows eng "SELECT COUNT(*) FROM note" ["2"]
      expectRows eng "SELECT score FROM note WHERE id = 2" ["2.0"]

  , sqlTest "parameter types are known and checked before a statement runs" $ \eng => do
      exec eng "CREATE TABLE p (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)"
      st <- prepare eng "SELECT name FROM p WHERE id = ?1 AND n > ?2 AND name LIKE ?3"
      types <- parameterTypes st
      expect (sort (map (\(i, t) => (i, show t)) types) == [(0, "INTEGER"), (1, "INTEGER"), (2, "TEXT")])
        ("inferred parameter types: " ++ show (map (\(i, t) => (i, show t)) types))
      expectError "text for an integer parameter" (runStatement st [VText "1", VInt 2, VText "%"]) isRuntime
      expectError "missing parameter" (runStatement st [VInt 1, VInt 2]) isRuntime
      ins <- prepare eng "INSERT INTO p VALUES (?, ?, ?)"
      expectError "wrong type in insert" (runStatement ins [VInt 1, VInt 2, VInt 3]) isRuntime
      expectRows eng "SELECT COUNT(*) FROM p" ["0"]
      _ <- runStatement ins [VInt 1, VText "a", VInt 5]
      Rows _ _ source <- runStatement st [VInt 1, VInt 2, VText "%"]
        | _ => failWith "no rows from the prepared query"
      got <- drain source []
      expect (got == ["a"]) ("prepared query returned " ++ show got)

  , sqlTest "a result cannot be read after a later statement has run" $ \eng => do
      execAll eng people
      Rows _ _ source <- execute eng "SELECT name FROM person ORDER BY id" []
        | _ => failWith "the query returned no row source"
      first <- source
      expect (first == Just [VText "Ada"]) ("first row: " ++ show first)
      exec eng "UPDATE person SET name = 'changed' WHERE id = 2"
      expectError "reading a result ended by an UPDATE" source isRuntime
      expectRows eng "SELECT name FROM person WHERE id = 2" ["changed"]

  , sqlTest "a prepared statement follows schema changes" $ \eng => do
      exec eng "CREATE TABLE q (id INTEGER PRIMARY KEY, k INTEGER)"
      exec eng "INSERT INTO q VALUES (1, 5), (2, 5), (3, 6)"
      st <- prepare eng "SELECT id FROM q WHERE k = ? ORDER BY id"
      let run = \k => do
            Rows _ _ source <- runStatement st [VInt k] | _ => failWith "no rows"
            drain source []
      a <- run 5
      exec eng "CREATE INDEX q_k ON q (k)"
      b <- run 5
      exec eng "DROP INDEX q_k"
      c <- run 5
      expect (a == ["1", "2"] && b == a && c == a) ("results differ across schema changes: " ++ show [a, b, c])
      exec eng "DROP TABLE q"
      expectError "run after the table is gone" (runStatement st [VInt 5]) isSemantic
  ]

-- A table with two indexes driven by random statements and compared with
-- a model after each batch.

record Item where
  constructor MkItem
  score : Int
  tag : String

Catalogue : Type
Catalogue = SortedMap Int Item

-- One random statement, applied to the engine and to the model. `base` is
-- the model at BEGIN when the statements run inside a transaction: a write
-- that fails there ends the transaction and undoes it, so the model goes
-- back to `base` and a new transaction is opened.
step : Engine -> (base : Maybe Catalogue) -> Catalogue -> Int -> DB Catalogue
step eng base model r =
  let kind = (r `div` 16) `mod` 10
      id = (r `div` 256) `mod` 400
      score = (r `div` 4096) `mod` 50
      tag = "t" ++ show ((r `div` 65536) `mod` 9)
      insertSql = "INSERT INTO item VALUES (" ++ show id ++ ", " ++ show score ++ ", '" ++ tag ++ "')"
  in if kind < 5
       then case lookup id model of
         Just _ => do
           expectError "duplicate id" (execute eng insertSql []) isConstraint
           case base of
             Nothing => pure model
             Just start => do
               exec eng "BEGIN"
               pure start
         Nothing => do
           exec eng insertSql
           pure (insert id (MkItem score tag) model)
     else if kind < 8
       then do
         n <- changedBy eng ("UPDATE item SET score = score + 1, tag = '" ++ tag ++ "' WHERE score = " ++ show score)
         let hit = filter (\(_, it) => it.score == score) (SortedMap.toList model)
         expect (n == length hit) ("UPDATE changed " ++ show n ++ " rows, model says " ++ show (length hit))
         pure (foldl (\m, (k, it) => insert k (MkItem (it.score + 1) tag) m) model hit)
     else do
       n <- changedBy eng ("DELETE FROM item WHERE tag = '" ++ tag ++ "' AND score < " ++ show score)
       let hit = filter (\(_, it) => it.tag == tag && it.score < score) (SortedMap.toList model)
       expect (n == length hit) ("DELETE removed " ++ show n ++ " rows, model says " ++ show (length hit))
       pure (foldl (\m, (k, _) => delete k m) model hit)

agrees : Engine -> Catalogue -> DB ()
agrees eng model = do
  let rows = SortedMap.toList model
  expectRows eng "SELECT id, score, tag FROM item ORDER BY id"
    (map (\(k, it) => show k ++ "|" ++ show it.score ++ "|" ++ it.tag) rows)
  expectRows eng "SELECT COUNT(*) FROM item WHERE score = 7" [show (length (filter (\(_, it) => it.score == 7) rows))]
  expectRows eng "SELECT COUNT(*) FROM item WHERE tag = 't3' AND score >= 20"
    [show (length (filter (\(_, it) => it.tag == "t3" && it.score >= 20) rows))]

steps : Engine -> (base : Maybe Catalogue) -> Catalogue -> (seed : Int) -> Nat -> DB (Catalogue, Int)
steps eng base model seed Z = pure (model, seed)
steps eng base model seed (S k) = do
  let r = nextRandom seed
  model' <- step eng base model r
  steps eng base model' r k

-- Fail each storage write of a transaction in turn, half of them as torn
-- writes, abandon the connection and reopen. A transaction whose commit was
-- reported is there, one whose failure was reported is not, and one that
-- failed after its commit point says so and is there. `lateFaults` says
-- whether the options make the commit write page files after its commit
-- point, so that some faults must land there.
crashSweep : (name : String) -> Options -> (lateFaults : Bool) -> Test
crashSweep name opts lateFaults = dbTest ("crash at every write of a transaction, " ++ name) $ do
  let setup = \eng => do
        exec eng "CREATE TABLE item (id INTEGER PRIMARY KEY, score INTEGER NOT NULL, tag TEXT NOT NULL)"
        exec eng "CREATE INDEX item_score ON item (score)"
        exec eng "CREATE UNIQUE INDEX item_tag ON item (tag)"
        exec eng "BEGIN"
        for_ (the (List Int) [1 .. 150]) $ \i =>
          exec eng ("INSERT INTO item VALUES (" ++ show i ++ ", " ++ show (i `mod` 13) ++ ", 'tag" ++ show i ++ "')")
        exec eng "COMMIT"
  let change = \eng => do
        exec eng "BEGIN"
        exec eng "UPDATE item SET score = score + 100 WHERE id % 3 = 0"
        exec eng "DELETE FROM item WHERE id % 5 = 0"
        for_ (the (List Int) [151 .. 220]) $ \i =>
          exec eng ("INSERT INTO item VALUES (" ++ show i ++ ", 1, 'tag" ++ show i ++ "')")
        exec eng "CREATE TABLE extra (n INTEGER)"
        exec eng "INSERT INTO extra VALUES (1), (2)"
        exec eng "COMMIT"
  let snapshot = \eng => do
        a <- rowsOf eng "SELECT id, score, tag FROM item ORDER BY id"
        b <- liftIO (runDB (rowsOf eng "SELECT n FROM extra ORDER BY n"))
        pure (a, either (const ["<no table>"]) id b)
  -- Reference states, and the number of writes the change needs.
  st0 <- liftIO newStorage
  path0 <- liftIO (freshPath "sql-crash-probe.idb")
  eng0 <- openWith st0 path0 opts
  setup eng0
  old <- snapshot eng0
  w0 <- liftIO (storageStats st0)
  change eng0
  new <- snapshot eng0
  w1 <- liftIO (storageStats st0)
  closeEngine eng0
  let writes = w1.writeOps - w0.writeOps
  expect (writes > 30 && old /= new) ("the change made only " ++ show writes ++ " writes")
  afterCommit <- newIORef (the Nat 0)
  for_ (the (List Int) [0 .. writes]) $ \k => do
    st <- liftIO newStorage
    path <- liftIO (freshPath "sql-crash.idb")
    eng <- openWith st path opts
    setup eng
    liftIO (injectFault st k (k `mod` 2 == 1))
    r <- liftIO (runDB (change eng))
    case r of
      Left (CommittedThenFailed _) => do
        modifyIORef afterCommit (+ 1)
        expectError "a statement on a connection that must be reopened"
          (rowsOf eng "SELECT COUNT(*) FROM item") isIO
      _ => pure ()
    liftIO (abandonDatabase (enginePager eng))
    liftIO (clearFault st)
    eng2 <- openWith st path opts
    got <- snapshot eng2
    problems <- integrityCheck eng2
    closeEngine eng2
    let at = " (fault after write " ++ show k ++ " of " ++ show writes ++ ")"
    expect (isNil problems) ("integrity check after recovery" ++ at ++ ": " ++ show problems)
    case r of
      Right () => expect (got == new) ("a committed transaction was lost" ++ at)
      Left (CommittedThenFailed _) =>
        expect (got == new) ("a transaction reported as committed was lost" ++ at)
      Left _ => expect (got == old) ("a transaction reported as failed was kept" ++ at)
  late <- readIORef afterCommit
  expect (not lateFaults || late > 0) "no fault landed after the commit point"

workloadTests : List Test
workloadTests =
  [ sqlTest "random statements agree with a model (seed 20261121)" $ \eng => do
      exec eng "CREATE TABLE item (id INTEGER PRIMARY KEY, score INTEGER NOT NULL, tag TEXT NOT NULL)"
      exec eng "CREATE INDEX item_score ON item (score)"
      exec eng "CREATE INDEX item_tag_score ON item (tag, score)"
      (m1, s1) <- steps eng Nothing empty 20261121 400
      agrees eng m1
      exec eng "BEGIN"
      (m2, s2) <- steps eng (Just m1) m1 s1 400
      agrees eng m2
      exec eng "COMMIT"
      agrees eng m2
      exec eng "BEGIN"
      _ <- steps eng (Just m2) m2 s2 300
      exec eng "ROLLBACK"
      agrees eng m2

  , crashSweep "with the log kept" (MkOptions 16 4194304 False 50000) False
  , crashSweep "with a checkpoint after every commit and a pool that spills" (MkOptions 8 1 False 50000) True
  ]

persistenceTests : List Test
persistenceTests =
  [ dbTest "schema, rows and indexes survive closing and reopening" $ do
      path <- liftIO (freshPath "sql-reopen.idb")
      eng <- openEngine path small
      execAll eng shop
      exec eng "CREATE TABLE big (id INTEGER PRIMARY KEY, body TEXT)"
      exec eng ("INSERT INTO big VALUES (1, '" ++ pack (replicate 20000 'z') ++ "')")
      closeEngine eng
      eng2 <- openEngine path small
      expectRows eng2 "SELECT name FROM users ORDER BY id" ["Alice", "Bob", "Cat"]
      expectRows eng2 "SELECT id FROM orders WHERE user_id = 1 ORDER BY id" ["100", "101"]
      expectRows eng2 "SELECT LENGTH(body) FROM big" ["20000"]
      expectRows eng2 "EXPLAIN QUERY PLAN SELECT id FROM orders WHERE user_id = 1"
        ["PROJECT orders.id", "  FILTER orders.user_id = 1", "    SEARCH orders USING INDEX idx_orders_user (user_id = 1)"]
      expectError "unique constraint after reopen"
        (execute eng2 "INSERT INTO users VALUES (8, 'Dup', 'bob@example.com', 1)" []) isConstraint
      exec eng2 "UPDATE big SET body = 'short'"
      exec eng2 "DROP TABLE orders"
      checked eng2
      closeEngine eng2
      eng3 <- openEngine path small
      expectRows eng3 "SELECT body FROM big" ["short"]
      checked eng3
      closeEngine eng3

  , dbTest "dropping tables returns their pages for reuse" $ do
      path <- liftIO (freshPath "sql-reuse.idb")
      eng <- openEngine path small
      let fill = do
            exec eng "CREATE TABLE bulk (id INTEGER PRIMARY KEY, body TEXT)"
            exec eng "CREATE INDEX bulk_body ON bulk (body)"
            exec eng "BEGIN"
            for_ (the (List Int) [1 .. 1500]) $ \i =>
              exec eng ("INSERT INTO bulk VALUES (" ++ show i ++ ", 'body number " ++ show i ++ "')")
            exec eng "COMMIT"
      fill
      first <- engineStats eng
      exec eng "DROP TABLE bulk"
      fill
      second <- engineStats eng
      expect (second.pageCount <= first.pageCount + 2)
        ("the database grew from " ++ show first.pageCount ++ " to " ++ show second.pageCount ++ " pages")
      checked eng
      closeEngine eng

  , dbTest "a query over more data than the buffer pool holds stays within it" $ do
      path <- liftIO (freshPath "sql-bounded.idb")
      eng <- openEngine path (MkOptions 16 4194304 False 50000)
      exec eng "CREATE TABLE wide (id INTEGER PRIMARY KEY, body TEXT)"
      exec eng "BEGIN"
      for_ (the (List Int) [1 .. 2000]) $ \i =>
        exec eng ("INSERT INTO wide VALUES (" ++ show i ++ ", '" ++ pack (replicate 300 'w') ++ "')")
      exec eng "COMMIT"
      expectRows eng "SELECT COUNT(*), SUM(LENGTH(body)) FROM wide" ["2000|600000"]
      stats <- engineStats eng
      expect (stats.pageCount > 100) ("the table has only " ++ show stats.pageCount ++ " pages")
      expect (stats.pool.cached <= 16) ("the pool holds " ++ show stats.pool.cached ++ " pages, capacity 16")
      checked eng
      closeEngine eng
  ]

apiTests : List Test
apiTests =
  [ dbTest "the library API: open, execute, query, prepare, transactions" $ do
      path <- liftIO (freshPath "sql-api.idb")
      db <- IdrisQL.openDatabase path defaultOptions
      _ <- IdrisQL.execute db "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL)" []
      ins <- IdrisQL.prepare db "INSERT INTO item (name, price) VALUES (?, ?)"
      n <- withTransaction db $ do
        a <- IdrisQL.run ins [VText "kettle", VReal 19.5]
        b <- IdrisQL.run ins [VText "cup", VNull]
        pure (a + b)
      expect (n == 2) ("inserted " ++ show n ++ " rows")
      expectError "a failing transaction body"
        (withTransaction db (IdrisQL.run ins [VText "lamp", VReal 5.0] >>= \_ => IdrisQL.run ins [VNull, VNull])) isConstraint
      rs <- query db "SELECT name, price FROM item WHERE price IS NOT NULL OR name = ? ORDER BY id" [VText "cup"]
      expect (rs.columns == ["name", "price"]) ("columns: " ++ show rs.columns)
      rows <- fetchAll rs
      expect (rows == [[VText "kettle", VReal 19.5], [VText "cup", VNull]]) ("rows: " ++ show rows)
      byName <- IdrisQL.prepare db "SELECT price FROM item WHERE name = ?"
      found <- runQuery byName [VText "kettle"]
      seen <- forRows found (\row => expect (row == [VReal 19.5]) ("row: " ++ show row))
      expect (seen == 1) ("prepared query returned " ++ show seen ++ " rows")
      names <- liftIO (map (map (.name)) (tables db))
      expect (names == ["item"]) ("tables: " ++ show names)
      expect (show (durability db) == "flushed to the operating system (no fsync)") "unexpected durability level"
      expect (not (recovery db).walFound || (recovery db).pagesRedone == 0) "a new database replayed a log"
      problems <- IdrisQL.integrityCheck db
      expect (isNil problems) ("integrity: " ++ show problems)
      IdrisQL.closeDatabase db
  ]

export
sqlTests : List Test
sqlTests = basicTests ++ constraintTests ++ queryTests ++ indexTests ++ txnTests ++ paramTests
           ++ workloadTests ++ persistenceTests ++ apiTests
