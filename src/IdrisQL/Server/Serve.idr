module IdrisQL.Server.Serve

import Data.Buffer
import Data.List
import Data.Maybe
import Data.String
import Network.Socket
import Network.Socket.Data
import System
import System.File
import IdrisQL.CLI.Shell
import IdrisQL.Engine
import IdrisQL.Error
import IdrisQL.Server.Http
import IdrisQL.Storage.Codec
import IdrisQL.Types

-- An HTTP front end for one database. The server holds the engine's single
-- connection and answers one request at a time, so requests are serial:
-- each one sees the committed result of every request before it.
--
--   GET  /health     200 when the server is running
--   POST /query      body: SQL text, one or more statements
--   POST /shutdown   from the loopback address only: close the database
--                    and exit
--
-- The server also stops, with an error, when a storage failure has left
-- the engine's connection unusable: restarting it runs recovery, and
-- answering every later request with the same failure helps nobody.
--
-- A request is its own unit of work. A transaction it opens must be
-- committed before the request ends; otherwise it is rolled back and the
-- request fails. The connection closes after every response.
--
-- Not provided: TLS, timeouts on slow clients, concurrent requests. Put
-- the server behind a load balancer or on a private network.

public export
record ServerConfig where
  constructor MkServerConfig
  host : String
  port : Int
  ||| When set, POST /query needs `Authorization: Bearer <token>`.
  token : Maybe String
  ||| Most rows one response may hold, over all its statements.
  maxRows : Nat
  ||| Largest request body, in bytes.
  maxBody : Int

maxHead : Nat
maxHead = 16384

toBytes : String -> IO (List Bits8)
toBytes s = do
  Right b <- runDB (stringBytes s) | Left _ => pure []
  unpackBytes b

-- Send everything, in pieces a single call can take. False when the
-- client has gone.
sendAll : Socket -> List Bits8 -> IO Bool
sendAll sock [] = pure True
sendAll sock bytes = do
  let (now, later) = splitAt 32768 bytes
  Right sent <- sendBytes sock now
    | Left _ => pure False
  if sent <= 0 then pure False
    else sendAll sock (drop (cast sent) now ++ later)

-- A list of bytes costs 16 bytes of memory for each one, so a large
-- response is converted and sent a slice at a time and never held whole
-- in that form.
sendText : Socket -> String -> IO ()
sendText sock text = go 0
  where
    size : Nat
    size = length text

    go : Nat -> IO ()
    go from =
      if from >= size then pure ()
        else do
          bytes <- toBytes (substr from 8192 text)
          True <- sendAll sock bytes | False => pure ()
          go (from + 8192)

respond : Socket -> (status : Int) -> (json : String) -> IO ()
respond sock status json = do
  top <- toBytes (responseHead status (stringByteLength json))
  True <- sendAll sock top | False => pure ()
  sendText sock json

errorBody : String -> String
errorBody msg = jsonObject [("error", jsonString msg)]

-- Read until the header block is complete. Every receive that succeeds
-- brings at least one byte, so the fuel bounds the bytes read, however
-- small the pieces a header arrives in.
readHead : Socket -> (fuel : Nat) -> List Bits8 -> IO (Maybe (Request, List Bits8))
readHead sock Z acc = pure Nothing
readHead sock (S fuel) acc =
  case splitHead acc of
    Just (top, rest) =>
      pure (if length top > maxHead then Nothing else map (\req => (req, rest)) (parseHead top))
    Nothing =>
      if length acc > maxHead then pure Nothing
        else do
          Right more <- recvBytes sock 4096 | Left _ => pure Nothing
          readHead sock fuel (acc ++ more)

-- Read until `wanted` body bytes have arrived, never asking for more than
-- are still missing.
readBody : Socket -> (wanted : Nat) -> (fuel : Nat) -> List (List Bits8) -> (have : Nat) -> IO (Maybe (List Bits8))
readBody sock wanted Z chunks have = pure Nothing
readBody sock wanted (S fuel) chunks have =
  if have >= wanted then pure (Just (take wanted (concat (reverse chunks))))
    else do
      Right more <- recvBytes sock (cast (min 65536 (minus wanted have))) | Left _ => pure Nothing
      readBody sock wanted fuel (more :: chunks) (have + length more)

kind : DbError -> String
kind (SyntaxError _ _) = "syntax"
kind (SemanticError _) = "semantic"
kind (ConstraintViolation _) = "constraint"
kind (RuntimeError _) = "runtime"
kind (TxError _) = "transaction"
kind (Unsupported _) = "unsupported"
kind (CommittedThenFailed _) = "committed-then-failed"
kind _ = "storage"

