#!/bin/sh
# Fail if the sources use a construct this project rules out: foreign
# functions written here, unchecked casts, totality escapes, or another
# database engine.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2
status=0

deny() {
  if grep -rnE --include='*.idr' "$1" src; then
    echo "check-rules: found $2" >&2
    status=1
  fi
}

deny '%foreign' 'a foreign function declaration'
deny '(^|[^A-Za-z_])(believe_me|really_believe_me)([^A-Za-z_]|$)' 'an unchecked cast'
deny '(^|[^A-Za-z_])(assert_total|assert_smaller|idris_crash|unsafePerformIO)([^A-Za-z_]|$)' 'a totality or purity escape'
deny '%default[[:space:]]+partial|^[[:space:]]*partial[[:space:]]*$' 'a partiality declaration'
# SQLite may be named in a comment that explains a dialect choice, never in
# code: only tests/differential and bench/ run it, as separate programs.
if grep -rnE --include='*.idr' '(sqlite|SQLite)' src | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(--|\|\|\|)'; then
  echo "check-rules: found a reference to SQLite in code" >&2
  status=1
fi

[ "$status" -eq 0 ] && echo "check-rules: ok"
exit "$status"
