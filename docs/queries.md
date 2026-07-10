# Queries

MongrelDB has two read paths. The **native query** API pushes conditions down
into the server's indexes for fast point and range lookups. The **SQL** path
covers everything else - joins, aggregations, recursive CTEs. Use the native
API when you can; fall back to SQL when you need it.

This document covers the native API only. See [sql.md](sql.md) for the SQL
path.

---

## The basic call

```tcl
set res [mongreldb::query $db $table $conditions $projection $limit]
# rows      -> list of row dicts
# truncated -> 1 if the limit cut the result off, 0 otherwise
lassign $res rows truncated
```

- `conditions` is a Tcl list of condition dicts (empty list = all rows).
- `projection` is a list of column ids to return. Omit for all columns.
- `limit` caps the row count. The server also enforces its own ceiling; check
  `truncated` to detect when you hit it.

Returned rows are flat cell lists in the same `{colId value ...}` shape as
the write path.

## Conditions

Build a condition with `mongreldb::condition`. The first argument is the
condition kind; the second is a dict of parameters.

```tcl
mongreldb::condition <kind> <paramDict>
```

### Primary-key lookup

```tcl
set cond [mongreldb::condition pk [dict create value 42]]
```

Matches the single row whose primary-key column equals `value`.

### Bitmap equality

```tcl
set cond [mongreldb::condition bitmap_eq [dict create column_id 2 value Alice]]
```

Exact equality on any indexed column. `column_id` is the numeric column id,
not the name.

### Range

```tcl
set cond [mongreldb::condition range [dict create \
    column_id 3 \
    lo 100.0 \
    hi 1000.0 \
    lo_inclusive 1 \
    hi_inclusive 0 \
]]
```

A half-open or closed range on an ordered column. Aliases: `column` -> `column_id`,
`min` -> `lo`, `max` -> `hi`, `min_inclusive` -> `lo_inclusive`,
`max_inclusive` -> `hi_inclusive`.

### Full-text containment (FM-index)

```tcl
set cond [mongreldb::condition fm_contains [dict create column_id 4 pattern hello]]
```

Substring search over an FM-indexed text column. `pattern` is the search
term (alias: `value` -> `pattern`).

### Null tests

```tcl
set cond [mongreldb::condition is_null     [dict create column_id 5]]
set cond [mongreldb::condition is_not_null [dict create column_id 5]]
```

## Combining conditions

Pass a list of conditions. Within one query, conditions are ANDed together:

```tcl
set conds [list \
    [mongreldb::condition bitmap_eq [dict create column_id 2 value Alice]] \
    [mongreldb::condition range     [dict create column_id 3 lo 100.0]] \
]
set res [mongreldb::query $db orders $conds {1 2 3} 100]
```

There is no client-side OR combinator. For OR across columns or complex
predicates, use the SQL path.

## Projection

Projection trims the response to the columns you actually need. The list
holds numeric column ids:

```tcl
# Only columns 1 (id) and 2 (customer) come back.
mongreldb::query $db orders $conds {1 2} 100
```

Omit the projection (or pass an empty list) to receive every column.

## Limits and truncation

Pass a limit to cap the response:

```tcl
set res [mongreldb::query $db orders $conds {1 2} 100]
lassign $res rows truncated
if {$truncated} {
    # Hit the limit - more rows exist on the server.
    ...
}
```

The server enforces its own maximum regardless of the limit you pass, so
always check `truncated` before assuming the result is complete. There is no
client-side offset; for pagination use SQL with `LIMIT`/`OFFSET`.

## Counting

`mongreldb::count` is the cheap way to count rows - it does not fetch them:

```tcl
set n [mongreldb::count $db orders]
```

## Reading the response

Each row is a flat cell list, the same shape used for writes:

```tcl
foreach row $rows {
    # row is {1 <id> 2 <customer> 3 <amount>}
    set amount [lindex $row [expr {[lsearch $row 3] + 1}]]
    ...
}
```

The cell list is column-id-first; iterate in pairs to pull out values by id.

## When to use SQL instead

Reach for the SQL path when you need:

- JOINs across tables.
- GROUP BY / aggregations (SUM, COUNT, AVG).
- ORDER BY on non-indexed columns.
- LIMIT/OFFSET pagination.
- Recursive CTEs or window functions.
- OR predicates, CASE expressions, computed columns.

See [sql.md](sql.md).

## Next steps

- [sql.md](sql.md) - the SQL escape hatch
- [transactions.md](transactions.md) - atomic writes
- [errors.md](errors.md) - error categories for query failures
