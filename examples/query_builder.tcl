# Example: native query builder (range_f64 + primary-key lookups) in Tcl.
#
# Run with:
#   tclsh examples/query_builder.tcl
#
# Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
# point MONGRELDB_URL at a running daemon.
#
# Creates a table, loads five rows with varying scores, then runs two native
# queries: a range scan over score in [60, 90], and an exact primary-key
# lookup for id == 4. Results are printed, then the table is dropped
# (even on error).
#
# Licensing: MIT OR Apache-2.0.

lappend auto_path [file join [file dirname [file dirname [info script]]] src]
package require mongreldb

set table "tcl_example_query_[clock seconds]"

set url [if {[info exists ::env(MONGRELDB_URL)] && $::env(MONGRELDB_URL) ne {}} {
    set ::env(MONGRELDB_URL)
} else {
    set {http://127.0.0.1:8453}
}]

set db [mongreldb::connect $url]
set tableCreated 0
set status 1

proc cleanup {db table tableCreated} {
    if {$tableCreated} {
        if {![catch {mongreldb::dropTable $db $table}]} {
            puts "Dropped table $table"
        }
    }
}

if {[catch {
    if {![mongreldb::health $db]} {
        puts stderr "daemon not reachable at $url"; exit 1
    }
    puts "Connected to MongrelDB"

    set cols [list \
        [dict create id 1 name id    ty int64   primary_key 1 nullable 0] \
        [dict create id 2 name name  ty varchar primary_key 0 nullable 0] \
        [dict create id 3 name score ty float64 primary_key 0 nullable 0] \
    ]
    set tid [mongreldb::createTable $db $table $cols]
    set tableCreated 1
    puts "Created table $table (id $tid)"

    # Load five rows with varying scores.
    mongreldb::put $db $table {1 1 2 Alice 3 40.0}
    mongreldb::put $db $table {1 2 2 Bob   3 65.0}
    mongreldb::put $db $table {1 3 2 Carol 3 82.0}
    mongreldb::put $db $table {1 4 2 Dave  3 91.0}
    mongreldb::put $db $table {1 5 2 Eve   3 12.5}
    puts "Inserted 5 rows"

    # Range query: 60 <= score <= 90 (both inclusive). The score column is
    # float64, so use range_f64 (range targets integer columns).
    set rangeCond [mongreldb::condition range_f64 [dict create column_id 3 lo 60.0 hi 150.0 lo_inclusive 1 hi_inclusive 1]]
    set res [mongreldb::query $db $table [list $rangeCond]]
    puts "  range \[60, 150\] on score: [llength [dict get $res rows]] rows"

    # Primary-key lookup: id == 4 (Dave).
    set pkCond [mongreldb::condition pk [dict create value 4]]
    set res [mongreldb::query $db $table [list $pkCond]]
    puts "  pk == 4: [llength [dict get $res rows]] rows"

    set status 0
} err]} {
    puts stderr "error: $err"
}

cleanup $db $table $tableCreated
exit $status
