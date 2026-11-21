# What is proved, checked, tested and assumed

Each claim about IdrisQL's correctness falls into one of five classes. This
document assigns every claim to its class and names the file that backs it.

| Class | Meaning |
|---|---|
| Machine-checked | The Idris type checker rejects a program that violates it. No test is involved. |
| Runtime-validated | The engine checks it while running and returns an error when it does not hold |
| Tested | A test exercises it. It can still be false for inputs no test tries. |
| Assumed | Nothing in this repository checks it |
| Known limitation | Known not to hold, or deliberately out of scope |

The project uses no `believe_me`, no `assert_total`, no `assert_smaller`, no
`unsafePerformIO` and declares no foreign function.
`scripts/check-rules.sh` fails the build if one appears.

## Machine-checked

### Totality of 11 modules

These modules begin with `%default total`. Every function in them is
checked to cover all inputs and to terminate.

| Module | What totality means there |
|---|---|
| `IdrisQL.SQL.Lexer`, `Token` | Tokenising any string ends, with tokens or an error |
| `IdrisQL.SQL.AST` | Rendering and comparing syntax trees ends |
| `IdrisQL.SQL.Typed` | Evaluating a typed expression on a row ends with a value or an error; so do simplification and renaming |
| `IdrisQL.Query.Algebra`, `Optimizer` | Every rewrite of a logical plan ends |
| `IdrisQL.Index.Node` | The cut functions used by splits and merges end |
| `IdrisQL.Storage.Format` | Range checks end |
| `IdrisQL.Types`, `Error`, `Options` | Value comparison and rendering end |

