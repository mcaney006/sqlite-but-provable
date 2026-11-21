# IdrisQL

An embedded SQL database engine written in Idris 2. It stores data in its
own page format, runs SQL through a typed intermediate representation, and
recovers committed transactions after the process is killed.

The engine is about 9,900 lines of Idris with no foreign functions, no
`believe_me` and no dependency beyond the `base` and `linear` packages that
ship with the compiler. SQLite appears only in the tests and benchmarks, as
a separate program whose answers IdrisQL's are compared with.

## Status

| Area | State |
|---|---|
| Storage | Slotted 4 KiB pages with checksums, overflow chains, free list, bounded buffer pool |
| Indexing | B+ trees with split, merge, redistribution and root contraction; primary, unique, secondary and composite indexes |
| SQL | `CREATE`/`DROP TABLE` and `INDEX`, `INSERT`, `SELECT` with joins, grouping, ordering and limits, `UPDATE`, `DELETE`, transactions, `EXPLAIN`, `ANALYZE`, bound parameters |
| Transactions | Write-ahead log, checkpoints, crash recovery; one connection per database |
| Durability | Survives process death. Does not survive power loss: Idris 2's `base` has no `fsync`. |
| Speed | 3 to about 500 times slower than SQLite, depending on the workload (`docs/BENCHMARKS.md`) |

Not supported: subqueries, `UNION`, `CASE`, `ALTER TABLE`, views, enforced
foreign keys, concurrent connections. `docs/SQL_COMPATIBILITY.md` has the
full list.

## Build and run

Requires Idris 2 version 0.8.0 with the Chez Scheme backend.

```sh
make build
./build/exec/idrisql example.idb
```

A database is a directory. The shell reads statements from standard input,
from `--file PATH`, or from `--execute SQL`.

```
$ ./build/exec/idrisql shop.idb
idrisql> CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE);
idrisql> INSERT INTO users VALUES (1, 'Alice', 'alice@example.com'), (2, 'Bob', 'bob@example.com');
idrisql> SELECT id, name FROM users WHERE email = 'bob@example.com';
id | name
---+-----
2  | Bob
idrisql> EXPLAIN QUERY PLAN SELECT name FROM users WHERE email = 'bob@example.com';
plan
------------------------------------------------------------------------
PROJECT users.name
  FILTER users.email = 'bob@example.com'
    SEARCH users USING INDEX users_email_key (email = 'bob@example.com')
idrisql> INSERT INTO users VALUES (3, 'Carol', 'bob@example.com');
Error: constraint violation: UNIQUE constraint failed: users.email
idrisql> .quit
```

`make demo` runs `examples/demo.sql`, which creates two tables and an
index, joins and aggregates them, rolls a transaction back, and then reopens
the database to show that the data is still there.

## Library

```idris
import IdrisQL

main : IO ()
main = do
  Right rows <- runDB $ do
      db <- openDatabase "shop.idb" defaultOptions
      _ <- execute db "CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)" []
      _ <- execute db "INSERT INTO item (name) VALUES (?)" [VText "kettle"]
      result <- query db "SELECT id, name FROM item WHERE name = ?" [VText "kettle"]
      rows <- fetchAll result
      closeDatabase db
      pure rows
    | Left e => putStrLn ("failed: " ++ show e)
  printLn rows
```

`src/IdrisQL.idr` also has prepared statements, row-at-a-time iteration,
`withTransaction`, and schema inspection.

`IdrisQL.Transaction.State` gives the same engine through a connection whose
type records whether a transaction is open. A session runs inside
`withDatabase path options session`:

```idris
session : (1 _ : Conn Idle) -> L1 IO (Closed Nat)
session c0 = do
  Ok () c1 <- begin c0
    | Fail _ c => end c 0
  Ok _ c2 <- execute c1 "INSERT INTO item (name) VALUES ('cup')" []
    | Fail _ c => end c 0          -- the failed statement rolled back; c is idle
  Ok () c3 <- commit c2
    | Fail _ c => end c 0
  end c3 1
```

Committing `c0`, beginning twice, or ending with `c2` does not compile.
`tests/typecheck/` holds those programs, and compiles both examples above.

## What the types guarantee

| Guarantee | Checked by |
|---|---|
| A page-header field offset lies inside the page | The compiler |
| An expression reads only columns that exist, at their declared types | The compiler |
| Optimizer rewrites and planning keep a query's column types | The compiler |
| A node split neither loses nor duplicates a cell | The compiler |
| A typed session ends with its transaction closed | The compiler |
| A page read from disk is intact | A checksum, at run time |
| The B+ tree stays ordered and balanced | Tests against a model, and `.check` |
| Recovery restores exactly the committed transactions | Fault-injection and SIGKILL tests |
| The optimizer preserves a query's meaning | Tests, including 180 comparisons with SQLite |

`docs/PROOFS.md` gives the complete account, including what is assumed and
what is known not to hold.

## Tests

```sh
make test               # everything below; needs sqlite3 on the PATH
make test-unit          # 279 tests: lexer and parser, storage, SQL, typed API
make test-typecheck     # 3 programs that must compile, 8 that must not
make test-differential  # 180 comparisons with the sqlite3 shell
make test-crash         # 40 rounds of SIGKILL and recovery
make bench              # 200,000 rows, timed against SQLite, results compared
```

## Documents

| File | Contents |
|---|---|
| `ARCHITECTURE.md` | Layers, plans, and the cost of each design decision |
| `docs/PLATFORM_CONSTRAINTS.md` | What Idris 2's `base` can do with files, measured, and what that forced |
| `docs/FILE_FORMAT.md` | Every byte of pages, rows, keys and log records |
| `docs/TRANSACTIONS.md` | Commit, checkpoint, recovery, and what a commit does and does not survive |
| `docs/SQL_COMPATIBILITY.md` | Supported SQL and differences from SQLite |
| `docs/PROOFS.md` | Machine-checked, runtime-validated, tested, assumed, and known limitations |
| `docs/BENCHMARKS.md` | Measurements against SQLite and where the time goes |
| `PROGRESS.md` | What exists, what does not, and what to do next |
