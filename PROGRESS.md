# Progress

State of the repository on 2026-11-21.

## Built and tested

| Component | Evidence |
|---|---|
| Page format, checksums, overflow chains, free list | `storage` suite |
| Buffer pool with pinning, dirty tracking, clock eviction, spill of uncommitted pages | `storage` suite; `bench/run.sh` with data 18 times the pool |
| B+ tree: split, merge, redistribute, root contraction, validation | 12,000 random operations against a model |
| Catalog, typed rows, order-preserving keys | `storage` and `sql` suites |
| Lexer, parser, analyzer to a typed IR | 192 front-end tests; 8 programs that must not compile |
| Optimizer and planner: constant folding, predicate pushdown, projection pushdown, index selection, join order, sort elimination, `ANALYZE` statistics | `sql` suite, exact `EXPLAIN` text for 14 statements |
| Executor: scans, index and nested-loop joins, sort-based aggregation, external sort, limits | `sql` suite; 180 comparisons with SQLite |
| Constraints: PRIMARY KEY, UNIQUE, NOT NULL, DEFAULT, CHECK | `sql` suite and differential tests |
| Write-ahead log, checkpoints, recovery | Fault at every write, torn writes, 40 SIGKILL rounds |
| Shell, library API, typed session API | `sql` and `typed` suites, `tests/typecheck` |
| CI | `.github/workflows/ci.yml` |

`make test` runs all of it: 279 unit tests, 11 compile-time cases, 180
differential checks and the crash test.

## Not built

| Item | Note |
|---|---|
| Power-loss durability | Not possible with Idris 2's `base`: no `fsync` |
| Concurrent connections | One process and one connection per database |
| Statement-level rollback, savepoints | A failed write ends its transaction |
| Foreign key enforcement | Parsed and stored only |
| Subqueries, `UNION`, `CASE`, `ALTER TABLE`, views | Rejected by the parser |
| Hash join, hash aggregation, index-only scans | The main reasons joins and range counts are slow |
| Append-friendly splits | Table pages end about half full |
| Proof that rewrites preserve query meaning | Types fix the result shape only |

## Measured

| Measure | Value |
|---|---|
| Source | About 9,900 lines of engine, 2,100 lines of tests |
| 200,000-row load, 3 indexes, one transaction | 21.3 s (SQLite 0.58 s) |
| 1,000 single-row transactions | 1.13 s (SQLite without fsync 0.34 s) |
| B+ tree lookup in memory | 9.4 µs |
| Database size for 200,000 rows | 37 MiB in 9,296 files (SQLite 11 MiB) |

Details and method: `docs/BENCHMARKS.md`.

## Next steps, in order of value

1. Index-only scans: answer a query from the index when it holds every
   column the query reads. The range benchmark fetches 300 rows per query
   that it never uses.
2. Hash join and hash aggregation.
3. Split the rightmost leaf unevenly on append, to fill table pages.
4. Statement-level rollback by keeping pre-statement page images.
5. Foreign key enforcement.
