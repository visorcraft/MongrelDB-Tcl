# SQL

The native query API covers point lookups, ranges, and full-text search.
When you need joins, aggregations, ORDER BY, LIMIT/OFFSET pagination, or
anything the query builder cannot express, drop down to SQL.

---

## The call

```tcl
mongreldb::sql $db $statement
```

The statement is sent verbatim to `/sql` with `format:json`. The server
parses, plans, and executes it - the client does no local SQL processing.

For a SELECT, the return value is the decoded JSON the server emitted
(usually a list of row objects keyed by column name). For statements that
produce no rows (INSERT, UPDATE, DELETE, CREATE TABLE), the return is the
server's status object or `{}` for empty bodies.

## A note on injection

**`mongreldb::sql` does not parameterize or sanitize input.** The statement
is a raw string; the client sends it as-is. Never interpolate untrusted
input into a SQL string:

```tcl
# DANGEROUS - $name came from a user and could contain a quote.
mongreldb::sql $db "SELECT * FROM users WHERE name = '$name'"
```

For trusted, static SQL this is fine. For anything that touches user input,
either:

- validate the input yourself and quote it carefully, or
- prefer the native query builder, which is type-safe by construction (see
  [queries.md](queries.md)).

## What SQL supports

The server implements a growing subset of ANSI SQL plus extensions. Common
supported features:

- DDL: `CREATE TABLE`, `DROP TABLE`, `CREATE TABLE AS SELECT`.
- DML: `INSERT`, `UPDATE`, `DELETE`.
- `SELECT` with `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`/`OFFSET`.
- JOINs (inner, left, right).
- Aggregates: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`.
- Window functions.
- Recursive CTEs (`WITH RECURSIVE`).

The exact set depends on the server version; check the server's own docs for
the authoritative grammar.

## Examples

### Aggregation

```tcl
set res [mongreldb::sql $db {
    SELECT customer, SUM(amount) AS total
    FROM orders
    GROUP BY customer
    ORDER BY total DESC
    LIMIT 10
}]
```

### Pagination

```tcl
set page [mongreldb::sql $db {
    SELECT id, customer FROM orders ORDER BY id LIMIT 20 OFFSET 40
}]
```

### CREATE TABLE AS SELECT

```tcl
mongreldb::sql $db {
    CREATE TABLE big_orders AS
    SELECT * FROM orders WHERE amount > 1000
}
```

## When to use native queries vs SQL

| Need | Use |
|------|-----|
| Point lookup by PK | `mongreldb::condition pk` |
| Equality on an indexed column | `mongreldb::condition bitmap_eq` |
| Range on an ordered column | `mongreldb::condition range` |
| Substring on an FM-indexed column | `mongreldb::condition fm_contains` |
| JOINs, GROUP BY, ORDER BY, OFFSET | `mongreldb::sql` |
| OR predicates, CASE, computed columns | `mongreldb::sql` |

Native conditions push down into the server's indexes and are usually faster
than the equivalent SQL, which has to go through the planner. Reach for SQL
when the native API cannot express what you need.

## Next steps

- [queries.md](queries.md) - the native condition API
- [transactions.md](transactions.md) - atomic writes
- [errors.md](errors.md) - SQL parse and runtime errors
