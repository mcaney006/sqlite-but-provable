module Tests.Storage

import Data.Buffer
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.String
import IdrisQL.Error
import IdrisQL.Index.BPlusTree
import IdrisQL.Index.Cursor
import IdrisQL.Index.KeyCodec
import IdrisQL.Storage.BufferPool
import IdrisQL.Storage.Codec
import IdrisQL.Storage.FileIO
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page
import IdrisQL.Storage.Pager
import IdrisQL.Storage.Recovery
import IdrisQL.Types
import Tests.Harness

-- Deterministic workloads. Every randomized test names its seed, so a
-- failure can be replayed exactly.

data Op = Put Int Int | Del Int

pad8 : Int -> String
pad8 k = let s = show k in pack (replicate (8 `minus` length s) '0') ++ s

-- Keys vary in length; the zero-padded number makes byte order numeric.
keyText : Int -> String
keyText k = pad8 k ++ pack (replicate (cast (k `mod` 23)) 'x')

-- About one value in eleven is large enough to need an overflow chain.
valText : Int -> Int -> String
valText k v = "v" ++ show v ++ ":" ++ show k ++ ":" ++ pack (replicate (cast len) 'y')
  where
    len : Int
    len = if (k + v) `mod` 11 == 0 then 3000 + (k `mod` 5000) else (k * 7 + v) `mod` 200

workload : (seed : Int) -> (ops : Nat) -> (keySpace : Int) -> List Op
workload seed ops keySpace = go seed ops 1
  where
    go : Int -> Nat -> Int -> List Op
    go _ Z _ = []
    go s (S n) version =
      let a = nextRandom s
          b = nextRandom a
          k = (b `div` 16) `mod` keySpace
      in (if (a `div` 16) `mod` 10 < 7 then Put k version else Del k) :: go b n (version + 1)

Model : Type
Model = SortedMap Int Int

runModel : List Op -> Model -> Model
runModel [] m = m
runModel (Put k v :: ops) m = runModel ops (insert k v m)
runModel (Del k :: ops) m = runModel ops (delete k m)

expected : Model -> List (String, String)
expected m = map (\(k, v) => (keyText k, valText k v)) (SortedMap.toList m)

putKV : Pager -> (root : Int) -> Int -> Int -> DB ()
putKV pg root k v = do
  key <- stringBytes (keyText k)
  val <- stringBytes (valText k v)
  ignore (put pg root key val)

applyOps : Pager -> (root : Int) -> List Op -> Model -> DB Model
applyOps pg root [] m = pure m
applyOps pg root (Put k v :: ops) m = do
  putKV pg root k v
  applyOps pg root ops (insert k v m)
applyOps pg root (Del k :: ops) m = do
  key <- stringBytes (keyText k)
  found <- delete pg root key
  expect (found == isJust (lookup k m)) ("delete of key " ++ show k ++ " disagrees with the model")
  applyOps pg root ops (delete k m)

contentsFrom : Pager -> (root : Int) -> Maybe Bytes -> DB (List (String, String))
contentsFrom pg root from = do
  c <- seek pg root from
  go c []
  where
    go : Cursor -> List (String, String) -> DB (List (String, String))
    go c acc = do
      Just (k, v) <- next c | Nothing => pure (reverse acc)
      ks <- liftIO (bytesString k)
      vs <- liftIO (bytesString v)
      go c ((ks, vs) :: acc)

-- Structural validation plus a full comparison against the model.
checkTree : Pager -> (root : Int) -> Model -> (what : String) -> DB TreeInfo
checkTree pg root model what = do
  info <- validate pg root
  got <- contentsFrom pg root Nothing
  let want = expected model
  expect (info.entries == cast (length want))
    (what ++ ": tree holds " ++ show info.entries ++ " entries, model " ++ show (length want))
  expect (got == want) (what ++ ": contents differ from the model")
  pure info

isCorrupt : DbError -> Bool
isCorrupt (Corrupt _) = True
isCorrupt _ = False

