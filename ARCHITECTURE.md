# Architecture

IdrisQL is one Idris 2 package of 36 library modules and a shell, about
10,500 lines. The engine depends on the compiler's `base` and `linear`
packages and nothing else; the HTTP server adds `network`, which also ships
with the compiler. A statement passes through the layers below from top to
bottom.

```
 SQL text
    |
    v
 Lexer -> Parser -> AST                      src/IdrisQL/SQL/{Lexer,Parser,AST}.idr
    |
    v
 Analyzer: names and types resolved          src/IdrisQL/SQL/Analyzer.idr
    |      output is the typed IR            src/IdrisQL/SQL/Typed.idr
    v
 Logical plan (relational algebra)           src/IdrisQL/Query/Algebra.idr
    |
    v
 Optimizer: rewrites on the logical plan     src/IdrisQL/Query/Optimizer.idr
    |
    v
 Planner: access paths, join method, order   src/IdrisQL/Query/Planner.idr
    |
    v
 Executor: pull-based row sources            src/IdrisQL/Query/{Executor,Sorter}.idr
    |
    v
 Engine: statements, constraints, schema     src/IdrisQL/Engine.idr, Query/Statement.idr
    |
    v
 Catalog, row and key codecs                 src/IdrisQL/Catalog/*, Index/KeyCodec.idr
    |
    v
 B+ tree and cursors                         src/IdrisQL/Index/{BPlusTree,Cursor,Node}.idr
    |
    v
 Pager: transactions, allocation, recovery   src/IdrisQL/Storage/{Pager,Recovery,WAL}.idr
    |
    v
 Buffer pool                                 src/IdrisQL/Storage/BufferPool.idr
    |
    v
 Pages and file access                       src/IdrisQL/Storage/{Page,Format,Codec,FileIO}.idr
```

Four entry points sit on top of the engine: the shell
(`src/Main.idr`, `src/IdrisQL/CLI/Shell.idr`), the library API
(`src/IdrisQL.idr`), the typed session API
(`src/IdrisQL/Transaction/State.idr`) and the HTTP server
(`src/IdrisQL/Server/{Http,Serve}.idr`, described in `docs/SERVER.md`).
The server holds the engine's one connection and runs each request's
statements through the same `execute` the shell uses.

## Front end

The lexer is total and records a line and column for every token. The
parser is recursive descent with one function per precedence level. It
rejects unsupported SQL by name (`docs/SQL_COMPATIBILITY.md`) instead of
accepting and ignoring it.

The analyzer resolves each name against a scope built from the `FROM`
clause and produces `TExpr ctx t`: an expression indexed by the row shape
it reads and the type it returns. Column references are positions with a
proof (`Elem t ctx`), not names. A grouped query is analyzed against two
scopes: the input rows for `WHERE` and aggregate arguments, and the grouped
rows for everything after.

## Plans

`LPlan ctx` has nine operators: scan, one row, filter, project, join,
aggregate, sort, distinct, limit. `ctx` is the shape of the rows the plan
produces.

The optimizer applies, in this order:

| Rewrite | Effect |
|---|---|
| Constant folding and filter simplification | `1 = 1 AND x` becomes `x`; a filter that is always true disappears |
| Predicate pushdown | A `WHERE` conjunct that reads one side of an inner join moves below it, and one that reads both sides becomes the join condition. Through a left join only left-side conjuncts move. An `ON` conjunct of a left join that reads only the right side moves into the right input. |

Every rewrite is a total function `LPlan ctx -> LPlan ctx`.

The planner turns the logical plan into `PPlan ctx` and makes the choices
that depend on the schema:

| Choice | Rule |
|---|---|
| Access path | Among a full scan, a rowid lookup or range, and each index whose leading columns are bound by equality (plus one range), the lowest estimated cost |
| Estimates | Row counts and distinct-key counts from `ANALYZE` when present; otherwise 1,000 rows per table, 1 in 100 for an equality, 3 in 10 for an inequality |
| Projection pushdown | Each scan decodes only the columns some operator above reads |
| Join method | Index nested loop when the join condition binds an index or the rowid of the inner table; otherwise nested loop |
| Join order | For an inner join, both orders are costed and the cheaper is used; the columns are then put back in the written order |
| Sort elimination | A sort is dropped when its keys are a prefix of the order the input already has, including through a projection that copies those columns |
| `ORDER BY .. LIMIT` | An index whose leading columns are the sort keys is walked in order instead of sorting the table |

`EXPLAIN` prints the logical plan, the plan after rewrites and the physical
plan. The physical plan printed is the value the executor runs, not a
description written separately.

## Execution

Every physical operator is a row source: an action that returns the next
row or the end. Rows are pulled one at a time, so a query's memory use does
not grow with its result, with three exceptions:

| Operator | Memory |
|---|---|
| Sort | Up to `sortMemoryRows` rows (50,000 by default) in memory; beyond that, sorted runs are written to `tmp/` and merged |
| `COUNT(DISTINCT x)` and the other `DISTINCT` aggregates | One set of distinct values per group |
| `UPDATE` and `DELETE` | The rowids of the rows to change |

Grouping and `DISTINCT` sort their input and then compare adjacent rows.

## Storage

Tables and indexes are B+ trees of byte-string keys. A table is keyed by
rowid; an index by its encoded columns followed by the rowid.
`docs/FILE_FORMAT.md` gives the layouts.

The buffer pool holds a fixed number of 4 KiB frames (2,048 by default) and
evicts with a clock sweep. Operations pin a page for the duration of one
access and unpin it on every path, including errors (`withPage`).

The pager owns transactions. Changed pages stay out of the page files until
commit, the log holds full page images, and recovery only redoes.
`docs/TRANSACTIONS.md` describes the protocol and its guarantees.

`src/IdrisQL/Storage/FileIO.idr` is the only module that reads or writes
database files. (The shell reads its script and writes to the console
itself.) It also counts writes and can fail the Nth one on request, which is
how the recovery tests inject faults without a foreign function.

## Where the types do work

| Guarantee | Mechanism |
|---|---|
| A fixed page offset is inside the page | `InPage off len`, discharged at compile time |
| A row has the shape of its table | `Row (tableCtx tbl)` |
| An expression reads existing columns at their types | `TExpr ctx t` with `Elem t ctx` |
| Rewrites and planning keep the result shape | `LPlan ctx -> LPlan ctx`, `LPlan ctx -> PPlan ctx` |
| A node split loses and duplicates nothing | `Cut.preserves : left ++ right = xs` |
| A typed session commits only an open transaction and ends idle | `Conn s` held linearly, `Closed` |

`docs/PROOFS.md` separates these from what is only checked at run time or
only tested.

## Design decisions and their cost

| Decision | Reason | Cost |
|---|---|---|
| One file per page | No seek in `base`; the torn unit equals the logged unit | A file open per uncached page; 9,296 files for 200,000 rows |
| Full page images in the log | Recovery is a copy; no per-operation redo logic to get wrong | 4 KiB logged per changed page |
| No statement-level undo | The log is redo-only | A failed write ends its transaction |
| Sort-based grouping, nested-loop joins | Fewer operators to verify and test | Slow joins and aggregates on large inputs |
| Static typing | It is what makes the typed IR possible | Stricter than SQLite; see `docs/SQL_COMPATIBILITY.md` |
| Single connection | No lock manager | No concurrency |
| Serial HTTP server, one connection per request | The engine has one connection, and the socket library has neither timeouts nor non-blocking I/O | One slow client holds up every other |
