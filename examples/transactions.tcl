# Example: atomic batch transactions with an idempotent retry in Tcl.
#
# Run with:
#   tclsh examples/transactions.tcl
#
# Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
# point MONGRELDB_URL at a running daemon.
#
# Creates a table, stages three puts in one transaction, and commits them
# atomically. It then verifies the row count. Finally it stages a fourth put
# and commits it twice with the SAME idempotency key: the daemon replays the
# first commit's result so the second commit is a no-op. The table is dropped
# at the end (even on error).
#
# Licensing: MIT OR Apache-2.0.

lappend auto_path [file join [file dirname [file dirname [info script]]] src]
package require mongreldb

set ts [clock seconds]
set table "tcl_example_txn_$ts"
set txnKey "tcl-example-txn-key-$ts"

set url [if {[info exists ::env(MONGRELDB_URL)] && $::env(MONGRELDB_URL) ne {}} {
    set ::env(MONGRELDB_URL)
} else {
    list {http://127.0.0.1:8453}
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

# Build a put-op dict referencing the per-run table.
proc putOp {table cells} {
    return [dict create put [dict create table $table cells $cells]]
}

if {[catch {
    if {![mongreldb::health $db]} {
        puts stderr "daemon not reachable at $url"; exit 1
    }
    puts "Connected to MongrelDB"

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

    # Stage three puts and commit them atomically.
    set batch1 [list \
        [putOp $table {1 1 2 Alice 3 95.5 4 active}] \
        [putOp $table {1 2 2 Bob   3 82.0 4 inactive}] \
        [putOp $table {1 3 2 Carol 3 78.3 4 paused}] \
    ]
    mongreldb::transaction $db $batch1
    puts "Committed transaction with 3 puts"

    set n [mongreldb::count $db $table]
    puts "Total rows after commit: $n"

    # Idempotent retry: stage a fourth put and commit twice with the same key.
    set batch2 [list [putOp $table {1 4 2 Dave 3 60.0 4 active}]]
    mongreldb::transaction $db $batch2 $txnKey
    puts "Committed 4th put with idempotency key $txnKey"

    mongreldb::transaction $db $batch2 $txnKey
    puts "Recommitted with same key (idempotent replay)"

    set n [mongreldb::count $db $table]
    puts "Total rows after idempotent retry: $n"

    set status 0
} err]} {
    puts stderr "error: $err"
}

cleanup $db $table $tableCreated
exit $status
