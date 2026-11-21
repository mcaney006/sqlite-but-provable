# Benchmarks

IdrisQL is between 3 and several hundred times slower than SQLite on the
workloads below, and its database directory is 3.2 times larger. This
document gives the numbers, how to reproduce them, and where the time goes.

Every figure was measured on 2026-11-21 on the machine described in
`docs/PLATFORM_CONSTRAINTS.md` (Apple M5, macOS 27.3, Idris 2 0.8.0 on Chez
Scheme 10.4.1) against SQLite 3.54.0. Nothing here is estimated.

## Method

`bench/run.sh` generates one data set, loads it into IdrisQL and into
SQLite, runs the same statements through both shells, and compares the
output of every phase byte for byte. A phase whose output differs is marked
and fails the script.

| Item | Value |
|---|---|
| Data | 200,000 rows: `customers` 20,000, `orders` 120,000, `events` 60,000 |
| Indexes | 3 secondary indexes, present during the load |
| Generator | Lehmer generator in awk, seed 20261121 |
| Timing | `/usr/bin/time -p`, wall clock, resolution 0.01 s, one run per phase |
| What is timed | One shell process per phase: start, open, statements from a file, close |
| SQLite, `synchronous=OFF` | Does not call `fsync`. This is the durability IdrisQL has, so it is the like-for-like column. |
| SQLite, default | Rollback journal, `synchronous=FULL` |

Process start is inside every figure. An IdrisQL shell that runs `SELECT 1`
and exits takes 0.05 s.

## Results with the default 8 MiB buffer pool

The data is 9,295 pages (36 MiB), 4.5 times the pool.

| Phase | Statements | IdrisQL (s) | SQLite OFF (s) | SQLite default (s) | IdrisQL / SQLite OFF | Same output |
|---|---:|---:|---:|---:|---:|---|
| load: 200,000 inserts in one transaction | 200,008 | 21.26 | 0.58 | 0.49 | 37 | yes |
| point: `WHERE id = ?` by primary key | 2,000 | 0.33 | 0.02 | 0.02 | 17 | yes |
| index: count and sum over one customer's orders | 2,000 | 1.33 | 0.06 | 0.04 | 22 | yes |
| range: count on a two-column index range | 200 | 4.97 | 0.01 | 0.01 | about 500 | yes |
| scan: three full-table aggregates | 3 | 2.80 | 0.07 | 0.08 | 40 | yes |
| join: two- and three-table joins with grouping | 3 | 7.32 | 0.08 | 0.09 | 92 | yes |
| sort: top 20 of 120,000 by two orderings, two `COUNT(DISTINCT)` | 3 | 2.97 | 0.07 | 0.06 | 42 | yes |
| write: 1,000 single-row transactions | 1,000 | 1.13 | 0.34 | 0.42 | 3.3 | yes |
| delete: 20,000 rows deleted, 4,019 updated, then counts | 5 | 4.45 | 0.09 | 0.07 | 49 | yes |

SQLite's times for the read phases are close to the timer's resolution, so
the ratios for those rows are rough.

Integrity check after the run: `ok`.

| Size | IdrisQL | SQLite |
|---|---:|---:|
| On disk | 37,184 KiB in 9,296 files | 11,700 KiB in 1 file |

## Results with a 2 MiB buffer pool

`CACHE=512`, the size of SQLite's default page cache. The data is 18 times
the pool.

| Phase | IdrisQL (s) | SQLite OFF (s) | SQLite default (s) | Same output |
|---|---:|---:|---:|---|
| load | 40.82 | 0.65 | 0.48 | yes |
| point | 0.47 | 0.02 | 0.02 | yes |
| index | 1.87 | 0.14 | 0.06 | yes |
| range | 6.62 | 0.02 | 0.01 | yes |
| scan | 3.26 | 0.05 | 0.16 | yes |
| join | 11.90 | 0.13 | 0.12 | yes |
| sort | 3.29 | 0.07 | 0.07 | yes |
| write | 1.41 | 0.48 | 0.51 | yes |
| delete | 6.83 | 0.10 | 0.17 | yes |

The load takes twice as long as with 8 MiB. In one transaction every page
that leaves the pool is written to `spill/` and read back when it is needed
again, at one file open and close each way.

With a 64 MiB pool, which holds the whole data set, the load took 21.33 s:
the same as with 8 MiB. At that point the load is limited by computation,
not by file access.

## Where the time goes

`make microbench` runs `src/Bench/Micro.idr`, which times single operations
with everything in memory.

| Operation | Time each |
|---|---:|
| Pin and unpin a cached page | 0.1 µs |
| Encode a 3-column row | 0.8 µs |
| Parse, check and plan an `INSERT` from text | 5.7 µs |
| B+ tree lookup, 100,000 keys, 3 levels | 9.4 µs |
| B+ tree insert, ascending keys | 12.5 µs |
| `SELECT` by primary key, prepared | 10.5 µs |
| `INSERT`, prepared and bound | 20.3 µs |
| `INSERT` from text | 25.7 µs |
| Commit of a transaction that wrote the 100,000-row tree | 180 ms |

Reading the two tables together:

1. Tree search is the largest single cost. A lookup spends about 3 µs per
   level comparing keys a byte at a time in Idris. The same loop cost 18 µs
   per lookup before the in-page search was rewritten as one loop over raw
   bytes (`Page.searchSlots`).
2. A page that is not in the pool costs a file open, read and close: 131 µs
   measured, against 9.4 µs for a whole in-memory lookup. This is the price
   of one file per page, which the platform's lack of seek forces
   (`docs/PLATFORM_CONSTRAINTS.md`).
3. The range phase is the worst case of both. A query in it finds about 300
   index entries (300 for the range 5..1005) and fetches the table row for
   each one, although the count could be answered from the index alone.
   The engine has no index-only scan.
4. Joins are index nested loops or plain nested loops, and grouping sorts
   its input. There is no hash join, merge join or hash aggregation. The
   first join query performs one tree lookup per order, 120,000 of them,
   and then sorts the 120,000 joined rows by region to group them.
5. The write phase is the closest to SQLite because both engines are then
   dominated by per-transaction overhead, and neither calls `fsync` in the
   like-for-like column.

## Why the database is 3.2 times larger

A node that fills up splits in the middle. With ascending keys the left
half is never filled again, so table pages end about half full. SQLite
splits the rightmost leaf unevenly for appends; IdrisQL does not. Each page
is also its own 4 KiB file.

## Reproducing

```sh
make build
make bench                 # default 8 MiB pool
CACHE=512 make bench       # 2 MiB pool
SCALE=2 make bench         # 400,000 rows
make microbench
```

`bench/run.sh` needs `sqlite3` on the PATH and writes its working files to
`build/bench/`.

## Sensitivity to other load

The tables above were measured while the machine was otherwise idle. A
rerun while its load average was 24 (10 cores) took 57.50 s for the load
phase against 21.26 s, and SQLite's join phase took 0.36 s against 0.08 s.
Compare runs made under the same conditions only.

The tables predate two small changes to the engine: a counter comparison
each time a row is read from a result, and a map lookup on each delete.
The in-memory figures were measured again after those changes and did not
move outside run-to-run variation (tree lookup 8.6 µs against 9.4 µs).

## What these figures are not

They are single runs on one machine, with a warm file cache, of one data
set. They do not measure concurrency (IdrisQL has none), power-loss
durability (IdrisQL has none), or SQLite tuned for speed.
