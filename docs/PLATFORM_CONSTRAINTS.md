# Platform constraints

IdrisQL is written in Idris 2 and uses only packages that ship with the
compiler: `base` and `linear` for the engine, and `network` for the HTTP
server. It declares no foreign functions. This document
records what that platform can and cannot do, measured before the storage
layer was designed, and the design decisions each fact forced.

## Environment the engine was built and measured on

| Item | Value |
|---|---|
| Compiler | Idris 2 version 0.8.0 (Homebrew build) |
| Backend | Chez Scheme 10.4.1 |
| Operating system | macOS 27.3 |
| CPU | Apple M5, 10 cores |
| Memory | 16 GiB |
| Packages used | `base`, `linear` |

CI (`.github/workflows/ci.yml`) builds and tests in three other
environments: Alpine 3.24 with its `idris2` 0.8.0 and `chez-scheme` 10.3.0
packages on `linux/amd64` and `linux/arm64`, and a toolchain built from
source by `scripts/pixi-toolchain.sh` (Idris 2 0.8.0, Chez Scheme 10.3.0)
on `ubuntu-24.04` and `macos-15`.

## File operations `base` provides

These are the calls `src/IdrisQL/Storage/FileIO.idr` uses. It is the only
module that touches the filesystem.

| Operation | `base` function |
|---|---|
| Open for read, truncating write, or append | `openFile` with `Read`, `WriteTruncate`, `Append` |
| Read bytes into a buffer at the handle's position | `readBufferData` |
| Write bytes from a buffer at the handle's position | `writeBufferData` |
| Push buffered bytes to the operating system | `fflush` |
| Delete a file | `removeFile` |
| Create a directory; fails if it exists | `createDir` |
| List and remove directories | `listDir`, `removeDir` |
| Process id and wall clock, combined once into a database id | `getPID`, `time` |

## File operations `base` does not provide

| Missing operation | Consequence for the design |
|---|---|
| Seek | A file is read from its start and written from its start. One file cannot hold many independently updatable pages. |
| `fsync` or any flush to the device | A commit can be handed to the operating system and no further. Power-loss durability is out of reach. |
| Rename | No atomic file replacement. The log, not a rename, makes page updates atomic. |
| File locks | Mutual exclusion uses `createDir`, which fails when the directory exists. |
| Truncate at an offset | The log is emptied by reopening it with `WriteTruncate`. |

`Data.Buffer`'s 16, 32 and 64-bit accessors use the byte order of the host.
The file format is little-endian, so every multi-byte field is assembled from
single bytes (`src/IdrisQL/Storage/Codec.idr`), except where the host is
little-endian and a faster whole-word read gives the same result (the page
checksum loop).

## Measurements that chose the page store

A probe program timed the candidate layouts on the machine above.

| Operation | Time |
|---|---:|
| Write one new 4 KiB file | 94 µs |
| Read one 4 KiB file | 131 µs |
| Rewrite one existing 4 KiB file | 162 µs |
| Read a 64 KiB file (16 pages) | 25 µs per file |
| Update one page of a 64 KiB file (read and rewrite all of it) | 117 µs |
| Append 4 KiB to an open log and `fflush` | 10 µs |
| Hash 4096 bytes in Idris, a byte at a time | 34 µs |

Two layouts were possible without seek: one file per page, or one file per
extent of several pages.

An extent file is faster to read and no slower to update. It was rejected
because rewriting an extent overwrites pages the current transaction never
touched. A crash during that write damages those neighbours, and their images
are not in the log, so recovery could not restore them. One file per page
keeps the unit that can be torn equal to the unit that is logged.

The cost of that choice is visible in `docs/BENCHMARKS.md`: a page that is
not in the buffer pool costs a file open, a read and a close, and the
database directory holds one file per page.

The byte-at-a-time hash figure is why the page checksum reads a 32-bit word
at a time on little-endian hosts.

## What the engine therefore does

| Area | Decision |
|---|---|
| Page store | `p/<page id div 256>/<page id>.pg`, one 4096-byte file per page |
| Atomicity | Redo-only write-ahead log of full page images. Page files receive committed pages only. |
| Durability | A commit returns after `fflush` of the log. The engine reports this level as `FlushedToOS` and offers no stronger one. |
| Mutual exclusion | A `LOCK` directory inside the database directory, created at open and removed at close |
| Stale locks | No way to ask whether the process that made `LOCK` is alive. A lock left by a dead process is taken over only with the explicit `--break-lock` option. |
| Concurrency | One process, one connection, one writer. See `docs/TRANSACTIONS.md`. |

## Network operations `network` provides and does not provide

`src/IdrisQL/Server/Serve.idr` is the only module that uses sockets.

| Provided | Function |
|---|---|
| Create, bind, listen, accept, close | `socket`, `bind`, `listen`, `accept`, `close` |
| Receive up to N bytes | `recvBytes`; an error result covers both end of stream and failure |
| Send bytes once, possibly fewer than given | `sendBytes` |

| Missing | Consequence |
|---|---|
| Socket options, including `SO_REUSEADDR` | A restart on the same port waits for the kernel to release it; the server retries its bind for 75 seconds |
| `MSG_NOSIGNAL`, and a SIGPIPE handler in `System.Signal` | The process that starts the server must ignore SIGPIPE |
| A SIGTERM handler in `System.Signal` | A clean stop is an HTTP request from the loopback address, sent by the container's entry point |
| Timeouts, `select` or `poll` | One connection is served at a time, and a silent client holds it |
| A configurable listen backlog | Fixed at 20 connections |
| TLS | Terminated by a load balancer, or not at all |

## A property of the generated program worth knowing

The Chez backend writes `build/exec/idrisql` as a shell script that starts
the compiled program as a child process. A signal sent to the script does not
reach the database process. `tests/crash/run.sh` starts
`build/exec/idrisql_app/idrisql.so` directly for that reason.