smallCache : Options
smallCache = MkOptions 16 4194304 False 50000

-- A fresh database. The catalog root (page 1) is an empty tree the tests
-- can use directly.
fresh : (name : String) -> Options -> DB (Storage, String, Pager)
fresh name opts = do
  st <- liftIO newStorage
  dir <- liftIO (freshPath name)
  pg <- createDatabase st dir opts
  pure (st, dir, pg)

inTransaction : Pager -> DB a -> DB a
inTransaction pg act = do
  beginTxn pg
  r <- act
  commitTxn pg
  pure r

cellFor : String -> String -> DB Bytes
cellFor k v = do
  key <- stringBytes k
  val <- stringBytes v
  mkLeafCell key val Nothing

pageTests : List Test
pageTests =
  [ dbTest "page: insert, delete and compaction keep every surviving cell" $ do
      p <- newPage
      liftIO (initPage p ptLeaf)
      -- Thirty cells inserted at slot 0, so the slot directory shifts each time.
      for_ (the (List Int) [0 .. 29]) $ \i => do
        cell <- cellFor ("k" ++ pad8 (29 - i)) (pack (replicate (cast (40 + i)) 'a'))
        ok <- insertCell p 0 cell
        expect ok "a cell did not fit an almost empty page"
      -- Delete the even slots, leaving holes.
      for_ (the (List Int) [14, 13 .. 0]) $ \i => deleteCell p (2 * i)
      n <- liftIO (slotCount p)
      expect (n == 15) ("15 cells should remain, found " ++ show n)
      -- Insert cells that only fit once the holes are compacted away.
      for_ (the (List Int) [0 .. 4]) $ \i => do
        cell <- cellFor ("z" ++ pad8 i) (pack (replicate 400 'b'))
        ok <- insertCell p (15 + i) cell
        expect ok "a cell did not fit after compaction should have made room"
      for_ (the (List Int) [0 .. 14]) $ \i => do
        c <- readLeafCell p i
        k <- liftIO (bytesString c.key)
        v <- liftIO (bytesString c.inline)
        expect (k == "k" ++ pad8 (2 * i + 1)) ("slot " ++ show i ++ " holds key " ++ k)
        expect (length v == cast (40 + (29 - (2 * i + 1)))) ("slot " ++ show i ++ " value length changed")
      used <- liftIO (usedBytes p)
      free <- liftIO (freeBytes p)
      expect (used + free == PageSize - HeaderSize) "used and free bytes do not add up"

  , dbTest "page: a full page refuses a cell and stays unchanged" $ do
      p <- newPage
      liftIO (initPage p ptLeaf)
      cell <- cellFor "key" (pack (replicate 900 'c'))
      rs <- traverse (\_ => insertCell p 0 cell) (the (List Int) [0 .. 5])
      expect (rs == [True, True, True, True, False, False]) ("unexpected fits: " ++ show rs)
      n <- liftIO (slotCount p)
      expect (n == 4) "a refused insert changed the slot count"

  , dbTest "page: the checksum catches a changed byte" $ do
      little <- hostLittleEndian
      p <- newPage
      liftIO (initPage p ptLeaf)
      cell <- cellFor "key" "value"
      _ <- insertCell p 0 cell
      liftIO (sealPage little p)
      ok <- liftIO (verifyPage little p)
      expect ok "a freshly sealed page fails verification"
      writeU16 p 2000 0xBEEF
      bad <- liftIO (verifyPage little p)
      expect (not bad) "a modified page still verifies"

  , dbTest "page: a slot offset outside the cell area is an error, not a read" $ do
      p <- newPage
      liftIO (initPage p ptLeaf)
      cell <- cellFor "key" "value"
      _ <- insertCell p 0 cell
      writeU16 p HeaderSize 7
      expectError "slot into header" (readLeafCell p 0) isCorrupt
      writeU16 p HeaderSize 5000
      expectError "slot past page" (readLeafCell p 0) isCorrupt

  , dbTest "page: a cell whose lengths run past the page end is rejected" $ do
      p <- newPage
      liftIO (initPage p ptLeaf)
      cell <- cellFor "key" "value"
      _ <- insertCell p 0 cell
      off <- slotOffset p 0
      writeU16 p off 60000
      expectError "oversized key length" (cellCopy p 0) isCorrupt
      expectError "oversized key length" (readLeafCell p 0) isCorrupt

  , dbTest "page: accessors refuse offsets outside the page" $ do
      p <- newPage
      expectError "read at 4095" (readU16 p 4095) isCorrupt
      expectError "read at -1" (readU8 p (-1)) isCorrupt
      expectError "write at 4094" (writeU32 p 4094 1) isCorrupt
      expectError "huge length" (readAt p 0 5000) isCorrupt
  ]

