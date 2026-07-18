# Quickstart

Zero to a running MongrelDB Tcl program in ten minutes. This guide walks
through importing the package, starting the daemon, and writing, running, and
understanding a complete script.

---

## 1. Prerequisites

You need Tcl 8.6+ and a `mongreldb-server` daemon.

### Install Tcl

On Debian/Ubuntu:

```sh
sudo apt install tcl tcl-dev
```

On macOS:

```sh
brew install tcl-tk
```

Verify:

```sh
tclsh <<< 'puts [info patchlevel]'   # >= 8.6
```

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.60.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the directory you pass as its first argument.

```sh
mkdir -p /tmp/mdb-data
/path/to/mongreldb-server /tmp/mdb-data
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

## 3. Import the package

```tcl
lappend auto_path /path/to/MongrelDB-Tcl/src
package require mongreldb
set db [mongreldb::connect http://127.0.0.1:8453]
```

## 4. Write your first script

Create `demo.tcl`:

```tcl
lappend auto_path src
package require mongreldb

# 1. Connect to the daemon.
set db [mongreldb::connect http://127.0.0.1:8453]

# 2. Health check before doing anything else.
if {![mongreldb::health $db]} {
    puts stderr "daemon not reachable"
    exit 1
}

# 3. Create a table. Two optional fields extend the schema:
#    - enum_variants: a fixed set of allowed values for a text column.
#    - default_value: a string applied when a row omits the column.
set cols [list \
    [dict create id 1 name id       ty int64   primary_key 1 nullable 0] \
    [dict create id 2 name customer ty varchar primary_key 0 nullable 0] \
    [dict create id 3 name amount   ty float64 primary_key 0 nullable 0 default_value 0.0] \
    [dict create id 4 name status   ty varchar primary_key 0 nullable 0 \
               enum_variants [list active inactive paused] default_value active] \
]
mongreldb::createTable $db orders $cols

# 4. Insert rows. cells is an even-length list {colId value ...}.
mongreldb::put $db orders {1 1 2 Alice 3 99.5 4 active}
mongreldb::put $db orders {1 2 2 Bob   3 150.0 4 inactive}

# 5. Query with a native index condition. Projection selects column ids 1,2.
set cond [mongreldb::condition range [dict create column_id 3 lo 100.0]]
set res [mongreldb::query $db orders [list $cond] {1 2} 100]
puts "rows: [llength [dict get $res rows]]"

# 6. Count the rows.
puts "total rows: [mongreldb::count $db orders]"
```

Run it:

```sh
tclsh demo.tcl
```

You should see the row count of 2.

## 5. What each part does

| Code | What it does |
|------|--------------|
| `mongreldb::connect` | Builds a client targeting one daemon. |
| `mongreldb::health` | GET `/health`; returns 1 when the daemon answers. |
| `mongreldb::createTable` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers. |
| `enum_variants` | Optional. Constrains a text column to a fixed value set; server-enforced on commit. Omit = absent. |
| `default_value` | Optional string default. Literal `"now"`/`"uuid"` strings go here; use `default_expr` only for dynamic defaults. Omit = absent. |
| `default_value_json` | Optional raw `null`, boolean, or number default, emitted as `default_value`. Caller must match the column type. |
| `default_expr` | Optional dynamic `now` or `uuid` default. |
| `mongreldb::put` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `mongreldb::query` | Builds a `/kit/query` body. Conditions push down to native indexes. |
| `projection {1 2}` | Server returns only those column ids, saving bandwidth. |
| `limit 100` | Caps the result; check the `truncated` key afterward. |
| `mongreldb::count` | GET `/tables/{name}/count`. |

## 6. History retention and time travel

MongrelDB keeps a durable MVCC history window. You can inspect it, widen it,
and query older epochs with `AS OF EPOCH`.

```tcl
puts [mongreldb::historyRetentionEpochs $db]  ;# current window, e.g. 1024
puts [mongreldb::earliestRetainedEpoch $db]   ;# oldest readable epoch, e.g. 3

# Widen the window. The response contains the updated values.
set resp [mongreldb::setHistoryRetentionEpochs $db 1000]
puts [dict get $resp history_retention_epochs]  ;# 1000

# Read the table as it existed at a captured commit epoch.
mongreldb::put $db orders {1 1 2 99.5}
set insertEpoch [mongreldb::lastEpoch $db]
set rows [mongreldb::sql $db "SELECT id, amount FROM orders AS OF EPOCH $insertEpoch"]
```

Increasing retention cannot restore history that has already been pruned. The
window is a durable GC/time-travel policy, so it requires admin privileges when
the daemon is running with auth.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `createTable`, never the `name`. Conditions take the numeric
`column_id`, not the string name.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `conflict` error
(HTTP 409), not as a silent no-op.

**Expecting `mongreldb::sql` to always return rows.** The `/sql` endpoint
streams Arrow IPC for `SELECT` in most builds, so `sql` returns the decoded
JSON when the server honors `format:json`, or `{}` for non-JSON bodies.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call fails with an `auth` error
unless you use `connectWithToken` or `connectWithBasicAuth`. See
[auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error category set and recovery patterns
