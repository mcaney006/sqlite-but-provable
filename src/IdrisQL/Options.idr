module IdrisQL.Options

%default total

public export
record Options where
  constructor MkOptions
  ||| Buffer pool capacity in 4 KiB pages. This bounds the memory used for
  ||| database pages. The default is 2048 pages, 8 MiB.
  cachePages : Int
  ||| A commit that leaves the log at least this many bytes long triggers a
  ||| checkpoint.
  checkpointBytes : Int
  ||| Take over a lock left behind by a dead process. The caller asserts
  ||| that no other process has the database open.
  breakLock : Bool
  ||| Rows a sort keeps in memory before it writes a run to disk.
  sortMemoryRows : Nat

public export
defaultOptions : Options
defaultOptions = MkOptions 2048 4194304 False 50000

||| What a completed log flush guarantees. This build has one level because
||| base exposes `fflush` and nothing stronger.
public export
data Durability
  = ||| The bytes were handed to the operating system. They survive the death
    ||| of this process. A power failure or kernel crash can still lose them.
    FlushedToOS

public export
Show Durability where
  show FlushedToOS = "flushed to the operating system (no fsync)"

public export
record RecoveryInfo where
  constructor MkRecoveryInfo
  ||| A log with a complete header was present at open.
  walFound : Bool
  committedTxns : Int
  ||| Page images of committed transactions written back to page files.
  pagesRedone : Int
  ||| Page images of transactions that never committed.
  pagesDiscarded : Int
  ||| The log ended in an incomplete or damaged record.
  tornTail : Bool

public export
noRecovery : RecoveryInfo
noRecovery = MkRecoveryInfo False 0 0 0 False