orderAgrees : (t : SqlType) -> List (Val t) -> DB ()
orderAgrees t vals = for_ vals $ \a => for_ vals $ \b => do
  ka <- keyPrefix [t] [Just a]
  kb <- keyPrefix [t] [Just b]
  o <- liftIO (compareBytes ka kb)
  expect (o == compareVal t a b) ("key order disagrees with value order for " ++ show t)

codecTests : List Test
codecTests =
  [ dbTest "codec: integers, doubles and strings round-trip" $ do
      bd <- newBuilder 4
      let ints = the (List Int64) [0, 1, -1, 255, 256, 9223372036854775807, -9223372036854775808]
      let reals = the (List Double) [0.0, 1.5, -2.25, 1.0e308, 4.9e-324, 149.99]
      let texts = ["", "plain", "quote ' and \"", "caf\233 \955 \128512"]
      traverse_ (putI64 bd) ints
      traverse_ (putDouble bd) reals
      traverse_ (putString bd) texts
      putU16 bd 65535
      putU32 bd 4294967295
      bytes <- finish bd
      d <- newDecoder bytes
      ints' <- traverse (\_ => takeI64 d) ints
      reals' <- traverse (\_ => takeDouble d) reals
      texts' <- traverse (\_ => takeString d) texts
      a <- takeU16 d
      b <- takeU32 d
      expect (ints' == ints) ("integers changed: " ++ show ints')
      expect (reals' == reals) ("doubles changed: " ++ show reals')
      expect (texts' == texts) ("strings changed: " ++ show texts')
      expect (a == 65535 && b == 4294967295) "unsigned fields changed"
      left <- liftIO (remaining d)
      expect (left == 0) "decoder did not consume everything"

  , dbTest "codec: reading past the end is an error" $ do
      bytes <- packBytes [1, 2, 3]
      d <- newDecoder bytes
      expectError "u32 from 3 bytes" (takeU32 d) isCorrupt
      d2 <- newDecoder bytes
      _ <- takeU8 d2
      expectError "string with a length that overruns" (takeString d2) isCorrupt

  , dbTest "codec: multi-byte fields are little-endian on disk" $ do
      bd <- newBuilder 8
      putU32 bd 0x01020304
      bytes <- finish bd
      raw <- liftIO (unpackBytes bytes)
      expect (raw == [4, 3, 2, 1]) ("u32 stored as " ++ show raw)

  , dbTest "keys: byte order matches value order for every type" $ do
      orderAgrees TInt [-9223372036854775808, -65536, -1, 0, 1, 255, 256, 65536, 9223372036854775807]
      orderAgrees TReal [-1.0e300, -2.5, -1.0e-300, 0.0, 1.0e-300, 1.5, 2.5, 1.0e300]
      orderAgrees TText ["", "a", "a\0", "a\0b", "aa", "ab", "b", "\233", "\955"]
      orderAgrees TBool [False, True]
      orderAgrees TBlob [[], [0], [0, 0], [0, 255], [1], [255]]

  , dbTest "keys: NULL sorts before every value and rowids order numerically" $ do
      n <- keyPrefix [TInt] [Nothing]
      v <- keyPrefix [TInt] [Just (-9223372036854775808)]
      o <- liftIO (compareBytes n v)
      expect (o == LT) "NULL does not sort first"
      let ids = the (List Int64) [-5, -1, 0, 1, 2, 1000, 9223372036854775807]
      keys <- traverse rowidKey ids
      back <- traverse keyRowid keys
      expect (back == ids) "rowid keys do not decode to the same rowids"
      for_ (zip keys (drop 1 keys)) $ \(a, b) => do
        o <- liftIO (compareBytes a b)
        expect (o == LT) "rowid keys are not ascending"

  , dbTest "keys: -0.0 and 0.0 share a key" $ do
      a <- keyPrefix [TReal] [Just 0.0]
      b <- keyPrefix [TReal] [Just (negate 0.0)]
      o <- liftIO (compareBytes a b)
      expect (o == EQ) "-0.0 and 0.0 encode differently"
  ]

