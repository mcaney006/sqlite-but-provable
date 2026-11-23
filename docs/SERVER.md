# HTTP server and container image

`idrisql DATABASE --serve PORT` opens one database and answers SQL over
HTTP/1.1 until it is told to stop. The container image runs that command.
The server is `src/IdrisQL/Server/Http.idr` (request parsing and JSON, pure
and total) and `src/IdrisQL/Server/Serve.idr` (sockets), about 550 lines
together.
It uses the `network` package that ships with Idris 2; the engine itself
still needs only `base` and `linear`.

## What it is and is not

One process holds the database and answers one request at a time. That
makes it a way to reach an IdrisQL database from another program or
another machine. It is not a replacement for PostgreSQL or MySQL: there
are no concurrent queries, no replication, no TLS, and a commit does not
survive power loss (`docs/TRANSACTIONS.md`).

## Starting it

```sh
idrisql shop.idb --serve 5480                      # 127.0.0.1 only
idrisql shop.idb --serve 5480 --host 0.0.0.0       # every interface
IDRISQL_TOKEN=change-me idrisql shop.idb --serve 5480
make serve DB=shop.idb PORT=5480                   # the first, with SIGPIPE ignored
```

Start it from a shell that ignores SIGPIPE (`trap '' PIPE`), as `make
serve`, `pixi run serve` and the container do. "Signals and stopping"
says why.

| Option | Default | Meaning |
|---|---|---|
| `--serve PORT` | none | Serve instead of opening the shell |
| `--host ADDRESS` | `127.0.0.1` | IPv4 address to listen on, as four numbers. Host names are refused. |
| `--max-rows N` | 100000 | Most rows one response may hold, over all its statements |
| `IDRISQL_TOKEN` (environment) | unset | When set, `POST /query` needs `Authorization: Bearer <token>` |

The shell's `--cache`, `--checkpoint` and `--break-lock` options apply too.

## Endpoints

| Request | Answer |
|---|---|
| `GET /health` | `200 {"status":"ok"}`. Never needs the token. |
| `POST /query` | Runs the SQL in the request body |
| `POST /shutdown` | From a loopback address only: closes the database and exits. Other callers get 403. |

Every response is JSON with a `Content-Length`, and the server closes the
connection after it.

## Queries

The body of `POST /query` is SQL text in UTF-8: one statement or several
separated by semicolons. The response has one entry per statement, in
order.

```
$ curl -s -X POST -H 'Authorization: Bearer change-me' http://127.0.0.1:5480/query --data-binary \
    "CREATE TABLE city (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, pop INTEGER);
     INSERT INTO city (name, pop) VALUES ('Dallas', 1304379), ('Austin', 961855);
     SELECT name, pop FROM city ORDER BY pop DESC"
{"results":[{"done":"CREATE TABLE"},{"changed":2},{"columns":["name","pop"],"rows":[["Dallas",1304379],["Austin",961855]]}]}
```

| Statement | Entry |
|---|---|
| A query | `{"columns":[...],"rows":[[...],...]}` |
| `INSERT`, `UPDATE`, `DELETE` | `{"changed":N}` |
| Anything else | `{"done":"CREATE TABLE"}` and the like |

| SQL value | JSON |
|---|---|
| INTEGER, REAL | number |
| TEXT | string |
| BOOLEAN | `true` or `false` |
| NULL | `null` |
| BLOB | `{"blob":"CAFE"}`, upper-case hexadecimal |
| REAL infinity | the string `"Infinity"` or `"-Infinity"` |

Bound parameters are not available over HTTP. Values go into the SQL text,
so the caller must quote them.

### Errors

The first statement that fails ends the request. `completed` is the number
of statements that ran before it.

```
{"error":"constraint violation: UNIQUE constraint failed: city.name","kind":"constraint","completed":0}
```

| Status | `kind` or cause |
|---:|---|
| 400 | `syntax`, `semantic`, `constraint`, `runtime`, `transaction`, `unsupported`; a body that is not UTF-8; a malformed request, which includes a carriage return that is not part of a line break; `Content-Length` headers that disagree |
| 401 | Token missing or wrong |
| 403 | `/shutdown` from a non-loopback address |
| 404, 405 | Unknown path, or the wrong method for a known one |
| 411 | `POST /query` without a usable `Content-Length`, or with a `Transfer-Encoding`. Chunked bodies are not read. |
| 413 | Body larger than 1 MiB. The server answers without reading the body, so a client still sending it can see a connection reset in place of the 413. |
| 500 | `storage` or `committed-then-failed`: see `docs/TRANSACTIONS.md` |

A request with `Expect: 100-continue` gets `100 Continue` before its body
is read. Text that holds only comments, between statements or after the
last one, is not a statement.