-- 400 for a statement the client got wrong, 500 for a storage failure.
statusFor : DbError -> Int
statusFor e = if kind e `elem` ["storage", "committed-then-failed"] then 500 else 400

drain : (limit : Nat) -> DB (Maybe (List Value)) -> List String -> DB (List String)
drain Z source acc = do
  Nothing <- source
    | Just _ => throw (RuntimeError "the result has more rows than the server's limit; add LIMIT")
  pure (reverse acc)
drain (S k) source acc = do
  Just row <- source | Nothing => pure (reverse acc)
  drain k source (jsonArray (map jsonValue row) :: acc)

-- One statement's entry in the response, and the rows it used up.
runOne : Engine -> (budget : Nat) -> String -> DB (String, Nat)
runOne eng budget sql = do
  r <- execute eng sql []
  case r of
    Rows names _ source => do
      rows <- drain budget source []
      pure (jsonObject [("columns", jsonArray (map jsonString names)), ("rows", jsonArray rows)], length rows)
    Changed n => pure (jsonObject [("changed", show n)], 0)
    Done what => pure (jsonObject [("done", jsonString what)], 0)

-- Run the statements in order and stop at the first failure, reporting
-- how many completed before it. The row limit is for the whole response:
-- it is held in memory, whichever statement its rows come from.
runAll : Engine -> (budget : Nat) -> List String -> List String -> IO (Either (Nat, DbError) (List String))
runAll eng budget [] done = pure (Right (reverse done))
runAll eng budget (s :: rest) done = do
  Right (one, used) <- runDB (runOne eng budget s)
    | Left e => pure (Left (length done, e))
  runAll eng (minus budget used) rest (one :: done)

query : Engine -> ServerConfig -> String -> IO (Int, String)
query eng cfg sql = do
  let (stmts, rest) = splitStatements sql
  r <- runAll eng cfg.maxRows (stmts ++ (if blankSql rest then [] else [rest])) []
  unfinished <- inTransaction eng
  when unfinished (ignore (runDB (execute eng "ROLLBACK" [])))
  pure $ case r of
    Left (completed, e) =>
      (statusFor e, jsonObject [("error", jsonString (show e)), ("kind", jsonString (kind e)),
                                ("completed", show completed)])
    Right results =>
      if unfinished
        then (400, jsonObject [("error", jsonString "the request ended with a transaction open; it was rolled back"),
                               ("kind", jsonString "transaction"), ("completed", show (length results))])
        else (200, jsonObject [("results", jsonArray results)])

authorized : ServerConfig -> Request -> Bool
authorized cfg req = case cfg.token of
  Nothing => True
  Just t => header "authorization" req == Just ("Bearer " ++ t)

loopback : SocketAddress -> Bool
loopback (IPv4Addr 127 _ _ _) = True
loopback _ = False

-- Bytes of the declared body that the client has sent or is sending and
-- that have not been read. None when the body is over the limit, which is
-- not worth reading, and none when the client is waiting for `100
-- Continue` before it sends anything.
unread : ServerConfig -> Request -> List Bits8 -> Integer
unread cfg req early = case framing req of
  Length n => if n > cast cfg.maxBody || expectsContinue req then 0 else n - cast (length early)
  _ => 0

-- Read and drop the rest of a body the request will not use. Closing a
-- connection with unread data resets it, and the client can then lose the
-- response that was just sent.
discard : Socket -> (left : Integer) -> (fuel : Nat) -> IO ()
discard sock left Z = pure ()
discard sock left (S fuel) =
  if left <= 0 then pure ()
    else do
      Right more <- recvBytes sock 65536 | Left _ => pure ()
      discard sock (left - cast (length more)) fuel

-- What the server does after a request.
data Next = Continue | Stop | Broken

refuse : Socket -> (left : Integer) -> (status : Int) -> String -> IO Next
refuse sock left status why = do
  discard sock left (cast left + 16)
  respond sock status (errorBody why)
  pure Continue

answer : Socket -> (status : Int) -> (json : String) -> IO Next
answer sock status json = respond sock status json >> pure Continue

unusable : String
unusable = "a storage failure left the database connection unusable; the server is stopping so that a restart can run recovery"

-- Run the SQL in a request body and answer it.
runQuery : Engine -> ServerConfig -> Socket -> List Bits8 -> IO Next
runQuery eng cfg sock body =
  if not (validUtf8 body) then answer sock 400 (errorBody "request body is not UTF-8")
  else do
    Right sql <- runDB (packBytes body >>= \b => liftIO (bytesString b))
      | Left e => answer sock 500 (errorBody (show e))
    (status, json) <- query eng cfg sql
    ok <- usable eng
    if ok then answer sock status json
      else do
        -- A storage error is already the answer; anything else would
        -- claim more than is known.
        respond sock 500 (if status >= 500 then json else errorBody unusable)
        pure Broken