pagerTests : List Test
pagerTests =
  [ dbTest "pager: a new database reopens with its header intact" $ do
      (st, dir, pg) <- fresh "pager-reopen.idb" defaultOptions
      closeDatabase pg
      pg2 <- openDatabase st dir defaultOptions
      n <- metaU32 pg2 offPageCount
      root <- metaU32 pg2 offCatalogRoot
      expect (n == 2 && root == 1) ("page count " ++ show n ++ ", catalog root " ++ show root)
      closeDatabase pg2

  , dbTest "pager: a second open of the same directory is refused" $ do
      (st, dir, pg) <- fresh "pager-lock.idb" defaultOptions
      expectError "second open" (openDatabase st dir defaultOptions)
        (\e => case e of
                 Locked _ => True
                 _ => False)
      closeDatabase pg
      pg2 <- openDatabase st dir defaultOptions
      closeDatabase pg2

  , dbTest "pager: opening a directory without a database fails cleanly" $ do
      st <- liftIO newStorage
      dir <- liftIO (freshPath "pager-absent.idb")
      expectError "open of nothing" (openDatabase st dir defaultOptions)
        (\e => case e of
                 IOFailure _ => True
                 _ => False)

  , dbTest "pager: freed pages are reused before the file grows" $ do
      (st, dir, pg) <- fresh "pager-freelist.idb" defaultOptions
      ids <- inTransaction pg (traverse (\_ => allocPage pg ptLeaf) (the (List Int) [1 .. 10]))
      expect (ids == [2 .. 11]) ("first allocations were " ++ show ids)
      inTransaction pg (traverse_ (freePage pg) [3, 5, 7])
      listed <- freeListPages pg
      expect (sort listed == [3, 5, 7]) ("free list holds " ++ show listed)
      again <- inTransaction pg (traverse (\_ => allocPage pg ptLeaf) (the (List Int) [1 .. 4]))
      expect (sort again == [3, 5, 7, 12]) ("reallocation returned " ++ show again)
      closeDatabase pg

  , dbTest "pager: rollback discards page changes and allocations" $ do
      (st, dir, pg) <- fresh "pager-rollback.idb" defaultOptions
      m <- inTransaction pg (applyOps pg 1 (workload 11 300 200) empty)
      before <- metaU32 pg offPageCount
      beginTxn pg
      _ <- applyOps pg 1 (workload 12 400 400) m
      rollbackTxn pg
      after <- metaU32 pg offPageCount
      expect (after == before) ("page count went from " ++ show before ++ " to " ++ show after)
      _ <- checkTree pg 1 m "after rollback"
      closeDatabase pg

  , dbTest "pager: writing outside a transaction is refused" $ do
      (st, dir, pg) <- fresh "pager-notxn.idb" defaultOptions
      expectError "alloc without transaction" (allocPage pg ptLeaf)
        (\e => case e of
                 TxError _ => True
                 _ => False)
      closeDatabase pg

  , dbTest "pager: a damaged header page is reported at open" $ do
      (st, dir, pg) <- fresh "pager-badmeta.idb" defaultOptions
      closeDatabase pg
      buf <- alloc PageSize
      _ <- readFileInto st (storePath dir 0) buf PageSize
      liftIO (wrU8 buf 40 0x5A)
      writeFileFrom st (storePath dir 0) buf PageSize
      expectError "open with damaged page 0" (openDatabase st dir defaultOptions) isCorrupt
      -- The failed open must not leave the lock behind.
      liftIO (wrU8 buf 40 0)
      expectError "open with damaged page 0 again" (openDatabase st dir defaultOptions)
        (\e => case e of
                 Locked _ => False
                 _ => True)
  ]

