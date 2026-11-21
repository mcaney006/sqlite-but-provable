# Transactions, durability and recovery

## What a commit guarantees

| Event after `COMMIT` returns | Committed data |
|---|---|
| The process exits, crashes, or is killed with SIGKILL | Survives |
| The operating system crashes or the machine loses power | May be lost, and the database may be left unreadable |

The reason for the second row is in `docs/PLATFORM_CONSTRAINTS.md`: Idris 2's
`base` library has `fflush`, which hands bytes to the operating system, and
nothing that forces them to the device. The engine names this level
`FlushedToOS` (`src/IdrisQL/Options.idr`) and the library function
`durability` returns it. No setting raises it.

Atomicity and isolation do not depend on that caveat for process failures: a
transaction interrupted by the death of the process leaves no trace after the
next open.

## Concurrency model

One process holds a database at a time, through one connection, and runs one
statement at a time. Transactions are therefore serial, which is the
strictest isolation level, and there is no lock manager, deadlock detection
or snapshot machinery.

Opening creates the directory `LOCK` inside the database directory;
`createDir` fails if it exists, and a second process is refused with the
error `Locked`. Closing removes it.

A process that dies leaves `LOCK` behind. `base` cannot test whether a
process is alive, so the engine cannot tell a dead owner from a live one.
`--break-lock` (or `breakLock` in `Options`) takes the lock over. Passing it
while another process still has the database open lets two writers run at
once and corrupts the database; an early version of `tests/crash/run.sh` did
exactly that by accident and the integrity check reported broken trees within
one round.

## Transaction boundaries

| Situation | Behaviour |
|---|---|
| A writing statement with no transaction open | Runs in its own transaction and commits |
| `BEGIN` .. `COMMIT` | One transaction. `END` is a synonym for `COMMIT`. |
| `ROLLBACK` | Undoes everything since `BEGIN`, including schema changes |
| `BEGIN` inside a transaction, `COMMIT` or `ROLLBACK` outside one | Error; nothing changes |
| A statement rejected when it is compiled: a syntax error, or an unknown name or type error in a query, `INSERT`, `UPDATE` or `DELETE` | Error; an open transaction stays open |
| A query that fails while producing rows | Error; an open transaction stays open |
| A writing statement that fails while running: a constraint violation, an overflow, an I/O error, or a schema statement whose names do not check out (`DROP TABLE` of a missing table, `CREATE TABLE` of an existing one) | The whole transaction is rolled back, including an explicit one |
| Any failure through the typed session API | The transaction is rolled back, and the connection comes back idle |
| Closing with a transaction open | The transaction is rolled back |

The row about writing statements differs from SQLite, which undoes only the
failed statement. Schema statements are in that row because they check
their names when they run, not when they are compiled. IdrisQL has no statement-level undo: the log is redo-only and
there are no savepoints. Rolling back the transaction is the only way to
guarantee that a half-applied statement leaves nothing behind. The shell
prints `The open transaction was rolled back.` when this happens.

`UPDATE` and `DELETE` collect the rowids they will change before changing
anything, so a statement never sees its own writes. That list is held in
memory.

A query's rows are produced as they are read. Running another statement on
the same connection ends the earlier query's result, and reading from it
after that fails with a runtime error.

## Where pages live

A page in the buffer pool is in one of three states.

| State | Meaning | If evicted |
|---|---|---|
| Clean | Same as its page file | Dropped |
| DirtyCommitted | Changed by a committed transaction and not yet in its page file. Its image is in the log. | Written to its page file |
| DirtyTxn | Changed by the open transaction | Written to `spill/<page>.pg` |

Page files never receive uncommitted data. That is what makes the log
redo-only: recovery has nothing to undo.

When the open transaction changes a DirtyCommitted page, the pool keeps a
copy of the committed image. Rollback restores it. If the frame is evicted
first, the committed copy goes to the page file and the uncommitted version
to `spill/`.

A transaction larger than the pool is bounded by disk, not memory: its pages
move to `spill/` as the pool fills.

## Commit

1. Append the full 4096-byte image of every page the transaction changed to
   the log.
