# SQL compatibility

IdrisQL accepts a subset of SQL. Where it accepts a statement, the intent is
that it means what the same statement means in SQLite, and
`tests/differential/run.sh` checks that for 86 queries and 12 data changes.
The differences are listed under "Differences from SQLite" below.

## Statements

| Statement | Supported forms |
|---|---|
| `CREATE TABLE` | `IF NOT EXISTS`; column constraints `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT <constant>`, `CHECK (<expr>)`, `REFERENCES t(c)`; table constraints `PRIMARY KEY (..)`, `UNIQUE (..)`, `CHECK (..)`, `FOREIGN KEY (..) REFERENCES t(..)` |
| `DROP TABLE` | `IF EXISTS` |
| `CREATE INDEX` | `UNIQUE`, `IF NOT EXISTS`, one or more columns |
| `DROP INDEX` | `IF EXISTS`. An index that backs a `PRIMARY KEY` or `UNIQUE` constraint cannot be dropped. |
| `INSERT` | `INSERT INTO t [(columns)] VALUES (..), (..), ...` |
| `SELECT` | `DISTINCT`; `*` and `t.*`; column aliases; `FROM` with table aliases; `[INNER] JOIN .. ON`, `LEFT [OUTER] JOIN .. ON`, `CROSS JOIN`, comma joins; `WHERE`; `GROUP BY`; `HAVING`; `ORDER BY` by expression, alias or position, `ASC`/`DESC`; `LIMIT n [OFFSET m]`; `SELECT` without `FROM` |
| `UPDATE` | `UPDATE t SET c = expr, ... [WHERE ..]` |
| `DELETE` | `DELETE FROM t [WHERE ..]` |
| `BEGIN [TRANSACTION]`, `COMMIT`, `END`, `ROLLBACK` | See `docs/TRANSACTIONS.md` |
| `EXPLAIN <statement>` | Logical plan, plan after rewrites, and physical plan |
| `EXPLAIN QUERY PLAN <statement>` | Physical plan only |
| `ANALYZE` | Counts rows per table and distinct keys per index for the planner |

`?` and `?N` mark parameters in any statement. Their types are inferred, and
a bound value of another type is refused before the statement runs.

## Types

| Type | Accepted names | Values |
|---|---|---|
| INTEGER | `INTEGER`, `INT`, `BIGINT` | 64-bit signed |
| REAL | `REAL`, `FLOAT`, `DOUBLE [PRECISION]` | IEEE 754 double; NaN is stored as NULL |
| TEXT | `TEXT`, `VARCHAR[(n)]`, `CHAR[(n)]` | Unicode text; the length in parentheses is ignored |
| BLOB | `BLOB` | bytes, written `X'0AFF'` |
| BOOLEAN | `BOOLEAN`, `BOOL` | `TRUE`, `FALSE` |

Columns are statically typed. A value of the wrong type is rejected when the
statement is checked, before anything runs. The only implicit conversions:
INTEGER widens to REAL, and the literals `0` and `1` are accepted where a
BOOLEAN is required.

## Expressions

| Kind | Supported |
|---|---|
| Arithmetic | `+ - * /` on INTEGER and REAL, `%` on INTEGER, unary `-` and `+` |
| Text | `||` on TEXT |
| Comparison | `= == <> != < <= > >=`, `IS NULL`, `IS NOT NULL`, `[NOT] BETWEEN`, `[NOT] IN (list)`, `[NOT] LIKE` with `%` and `_` |
| Logic | `AND`, `OR`, `NOT`, with SQL three-valued logic |
| Functions | `LENGTH`, `UPPER`, `LOWER`, `ABS`, `COALESCE`, `CAST(x AS type)` |
| Aggregates | `COUNT(*)`, `COUNT(x)`, `SUM`, `AVG`, `MIN`, `MAX`; `DISTINCT` inside `COUNT`, `SUM` and `AVG` |
| Literals | integers, reals (`1.5`, `.5`, `1e3`), strings with `''` for a quote, `X'..'` blobs, `TRUE`, `FALSE`, `NULL` |
| Identifiers | case-insensitive; `"double quoted"` keeps spaces and reserved words |
| Comments | `-- to end of line` and `/* .. */` |

