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
| A statement rejected before it runs (syntax, unknown name, type error) | Error; an open transaction stays open |
| A query that fails while producing rows | Error; an open transaction stays open |
| A writing statement that fails while running (constraint violation, overflow, I/O error) | The whole transaction is rolled back, including an explicit one |
| Closing with a transaction open | The transaction is rolled back |

The second-to-last row differs from SQLite, which undoes only the failed
statement. IdrisQL has no statement-level undo: the log is redo-only and
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

If step 1 or 2 fails, the transaction is rolled back. If any write to the
log or a page file fails, the connection refuses further work until the
database is reopened, because the pool can no longer be trusted to match the
disk.

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

1. Delete everything in `spill/` and `tmp/`.
2. Read the log to the first record that is incomplete or fails its
   checksum, collecting the ids of transactions that have a commit record.
3. Read it again and write each page image that belongs to a committed
   transaction to its page file, in log order.
4. Empty the log.

Two passes keep memory use independent of the log's length. Running recovery
twice gives the same page files, so a crash during recovery is repaired by
the next open.

A page file that was being written when the process died can be short or
empty. Its image is in the log (the checkpoint that would discard it had not
finished), so step 3 replaces it.

The shell reports what recovery did on standard error, for example:

```
recovered 3 committed transactions (9 pages) from the write-ahead log; discarded 5 pages of unfinished transactions
```

The same figures are available to a program as `recovery db`.

## How this is tested

| Test | What it does | Result recorded on the reference machine |
|---|---|---|
| `storage` suite, crash sweeps (`src/Tests/Storage.idr`) | Runs a workload, makes the Nth storage write fail, for every N, with and without writing half of the failing write; abandons the pager without cleanup; reopens and compares with a model. Repeated with a checkpoint after every commit and with a pool small enough to spill. | All pass |
| `sql` suite, crash sweep (`src/Tests/Sql.idr`) | The same at SQL level over a transaction that updates, deletes, inserts and creates a table, with two indexes: after recovery the database equals the state before or the state after, never a mixture, and the integrity check passes. | Passes for every write of the transaction |
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
