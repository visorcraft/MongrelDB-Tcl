# Errors

Every `mongreldb::` command that talks to the server can throw a Tcl error on
failure. The error carries a **category** in the Tcl `errorcode` list so you
can branch on it with `try ... trap` without parsing the error message.

---

## The category set

| Category | HTTP status | Cause |
|----------|-------------|-------|
| `auth` | 401, 403 | Missing, malformed, or rejected `Authorization` header. Bad token or basic-auth credentials. |
| `not_found` | 404 | Unknown table name, or a row that does not exist. |
| `conflict` | 409 | Unique constraint violation: duplicate primary key, or a column-level uniqueness/enum violation. |
| `query` | 400, 5xx | Malformed request body, unknown column id, a server-side planner/execution error, or a response that exceeded the size cap. |
| `network` | - | The HTTP request itself failed: connection refused, DNS error, timeout, broken pipe. |
| `json` | - | The server returned a response that could not be decoded as JSON when JSON was expected. |

## Matching with `try ... trap`

The category is the second element of the `errorcode` list, under the
`MONGRELDB` prefix:

```tcl
try {
    mongreldb::put $db orders {1 1 2 Alice}
} trap {MONGRELDB conflict} {e ec} {
    puts stderr "duplicate row, skipping: $e"
} trap {MONGRELDB auth} {e ec} {
    puts stderr "bad credentials: $e"
    exit 1
} trap {MONGRELDB network} {e ec} {
    puts stderr "daemon unreachable, will retry: $e"
} on error {e ec} {
    puts stderr "unexpected: $e ($ec)"
}
```

The `trap` pattern `{MONGRELDB <category>}` matches the prefix and category
elements of the errorcode. Use a trailing `on error` arm as a catch-all for
anything you did not anticipate.

## Reading the detail

The error message (`$e` above) is human-readable and includes the server's
own error text when the server produced one:

```
conflict: duplicate primary key value
```

For server errors the daemon wraps detail in an envelope
(`{"error":{"message":..., "code":..., "op_index":...}}`). The client
extracts `message` for the error string. `op_index` (when present) identifies
which op in a batch transaction triggered the rollback.

## Recoverable vs not

| Category | Recoverable? | Pattern |
|----------|--------------|---------|
| `network` | Yes - retry after backoff | Transient; the daemon may have restarted. |
| `conflict` | Sometimes - re-read, reconcile, retry | The data changed under you. Re-fetch and decide. |
| `auth` | No - fix credentials and reconnect | Stale token, wrong password. |
| `not_found` | No - check the table/row id | Programming error or race. |
| `query` | No - fix the request | Malformed body, bad column id, etc. |
| `json` | No - protocol mismatch | Likely a server version skew. |

## Retrying safely

For `network` errors, retry with backoff. If the operation is a write, pass
an idempotency key so a replayed request is deduplicated on the server:

```tcl
proc safe_put {db table cells} {
    set key "put-[clock microseconds]"
    for {set i 0} {$i < 3} {incr i} {
        try {
            return [mongreldb::transaction $db \
                [list [dict create put [dict create table $table cells $cells]]] \
                $key]
        } trap {MONGRELDB network} {e ec} {
            after [expr {200 * (1 << $i)}]
        }
    }
    error "gave up after retries: $e"
}
```

See [transactions.md](transactions.md) for more on idempotency keys.

## The size cap

The client rejects any response body larger than 256 MB with a `query`
error. This is a guard against runaway queries exhausting memory. If you hit
it, narrow your query (add a `limit`, project fewer columns, or page with
SQL `LIMIT`/`OFFSET`).

## Next steps

- [transactions.md](transactions.md) - atomic writes and idempotency
- [queries.md](queries.md) - native conditions and projection
- [auth.md](auth.md) - the `auth` category in depth