The other 23 modules are checked for coverage only (Idris's default): every
case is handled, but termination is not proved. They contain the loops over
disk structures and the recursive-descent parser. See "Runtime-validated"
for the bounds on those loops.

### Typed rows and expressions

`Row : List SqlType -> Type` (`src/IdrisQL/Types.idr`) is a row whose shape
is in its type. `TExpr ctx t` (`src/IdrisQL/SQL/Typed.idr`) is an expression
over rows of shape `ctx` with result type `t`. A column reference carries an
`Elem t ctx`: a proof that the column exists and has type `t`.

Consequences the compiler enforces:

- `eval` cannot read a column that is not in the row, or read one at the
  wrong type. There is no runtime type check in expression evaluation.
- The analyzer (`src/IdrisQL/SQL/Analyzer.idr`) can only produce well-typed
  expressions. A SQL type error becomes a `SemanticError` at the point where
  a `TExpr` cannot be built.
- A logical plan `LPlan ctx` and a physical plan `PPlan ctx` are indexed by
  the shape of the rows they produce. The optimizer's rewrites have type
  `LPlan ctx -> LPlan ctx` and the planner's `LPlan ctx -> PPlan ctx`, so
  neither can change the number or types of a query's columns.
- A scan of table `tbl` produces `Row (tableCtx tbl)`: the row shape is
  computed from the catalog entry.
- `decodeRow ts` returns a `Row ts` or an error. A stored row that does not
  match the declared column types cannot reach the executor.

`tests/typecheck/fail/AddTextToInteger.idr` and `ColumnOutsideRow.idr` are
programs the compiler must reject for these reasons.

What this does not say: that a rewrite preserves the query's meaning. See
"Tested".

### Page bounds for fixed offsets

`InPage off len` (`src/IdrisQL/Storage/Format.idr`) is evidence that the
bytes `off .. off+len-1` lie inside a 4096-byte page. The page accessors
`getU8`, `getU16`, `getU32`, `getBits64` and their setters
(`src/IdrisQL/Storage/Page.idr`) require it as an erased argument.

For a literal offset the compiler finds the evidence by evaluating the three
comparisons. Every page-header and meta-page field is read and written this
way, so a wrong constant in `Format.idr` that pointed outside the page would
not compile. `tests/typecheck/fail/ReadPastPage.idr` is the rejected
example; `pass/PageInBounds.idr` is the boundary case that compiles.

For an offset computed at run time the evidence comes from `checkRange`,
which is a runtime check. That part belongs to the next section.

### B+ tree cuts

`src/IdrisQL/Index/Node.idr` holds the pure functions that decide where a
node splits and how two nodes share their cells. Proved about them:

| Statement | Name |
|---|---|
| The two parts of a cut, concatenated, are the original list: nothing lost, duplicated or reordered | `Cut.preserves`, a field of every `Cut` |
| The left part of a cut of a non-empty list is non-empty | `cutLeftNonEmpty` |
| The right part of a cut of a list with at least two elements is non-empty | `cutRightNonEmpty` |
| Joining two nodes and cutting the result keeps every cell of both | `recutPreserves` |
| A three-way cut (left, separator, right) reassembles to the original | `Cut3.preserves` |
| Inserting one element makes a list one longer | `insertAtLength` |

These are statements about lists of cells. The tree code reads cells from
pages, calls these functions, and writes the parts back. The reading and
writing are not proved; the tree as a whole is in "Tested".

### Transaction state of a typed session

`src/IdrisQL/Transaction/State.idr` offers the engine through
`Conn s`, where `s` is `Idle` or `Active`, held linearly inside
`withDatabase`.

| A session that does this | Is rejected because |
|---|---|
| Commits or rolls back with no transaction open | `commit` and `rollback` take `Conn Active` |
| Begins a transaction inside another | `begin` takes `Conn Idle` |
| Ends with a transaction open | `end` takes `Conn Idle` |
| Uses a connection after an operation consumed it | The connection is linear |
| Returns without handing the connection back | A session must return a `Closed`. Its constructor is private and `end`, the only function that makes one, takes the idle connection. |

A statement that fails inside a transaction returns `Fail` with a
`Conn Idle`, which is how the type records that the engine rolled the
transaction back.

`tests/typecheck/fail/` has one rejected program per row.

A caveat observed while writing those tests: Idris 2 0.8.0 accepts a linear
variable that is never used when it was bound by a pattern-matching `<-`, as
in `Ok _ c1 <- execute c0 ...` followed by code that ignores `c1`. The first
version of this API (`connect` and `disconnect`) depended on the compiler
rejecting that, and a program that dropped its connection compiled. The
`Closed` design does not depend on it: a session that drops its connection
has nothing to pass to `end`. The plain API in `src/IdrisQL.idr` has no such
guarantee; there, closing a database is the caller's responsibility.

### Byte ranges

The constructor of `Bytes` (`src/IdrisQL/Storage/Codec.idr`) is private to
its module. Code outside it can obtain a `Bytes` only from functions that
check the range against the buffer first.

## Runtime-validated

| Invariant | Where | On violation |
|---|---|---|
| A page read from disk matches its checksum and is 4096 bytes | `BufferPool.loadFile` | `Corrupt` |
| A log record matches its checksum | `WAL.scanWal` | Replay stops there |
| The log belongs to this database, checked before any of it is replayed | `Pager.openDatabase` | `Corrupt` |
| Format version and page size are ones this build reads | `Pager.readMeta` | `Unsupported` |
| A computed page offset is in range | `Format.checkRange`, via `Page.readU16` and others | `Corrupt` |
| Slot offsets and key ranges inside the tree search loop are in range | `Page.searchSlots`, plain comparisons before each raw read | `Corrupt` |
| A page has the type its position in the tree requires | `BPlusTree` | `Corrupt` |
| A stored row's tags match the table's column types, also in columns the query does not read | `Record.decodeRow` | `Corrupt` |
| Tree descent ends | Depth limit of 64 | `Corrupt` |
| Overflow and free-list walks end | Bounded by the recorded length and count | `Corrupt` |
| Keys strictly ascending and inside the range set by the ancestors' separators; all leaves at one depth; the leaf chain visits exactly the leaves, in order; no page reachable twice; free-space accounting and overflow lengths correct | `BPlusTree.validate`, run by `.check` | Reported |
| Every page is in exactly one tree or on the free list; every index has exactly one entry per row | `Engine.integrityCheck`, run by `.check` | Reported |
| NOT NULL, UNIQUE, PRIMARY KEY, CHECK | `Engine`, before a row is written | `ConstraintViolation` |
| Parameter values have the inferred types | `Statement.checkParams` | `RuntimeError` |
| A query's rows are read only while its statement is the latest on the connection | `Engine.current` | `RuntimeError` |
| No statement runs after a failure in commit, checkpoint or rollback | `Pager.guarded`, `Pager.ensureUsable` | `IOFailure` until reopen |
| A failure after the commit point is not reported as a rollback | `Pager.commitTxn` | `CommittedThenFailed` |

## Tested

Figures are from the reference machine in `docs/PLATFORM_CONSTRAINTS.md`.

| Property | Test | Size |
|---|---|---|
| Lexer and parser accept the supported grammar, reject the rest with a position | `sql-frontend` suite | 192 tests |
| Pages, codecs, pager, free list, B+ tree, recovery | `storage` suite | 44 tests, including the next two rows |
| B+ tree agrees with a sorted-map model under random inserts, overwrites and deletes, and validates afterwards | `storage` suite, seeds 20261121 and 7 | 6,000 operations per seed |
| Recovery leaves exactly the committed transactions when any single write fails or is torn | `storage` suite crash sweeps | 5 configurations, every write of the transaction in each |
| SQL semantics: three-valued logic, constraints, joins, aggregates, ordering, parameters, transactions, DDL rollback | `sql` suite | 47 tests |
| Queries return the same rows with and without indexes, and after `ANALYZE` | `sql` suite | 14 queries, 3 indexes |
| Random statements agree with a model, in autocommit and inside transactions | `sql` suite, seed 20261121 | 1,100 statements |
| EXPLAIN prints the plan the planner chose | `sql` suite | Exact plan text for 14 statements |
| The optimizer and planner preserve results | Indirectly, by every test above and by the differential tests | |
| Results equal SQLite's | `tests/differential/run.sh` | 86 queries before and after 12 data changes, 7 rejected statements: 180 checks |
| Results equal SQLite's at 200,000 rows with a pool smaller than the data | `bench/run.sh` | 9 phases, 4,212 queries |
| A killed process loses no acknowledged commit and leaves no partial transaction | `tests/crash/run.sh` | 40 kills per run |
| Typed sessions, page bounds and typed expressions accept and reject what they should | `typed` suite and `tests/typecheck` | 1 run; 3 programs that compile, 8 that are rejected |

## Assumed

| Assumption | Why it matters |
|---|---|
| The Idris 2 compiler, its `base` library and Chez Scheme are correct | Everything above is relative to them |
| After `fflush` returns, the operating system holds the bytes and returns them to later reads, also after the process dies | Commit durability |
| `createDir` is atomic and fails when the directory exists | The lock |
| No other program writes into the database directory | Page files have no protection beyond a checksum |
| A torn write changes the page's 32-bit hash | The checksum is not a CRC and is not designed against adversaries |
| Two databases never get the same id: a nanosecond clock reading mixed with the process id | The id is what pairs a log with its database |

## Known limitations

| Limitation | Detail |
|---|---|
| No proof that the optimizer preserves meaning | Types fix the result shape only |
| No proof of B+ tree invariants across operations | Model-tested, and validated on demand |
| No proof of recovery | Fault-injected and kill-tested |
| Termination of 23 modules is unproved | Bounded at run time where a corrupted structure could loop, with one exception in the next row |
| A scan follows leaf links without a bound | A corrupted leaf chain that forms a cycle makes a scan loop. `.check` detects the cycle. |
| Unused linear pattern variables are accepted by the compiler | Described under "Transaction state of a typed session" |
| Power loss | Outside what the platform allows; see `docs/TRANSACTIONS.md` |
| A misdirected write is not detected | The checksum does not cover the page number, so a whole valid page in the wrong file passes |
| A non-root leaf can stay empty after deletes | Counted by the validator, not treated as damage |