2. Append a commit record and `fflush` the log. This is the commit point.
3. Mark those pages DirtyCommitted; copy any that are in `spill/` to their
   page files; empty `spill/`.

The log is written a page image at a time. A transaction that changes one
row in each of 50 pages logs 50 pages, about 200 KiB.

What a failure means depends on where it happens.

| Failure | Result |
|---|---|
| In step 1 or 2 | The transaction is reported as failed and rolled back, and the connection refuses every later statement until the database is reopened. If the commit record did reach the file in spite of the error, the next open will treat the transaction as committed. |
| In step 3, or in the checkpoint that may follow | The error is `CommittedThenFailed`: the transaction is committed and will be there after reopening. The connection refuses every later statement, because its pool may no longer match the disk. |
| Writing an evicted page to `spill/` or to its page file during a statement | The statement fails and its transaction is rolled back. The connection stays usable. |
| During a rollback | The connection refuses every later statement until the database is reopened. |

## Checkpoint

After a commit that leaves the log at or above `checkpointBytes` (4 MiB by
default; `--checkpoint` in the shell), and at close:

1. Write every DirtyCommitted page to its page file.
2. Empty the log by reopening it for truncating write, and give it a new
   salt.

A crash during step 1 leaves the log whole, and recovery writes the same
images again. A crash during step 2 leaves either the old log or an empty
one, and the page files are already complete.

## Recovery

Every open runs recovery before anything else.

1. Delete everything in `spill/`.
2. Read the log to the first record that is incomplete or fails its
   checksum, collecting the ids of transactions that have a commit record.
   A read error is reported as an error, not taken for the end of the log.
3. Compare the log's database id with page 0's. A log written for another
   database is refused here, before any of it is applied. If page 0 cannot
   be read, the comparison is made after step 4.
4. Read the log again and write each page image that belongs to a committed
   transaction to its page file, in log order.
5. Empty the log.

`tmp/` is emptied after recovery.

Two passes keep memory use independent of the log's length. Running recovery
twice gives the same page files, so a crash during recovery is repaired by
the next open.

A page file that was being written when the process died can be short or
empty. Its image is in the log (the checkpoint that would discard it had not
finished), so step 4 replaces it.

The shell reports what recovery did on standard error, for example:

```
recovered 3 committed transactions (9 pages) from the write-ahead log; discarded 5 pages of unfinished transactions
```

The same figures are available to a program as `recovery db`.

## How this is tested

| Test | What it does | Result recorded on the reference machine |
|---|---|---|
| `storage` suite, crash sweeps (`src/Tests/Storage.idr`) | Runs a workload, makes the Nth storage write fail, for every N, with and without writing half of the failing write; abandons the pager without cleanup; reopens and compares with a model. Repeated with a checkpoint after every commit and with a pool small enough to spill. | All pass |
| `sql` suite, crash sweeps (`src/Tests/Sql.idr`) | The same at SQL level over a transaction that updates, deletes, inserts and creates a table, with two indexes. A transaction reported as committed is present after reopening; one reported as failed is absent; one that failed with `CommittedThenFailed` is present, and its connection refuses the next statement. Run with the log kept, and with a checkpoint after every commit and an 8-page pool. | Both pass for every write of the transaction |
| `tests/crash/run.sh` | Starts the real program on a workload of 20-row transactions, sends SIGKILL after 30 to 480 ms, reopens, and checks integrity, that every batch has exactly 20 rows, that batches are 1..m without a gap, and that m is at least the last batch the process reported. 40 rounds on one database, with a 64 KiB checkpoint threshold. | Two runs: 40 kills each; 33 and 36 recoveries replayed the log; 79,480 and 59,200 rows survived; 0 failures in both. The counts vary with timing. |

In-process fault injection and SIGKILL both leave the operating system
running. Neither test says anything about power loss.

## Limits of the transaction design

| Limit | Detail |
|---|---|
| No power-loss durability | See the first section |
| No statement-level rollback | A failed write ends the transaction |
| No savepoints or nested transactions | Not parsed |
| One connection | No concurrent readers |
| Log volume | Full page images, no deltas and no compression |
| Stale locks | Need `--break-lock` and the user's knowledge that no other process is running |
