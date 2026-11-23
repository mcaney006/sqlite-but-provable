#!/bin/sh
# Start the server on a real socket and check its answers with curl.
#
#   PORT  port to use (default 15481)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
APP="${IDRISQL_APP:-$root/build/exec/idrisql_app}"
PORT="${PORT:-15481}"
[ -x "$APP/idrisql.so" ] || { echo "server: $APP/idrisql.so not built" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "server: curl not found" >&2; exit 2; }

work="$root/build/server-test"
rm -rf "$work"
mkdir -p "$work"
db="$work/served.idb"
base="http://127.0.0.1:$PORT"
passed=0
failed=0
pid=""

# The program is started directly, with SIGPIPE ignored as the container's
# entry point does, so that a signal sent to $pid reaches it.
start() {
  (
    trap '' PIPE
    unset IDRISQL_TOKEN
    [ -n "${1:-}" ] && { IDRISQL_TOKEN="$1"; export IDRISQL_TOKEN; }
    LD_LIBRARY_PATH="$APP${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    DYLD_LIBRARY_PATH="$APP${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
      exec "$APP/idrisql.so" "$db" --serve "$PORT" --max-rows 70000 2>"$work/server.err"
  ) &
  pid=$!
  # A restart on the same port can wait for the kernel to release it: the
  # server retries its bind for up to 75 seconds.
  tries=0
  until curl -s -m 1 "$base/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 900 ] && { echo "server: did not start"; cat "$work/server.err"; exit 1; }
    kill -0 "$pid" 2>/dev/null || { echo "server: exited at startup"; cat "$work/server.err"; exit 1; }
    sleep 0.1
  done
}

# Whatever happens, do not leave a server holding the port and the lock.
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null' EXIT

stop() {
  curl -s -m 5 -X POST "$base/shutdown" >/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}

# check NAME EXPECTED-STATUS EXPECTED-BODY curl-arguments...
check() {
  name="$1"; want_status="$2"; want_body="$3"; shift 3
  got="$(curl -s -m 20 -o "$work/body" -w '%{http_code}' "$@")"
  body="$(cat "$work/body")"
  if [ "$got" = "$want_status" ] && [ "$body" = "$want_body" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected %s %s\n  got      %s %s\n' "$name" "$want_status" "$want_body" "$got" "$body"
  fi
}

sql() { check "$1" "$2" "$3" -X POST "$base/query" --data-binary "$4"; }

start ""

check "health" 200 '{"status":"ok"}' "$base/health"
check "unknown path" 404 '{"error":"no such path"}' "$base/nowhere"
check "wrong method" 405 '{"error":"method not allowed"}' "$base/query"

sql "schema, rows and a query in one request" 200 \
  '{"results":[{"done":"CREATE TABLE"},{"changed":2},{"columns":["id","name","score","ok","raw"],"rows":[[1,"Ada \"L\"",1.5,true,{"blob":"00FF"}],[2,null,null,false,null]]}]}' \
  "CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, score REAL, ok BOOLEAN, raw BLOB);
   INSERT INTO person VALUES (1, 'Ada \"L\"', 1.5, TRUE, X'00FF'), (2, NULL, NULL, FALSE, NULL);
   SELECT * FROM person ORDER BY id"

sql "text outside ASCII" 200 '{"results":[{"changed":1},{"columns":["name"],"rows":[["Zoë €"]]}]}' \
  "INSERT INTO person (id, name) VALUES (3, 'Zoë €'); SELECT name FROM person WHERE id = 3"

sql "a semicolon inside a string does not split the statement" 200 \
  '{"results":[{"columns":["a;b"],"rows":[["a;b"]]}]}' "SELECT 'a;b' AS \"a;b\""

sql "constraint violation" 400 \
  '{"error":"constraint violation: UNIQUE constraint failed: person.id","kind":"constraint","completed":0}' \
  "INSERT INTO person (id) VALUES (1)"

sql "syntax error after a statement that ran" 400 \
  '{"error":"syntax error at 1:2: expected a statement but found '"'"'SELEC'"'"'","kind":"syntax","completed":1}' \
  "SELECT COUNT(*) FROM person; SELEC 1"

sql "a committed transaction" 200 '{"results":[{"done":"BEGIN"},{"changed":1},{"done":"COMMIT"}]}' \
  "BEGIN; INSERT INTO person (id, name) VALUES (4, 'kept'); COMMIT"

sql "a transaction left open is rolled back" 400 \
  '{"error":"the request ended with a transaction open; it was rolled back","kind":"transaction","completed":2}' \
  "BEGIN; INSERT INTO person (id, name) VALUES (5, 'dropped')"

sql "the next request sees the committed row and not the rolled-back one" 200 \
  '{"results":[{"columns":["id"],"rows":[[1],[2],[3],[4]]}]}' "SELECT id FROM person ORDER BY id"

sql "an empty request" 200 '{"results":[]}' ""

sql "comments after and between statements are not statements" 200 \
  '{"results":[{"columns":["1"],"rows":[[1]]},{"columns":["2"],"rows":[[2]]}]}' \
  "SELECT 1; -- between
   ; SELECT 2; /* after */ -- the end"

check "two Content-Length headers that disagree" 400 '{"error":"conflicting Content-Length headers"}' \
  -X POST "$base/query" -H 'Content-Length: 8' -H 'Content-Length: 9' --data-binary "SELECT 1"

# curl waits a second for 100 Continue before it sends a body it announced
# this way; an answer that takes that long means the server never sent it.
took="$(curl -s -m 20 -o "$work/body" -w '%{time_total}' -X POST "$base/query" -H 'Expect: 100-continue' --data-binary "SELECT 7")"
if [ "$(cat "$work/body")" = '{"results":[{"columns":["7"],"rows":[[7]]}]}' ] && awk -v t="$took" 'BEGIN { exit !(t < 0.9) }'; then
  passed=$((passed + 1))
else
  failed=$((failed + 1)); echo "FAIL Expect: 100-continue took ${took}s and returned $(cat "$work/body")"
fi

printf '\377\376' > "$work/not-utf8"
check "a body that is not UTF-8" 400 '{"error":"request body is not UTF-8"}' \
  -X POST "$base/query" --data-binary "@$work/not-utf8"

check "a Content-Length too large for any integer" 411 '{"error":"POST /query needs a Content-Length"}' \
  -X POST "$base/query" -H 'Content-Length: 18446744073709551615' --data-binary "SELECT 1"

# 600 KiB that the server answers without using: it must read them first,
# or closing the connection resets it and the client loses the answer.
awk 'BEGIN { for (i = 0; i < 60000; i++) printf "-- padding\n" }' > "$work/unused"
check "an unknown path with a body" 404 '{"error":"no such path"}' \
  -X POST "$base/nowhere" --data-binary "@$work/unused"

check "no Content-Length" 411 '{"error":"POST /query needs a Content-Length"}' \
  -X POST "$base/query" -H 'Content-Length:' -H 'Transfer-Encoding: chunked' --data-binary "SELECT 1"

# A result of 60,000 rows, about 3 MiB of JSON, and one row over the limit.
awk 'BEGIN { print "CREATE TABLE big (id INTEGER PRIMARY KEY, pad TEXT);"; print "BEGIN;"
             for (i = 1; i <= 300; i++) printf "INSERT INTO big VALUES (%d, '\''padding-padding'\'');\n", i
             print "COMMIT;" }' > "$work/big.sql"
curl -s -m 30 -o /dev/null -X POST "$base/query" --data-binary "@$work/big.sql"
large="SELECT a.id, b.id, a.pad FROM big a CROSS JOIN big b LIMIT 60000"
curl -s -m 30 -o "$work/large" -X POST "$base/query" --data-binary "$large"
rows="$(tr -cd '[' < "$work/large" | wc -c | tr -d ' ')"
# One bracket for "results", one for "columns", one for "rows", one per row.
if [ "$rows" = 60003 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL large result: $rows brackets"; fi
sql "the row limit is for the whole response" 400 \
  '{"error":"runtime error: the result has more rows than the server'"'"'s limit; add LIMIT","kind":"runtime","completed":1}' \
  "$large; $large"
sql "a result over the row limit" 400 \
  '{"error":"runtime error: the result has more rows than the server'"'"'s limit; add LIMIT","kind":"runtime","completed":0}' \
  "SELECT a.id FROM big a CROSS JOIN big b"

# Clients that give up before the answer arrives must not stop the server.
i=0
while [ "$i" -lt 5 ]; do
  curl -s -m 0.05 -o /dev/null -X POST "$base/query" --data-binary "$large"
  i=$((i + 1))
done
sleep 2
check "the server survives clients that disconnect early" 200 '{"status":"ok"}' "$base/health"

stop
if [ -d "$db/LOCK" ]; then failed=$((failed + 1)); echo "FAIL shutdown left the lock behind"; else passed=$((passed + 1)); fi

# With a token: refused without it, accepted with it, and the data is
# still there after the restart.
start "s3cret-token"
sql "no token" 401 '{"error":"missing or wrong bearer token"}' "SELECT 1"
check "wrong token" 401 '{"error":"missing or wrong bearer token"}' \
  -X POST "$base/query" -H 'Authorization: Bearer nope' --data-binary "SELECT 1"
check "wrong token with a body" 401 '{"error":"missing or wrong bearer token"}' \
  -X POST "$base/query" -H 'Authorization: Bearer nope' --data-binary "@$work/unused"
check "right token, data from before the restart" 200 '{"results":[{"columns":["COUNT(*)"],"rows":[[4]]}]}' \
  -X POST "$base/query" -H 'Authorization: Bearer s3cret-token' --data-binary "SELECT COUNT(*) FROM person"
check "health needs no token" 200 '{"status":"ok"}' "$base/health"
stop

printf 'server: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