After a storage failure that leaves the engine's connection unusable, the
server answers that request with 500 and exits with status 1. The engine
would refuse every later statement, and only reopening the database, which
runs recovery, clears it. Under Docker with a restart policy, or under
ECS, the restart does that.

### Transactions

A request is one unit of work. `BEGIN ... COMMIT` inside one request is one
transaction. A request that ends with a transaction open gets it rolled
back and a 400, because the connection that opened it is gone and the next
request may come from a different client. A statement outside `BEGIN` runs
in its own transaction, so in a request of three such statements where the
third fails, the first two stay committed.

## Limits

| Limit | Value |
|---|---|
| Requests in progress | 1. Others wait in the kernel's accept queue, which the socket library sets to 20 connections. |
| Request header | 16 KiB |
| Request body | 1 MiB. The body is held as a list of bytes, which takes 16 times its size in memory. |
| Rows in one response | `--max-rows`, 100,000 by default, counted over every statement in the request. Going over is a 400 that says to add `LIMIT`. |
| Response | Built in memory as one string, then sent in slices. 60,000 rows of three columns were 1,626,052 bytes and took 0.34 s on the reference machine, and the server's resident memory afterwards was 92 MiB. Choose `--max-rows` with the memory available in mind. |
| Connections | Closed after each response; no keep-alive |
| TLS | None. Put a load balancer or a private network in front. |
| Timeouts | None. A client that connects and sends nothing holds the server until it disconnects. |
| Token check | Plain string comparison, not constant-time |
| Addresses | IPv4 |

The missing timeouts are the reason not to expose the port to a network
you do not control. `deploy/aws` puts an Application Load Balancer in
front, which closes a connection that stays idle longer than its idle
timeout.

`POST /shutdown` trusts the peer address. A reverse proxy that runs on the
same host or in the same network namespace (a sidecar container, for
example) makes every request look local, so it must not forward that path.

## Signals and stopping

Idris 2's `System.Signal` can handle SIGINT, SIGHUP, SIGQUIT and a few
others. SIGTERM and SIGPIPE are not among them, and the socket library
sends without `MSG_NOSIGNAL`. Two consequences, both handled outside the
program:

| Problem | Handling |
|---|---|
| A client that disconnects before its response is written raises SIGPIPE, which would end the server | Start the server with SIGPIPE ignored (`trap '' PIPE` in the shell that starts it). An ignored signal stays ignored in the started program. The container's entry point does this. |
| SIGTERM ends the process without closing the database, leaving `LOCK` behind | The container's entry point catches SIGTERM and sends `POST /shutdown` over the loopback address. The server closes the database, which writes a checkpoint and removes the lock, and exits with status 0. |

Both requests from the entry point and the image's health check go to
`IDRISQL_PORT` and bypass any proxy named in the environment. Set the
port with that variable, not by passing `--serve` to the container.

SIGKILL cannot be handled. It leaves the lock behind, and the next start
is refused until `--break-lock` is passed. Committed data is intact either
way; recovery runs at open.

`--break-lock` is unconditional, and a second process that uses it while
the first is still running corrupts the database. The container's entry
point adds the check the engine cannot make. While a container holds the
database it touches `<database>.alive` every two seconds. A container
started with `IDRISQL_BREAK_LOCK=1` that finds a lock waits until that
file has gone untouched for `IDRISQL_LOCK_STALE_SECONDS` (30 by default),
and only then passes `--break-lock`. Both times are read from the file
system that holds the database, so the two containers' clocks do not have
to agree. A lock with no `.alive` file beside it was taken some other way,
for example by `idrisql` run directly or by a container given another
command than `serve` or `shell`, and is treated as stale.

This is detection, not fencing. The engine has no notion of who owns the
lock, so a holder that is alive but has not managed to touch the file for
that long would be written over. To narrow that case, a container that
fails to write the file five times in a row, about ten seconds, kills its
own server.

The socket library also sets no `SO_REUSEADDR`. After a server stops, the
kernel keeps its port for the length of TCP's TIME_WAIT state: about 30
seconds on macOS and 60 on Linux, measured by the restart step of
`tests/server/run.sh`. A server started in that window says so and retries
its bind once a second for up to 75 seconds before giving up. Any other
bind failure is reported at once. A new container has
its own network namespace and does not wait.

## Container image

`ghcr.io/mcaney006/sqlite-but-provable`, for `linux/amd64` and
`linux/arm64`. The workflow in `.github/workflows/ci.yml` publishes it only
after the test stage has passed on that architecture.

