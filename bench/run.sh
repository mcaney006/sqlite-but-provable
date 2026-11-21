#!/bin/sh
# Load the same generated data into IdrisQL and SQLite, run the same
# statements through both, check that they print the same results, and
# report wall-clock time for each phase.
#
# This is also the scale test: the default data set is 200,000 rows in
# three tables with three secondary indexes, about ten times the size of
# the buffer pool it is run with.
#
#   SCALE   multiplier for the row counts (default 1 = 200,000 rows)
#   CACHE   IdrisQL buffer pool in 4 KiB pages (default 512 = 2 MiB, the
#           size of SQLite's default page cache)
#   SEED    seed of the generated data
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
IDRISQL="${IDRISQL:-$root/build/exec/idrisql}"
SQLITE3="${SQLITE3:-sqlite3}"
SCALE="${SCALE:-1}"
CACHE="${CACHE:-512}"
SEED="${SEED:-20261121}"
command -v "$SQLITE3" >/dev/null 2>&1 || { echo "bench: $SQLITE3 not found" >&2; exit 2; }
[ -x "$IDRISQL" ] || { echo "bench: $IDRISQL not built" >&2; exit 2; }

work="$root/build/bench"
rm -rf "$work"
mkdir -p "$work"
ours="$work/ours.idb"
fast="$work/sqlite-off.db"
full="$work/sqlite-full.db"

customers=$((20000 * SCALE))
orders=$((120000 * SCALE))
events=$((60000 * SCALE))

gen() {
  awk -v seed="$SEED" -v customers="$customers" -v orders="$orders" -v events="$events" -v phase="$1" '
    function rnd(n) { seed = (seed * 48271) % 2147483647; return seed % n }
    BEGIN {
      split("north south east west centre", region, " ")
      split("new paid shipped returned", status, " ")
      split("created packed sent delivered", kind, " ")
      if (phase == "load") {
        print "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, region TEXT NOT NULL, score INTEGER NOT NULL);"
        print "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL, status TEXT NOT NULL, amount INTEGER NOT NULL, note TEXT NOT NULL);"
        print "CREATE TABLE events (id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL, kind TEXT NOT NULL);"
        print "CREATE INDEX orders_customer ON orders (customer_id);"
        print "CREATE INDEX orders_status_amount ON orders (status, amount);"
        print "CREATE INDEX events_order ON events (order_id);"
        print "BEGIN;"
        for (i = 1; i <= customers; i++)
          printf "INSERT INTO customers VALUES (%d, '\''customer %d'\'', '\''%s'\'', %d);\n", i, i, region[1 + rnd(5)], rnd(1000)
        for (i = 1; i <= orders; i++)
          printf "INSERT INTO orders VALUES (%d, %d, '\''%s'\'', %d, '\''order note %d'\'');\n", i, 1 + rnd(customers), status[1 + rnd(4)], 1 + rnd(100000), i
        for (i = 1; i <= events; i++)
          printf "INSERT INTO events VALUES (%d, %d, '\''%s'\'');\n", i, 1 + rnd(orders), kind[1 + rnd(4)]
        print "COMMIT;"
      }
      if (phase == "point")
        for (i = 1; i <= 2000; i++) printf "SELECT name, score FROM customers WHERE id = %d;\n", 1 + rnd(customers)
      if (phase == "index")
        for (i = 1; i <= 2000; i++) printf "SELECT COUNT(*), SUM(amount) FROM orders WHERE customer_id = %d;\n", 1 + rnd(customers)
      if (phase == "range")
        for (i = 1; i <= 200; i++) { lo = 1 + rnd(99000); printf "SELECT COUNT(*) FROM orders WHERE status = '\''paid'\'' AND amount BETWEEN %d AND %d;\n", lo, lo + 1000 }
      if (phase == "scan") {
        print "SELECT status, COUNT(*), SUM(amount), MIN(amount), MAX(amount) FROM orders GROUP BY status ORDER BY status;"
        print "SELECT COUNT(*) FROM orders WHERE note LIKE '\''%77'\'';"
        print "SELECT kind, COUNT(*) FROM events GROUP BY kind ORDER BY kind;"
      }
      if (phase == "join") {
        print "SELECT c.region, COUNT(*), SUM(o.amount) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.region ORDER BY c.region;"
        print "SELECT o.status, COUNT(*) FROM orders o JOIN events e ON e.order_id = o.id WHERE e.kind = '\''sent'\'' GROUP BY o.status ORDER BY o.status;"
        print "SELECT c.region, COUNT(e.id) FROM customers c JOIN orders o ON o.customer_id = c.id JOIN events e ON e.order_id = o.id WHERE c.score > 990 GROUP BY c.region ORDER BY c.region;"
      }
      if (phase == "sort") {
        print "SELECT id, amount FROM orders ORDER BY amount DESC, id LIMIT 20;"
        print "SELECT id FROM orders ORDER BY note LIMIT 20;"
        print "SELECT COUNT(DISTINCT customer_id), COUNT(DISTINCT amount) FROM orders;"
      }
      if (phase == "write")
        for (i = 1; i <= 1000; i++) {
          k = rnd(3)
          if (k == 0) printf "INSERT INTO orders VALUES (%d, %d, '\''new'\'', %d, '\''late order'\'');\n", orders + i, 1 + rnd(customers), 1 + rnd(100000)
          if (k == 1) printf "UPDATE orders SET amount = amount + 1, status = '\''paid'\'' WHERE id = %d;\n", 1 + rnd(orders)
          if (k == 2) printf "DELETE FROM orders WHERE id = %d;\n", 1 + rnd(orders)
        }
      if (phase == "delete") {
        print "DELETE FROM events WHERE id % 3 = 0;"
        print "UPDATE customers SET score = score + 1 WHERE region = '\''north'\'';"
        print "SELECT COUNT(*) FROM events;"
        print "SELECT SUM(score) FROM customers;"
        print "SELECT COUNT(*), SUM(amount) FROM orders;"
      }
    }'
}

