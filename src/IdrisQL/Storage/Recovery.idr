module IdrisQL.Storage.Recovery

import Data.IORef
import Data.SortedSet
import IdrisQL.Error
import public IdrisQL.Options
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Page
import IdrisQL.Storage.WAL

||| Redo-only recovery in two sequential passes over the log, so memory use
||| does not grow with the log: the first pass collects the ids of committed
||| transactions, the second writes their page images to the page files in
||| log order. Page files never hold uncommitted data, so there is nothing
||| to undo. Running it twice gives the same page files.
export
recover : Pool -> (walPath : String) -> (hostLittle : Bool) -> DB (RecoveryInfo, WalScan)
recover pool walPath hostLittle = do
  committed <- newIORef (the (SortedSet Int) empty)
  scan <- scanWal walPath hostLittle $ \r => case r of
    WalCommit tx => modifyIORef committed (insert tx)
    WalPage _ _ _ => pure ()
  txs <- readIORef committed
  redone <- newIORef 0
  discarded <- newIORef 0
  _ <- scanWal walPath hostLittle $ \r => case r of
    WalCommit _ => pure ()
    WalPage tx pageId page =>
      if contains tx txs
        then writeStorePage pool pageId page >> modifyIORef redone (+ 1)
        else modifyIORef discarded (+ 1)
  let info = MkRecoveryInfo scan.present (cast (length (Prelude.toList txs)))
               !(readIORef redone) !(readIORef discarded) scan.tornTail
  pure (info, scan)
