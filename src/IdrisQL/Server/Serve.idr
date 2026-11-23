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
  ||| Largest result a statement may return.
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

-- Read until the header block is complete.
readHead : Socket -> (fuel : Nat) -> List Bits8 -> IO (Maybe (Request, List Bits8))
readHead sock Z acc = pure Nothing
readHead sock (S fuel) acc =
  case splitHead acc of
    Just (top, rest) => pure (map (\req => (req, rest)) (parseHead top))
    Nothing =>
      if length acc > maxHead then pure Nothing
        else do
          Right more <- recvBytes sock 4096 | Left _ => pure Nothing
          readHead sock fuel (acc ++ more)

-- Read until `wanted` body bytes have arrived.
readBody : Socket -> (wanted : Nat) -> (fuel : Nat) -> List (List Bits8) -> (have : Nat) -> IO (Maybe (List Bits8))
readBody sock wanted Z chunks have = pure Nothing
readBody sock wanted (S fuel) chunks have =
  if have >= wanted then pure (Just (take wanted (concat (reverse chunks))))
    else do
      Right more <- recvBytes sock 65536 | Left _ => pure Nothing
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

runOne : Engine -> ServerConfig -> String -> DB String
runOne eng cfg sql = do
  r <- execute eng sql []
  case r of
    Rows names _ source => do
      rows <- drain cfg.maxRows source []
      pure (jsonObject [("columns", jsonArray (map jsonString names)), ("rows", jsonArray rows)])
    Changed n => pure (jsonObject [("changed", show n)])
    Done what => pure (jsonObject [("done", jsonString what)])

-- Run the statements in order and stop at the first failure, reporting
-- how many completed before it.
runAll : Engine -> ServerConfig -> List String -> List String -> IO (Either (Nat, DbError) (List String))
runAll eng cfg [] done = pure (Right (reverse done))
runAll eng cfg (s :: rest) done = do
  Right one <- runDB (runOne eng cfg s)
    | Left e => pure (Left (length done, e))
  runAll eng cfg rest (one :: done)

query : Engine -> ServerConfig -> String -> IO (Int, String)
query eng cfg sql = do
  let (stmts, rest) = splitStatements sql
  r <- runAll eng cfg (stmts ++ (if trim rest == "" then [] else [rest])) []
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

-- Bytes of the declared body that have not arrived yet. A body over the
-- limit counts as none: it is not worth reading.
unread : ServerConfig -> Maybe Integer -> List Bits8 -> Integer
unread cfg (Just n) early = if n > cast cfg.maxBody then 0 else n - cast (length early)
unread cfg Nothing early = 0

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

refuse : Socket -> (left : Integer) -> (status : Int) -> String -> IO Bool
refuse sock left status why = do
  discard sock left (cast left + 16)
  respond sock status (errorBody why)
  pure False

-- Answer one request. True when the server should stop.
handle : Engine -> ServerConfig -> Socket -> SocketAddress -> IO Bool
handle eng cfg sock peer = do
  Just (req, early) <- readHead sock 64 []
    | Nothing => respond sock 400 (errorBody "malformed request") >> pure False
  let declared = header "content-length" req >>= contentLength
  let left = unread cfg declared early
  case (req.method, req.path) of
    ("GET", "/health") => respond sock 200 (jsonObject [("status", jsonString "ok")]) >> pure False
    ("POST", "/shutdown") =>
      if loopback peer
        then respond sock 200 (jsonObject [("status", jsonString "stopping")]) >> pure True
        else refuse sock left 403 "shutdown is accepted from the loopback address only"
    ("POST", "/query") =>
      if not (authorized cfg req) then refuse sock left 401 "missing or wrong bearer token"
      else case declared of
        Nothing => respond sock 411 (errorBody "POST /query needs a Content-Length") >> pure False
        Just n =>
          if n > cast cfg.maxBody then respond sock 413 (errorBody "request body too large") >> pure False
          else do
            Just body <- readBody sock (cast n) (cast n + 16) [early] (length early)
              | Nothing => respond sock 400 (errorBody "request body shorter than its Content-Length") >> pure False
            if not (validUtf8 body) then respond sock 400 (errorBody "request body is not UTF-8") >> pure False
              else do
                Right sql <- runDB (packBytes body >>= \b => liftIO (bytesString b))
                  | Left e => respond sock 500 (errorBody (show e)) >> pure False
                (status, json) <- query eng cfg sql
                respond sock status json
                pure False
    (_, path) =>
      if path `elem` ["/health", "/query", "/shutdown"]
        then refuse sock left 405 "method not allowed"
        else refuse sock left 404 "no such path"

acceptLoop : Engine -> ServerConfig -> Socket -> IO ()
acceptLoop eng cfg listener = do
  Right (client, peer) <- accept listener
    | Left _ => acceptLoop eng cfg listener
  stop <- handle eng cfg client peer
  close client
  if stop then pure () else acceptLoop eng cfg listener

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
||| address cannot be bound. The caller closes the engine.
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
  acceptLoop eng cfg listener
  close listener
  pure (Right ())
