# IdrisQL

An embedded SQL database engine written in Idris 2. It stores data in its
own page format, runs SQL through a typed intermediate representation, and
recovers committed transactions after the process is killed.

The engine, shell and server are about 10,500 lines of Idris with no
foreign functions and no `believe_me`. The engine depends on the `base` and
`linear` packages that ship with the compiler, and the HTTP server adds
`network`, which ships with it too. SQLite appears only in the tests and
benchmarks, as a separate program whose answers IdrisQL's are compared
with.

It can be used three ways: as a library, through a shell, or as an HTTP
server in a container. It is not a replacement for PostgreSQL, MySQL or
SQLite in production: one process and one request at a time, and no
durability across power loss.

## Status

| Area | State |
|---|---|
| Storage | Slotted 4 KiB pages with checksums, overflow chains, free list, bounded buffer pool |
| Indexing | B+ trees with split, merge, redistribution and root contraction; primary, unique, secondary and composite indexes |
| SQL | `CREATE`/`DROP TABLE` and `INDEX`, `INSERT`, `SELECT` with joins, grouping, ordering and limits, `UPDATE`, `DELETE`, transactions, `EXPLAIN`, `ANALYZE`, bound parameters |
| Transactions | Write-ahead log, checkpoints, crash recovery; one connection per database |
| Durability | Survives process death. Does not survive power loss: Idris 2's `base` has no `fsync`. |
| Speed | 3 to about 500 times slower than SQLite, depending on the workload (`docs/BENCHMARKS.md`) |
| Server | HTTP/1.1 with JSON results, one request at a time, optional bearer token (`docs/SERVER.md`) |
| Packaging | Container image for `linux/amd64` and `linux/arm64`; pixi tasks for Linux and macOS; a Terraform module for AWS that has been validated and never applied |

Not supported: subqueries, `UNION`, `CASE`, `ALTER TABLE`, views, enforced
foreign keys, concurrent connections. `docs/SQL_COMPATIBILITY.md` has the
full list.

## Install and run

| Route | Needs | Platforms |
|---|---|---|
| Container image | Docker or another OCI runtime | Anything that runs Linux containers, Windows included |
| pixi | [pixi](https://pixi.sh) | Linux and macOS, x86-64 and arm64 |
| Your own toolchain | Idris 2 version 0.8.0 with the Chez Scheme backend, and make | Wherever that runs |

### Container

```sh
docker run -d --name idrisql -p 127.0.0.1:5480:5480 \
  -e IDRISQL_TOKEN=change-me -v idrisql-data:/data \
  ghcr.io/mcaney006/sqlite-but-provable:edge

curl -s -X POST -H 'Authorization: Bearer change-me' \
  --data-binary "SELECT 1 + 1 AS two" http://127.0.0.1:5480/query
# {"results":[{"columns":["two"],"rows":[[2]]}]}
```

`docs/SERVER.md` has the API, the image's settings and its limits.
`deploy/aws` runs the same image on Amazon ECS with the data on EFS.

### pixi

```sh
pixi run build      # compile; the first run also builds the toolchain
pixi run test       # every test suite
pixi run shell      # the shell on ./main.idb
pixi run serve      # the HTTP server on 127.0.0.1:5480
pixi run dev        # incremental build into build-inc/
```

conda-forge packages neither Idris 2 nor Chez Scheme, so the first run
compiles Chez Scheme 10.3.0 and Idris 2 0.8.0 from source into
`~/.cache/idrisql` (`scripts/pixi-activate.sh` explains the location). On
the reference machine the first `pixi run build` followed by `pixi run
test` took 13 minutes 12 seconds; later runs skip the toolchain. pixi
supplies the C compiler, make, GMP, curl and sqlite3.

### Your own toolchain

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
make test               # the next five; needs sqlite3 and curl on the PATH
make test-unit          # 293 tests: lexer and parser, storage, SQL, typed API, HTTP
make test-typecheck     # 3 programs that must compile, 8 that must not
make test-differential  # 180 comparisons with the sqlite3 shell
make test-crash         # 40 rounds of SIGKILL and recovery
make test-server        # 25 checks of the HTTP server on a real socket
make docker-test        # all of the above inside Alpine
make test-container     # 9 checks of the container image
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
| `docs/SERVER.md` | The HTTP API, the container image, and what the server does not do |
| `deploy/aws/README.md` | The Terraform module: what it creates, why it runs one task, durability on EFS |
| `docs/PROOFS.md` | Machine-checked, runtime-validated, tested, assumed, and known limitations |
| `docs/BENCHMARKS.md` | Measurements against SQLite, where the time goes, and build times |
| `PROGRESS.md` | What exists, what does not, and what to do next |