# Seconds of wall-clock time a command takes reading its statements from
# the file given first, to a hundredth.
timed() {
  input="$1"; shift
  /usr/bin/time -p "$@" 2>"$work/time.txt" >"$work/out.txt" <"$input"
  awk '$1 == "real" { print $2 }' "$work/time.txt"
}

printf '%s\n' "| phase | statements | IdrisQL (s) | SQLite, synchronous=OFF (s) | SQLite, default (s) | results match |"
printf '%s\n' "|---|---:|---:|---:|---:|---|"
mismatch=0
for phase in load point index range scan join sort write delete; do
  gen "$phase" > "$work/$phase.sql"
  n="$(grep -c ';' "$work/$phase.sql")"
  { echo "PRAGMA synchronous=OFF;"; cat "$work/$phase.sql"; } > "$work/$phase.off.sql"

  a="$(timed "$work/$phase.sql" "$IDRISQL" "$ours" --cache "$CACHE")"; cp "$work/out.txt" "$work/$phase.ours"
  b="$(timed "$work/$phase.off.sql" "$SQLITE3" -batch -list -nullvalue NULL "$fast")"; cp "$work/out.txt" "$work/$phase.off"
  c="$(timed "$work/$phase.sql" "$SQLITE3" -batch -list -nullvalue NULL "$full")"; cp "$work/out.txt" "$work/$phase.full"

  if cmp -s "$work/$phase.ours" "$work/$phase.off" && cmp -s "$work/$phase.ours" "$work/$phase.full"; then
    same=yes
  else
    same=NO; mismatch=$((mismatch + 1))
  fi
  printf '| %s | %s | %s | %s | %s | %s |\n' "$phase" "$n" "$a" "$b" "$c" "$same"
done

echo
check="$("$IDRISQL" "$ours" --execute ".check" 2>&1)"
echo "integrity check: $check"
"$IDRISQL" "$ours" --cache "$CACHE" --execute ".stats" 2>&1 | sed 's/^/  /'
echo "rows loaded: $((customers + orders + events))"
echo "IdrisQL database: $(du -sk "$ours" | awk '{print $1}') KiB in $(find "$ours" -type f | wc -l | tr -d ' ') files"
echo "SQLite database: $(du -sk "$fast" | awk '{print $1}') KiB"
[ "$mismatch" -eq 0 ] && [ "$check" = "ok" ]
