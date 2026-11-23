#!/bin/sh
# Container entry point.
#
#   serve [options]   answer SQL over HTTP (the default)
#   shell [options]   the interactive shell on the same database
#   anything else     passed to idrisql unchanged
#
# Environment:
#   IDRISQL_DATABASE    database directory (default /data/main.idb)
#   IDRISQL_PORT        port to serve on (default 5480). Set the port here,
#                       not with --serve: the stop request and the health
#                       check go to this one.
#   IDRISQL_TOKEN       bearer token POST /query requires; unset means none
#   IDRISQL_MAX_ROWS    largest result a statement may return (default 100000)
#   IDRISQL_BREAK_LOCK  1 to take over a lock whose holder has stopped
#                       marking itself alive (see below)
#   IDRISQL_LOCK_STALE_SECONDS
#                       how long the holder must have been silent (default 30)
#
# A container that holds the database touches "$db.alive" every two
# seconds. The engine cannot tell a dead lock holder from a live one, so
# this file is what IDRISQL_BREAK_LOCK=1 goes by: it waits until the file
# has not been touched for IDRISQL_LOCK_STALE_SECONDS, and only then
# passes --break-lock. A lock with no such file beside it was not taken by
# this entry point and is treated as stale. The file is never removed: a
# container that fails to get the lock must not erase the holder's mark.
set -eu

db="${IDRISQL_DATABASE:-/data/main.idb}"
port="${IDRISQL_PORT:-5480}"
alive="$db.alive"

# Mark this container alive until process $1 is gone. If the mark cannot
# be written five times running, another container may soon take this one
# for dead, so the process is killed first: a killed process is a case
# recovery handles, two writers are not.
heartbeat() {
  touch "$alive"
  (
    missed=0
    while kill -0 "$1" 2>/dev/null; do
      sleep 2
      if touch "$alive" 2>/dev/null; then missed=0; else missed=$((missed + 1)); fi
      if [ "$missed" -ge 5 ]; then
        echo "idrisql: cannot write $alive; stopping so that no other container opens the database alongside this one" >&2
        kill -9 "$1" 2>/dev/null || true
        exit 0
      fi
    done
  ) &
}

# Seconds since the lock holder last marked itself alive. Both times are
# set by the file system that holds the database, so the clocks of two
# containers do not have to agree.
silent_for() {
  [ -e "$alive" ] || { echo 1000000; return; }
  # Anything that goes wrong here reads as "alive": waiting is the safe side.
  touch "$db.clock" 2>/dev/null || { echo 0; return; }
  now="$(stat -c %Y "$db.clock" 2>/dev/null)" || { echo 0; return; }
  seen="$(stat -c %Y "$alive" 2>/dev/null)" || { echo 0; return; }
  echo $((now - seen))
}

case "${1:-serve}" in
  serve)
    [ "$#" -gt 0 ] && shift
    set -- "$db" --serve "$port" --host 0.0.0.0 "$@"
    [ -n "${IDRISQL_MAX_ROWS:-}" ] && set -- "$@" --max-rows "$IDRISQL_MAX_ROWS"

    trap 'exit 143' TERM INT
    if [ "${IDRISQL_BREAK_LOCK:-0}" = 1 ] && [ -d "$db/LOCK" ]; then
      stale="${IDRISQL_LOCK_STALE_SECONDS:-30}"
      told=0
      while [ -d "$db/LOCK" ] && [ "$(silent_for)" -lt "$stale" ]; do
        [ "$told" = 1 ] || echo "idrisql: $db is locked and its holder was alive within the last $stale seconds; waiting" >&2
        told=1
        sleep 1
      done
      if [ -d "$db/LOCK" ]; then
        echo "idrisql: the holder of the lock on $db has stopped; taking the lock over" >&2
        set -- "$@" --break-lock
      fi
    fi

    # The socket library sends without MSG_NOSIGNAL, so a client that
    # disconnects early would end the server with SIGPIPE. An ignored
    # signal stays ignored in the program started below.
    trap '' PIPE

    # The program cannot catch SIGTERM itself. Ask it over the loopback
    # address to close the database, so the lock is released and the log
    # is checkpointed. It may not be listening yet, so ask until it has
    # answered or is gone.
    child=""
    signalled=0
    stop() {
      signalled=1
      [ -n "$child" ] || return 0
      while kill -0 "$child" 2>/dev/null; do
        wget -q -Y off -O /dev/null --post-data= "http://127.0.0.1:$port/shutdown" 2>/dev/null && break
        sleep 1
      done
    }
    trap stop TERM INT

    touch "$alive"
    idrisql "$@" &
    child=$!
    heartbeat "$child"
    [ "$signalled" = 0 ] || stop

    # A signal interrupts wait before the program has exited; wait again
    # for its real status. 127 means the earlier wait had already collected
    # it, and that status stands.
    status=0
    wait "$child" || status=$?
    while [ "$signalled" = 1 ]; do
      signalled=0
      again=0
      wait "$child" || again=$?
      [ "$again" = 127 ] || status=$again
    done
    exit "$status"
    ;;
  shell)
    shift
    heartbeat "$$"
    exec idrisql "$db" "$@"
    ;;
  *)
    exec idrisql "$@"
    ;;
esac