treeRun : (name : String) -> List Op -> Test
treeRun name ops = dbTest ("b+tree: " ++ name) $ do
  (st, dir, pg) <- fresh ("tree-" ++ name ++ ".idb") defaultOptions
  m <- inTransaction pg (applyOps pg 1 ops empty)
  info <- checkTree pg 1 m "after load"
  expect (info.depth >= 2) ("expected the tree to have split; depth " ++ show info.depth)
  closeDatabase pg
  pg2 <- openDatabase st dir defaultOptions
  _ <- checkTree pg2 1 m "after reopen"
  closeDatabase pg2

treeTests : List Test
treeTests =
  [ treeRun "ascending-inserts" (map (\k => Put k 1) [0 .. 2999])
  , treeRun "descending-inserts" (map (\k => Put k 1) [2999, 2998 .. 0])
  , treeRun "random-seed-20261121" (workload 20261121 6000 2500)
  , treeRun "random-seed-7" (workload 7 6000 800)

  , dbTest "b+tree: overwriting moves values between inline and overflow storage" $ do
      (st, dir, pg) <- fresh "tree-overwrite.idb" defaultOptions
      let ops = concatMap (\v => map (\k => Put k v) (the (List Int) [0 .. 199])) (the (List Int) [1 .. 6])
      m <- inTransaction pg (applyOps pg 1 ops empty)
      info <- checkTree pg 1 m "after six overwrites"
      expect (info.overflowPages > 0) "no value used an overflow chain"
      closeDatabase pg

  , dbTest "b+tree: deleting everything returns every page to the free list" $ do
      (st, dir, pg) <- fresh "tree-drain.idb" defaultOptions
      m <- inTransaction pg (applyOps pg 1 (workload 3 4000 1500) empty)
      _ <- checkTree pg 1 m "after load"
      let dels = map (Del . fst) (SortedMap.toList m)
      m2 <- inTransaction pg (applyOps pg 1 dels m)
      info <- checkTree pg 1 m2 "after deleting all"
      expect (info.depth == 1 && info.leaves == 1) ("root did not contract: depth " ++ show info.depth)
      pages <- metaU32 pg offPageCount
      free <- metaU32 pg offFreeCount
      listed <- freeListPages pg
      expect (free == pages - 2 && cast (length listed) == free)
        (show pages ++ " pages, " ++ show free ++ " free, list of " ++ show (length listed))
      closeDatabase pg

  , dbTest "b+tree: deletes in ascending and descending order keep the tree valid" $ do
      (st, dir, pg) <- fresh "tree-ordered-delete.idb" defaultOptions
      m <- inTransaction pg (applyOps pg 1 (map (\k => Put k 1) [0 .. 2999]) empty)
      m2 <- inTransaction pg (applyOps pg 1 (map Del [0 .. 999]) m)
      _ <- checkTree pg 1 m2 "after deleting the low third"
      m3 <- inTransaction pg (applyOps pg 1 (map Del [2999, 2998 .. 2000]) m2)
      _ <- checkTree pg 1 m3 "after deleting the high third"
      closeDatabase pg

  , dbTest "b+tree: a range scan starts at the first key not below its bound" $ do
      (st, dir, pg) <- fresh "tree-range.idb" defaultOptions
      m <- inTransaction pg (applyOps pg 1 (map (\k => Put (2 * k) 1) [0 .. 999]) empty)
      from <- stringBytes (pad8 1001)
      got <- contentsFrom pg 1 (Just from)
      let want = expected (fromList (filter (\(k, _) => k >= 1002) (SortedMap.toList m)))
      expect (got == want) ("range scan returned " ++ show (length got) ++ " rows, expected " ++ show (length want))
      past <- stringBytes "99999999"
      none <- contentsFrom pg 1 (Just past)
      expect (isNil none) "a scan past the last key returned rows"
      closeDatabase pg

  , dbTest "b+tree: lookups find present keys and miss absent ones" $ do
      (st, dir, pg) <- fresh "tree-lookup.idb" defaultOptions
      m <- inTransaction pg (applyOps pg 1 (workload 5 3000 3000) empty)
      for_ (the (List Int) [0, 10 .. 2990]) $ \k => do
        key <- stringBytes (keyText k)
        r <- lookup pg 1 key
        got <- case r of
                 Nothing => pure Nothing
                 Just b => map Just (liftIO (bytesString b))
        expect (got == map (valText k) (lookup k m)) ("lookup of key " ++ show k ++ " is wrong")
      last <- lastKey pg 1
      lastText <- case last of
                    Nothing => pure ""
                    Just b => liftIO (bytesString b)
      expect (Just lastText == map (keyText . fst) (rightMost m)) "lastKey is not the greatest key"
      closeDatabase pg

  , dbTest "b+tree: a key over the size limit is refused" $ do
      (st, dir, pg) <- fresh "tree-bigkey.idb" defaultOptions
      beginTxn pg
      key <- stringBytes (pack (replicate 1001 'k'))
      val <- stringBytes "v"
      expectError "oversized key" (put pg 1 key val)
        (\e => case e of
                 RuntimeError _ => True
                 _ => False)
      rollbackTxn pg
      closeDatabase pg

  , dbTest "b+tree: maximum-size keys still split and merge correctly" $ do
      (st, dir, pg) <- fresh "tree-maxkeys.idb" defaultOptions
      let keyOf = \k => pad8 k ++ pack (replicate 990 'k')
      beginTxn pg
      for_ (the (List Int) [0 .. 119]) $ \k => do
        key <- stringBytes (keyOf k)
        val <- stringBytes (show k)
        ignore (put pg 1 key val)
      commitTxn pg
      info <- validate pg 1
      expect (info.entries == 120 && info.depth >= 3) ("entries " ++ show info.entries ++ ", depth " ++ show info.depth)
      beginTxn pg
      for_ (the (List Int) [0 .. 109]) $ \k => do
        key <- stringBytes (keyOf k)
        found <- delete pg 1 key
        expect found ("key " ++ show k ++ " vanished")
      commitTxn pg
      info2 <- validate pg 1
      expect (info2.entries == 10) ("entries after delete: " ++ show info2.entries)
      closeDatabase pg

  , dbTest "b+tree: a workload larger than the buffer pool spills and still commits" $ do
      (st, dir, pg) <- fresh "tree-spill.idb" smallCache
      m <- inTransaction pg (applyOps pg 1 (workload 9 5000 4000) empty)
      stats <- pagerStats pg
      expect (stats.pool.spills > 0) "the transaction never spilled; the test is not exercising eviction"
      expect (stats.pool.cached <= 16) ("pool holds " ++ show stats.pool.cached ++ " pages, capacity 16")
      _ <- checkTree pg 1 m "after commit with spills"
      beginTxn pg
      _ <- applyOps pg 1 (workload 10 3000 4000) m
      rollbackTxn pg
      _ <- checkTree pg 1 m "after rollback with spills"
      leftovers <- listDirectory (dir ++ "/spill")
      expect (isNil (filter (\n => n /= "." && n /= "..") leftovers)) "spill files remain after rollback"
      closeDatabase pg
      pg2 <- openDatabase st dir smallCache
      _ <- checkTree pg2 1 m "after reopen"
      closeDatabase pg2
  ]

