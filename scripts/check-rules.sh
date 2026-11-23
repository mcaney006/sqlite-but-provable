#!/bin/sh
# Fail if the sources use a construct this project rules out: foreign
# functions written here, unchecked casts, totality escapes, or another
# database engine.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2
status=0

# Relative paths, so a space in the checkout's own path does not matter.
files="$(find src -name '*.idr')"
[ -n "$files" ] || { echo "check-rules: no sources under src" >&2; exit 2; }

# Print the lines that match. A grep that cannot run is an error, not a
# clean result.
scan() {
  # shellcheck disable=SC2086
  grep -nE -- "$1" $files
  code=$?
  [ "$code" -le 1 ] || { echo "check-rules: grep failed" >&2; exit 2; }
  return "$code"
}

deny() {
  if scan "$1"; then
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
named="$(scan '(sqlite|SQLite)')"
[ $? -le 1 ] || exit 2
if printf '%s\n' "$named" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(--|\|\|\|)' | grep .; then
  echo "check-rules: found a reference to SQLite in code" >&2
  status=1
fi

[ "$status" -eq 0 ] && echo "check-rules: ok"
exit "$status"
