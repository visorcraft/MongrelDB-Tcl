# Transactions

Transactions stage and commit a batch of put / upsert / delete / delete-by-pk
operations atomically. Either every op in the batch is applied, or none are.

This document covers:

- the single-op helpers (`put`, `upsert`, `delete`, `deleteByPk`),
- multi-op batches via `mongreldb::transaction`,
- the cells wire format,
- idempotency keys for safe retries,
- the per-op result envelope.

---

## Single-op helpers

Each helper is sugar over a one-op transaction posted to `/kit/txn`. They
return the per-op result dict (or throw on failure).

| Command | Op shape | Notes |
|---------|----------|-------|
| `mongreldb::put $db table cells` | `put` | Insert a row. PK conflict throws `conflict`. |
| `mongreldb::upsert $db table cells ?updateCells?` | `upsert` | Insert-or-update on PK match. `updateCells` are the columns to overwrite when the row exists. |
| `mongreldb::delete $db table rowId` | `delete` | Delete by the internal numeric row id returned in query results. |
| `mongreldb::deleteByPk $db table pk` | `delete_by_pk` | Delete by the primary-key column value. |

Cells are an **even-length flat list** of `{colId value colId value ...}`:

```tcl
mongreldb::put $db orders {1 1 2 Alice 3 99.5}
#            column id ---^ ^--- value
```

The wire format is `[col_id, value, col_id, value, ...]` - the Tcl list maps
directly to that JSON array.

## Multi-op batches

`mongreldb::transaction` posts a list of ops as one atomic commit. Every op
shares the same all-or-nothing guarantee: a single failure rolls back the
entire batch.

```tcl
set ops [list \
    [dict create put         [dict create table orders cells {1 1 2 Alice 3 9.99}]] \
    [dict create put         [dict create table orders cells {1 2 2 Bob   3 14.50}]] \
    [dict create upsert      [dict create table orders cells {1 3 2 Carol 3 7.00}]] \
    [dict create delete_by_pk [dict create table orders pk 4]] \
]
set results [mongreldb::transaction $db $ops]
```

Each op is a one-key dict whose key is the op type (`put`, `upsert`, `delete`,
`delete_by_pk`) and whose value is the op body. This mirrors the wire shape
exactly, so anything you can express as an op dict you can put in the batch.

The command returns a list of per-op result dicts - one entry per input op,
in order. For a `put` the result typically carries the assigned row id.

## The cells format

Cells are flattened into the wire array. The order does not matter on the
server side (it indexes by column id), but emitting them in ascending column
order keeps the request deterministic:

```tcl
# Two columns, ascending by id
mongreldb::put $db users {1 42 2 alice@example.com}
```

For `upsert`, the optional `updateCells` are the columns to overwrite when
the row already exists:

```tcl
mongreldb::upsert $db users {1 42 2 new@example.com} {2 new@example.com}
#                  ^^^^^^^^ insert payload           ^^^^^^^^^^^^^^^^^ update payload
```

## Idempotency keys

Network retries can replay a transaction. To make retries safe, pass an
idempotency key: the server deduplicates any request that carries the same
key within its retention window.

```tcl
set key "checkout-[clock milliseconds]"
# Safe to retry on timeout: the server applies this exactly once.
mongreldb::transaction $db $ops $key
```

Pick a key that is unique to the logical operation (a request id, a checkout
id, a content hash). Do **not** reuse keys across logically distinct
transactions - the second request will be deduplicated as a replay and its
ops silently dropped.

## Per-op results

`mongreldb::transaction` returns a list with one result dict per input op.
Single-op helpers return the first element directly.

```tcl
set results [mongreldb::transaction $db $ops]
foreach r $results {
    puts [dict get $r row_id]
}
```

The exact keys depend on the op type and the server version. Treat the result
as informational; do not gate correctness on a specific field being present.

## Error handling

A failed batch throws a `mongreldb` error. The error is tagged with a
category so you can branch on it. The category is in the Tcl `errorcode`:

```tcl
try {
    mongreldb::transaction $db $ops
} trap {MONGRELDB conflict} {e ec} {
    # A unique constraint (PK or column-level) was violated.
    puts stderr "conflict: $e"
} trap {MONGRELDB query} {e ec} {
    # Malformed op, unknown table, or a server-side planner error.
    puts stderr "query error: $e"
}
```

For a batch failure the server reports which op index caused the rollback
when available; it appears in the error detail. See [errors.md](errors.md)
for the full category set.

## When to batch

- **Atomic multi-row writes.** Inserting a parent and children that must
  succeed together belongs in one transaction.
- **Throughput.** One round trip for N ops is cheaper than N round trips.
- **Idempotent retries.** A batch with an idempotency key can be retried
  safely after a timeout.

Do **not** batch when:

- The ops are independent and either can fail without affecting the other -
  use separate `put` calls.
- You need per-op error isolation - the server rolls back the whole batch on
  the first error.

## Next steps

- [queries.md](queries.md) - read paths and native index conditions
- [errors.md](errors.md) - the full error category set
- [sql.md](sql.md) - escaping the query builder when you need full SQL