| Tag | Points at |
|---|---|
| `edge` | The latest commit on `main` |
| `sha-<commit>` | One commit. Use this, or a digest, where the version must not move. |
| `<version>` | One `v*` tag: `v0.2.0` publishes `0.2.0` |
| `<major>.<minor>` | The `v*` tag of that series pushed last: `v0.2.0` also publishes `0.2` |
| `latest` | The `v*` tag pushed last. Pre-release tags such as `v0.3.0-rc.1` do not move it. |

```sh
docker run -d --name idrisql -p 127.0.0.1:5480:5480 \
  -e IDRISQL_TOKEN=change-me -v idrisql-data:/data \
  ghcr.io/mcaney006/sqlite-but-provable:edge

curl -s -X POST -H 'Authorization: Bearer change-me' \
  --data-binary "SELECT 1 + 1 AS two" http://127.0.0.1:5480/query
# {"results":[{"columns":["two"],"rows":[[2]]}]}
```

| Environment variable | Default | Meaning |
|---|---|---|
| `IDRISQL_DATABASE` | `/data/main.idb` | Database directory |
| `IDRISQL_PORT` | `5480` | Port to serve on |
| `IDRISQL_TOKEN` | unset | Bearer token for `POST /query` |
| `IDRISQL_MAX_ROWS` | 100000 | Same as `--max-rows` |
| `IDRISQL_BREAK_LOCK` | unset | `1` takes over a lock whose holder has stopped marking itself alive; see "Signals and stopping" |
| `IDRISQL_LOCK_STALE_SECONDS` | 30 | How long the holder must have been silent before its lock is taken |

| Property | Value |
|---|---|
| Base | Alpine 3.24, the first stable release that packages Idris 2 0.8.0 |
| Contents | Chez Scheme, the compiled program, its support library, two shell scripts. The compiling and the running stage share one Chez Scheme layer. |
| Size | 26 MB uncompressed on `linux/arm64` |
| User | `idrisql`, uid and gid 10001 |
| Labels | `org.opencontainers.image.version` is the version in `idrisql.ipkg`, the one `idrisql --version` prints; a pre-release tag such as `v0.3.0-rc.1` therefore carries `0.3.0`. `org.opencontainers.image.revision` is the commit the image was built from. The `0.2.0` image and the images of earlier commits have neither. |
| Volume | `/data` |
| Writes outside `/data` | None. It runs with `--read-only` and `--cap-drop ALL`; `tests/container/run.sh` starts it that way. |
| Health check | `GET /health` every 10 seconds |

The image also holds the shell. With the server stopped:

```sh
docker run --rm -it -v idrisql-data:/data ghcr.io/mcaney006/sqlite-but-provable:edge shell
docker run --rm -v idrisql-data:/data ghcr.io/mcaney006/sqlite-but-provable:edge shell --execute ".check"
```

### Building it

```sh
make docker           # the runtime image, tagged idrisql:dev
make docker-test      # every test suite inside Alpine
make test-container   # start, query, stop, restart, stale lock
```

The Dockerfile has five stages: `base` (Alpine with `chez-scheme`),
`toolchain` (adds `idris2` and `make`), `build` (compiles the sources),
`test` (adds `sqlite` and `curl` and runs the suites) and `runtime`.

The `build` stage keeps the checked modules of the previous build in a
BuildKit cache mount. Idris 2 0.8.0 decides what to re-check by file time,
which is wrong for a cache shared between checkouts, so
`docker/cached-build.sh` compares SHA-256 hashes of the sources and forces
a re-check of every file whose content differs. Build times are in
`docs/BENCHMARKS.md`.

## How it is tested

| Test | What it covers | Result |
|---|---|---|
| `server` unit suite (`src/Tests/Server.idr`) | Header splitting and parsing, malformed request lines, lone carriage returns, body framing, `Expect`, numbers, listen addresses, UTF-8 validation, JSON escaping and values, response headers | 12 pass |
| `tests/server/run.sh` | The real program on a socket, with curl: statuses 200, 400, 401, 404, 405 and 411, multi-statement requests, comment-only text, text outside ASCII, a rolled-back open transaction, conflicting lengths, `Expect: 100-continue`, a 60,000-row result, the row limit for one statement and for a response, 600 KiB bodies the server answers without using, five clients that disconnect mid-response, shutdown releasing the lock, a restart on the same port, token checks | 29 pass on macOS and on Alpine |
| `tests/container/run.sh` | The image with a read-only root and no capabilities: health, token, a query, `docker stop` exiting 0, data after a restart, a second container waiting while the first is alive, refusal of a stale lock without the option, takeover after `docker kill`, SIGTERM while waiting | 9 pass |

Not tested: statuses 403, 413 and 500, the exit after a storage failure,
load, many simultaneous clients, slow clients, and any deployment on AWS.