Arithmetic rules, each checked against SQLite by the differential tests:
integer division truncates toward zero; `%` takes the sign of the dividend;
division or remainder by zero gives NULL.

## Constraints

| Constraint | Enforcement |
|---|---|
| `PRIMARY KEY` on one INTEGER column | That column is the rowid. Omitted or NULL on insert, it is assigned one more than the largest rowid in the table, and at least 1. |
| Other `PRIMARY KEY` | NOT NULL on each column and a unique index named `<table>_pkey` |
| `UNIQUE` | A unique index named `<table>_<columns>_key`. Rows with a NULL in the key do not conflict. |
| `NOT NULL` | Checked on insert and update |
| `DEFAULT` | A constant expression, used when an insert names other columns |
| `CHECK` | Evaluated on insert and update. A result of NULL passes. |
| `FOREIGN KEY`, `REFERENCES` | Parsed, stored and shown by `.schema`. Not enforced. |

## Differences from SQLite

| Topic | SQLite | IdrisQL |
|---|---|---|
| Typing | Dynamic, with type affinity | Static. `'a' = 1`, `1 || 'x'` and `a + 'x'` are errors. |
| A write that fails inside a transaction | Undoes the statement | Rolls back the transaction |
| Integer overflow | Converts to REAL | Error |
| `SUM` of integers that overflows | Error | Error |
| Booleans | Integers 0 and 1 | A type; printed `TRUE` and `FALSE` |
| `LIKE` | ASCII case-insensitive, `ESCAPE` clause | ASCII case-insensitive, no `ESCAPE` |
| `GROUP BY` position (`GROUP BY 1`) | Accepted | Not accepted; `ORDER BY 1` is |
| Bare columns in a grouped query | Accepted | Error unless the column is in `GROUP BY` |
| Foreign keys | Enforced when enabled | Never enforced |
| NULL ordering | NULLs first in `ASC` | Same; `NULLS FIRST`/`LAST` is not parsed |
| Text collation | Bytewise by default | Bytewise by code point, no other collation |

## Not supported

Each of these is a syntax error. For most the message names the feature, for
example `subqueries are not supported`.

| Feature | Example |
|---|---|
| Subqueries | `SELECT (SELECT 1)`, `x IN (SELECT ..)` |
| Set operations | `UNION`, `INTERSECT`, `EXCEPT` |
| `CASE` | `CASE WHEN .. THEN .. END` |
| `INSERT .. SELECT`, `INSERT .. DEFAULT VALUES`, `DEFAULT` as a value | |
| `ALTER TABLE` | |
| Views, triggers, virtual tables | |
| `RIGHT` and `FULL` joins, `NATURAL`, `USING` | |
| Window functions | `OVER (..)` |
| Savepoints | `SAVEPOINT`, `RELEASE` |
| Descending index columns | `CREATE INDEX i ON t (a DESC)` |
| `LIMIT m, n`; `OFFSET` without `LIMIT` | |
| Hexadecimal integer literals | `0x10` |
| `PRAGMA`, `VACUUM`, `ATTACH` | |
| Functions other than those listed | `SUBSTR`, `ROUND`, date and time functions |

## Shell

```
idrisql DATABASE [--execute SQL | --file PATH] [--mode list|table]
                 [--cache PAGES] [--checkpoint BYTES] [--break-lock]
```

Dot commands: `.tables`, `.schema [TABLE]`, `.indexes [TABLE]`, `.check`
(integrity check), `.stats`, `.checkpoint`, `.mode list|table`, `.help`,
`.quit`.

In list mode a row prints as `a|b|c` and NULL as `NULL`. Errors go to
standard error, and a script stops at its first error with exit status 1.