handle : Engine -> ServerConfig -> Socket -> SocketAddress -> IO Next
handle eng cfg sock peer = do
  Just (req, early) <- readHead sock (maxHead + 8) []
    | Nothing => answer sock 400 (errorBody "malformed request")
  let left = unread cfg req early
  case (req.method, req.path) of
    ("GET", "/health") => answer sock 200 (jsonObject [("status", jsonString "ok")])
    ("POST", "/shutdown") =>
      if loopback peer
        then respond sock 200 (jsonObject [("status", jsonString "stopping")]) >> pure Stop
        else refuse sock left 403 "shutdown is accepted from the loopback address only"
    ("POST", "/query") =>
      if not (authorized cfg req) then refuse sock left 401 "missing or wrong bearer token"
      else case framing req of
        NoLength => answer sock 411 (errorBody "POST /query needs a Content-Length")
        Conflicting => answer sock 400 (errorBody "conflicting Content-Length headers")
        Length n =>
          if n > cast cfg.maxBody then answer sock 413 (errorBody "request body too large")
          else do
            -- A client that asked may be holding its body back until told.
            when (expectsContinue req && cast (length early) < n) $ do
              go <- toBytes "HTTP/1.1 100 Continue\r\n\r\n"
              ignore (sendAll sock go)
            Just body <- readBody sock (cast n) (cast n + 16) [early] (length early)
              | Nothing => answer sock 400 (errorBody "request body shorter than its Content-Length")
            runQuery eng cfg sock body
    (_, path) =>
      if path `elem` ["/health", "/query", "/shutdown"]
        then refuse sock left 405 "method not allowed"
        else refuse sock left 404 "no such path"

-- `failures` counts accepts that failed in a row. A failure that does not
-- clear, such as no file descriptors left, ends the server so that the
-- caller can close the database.
acceptLoop : Engine -> ServerConfig -> Socket -> (failures : Nat) -> IO (Either String ())
acceptLoop eng cfg listener failures = do
  Right (client, peer) <- accept listener
    | Left e =>
        if failures >= 50
          then pure (Left ("cannot accept connections (error " ++ show e ++ ")"))
          else usleep 100000 >> acceptLoop eng cfg listener (S failures)
  next <- handle eng cfg client peer
  close client
  case next of
    Continue => acceptLoop eng cfg listener 0
    Stop => pure (Right ())
    Broken => pure (Left unusable)

-- EADDRINUSE on Linux and on macOS.
addressInUse : Int -> Bool
addressInUse e = e == 98 || e == 48

-- The socket library does not set SO_REUSEADDR, so for up to a minute
-- after a server stops the kernel refuses its port to the next one. Keep
-- trying for that long before giving up. Any other failure is final.
bindWithin : ServerConfig -> Socket -> (seconds : Nat) -> IO Int
bindWithin cfg listener seconds = do
  e <- bind listener (Just (parseIPv4 cfg.host)) cfg.port
  case seconds of
    S k => if addressInUse e then sleep 1 >> bindWithin cfg listener k else pure e
    Z => pure e

||| Serve `eng` until a shutdown request arrives. Returns `Left` when the
||| address cannot be bound, when connections can no longer be accepted,
||| or when a storage failure has made the engine unusable. The caller
||| closes the engine.
export
serve : Engine -> ServerConfig -> IO (Either String ())
serve eng cfg = do
  Right listener <- socket AF_INET Stream 0
    | Left e => pure (Left ("cannot create a socket (error " ++ show e ++ ")"))
  first <- bindWithin cfg listener 0
  bound <- the (IO Int) $
    if addressInUse first
      then do
        _ <- fPutStrLn stderr ("idrisql: port " ++ show cfg.port ++ " is in use; trying for 75 seconds")
        bindWithin cfg listener 75
      else pure first
  0 <- pure bound
    | e => close listener >> pure (Left ("cannot bind " ++ cfg.host ++ ":" ++ show cfg.port ++ " (error " ++ show e ++ ")"))
  0 <- listen listener
    | e => close listener >> pure (Left ("cannot listen (error " ++ show e ++ ")"))
  _ <- fPutStrLn stderr ("idrisql: serving on " ++ cfg.host ++ ":" ++ show cfg.port
                         ++ (if isNothing cfg.token then ", no token required" else ", bearer token required"))
  result <- acceptLoop eng cfg listener 0
  close listener
  pure result