-- Recovery. "Crash" means `abandonDatabase`: the connection is dropped with
-- no rollback and no checkpoint, as when the process is killed.

crashSweep : (name : String) -> Options -> (torn : Bool) -> Test
crashSweep name opts torn = dbTest ("recovery: " ++ name) $ do
  let baseOps = workload 101 400 300
  let txnOps = workload 202 250 300
  let base = runModel baseOps empty
  let after = runModel txnOps base
  -- Count the writes the transaction needs when nothing fails.
  (st0, dir0, pg0) <- fresh ("crash-" ++ name ++ "-probe.idb") opts
  _ <- inTransaction pg0 (applyOps pg0 1 baseOps empty)
  before <- liftIO (storageStats st0)
  _ <- inTransaction pg0 (applyOps pg0 1 txnOps base)
  done <- liftIO (storageStats st0)
  closeDatabase pg0
  let writes = done.writeOps - before.writeOps
  expect (writes > 20) ("the transaction made only " ++ show writes ++ " writes")
  for_ (the (List Int) [0 .. writes]) $ \k => do
    (st, dir, pg) <- fresh ("crash-" ++ name ++ ".idb") opts
    _ <- inTransaction pg (applyOps pg 1 baseOps empty)
    liftIO (injectFault st k torn)
    r <- liftIO (runDB (inTransaction pg (applyOps pg 1 txnOps base)))
    liftIO (abandonDatabase pg)
    liftIO (clearFault st)
    pg2 <- openDatabase st dir opts
    _ <- validate pg2 1
    got <- contentsFrom pg2 1 Nothing
    let where_ = " (fault after " ++ show k ++ " of " ++ show writes ++ " writes)"
    case r of
      Right _ => expect (got == expected after) ("a transaction that reported commit was lost" ++ where_)
      Left _ => expect (got == expected base || got == expected after)
                  ("recovered state is neither the old nor the new one" ++ where_)
    free <- freeListPages pg2
    closeDatabase pg2

