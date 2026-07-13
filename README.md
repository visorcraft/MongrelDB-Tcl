<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Tcl Client</h1>

<p align="center">
  <b>Pure Tcl HTTP client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  Built on the Tcl 8.6+ standard library (<code>http</code>) plus <code>json</code> from <a href="https://core.tcl-lang.org/tcllib/">tcllib</a>. Requires <a href="https://core.tcl-lang.org/tcllib/">tcllib</a> for JSON support.
</p>

<p align="center">
  <a href="https://github.com/visorcraft/MongrelDB-Tcl/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Tcl/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/visorcraft/MongrelDB/releases"><img src="https://img.shields.io/badge/server-v0.52.2-blue.svg" alt="MongrelDB server" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Tcl package | `mongreldb` 0.52.2 | `lappend auto_path src; package require mongreldb` |

## Requirements

- **Tcl 8.6 or newer** (uses `tailcall`, `try`/`trap`, and `dict`)
- The standard `http` package (bundled with Tcl 8.6+)
- [`tcllib`](https://core.tcl-lang.org/tcllib/) for the `json` package (the `json` package is part of tcllib, not the Tcl core). Install via your OS package manager (e.g. `apt-get install tcllib`), Homebrew (`brew install tcl-tcllib`), or `teacup install json`.
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `mongreldb::put`, `mongreldb::upsert` (insert-or-update on PK conflict), `mongreldb::delete` by row id and `mongreldb::deleteByPk` by primary key, with idempotency keys for safe retries.
- **Query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality, learned-range, null checks, and FM-index full-text search. Conditions are AND-ed.
- **Idempotent batch transactions** - all operations staged locally and committed atomically with `mongreldb::transaction`, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint via `mongreldb::sql`: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Typed exceptions**: failures throw with an error code of the form `{MONGRELDB <category>}` so callers can match by category with `try ... trap`.

## Examples

Runnable, commented examples live in the docs:

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete script.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - error categories, the HTTP-status mapping, and recovery patterns.

## Quick Example

```tcl
lappend auto_path /path/to/MongrelDB-Tcl/src
package require mongreldb

set db [mongreldb::connect http://127.0.0.1:8453]

# Create a table.
set cols [list \
    [dict create id 1 name id       ty int64   primary_key 1 nullable 0] \
    [dict create id 2 name customer ty varchar primary_key 0 nullable 0] \
    [dict create id 3 name amount   ty float64 primary_key 0 nullable 0] \
]
set constraintsJson {{"checks":[{"id":1,"name":"ck_status","expr":{"IsNotNull":3}}]}}
mongreldb::createTable $db orders $cols $constraintsJson

# Insert rows (cells is an even-length list {colId value ...}).
mongreldb::put $db orders {1 1 2 Alice 3 99.50}
mongreldb::put $db orders {1 2 2 Bob   3 150.00}

# Query with a native index condition (learned-range index).
set cond [mongreldb::condition range [dict create column_id 3 lo 100.0]]
set res [mongreldb::query $db orders [list $cond]]
puts "rows: [llength [dict get $res rows]]"

puts "count: [mongreldb::count $db orders]"  ;# 2

# Run SQL.
mongreldb::sql $db "UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'"
```

## Authentication

```tcl
# Bearer token (--auth-token mode)
set db [mongreldb::connectWithToken http://127.0.0.1:8453 my-secret-token]

# HTTP Basic (--auth-users mode)
set db [mongreldb::connectWithBasicAuth http://127.0.0.1:8453 admin s3cret]
```

A token takes precedence over basic auth if both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```tcl
set ops [list \
    [dict create put [dict create table orders cells {1 10 2 Dave 3 50.0}]] \
    [dict create put [dict create table orders cells {1 11 2 Eve 3 75.0}]] \
    [dict create delete_by_pk [dict create table orders pk 2]] \
]

# Atomic - all or nothing. The idempotency key makes it safe to retry.
try {
    mongreldb::transaction $db $ops batch-1
} trap {MONGRELDB conflict} {e opts} {
    puts "constraint violated: $e"
}
```

## Native query builder

Conditions push down to the engine's specialized indexes. Build them with
`mongreldb::condition`; multiple conditions are AND-ed.

```tcl
# Bitmap equality (low-cardinality columns)
set bitmap [mongreldb::condition bitmap_eq [dict create column_id 2 value Alice]]

# Range query (learned-range index)
set range [mongreldb::condition range [dict create column_id 3 lo 50.0 hi 150.0]]

set res [mongreldb::query $db orders [list $bitmap $range] {1 3} 100]
if {[dict get $res truncated]} {
    # result set hit the limit; more matches exist on the server
}
```

## Schema constraints

Optional fields on a column dict let you constrain what goes into a column
at create time. All are omitted from the wire JSON when left unset, so
existing schemas are unaffected.

```tcl
# An enum column whose values must come from this fixed set.
# Wire emit: "enum_variants": ["active","inactive","paused"]
set cols [list \
    [dict create id 1 name id       ty int64   primary_key 1 nullable 0] \
    [dict create id 2 name customer ty varchar primary_key 0 nullable 0] \
    [dict create id 3 name status   ty enum    primary_key 0 nullable 0 \
               enum_variants [list active inactive paused] default_value active] \
]
mongreldb::createTable $db orders $cols
```

`enum_variants` is a Tcl list of strings; omitting it means "absent".
`default_value` is a string. Use `default_value_json` for raw null, boolean,
or number defaults, and `default_expr` for dynamic `now` or `uuid`. Literal
`"now"` and `"uuid"` strings are expressed through `default_value`, not
`default_expr`. The constraint is enforced server-side, so a row whose value
falls outside the listed variants surfaces as a `conflict` error on
`mongreldb::put` / `mongreldb::transaction`.
The optional fourth argument is a validated JSON object in the daemon's
`constraints` shape. Its `checks` array is sent as `constraints.checks`.

## SQL

```tcl
mongreldb::sql $db "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)"
mongreldb::sql $db "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500"

# Recursive CTEs and window functions
mongreldb::sql $db "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r"
mongreldb::sql $db "SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders"
```

## Error handling

Methods throw on failure with an error code of the form
`{MONGRELDB <category>}`. Use `try ... trap` to catch by category.

```tcl
try {
    mongreldb::schemaFor $db missing_table
} trap {MONGRELDB not_found} {e opts} {
    puts "not found: $e"
} trap {MONGRELDB conflict} {e opts} {
    puts "constraint: $e"
} trap {MONGRELDB auth} {e opts} {
    puts "not authorized: $e"
} trap {MONGRELDB network} {e opts} {
    puts "can't reach daemon: $e"
}
```

## API reference

### Client lifecycle

| Command | Description |
|---------|-------------|
| `mongreldb::connect url` | Construct a client (empty url defaults to `http://127.0.0.1:8453`) |
| `mongreldb::connectWithToken url token` | Bearer token auth (`--auth-token` mode) |
| `mongreldb::connectWithBasicAuth url user pass` | HTTP Basic auth (`--auth-users` mode) |
| `mongreldb::close db` | Close the client and free per-handle state |
| `mongreldb::lastError db` | Message for the most recent failure |

### Database operations

| Command | Description |
|---------|-------------|
| `mongreldb::health db` | Check daemon health |
| `mongreldb::tables db` | List table names |
| `mongreldb::createTable db name cols ?constraintsJson?` | Create a table |
| `mongreldb::dropTable db name` | Drop a table |
| `mongreldb::count db table` | Row count |
| `mongreldb::put db table cells key` | Insert a row |
| `mongreldb::upsert db table cells upd key` | Upsert a row |
| `mongreldb::delete db table rowId` | Delete by row id |
| `mongreldb::deleteByPk db table pk` | Delete by primary key |
| `mongreldb::transaction db ops key` | Commit a batch atomically |
| `mongreldb::query db table conds proj limit offset` | Run a paged native query |
| `mongreldb::condition type params` | Build a query condition |
| `mongreldb::sql db statement` | Execute SQL |
| `mongreldb::schema db` | Full schema catalog |
| `mongreldb::schemaFor db table` | Single-table descriptor |
| `mongreldb::historyRetentionEpochs db` | Current history-retention window |
| `mongreldb::earliestRetainedEpoch db` | Oldest epoch still readable with `AS OF EPOCH` |
| `mongreldb::setHistoryRetentionEpochs db epochs` | Set the durable MVCC window |
| `mongreldb::lastEpoch db` | Commit epoch of the most recent `/kit/txn` |

## Building and testing

```sh
# Verify the package loads
tclsh <<< 'lappend auto_path src; package require mongreldb; puts ok'

# Run the offline wire-shape unit tests (no daemon needed)
tclsh tests/wire_shape_test.tcl

# Run the live integration suite. Set MONGRELDB_URL to use an already-running
# daemon. Tests self-skip when no daemon is reachable.
tclsh tests/live_test.tcl
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.52.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## History retention

Use `historyRetentionEpochs`, `setHistoryRetentionEpochs`, `earliestRetainedEpoch`,
and `lastEpoch` with MongrelDB 0.48.0+. The retention window controls how far
back `AS OF EPOCH` time-travel queries can read; increasing it cannot bring back
history that has already been pruned.

```tcl
# Inspect the current durable MVCC window.
puts [mongreldb::historyRetentionEpochs $db]  ;# e.g. 1024
puts [mongreldb::earliestRetainedEpoch $db]   ;# e.g. 3

# Widen the window. The response contains the updated values.
set resp [mongreldb::setHistoryRetentionEpochs $db 1000]
puts [dict get $resp history_retention_epochs]  ;# 1000

# After a write, lastEpoch holds the commit epoch of the most recent put,
# upsert, delete, or transaction commit.
mongreldb::put $db orders {1 1 2 99.5}
set insertEpoch [mongreldb::lastEpoch $db]
set rows [mongreldb::sql $db "SELECT id, amount FROM orders AS OF EPOCH $insertEpoch"]
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the code pure Tcl 8.6+; the only external dependency allowed is `tcllib` (for the `json` package).
4. Match the existing style: `mongreldb::` namespace, snake/camelCase commands.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
