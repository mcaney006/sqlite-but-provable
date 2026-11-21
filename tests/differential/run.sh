#!/bin/sh
# Run the same statements through IdrisQL and the sqlite3 command-line
# shell and compare what they print. SQLite is used here as a reference
# for results only; IdrisQL never calls it.
#
#   SEED  seed of the generated data (default 20261121)
#   ROWS  rows in the emp table (default 3000)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
IDRISQL="${IDRISQL:-$root/build/exec/idrisql}"
SQLITE3="${SQLITE3:-sqlite3}"
SEED="${SEED:-20261121}"
ROWS="${ROWS:-3000}"

command -v "$SQLITE3" >/dev/null 2>&1 || { echo "differential: $SQLITE3 not found" >&2; exit 2; }
[ -x "$IDRISQL" ] || { echo "differential: $IDRISQL not built" >&2; exit 2; }

work="$root/build/differential"
rm -rf "$work"
mkdir -p "$work"
ours="$work/ours.idb"
theirs="$work/theirs.sqlite"

# The same data for both engines, from a Lehmer generator so that every
# awk produces the same file for the same seed.
awk -v seed="$SEED" -v rows="$ROWS" '
  function rnd(n) { seed = (seed * 48271) % 2147483647; return seed % n }
  BEGIN {
    print "CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, budget INTEGER NOT NULL);"
    print "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT NOT NULL, dept_id INTEGER, salary INTEGER NOT NULL, rating REAL, hired TEXT NOT NULL);"
    print "CREATE TABLE project (id INTEGER PRIMARY KEY, dept_id INTEGER NOT NULL, title TEXT NOT NULL);"
    print "CREATE INDEX emp_dept ON emp (dept_id);"
    print "CREATE INDEX emp_salary_name ON emp (salary, name);"
    print "CREATE INDEX project_dept ON project (dept_id);"
    print "BEGIN;"
    for (i = 1; i <= 12; i++)
      printf "INSERT INTO dept VALUES (%d, '\''dept-%02d'\'', %d);\n", i, i, 100000 + rnd(900) * 1000
    for (i = 1; i <= rows; i++) {
      d = rnd(12); dept = (d == 0) ? "NULL" : d
      rating = (rnd(10) == 0) ? "NULL" : sprintf("%.2f", rnd(21) * 0.25)
      printf "INSERT INTO emp VALUES (%d, '\''%s%d'\'', %s, %d, %s, '\''20%02d-%02d-%02d'\'');\n", \
             i, (i % 10 == 0) ? "Emp" : "emp", i, dept, 30000 + rnd(120001), rating, 15 + rnd(10), 1 + rnd(12), 1 + rnd(28)
    }
    for (i = 1; i <= 20; i++)
      printf "INSERT INTO project VALUES (%d, %d, '\''project-%d'\'');\n", i, 1 + rnd(12), i
    print "COMMIT;"
  }' > "$work/load.sql"

run_ours() { "$IDRISQL" "$ours" --execute "$1" 2>"$work/ours.err"; }
run_theirs() { "$SQLITE3" -batch -list -nullvalue NULL "$theirs" "$1" 2>"$work/theirs.err"; }

"$IDRISQL" "$ours" --file "$work/load.sql" >/dev/null || { echo "differential: IdrisQL could not load the data" >&2; exit 1; }
"$SQLITE3" -batch "$theirs" < "$work/load.sql" || { echo "differential: sqlite3 could not load the data" >&2; exit 1; }

passed=0
failed=0

compare() {
  round="$1"
  n=0
  while IFS= read -r q; do
    n=$((n + 1))
    [ -n "$q" ] || continue
    run_ours "$q" > "$work/ours.out"; a=$?
    run_theirs "$q" > "$work/theirs.out"; b=$?
    if [ "$a" -eq 0 ] && [ "$b" -eq 0 ] && cmp -s "$work/ours.out" "$work/theirs.out"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      printf 'FAIL %s query %d: %s\n' "$round" "$n" "$q"
      [ "$a" -eq 0 ] || sed 's/^/  idrisql: /' "$work/ours.err"
      [ "$b" -eq 0 ] || sed 's/^/  sqlite3: /' "$work/theirs.err"
      diff "$work/ours.out" "$work/theirs.out" | head -6 | sed 's/^/  /'
    fi
  done < "$here/queries.sql"
}

compare "after load"

# Statements both engines must refuse, leaving the data as it was.
n=0
while IFS= read -r q; do
  n=$((n + 1))
  [ -n "$q" ] || continue
  run_ours "$q" >/dev/null; a=$?
  run_theirs "$q" >/dev/null; b=$?
  if [ "$a" -ne 0 ] && [ "$b" -ne 0 ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL rejected statement %d (idrisql exit %d, sqlite3 exit %d): %s\n' "$n" "$a" "$b" "$q"
  fi
done < "$here/rejected.sql"

n=0
while IFS= read -r q; do
  n=$((n + 1))
  [ -n "$q" ] || continue
  run_ours "$q" >/dev/null; a=$?
  run_theirs "$q" >/dev/null; b=$?
  if [ "$a" -ne 0 ] || [ "$b" -ne 0 ]; then
    failed=$((failed + 1))
    printf 'FAIL mutation %d (idrisql exit %d, sqlite3 exit %d): %s\n' "$n" "$a" "$b" "$q"
    sed 's/^/  idrisql: /' "$work/ours.err"; sed 's/^/  sqlite3: /' "$work/theirs.err"
  fi
done < "$here/mutations.sql"

compare "after mutations"

check="$("$IDRISQL" "$ours" --execute ".check" 2>&1)"
if [ "$check" = "ok" ]; then
  passed=$((passed + 1))
else
  failed=$((failed + 1))
  printf 'FAIL integrity check: %s\n' "$check"
fi

printf 'differential: %d passed, %d failed (seed %s, %s rows)\n' "$passed" "$failed" "$SEED" "$ROWS"
[ "$failed" -eq 0 ]