rawFile : Storage -> String -> DB (Buffer, Int)
rawFile st path = do
  buf <- alloc 33554432
  Just n <- readFileInto st path buf 33554432
    | Nothing => failWith (path ++ " does not exist")
  pure (buf, n)

recoveryTests : List Test
recoveryTests =
  [ dbTest "recovery: committed transactions survive a crash before any checkpoint" $ do
      (st, dir, pg) <- fresh "rec-redo.idb" defaultOptions
      m1 <- inTransaction pg (applyOps pg 1 (workload 31 1500 900) empty)
      m2 <- inTransaction pg (applyOps pg 1 (workload 32 1500 900) m1)
      liftIO (abandonDatabase pg)
      pg2 <- openDatabase st dir defaultOptions
      let info = pagerRecovery pg2
      expect (info.walFound && info.committedTxns == 2 && info.pagesRedone > 0)
        ("recovery saw " ++ show info.committedTxns ++ " transactions, redid " ++ show info.pagesRedone ++ " pages")
      _ <- checkTree pg2 1 m2 "after recovery"
      closeDatabase pg2

  , dbTest "recovery: an uncommitted transaction leaves no trace" $ do
      (st, dir, pg) <- fresh "rec-uncommitted.idb" smallCache
      m <- inTransaction pg (applyOps pg 1 (workload 41 800 500) empty)
      beginTxn pg
      _ <- applyOps pg 1 (workload 42 3000 3000) m
      liftIO (abandonDatabase pg)
      pg2 <- openDatabase st dir smallCache
      _ <- checkTree pg2 1 m "after recovery"
      leftovers <- listDirectory (dir ++ "/spill")
      expect (isNil (filter (\n => n /= "." && n /= "..") leftovers)) "spill files survived recovery"
      closeDatabase pg2

  , dbTest "recovery: running it twice gives the same database" $ do
      (st, dir, pg) <- fresh "rec-twice.idb" defaultOptions
      m <- inTransaction pg (applyOps pg 1 (workload 51 2000 1200) empty)
      liftIO (abandonDatabase pg)
      pg2 <- openDatabase st dir defaultOptions
      liftIO (abandonDatabase pg2)
      pg3 <- openDatabase st dir defaultOptions
      _ <- checkTree pg3 1 m "after second recovery"
      closeDatabase pg3

  , dbTest "recovery: a log cut inside the last commit drops only that transaction" $ do
      (st, dir, pg) <- fresh "rec-truncated.idb" defaultOptions
      m1 <- inTransaction pg (applyOps pg 1 (workload 61 900 700) empty)
      _ <- inTransaction pg (applyOps pg 1 (workload 62 900 700) m1)
      liftIO (abandonDatabase pg)
      (buf, n) <- rawFile st (dir ++ "/wal")
      writeFileFrom st (dir ++ "/wal") buf (n - 10)
      pg2 <- openDatabase st dir defaultOptions
      let info = pagerRecovery pg2
      expect (info.tornTail && info.committedTxns == 1 && info.pagesDiscarded > 0)
        ("torn " ++ show info.tornTail ++ ", committed " ++ show info.committedTxns
         ++ ", discarded " ++ show info.pagesDiscarded)
      _ <- checkTree pg2 1 m1 "after recovery from a truncated log"
      closeDatabase pg2

  , dbTest "recovery: a corrupted record stops replay at the last good commit" $ do
      (st, dir, pg) <- fresh "rec-corrupt.idb" defaultOptions
      m1 <- inTransaction pg (applyOps pg 1 (workload 71 900 700) empty)
      mid <- liftIO (storageStats st)
      _ <- inTransaction pg (applyOps pg 1 (workload 72 900 700) m1)
      liftIO (abandonDatabase pg)
      (buf, n) <- rawFile st (dir ++ "/wal")
      -- Flip a byte inside the last page image of the second transaction.
      b <- liftIO (rdU8 buf (n - 2000))
      liftIO (wrU8 buf (n - 2000) ((b + 1) `mod` 256))
      writeFileFrom st (dir ++ "/wal") buf n
      pg2 <- openDatabase st dir defaultOptions
      expect (pagerRecovery pg2).tornTail "the damaged record was not noticed"
      _ <- checkTree pg2 1 m1 "after recovery from a corrupted log"
      closeDatabase pg2

  , dbTest "recovery: a log from another database is refused" $ do
      (st, dir, pg) <- fresh "rec-foreign-a.idb" defaultOptions
      _ <- inTransaction pg (applyOps pg 1 (workload 81 300 200) empty)
      liftIO (abandonDatabase pg)
      (buf, n) <- rawFile st (dir ++ "/wal")
      liftIO (wrU8 buf 16 0xAB >> wrU8 buf 17 0xCD)
      writeFileFrom st (dir ++ "/wal") buf n
      expectError "foreign log" (openDatabase st dir defaultOptions) isCorrupt

  , dbTest "recovery: a torn page file is repaired from the log" $ do
      (st, dir, pg) <- fresh "rec-tornpage.idb" (MkOptions 256 4194304 False 50000)
      m <- inTransaction pg (applyOps pg 1 (workload 91 1200 800) empty)
      liftIO (abandonDatabase pg)
      -- Simulate a checkpoint that died while rewriting the root page.
      buf <- alloc PageSize
      writeFileFrom st (storePath dir 1) buf 1000
      pg2 <- openDatabase st dir defaultOptions
      _ <- checkTree pg2 1 m "after repairing a torn page"
      closeDatabase pg2

  , crashSweep "fault-at-every-write" defaultOptions False
  , crashSweep "torn-write-at-every-write" defaultOptions True
  , crashSweep "fault-with-checkpoint-per-commit" (MkOptions 256 1 False 50000) False
  , crashSweep "torn-write-with-checkpoint-per-commit" (MkOptions 256 1 False 50000) True
  , crashSweep "fault-with-spilling-pool" (MkOptions 8 4194304 False 50000) False
  ]

export
storageTests : List Test
storageTests = pageTests ++ codecTests ++ pagerTests ++ treeTests ++ recoveryTests
