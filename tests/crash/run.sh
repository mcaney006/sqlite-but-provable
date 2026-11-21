#!/bin/sh
# Kill the database process with SIGKILL in the middle of a write workload,
# reopen the database, and check what recovery left. Repeats on the same
# database so that later rounds recover on top of earlier recoveries.
#
# The workload commits batches of 20 rows and prints a batch's number after
# its COMMIT returns. After each kill:
#   - the integrity check must pass;
#   - every batch present must hold exactly 20 rows (atomicity);
#   - the batches present must be 1..m with no gap;
#   - m must be at least the last batch number the process printed
#     (a commit that was acknowledged is still there).
#
# SIGKILL ends the process only. It says nothing about power loss, which
# this engine does not claim to survive: see docs/TRANSACTIONS.md.
#
#   ROUNDS      kills to perform (default 40)
#   CHECKPOINT  log bytes that trigger a checkpoint (default 65536, so that
#               kills also land inside checkpoints)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
APP="${IDRISQL_APP:-$root/build/exec/idrisql_app}"
ROUNDS="${ROUNDS:-40}"
CHECKPOINT="${CHECKPOINT:-65536}"
[ -x "$APP/idrisql.so" ] || { echo "crash: $APP/idrisql.so not built" >&2; exit 2; }

# build/exec/idrisql is a shell script that starts the program as a child.
# Killing that script leaves the database process running, so the program
# is started directly.
engine() {
  LD_LIBRARY_PATH="$APP${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  DYLD_LIBRARY_PATH="$APP${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$APP/idrisql.so" "$@"
}

work="$root/build/crash"
rm -rf "$work"
mkdir -p "$work"
db="$work/crash.idb"

sql() { engine "$db" --break-lock --cache 64 --checkpoint "$CHECKPOINT" --execute "$1" 2>"$work/err"; }

sql "CREATE TABLE log (id INTEGER PRIMARY KEY, batch INTEGER NOT NULL, n INTEGER NOT NULL, pad TEXT NOT NULL); CREATE INDEX log_batch ON log (batch)" \
  || { echo "crash: cannot create the table" >&2; cat "$work/err" >&2; exit 1; }

next=1
killed=0
failed=0
recovered=0
round=1
while [ "$round" -le "$ROUNDS" ]; do
  awk -v from="$next" 'BEGIN {
    pad = sprintf("%120s", ""); gsub(/ /, "x", pad)
    for (b = from; b < from + 400; b++) {
      print "BEGIN;"
      for (n = 1; n <= 20; n++) printf "INSERT INTO log (batch, n, pad) VALUES (%d, %d, '\''%s'\'');\n", b, n, pad
      print "COMMIT;"
      printf "SELECT %d;\n", b
    }
  }' > "$work/workload.sql"

  # Not through engine(): a function started with & runs in a subshell, and
  # the signal would reach that subshell.
  LD_LIBRARY_PATH="$APP${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  DYLD_LIBRARY_PATH="$APP${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$APP/idrisql.so" "$db" --break-lock --cache 64 --checkpoint "$CHECKPOINT" --file "$work/workload.sql" \
    > "$work/acked" 2>"$work/run.err" &
  pid=$!
  sleep "$(awk -v r="$round" 'BEGIN { srand(r); printf "%.2f", 0.03 + rand() * 0.45 }')"
  if kill -9 "$pid" 2>/dev/null; then killed=$((killed + 1)); fi
  wait "$pid" 2>/dev/null

  acked="$(tail -n 1 "$work/acked" 2>/dev/null)"
  case "$acked" in ''|*[!0-9]*) acked=0 ;; esac

  notice="$(sql ".check")"
  if grep -q '^recovered' "$work/err"; then recovered=$((recovered + 1)); fi
  if [ "$notice" != "ok" ]; then
    failed=$((failed + 1)); echo "FAIL round $round: integrity check: $notice"; cat "$work/err"
  fi
  partial="$(sql "SELECT batch, COUNT(*) FROM log GROUP BY batch HAVING COUNT(*) <> 20")"
  if [ -n "$partial" ]; then
    failed=$((failed + 1)); echo "FAIL round $round: partial batches: $partial"
  fi
  shape="$(sql "SELECT COUNT(DISTINCT batch), COALESCE(MIN(batch), 1), COALESCE(MAX(batch), 0) FROM log")"
  count="${shape%%|*}"; rest="${shape#*|}"; low="${rest%%|*}"; high="${rest#*|}"
  if [ "$low" != 1 ] || [ "$count" != "$high" ]; then
    failed=$((failed + 1)); echo "FAIL round $round: batches are not 1..m: count $count, min $low, max $high"
  fi
  if [ "$high" -lt "$acked" ]; then
    failed=$((failed + 1)); echo "FAIL round $round: batch $acked was acknowledged, but only $high are present"
  fi
  next=$((high + 1))
  round=$((round + 1))
done

rows="$(sql "SELECT COUNT(*) FROM log")"
printf 'crash: %d rounds, %d processes killed while running, %d recoveries replayed the log, %d batches (%s rows) survive, %d failures\n' \
  "$ROUNDS" "$killed" "$recovered" "$((next - 1))" "$rows" "$failed"
[ "$failed" -eq 0 ]
