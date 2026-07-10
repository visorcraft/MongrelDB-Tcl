# Example: basic CRUD operations with the MongrelDB Tcl client.
#
# Run with:
#   tclsh examples/basic_crud.tcl
#
# Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
# point MONGRELDB_URL at a running daemon.
#
# Creates a table, inserts three rows, counts them, queries all rows, upserts
# (updates) one row by primary key, deletes one row, then drops the table.
# Progress is printed at every step.
#
# The "status" column is an enum ("active" | "inactive" | "paused") with a
# default of "active"; the "score" column has a numeric default of "0.0".
# These are emitted as "enum_variants" and "default_value" keys in the
# /kit/create_table wire JSON.
#
# Licensing: MIT OR Apache-2.0.

lappend auto_path [file join [file dirname [file dirname [info script]]] src]
package require mongreldb

# Per-run unique suffix (unix time) keeps every invocation isolated on a
# shared daemon.
set table "tcl_example_crud_[clock seconds]"

set url [if {[info exists ::env(MONGRELDB_URL)] && $::env(MONGRELDB_URL) ne {}} {
    set ::env(MONGRELDB_URL)
} else {
    set {http://127.0.0.1:8453}
}]

set db [mongreldb::connect $url]
set tableCreated 0
set status 1

# Helper to drop the table on any exit path.
proc cleanup {db table tableCreated} {
    if {$tableCreated} {
        if {![catch {mongreldb::dropTable $db $table}]} {
            puts "Dropped table $table"
        } else {
            puts "drop_table failed"
        }
    }
}

if {[catch {
    # 1. Health check.
    if {![mongreldb::health $db]} {
        puts stderr "daemon not reachable at $url"
        exit 1
    }
    puts "Connected to MongrelDB"

    # 2. Create the table. The status column is an enum with a default.
    set statusVariants [list active inactive paused]
    set cols [list \
        [dict create id 1 name id     ty int64   primary_key 1 nullable 0] \
        [dict create id 2 name name   ty varchar primary_key 0 nullable 0] \
        [dict create id 3 name score  ty float64 primary_key 0 nullable 0 default_value 0.0] \
        [dict create id 4 name status ty varchar primary_key 0 nullable 0 \
                   enum_variants $statusVariants default_value active] \
    ]
    set tid [mongreldb::createTable $db $table $cols]
    set tableCreated 1
    puts "Created table $table (id $tid)"

    # 3. Insert three rows.
    mongreldb::put $db $table {1 1 2 Alice 3 95.5 4 active}
    mongreldb::put $db $table {1 2 2 Bob   3 82.0 4 inactive}
    mongreldb::put $db $table {1 3 2 Carol 3 78.3 4 paused}
    puts "Inserted 3 rows"

    # 4. Count.
    set n [mongreldb::count $db $table]
    puts "Total rows: $n"

    # 5. Query all rows.
    set res [mongreldb::query $db $table]
    set rows [dict get $res rows]
    puts "Query returned [llength $rows] rows:"

    # 6. Upsert (update) Alice's score and mark her paused.
    mongreldb::upsert $db $table {1 1 2 Alice 3 100.0 4 paused} {2 Alice 3 100.0 4 paused}
    puts "Upserted Alice's score to 100.0"
    set n [mongreldb::count $db $table]
    puts "Total rows after upsert: $n"

    # 7. Delete Carol (primary key 3).
    mongreldb::deleteByPk $db $table 3
    set n [mongreldb::count $db $table]
    puts "Deleted Carol; remaining rows: $n"

    set status 0
} err]} {
    puts stderr "error: $err"
}

cleanup $db $table $tableCreated
exit $status
