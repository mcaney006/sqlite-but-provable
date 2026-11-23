#!/bin/sh
# Run the container image the way deploy/aws runs it: read-only root file
# system, no capabilities, the database on a volume, a bearer token. Check
# that it answers, stops cleanly, keeps its data, and that a second
# container never opens the database while the first is alive.
#
#   tests/container/run.sh [IMAGE]     default idrisql:dev
#   PORT    first of two host ports to use (default 15482)
#   DOCKER  docker command (default docker)
set -u
image="${1:-idrisql:dev}"
port="${PORT:-15482}"
docker="${DOCKER:-docker}"
name="idrisql-test-$$"
first="http://127.0.0.1:$port"
second="http://127.0.0.1:$((port + 1))"
token="container-test-token"
kept='{"results":[{"columns":["body"],"rows":[["kept"]]}]}'
passed=0
failed=0

cleanup() {
  $docker rm -f "$name" "$name-2" >/dev/null 2>&1
  $docker volume rm -f "$name" >/dev/null 2>&1
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); }
bad() { failed=$((failed + 1)); echo "FAIL $1"; }

# run NAME HOST-PORT [docker run options]
run() {
  cname="$1"; hport="$2"; shift 2
  $docker run -d --name "$cname" --read-only --cap-drop ALL \
    -e IDRISQL_TOKEN="$token" "$@" \
    -p "127.0.0.1:$hport:5480" -v "$name:/data" "$image" >/dev/null
}

# up URL TENTHS: wait for the server at URL to answer.
up() {
  tries=0
  until curl -s -m 1 "$1/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt "$2" ] && return 1
    sleep 0.1
  done
}

query() { curl -s -m 20 -X POST -H "Authorization: Bearer $token" --data-binary "$2" "$1/query"; }

run "$name" "$port" || { echo "container: could not start $image"; exit 1; }
if up "$first" 100; then ok; else bad "the server did not answer"; $docker logs "$name"; exit 1; fi

got="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST --data-binary 'SELECT 1' "$first/query")"
if [ "$got" = 401 ]; then ok; else bad "a request without the token got $got, expected 401"; fi

got="$(query "$first" "CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT NOT NULL); INSERT INTO note VALUES (1, 'kept'); SELECT body FROM note")"
want='{"results":[{"done":"CREATE TABLE"},{"changed":1},{"columns":["body"],"rows":[["kept"]]}]}'
if [ "$got" = "$want" ]; then ok; else bad "first query returned $got"; fi

# docker stop sends SIGTERM. The entry point turns it into a clean close.
$docker stop -t 30 "$name" >/dev/null
code="$($docker inspect -f '{{.State.ExitCode}}' "$name")"
if [ "$code" = 0 ]; then ok; else bad "docker stop: exit code $code, expected 0"; fi

$docker start "$name" >/dev/null
if up "$first" 100 && [ "$(query "$first" 'SELECT body FROM note')" = "$kept" ]; then ok
else bad "the row was not there after a restart"; fi

# A second container on the same volume, told to take over stale locks,
# must wait for as long as the first one is alive.
run "$name-2" "$((port + 1))" -e IDRISQL_BREAK_LOCK=1 -e IDRISQL_LOCK_STALE_SECONDS=6
sleep 9
if curl -s -m 1 "$second/health" >/dev/null 2>&1; then bad "a second container opened a database whose holder is alive"
elif [ "$(query "$first" 'SELECT body FROM note')" = "$kept" ]; then ok
else bad "the first container stopped answering while a second one waited"; fi

# SIGKILL leaves the lock on the volume. A start without the option must
# refuse it...
$docker kill "$name" >/dev/null
$docker start "$name" >/dev/null
code="$($docker wait "$name")"
if [ "$code" != 0 ] && $docker logs "$name" 2>&1 | grep -qi 'lock'; then ok
else bad "a start over a stale lock exited $code without naming the lock"; fi

# ...and the waiting container takes the lock once its holder has been
# silent for the six seconds it was given.
if up "$second" 300 && [ "$(query "$second" 'SELECT body FROM note')" = "$kept" ]; then ok
else bad "the waiting container did not take over a dead holder's lock"; $docker logs "$name-2" 2>&1 | tail -5; fi

# SIGTERM while a container is still waiting for the lock ends it at once.
$docker rm -f "$name" >/dev/null 2>&1
run "$name" "$port" -e IDRISQL_BREAK_LOCK=1 -e IDRISQL_LOCK_STALE_SECONDS=600
sleep 2
start="$(date +%s)"
$docker stop -t 30 "$name" >/dev/null
if [ $(( $(date +%s) - start )) -lt 10 ]; then ok; else bad "a waiting container ignored SIGTERM"; fi

printf 'container: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
