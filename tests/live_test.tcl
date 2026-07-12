# live_test.tcl - live integration tests for the MongrelDB Tcl client.
#
# These exercise the full client surface against a running mongreldb-server
# daemon. They self-skip (print SKIP and pass) when no daemon is reachable.
#
# Point at an already-running daemon with the MONGRELDB_URL environment
# variable. By default this connects to http://127.0.0.1:8453.
#
# The live conformance matrix mirrors the other official clients: health,
# create_table, drop_table, count, put, upsert, delete (by row id), delete_by_pk,
# query (pk), query (range), transaction (batch commit), table_names, schema,
# schema_for, sql, idempotency_key, error not_found, history retention, and
# AS OF EPOCH time travel.
#
# Run with:
#   tclsh tests/live_test.tcl
#
# Licensing: MIT OR Apache-2.0.

lappend auto_path [file join [file dirname [file dirname [info script]]] src]
package require mongreldb

# ── Tiny test framework ───────────────────────────────────────────────────

set g_pass 0
set g_fail 0
set g_skip 0

proc test {name body} {
    global g_pass g_fail g_skip
    puts "== $name"
    set beforeFail $g_fail
    set beforeSkip $g_skip
    # Catch the test-abort/skip signals so one failing/skipped test does not
    # abort the whole run. The body calls fail/skip to record the outcome and
    # then throws one of these signals.
    if {[catch [list uplevel 1 $body] err opts]} {
        # Only a test-abort or test-skip signal is expected; re-raise others.
        set code [dict get $opts -code]
        if {$code == 1} {
            # 1 = TCL_ERROR. Distinguish our signals from a real crash by the
            # error message: "test-abort" / "test-skip" are ours.
            if {$err ni {test-abort test-skip}} {
                puts "  UNEXPECTED ERROR: $err"
                incr g_fail
            }
        }
    }
    # Count a pass only when the test neither failed nor skipped.
    if {$g_fail == $beforeFail && $g_skip == $beforeSkip} { incr g_pass }
}

proc fail {msg} {
    global g_fail
    puts "  FAIL $msg"
    incr g_fail
    # Stop the current test by throwing; the [test] wrapper catches it.
    return -code error "test-abort"
}

proc skip {{reason "(no daemon)"}} {
    global g_skip
    puts "  SKIP: $reason"
    incr g_skip
    return -code error "test-skip"
}

proc check {cond msg} {
    if {![uplevel 1 [list expr $cond]]} {
        fail $msg
    }
}

# ── Daemon harness ────────────────────────────────────────────────────────

set g_client {}
set g_have_daemon 0

set url [if {[info exists ::env(MONGRELDB_URL)] && $::env(MONGRELDB_URL) ne {}} {
    set ::env(MONGRELDB_URL)
} else {
    list {http://127.0.0.1:8453}
}]

if {[catch {
    set c [mongreldb::connect $url]
    set g_have_daemon [mongreldb::health $c]
    if {$g_have_daemon} { set g_client $c }
} err]} {
    set g_have_daemon 0
    puts stderr "--- no mongreldb-server reachable at $url; live tests skipped"
}

proc assertDaemon {} {
    global g_have_daemon
    if {!$g_have_daemon} { skip "no mongreldb-server available" }
}

# ── Helpers ───────────────────────────────────────────────────────────────

proc intCol {id name pk} {
    return [dict create id $id name $name ty int64 primary_key $pk nullable [expr {!$pk}]]
}
proc floatCol {id name} {
    return [dict create id $id name $name ty float64 primary_key 0 nullable 0]
}
proc varcharCol {id name} {
    return [dict create id $id name $name ty varchar primary_key 0 nullable 0]
}

# Drop-then-create so a fresh table is ready for the test. Ignores not-found.
proc freshTable {name cols} {
    global g_client
    catch {mongreldb::dropTable $g_client $name}
    mongreldb::createTable $g_client $name $cols
}

# Temporarily widen the retention window, run body, then restore the original
# window even if body throws. Avoids leaking a non-default retention setting
# to later live tests. Returns the response from the initial setter call.
proc withRestoredRetention {db tmp body} {
    set original [mongreldb::historyRetentionEpochs $db]
    set setResp [mongreldb::setHistoryRetentionEpochs $db $tmp]
    set code [catch {uplevel 1 $body} err opts]
    if {$code != 0} {
        catch {mongreldb::setHistoryRetentionEpochs $db $original}
        return -options $opts $err
    }
    mongreldb::setHistoryRetentionEpochs $db $original
    return $setResp
}

# ── Tests (14-operation conformance matrix) ───────────────────────────────

# 1. health
test test_health {
    assertDaemon
    set ok [mongreldb::health $::g_client]
    check {$ok == 1} "health failed"
}

# 2. create_table + count
test test_create_table_and_count {
    assertDaemon
    set cols [list [intCol 1 id 1] [floatCol 2 amount]]
    freshTable tcl_tbl_count $cols
    set n [mongreldb::count $::g_client tcl_tbl_count]
    check {$n == 0} "expected 0 rows, got $n"
}

# 3. put + count
test test_put_and_count {
    assertDaemon
    set cols [list [intCol 1 id 1] [floatCol 2 amount]]
    freshTable tcl_put $cols
    mongreldb::put $::g_client tcl_put {1 1 2 99.5}
    mongreldb::put $::g_client tcl_put {1 2 2 150.0}
    set n [mongreldb::count $::g_client tcl_put]
    check {$n == 2} "expected 2 rows, got $n"
}

# 4. upsert (update on conflict)
test test_upsert {
    assertDaemon
    set cols [list [intCol 1 id 1] [floatCol 2 amount]]
    freshTable tcl_upsert $cols
    mongreldb::put $::g_client tcl_upsert {1 1 2 10.0}
    mongreldb::upsert $::g_client tcl_upsert {1 1 2 20.0} {2 20.0}
    set n [mongreldb::count $::g_client tcl_upsert]
    check {$n == 1} "expected 1 row after upsert, got $n"

    set cond [mongreldb::condition pk [dict create value 1]]
    set res [mongreldb::query $::g_client tcl_upsert [list $cond]]
    set rows [dict get $res rows]
    check {[llength $rows] == 1} "expected 1 row from pk query"
}

# 5. query by primary key
test test_query_by_pk {
    assertDaemon
    set cols [list [intCol 1 id 1]]
    freshTable tcl_pk $cols
    mongreldb::put $::g_client tcl_pk {1 42}
    mongreldb::put $::g_client tcl_pk {1 43}
    set cond [mongreldb::condition pk [dict create value 42]]
    set res [mongreldb::query $::g_client tcl_pk [list $cond]]
    set rows [dict get $res rows]
    check {[llength $rows] == 1} "expected 1 row, got [llength $rows]"
}

# 6. query by range
test test_query_range {
    assertDaemon
    set cols [list [intCol 1 id 1] [intCol 2 amount 0]]
    freshTable tcl_range $cols
    mongreldb::put $::g_client tcl_range {1 1 2 50}
    mongreldb::put $::g_client tcl_range {1 2 2 120}
    mongreldb::put $::g_client tcl_range {1 3 2 200}
    set cond [mongreldb::condition range [dict create column_id 2 lo 100 hi 150]]
    set res [mongreldb::query $::g_client tcl_range [list $cond]]
    set rows [dict get $res rows]
    check {[llength $rows] == 1} "expected exactly 1 matching row, got [llength $rows]"
    check {[dict get $res truncated] == 0} "result should not be truncated"
}

# 7. transaction (batch commit)
test test_transaction_commit {
    assertDaemon
    set cols [list [intCol 1 id 1]]
    freshTable tcl_txn $cols
    set ops [list \
        [dict create put [dict create table tcl_txn cells {1 1}]] \
        [dict create put [dict create table tcl_txn cells {1 2}]] \
        [dict create put [dict create table tcl_txn cells {1 3}]] \
    ]
    mongreldb::transaction $::g_client $ops
    set n [mongreldb::count $::g_client tcl_txn]
    check {$n == 3} "expected 3 rows after commit, got $n"
}

# 8. delete_by_pk
test test_delete_by_pk {
    assertDaemon
    set cols [list [intCol 1 id 1]]
    freshTable tcl_del $cols
    mongreldb::put $::g_client tcl_del {1 5}
    set n [mongreldb::count $::g_client tcl_del]
    check {$n == 1} "expected 1 row, got $n"
    mongreldb::deleteByPk $::g_client tcl_del 5
    set n [mongreldb::count $::g_client tcl_del]
    check {$n == 0} "expected 0 rows after delete, got $n"
}

# 9. delete by row id
test test_delete_by_row_id {
    assertDaemon
    set cols [list [intCol 1 id 1]]
    freshTable tcl_delrow $cols
    mongreldb::put $::g_client tcl_delrow {1 7}
    # First inserted row on a fresh table has internal row_id 1.
    mongreldb::delete $::g_client tcl_delrow 1
    set n [mongreldb::count $::g_client tcl_delrow]
    check {$n == 0} "expected 0 rows after delete by row id, got $n"
}

# 10. string values round-trip
test test_string_values {
    assertDaemon
    set cols [list [intCol 1 id 1] [varcharCol 2 label] [floatCol 3 amount]]
    freshTable tcl_str $cols
    mongreldb::put $::g_client tcl_str {1 1 2 {hello world} 3 1.5}
    set cond [mongreldb::condition pk [dict create value 1]]
    set res [mongreldb::query $::g_client tcl_str [list $cond]]
    set rows [dict get $res rows]
    check {[llength $rows] == 1} "expected 1 row, got [llength $rows]"
}

# 11. sql
test test_sql {
    assertDaemon
    set cols [list [intCol 1 id 1] [intCol 2 amount 0]]
    freshTable tcl_sql $cols
    set n [mongreldb::count $::g_client tcl_sql]
    check {$n == 0} "expected 0 rows before SQL INSERT, got $n"
    mongreldb::sql $::g_client "INSERT INTO tcl_sql (id, amount) VALUES (10, 42)"
    set n [mongreldb::count $::g_client tcl_sql]
    check {$n == 1} "expected count to increase to 1 after INSERT, got $n"
}

# 12. table_names
test test_table_names {
    assertDaemon
    set cols [list [intCol 1 id 1]]
    freshTable tcl_tables $cols
    set names [mongreldb::tables $::g_client]
    set found 0
    foreach nm $names {
        if {$nm eq "tcl_tables"} { set found 1; break }
    }
    check {$found == 1} "table list missing tcl_tables"
}

# 13. schema + schema_for
test test_schema_for {
    assertDaemon
    set cols [list [intCol 1 id 1] [floatCol 2 amount]]
    freshTable tcl_schema $cols
    set body [mongreldb::schemaFor $::g_client tcl_schema]
    check {[llength $body] > 0} "expected non-empty schema body"
}

# 14. error not_found
test test_error_not_found {
    assertDaemon
    set threw 0
    set code {}
    try {
        mongreldb::schemaFor $::g_client tcl_does_not_exist_xyz
    } trap {MONGRELDB not_found} {} {
        set threw 1
    } on error {} {}
    check {$threw == 1} "expected not_found error"
}

# 15. idempotency key
test test_idempotency_key {
    assertDaemon
    set cols [list [intCol 1 id 1]]
    freshTable tcl_idem $cols
    set key "idem-key-[clock seconds]"
    mongreldb::put $::g_client tcl_idem {1 1} $key
    set n [mongreldb::count $::g_client tcl_idem]
    check {$n == 1} "expected 1 row, got $n"
    # Second put with a DIFFERENT value but the SAME key replays the original
    # result; the row count stays at 1.
    catch {mongreldb::put $::g_client tcl_idem {1 2} $key}
    set n [mongreldb::count $::g_client tcl_idem]
    check {$n == 1} "expected 1 row after duplicate idempotent commit, got $n"
}

# 16. history retention round trip
# 17. AS OF EPOCH time travel

test test_history_retention_round_trip {
    assertDaemon
    set original [mongreldb::historyRetentionEpochs $::g_client]
    check {$original > 0} "expected positive default retention, got $original"
    # earliest_retained_epoch is 0 until the first commit, which is fine.
    set earliest [mongreldb::earliestRetainedEpoch $::g_client]
    check {$earliest >= 0} "expected non-negative earliest retained epoch, got $earliest"

    set updated [withRestoredRetention $::g_client 1000 {
        set now [mongreldb::historyRetentionEpochs $::g_client]
        check {$now == 1000} "retention not updated to 1000, got $now"
    }]
    check {[dict exists $updated history_retention_epochs]} "setter response missing key"
}

test test_as_of_epoch_time_travel {
    assertDaemon
    set cols [list [intCol 1 id 1] [floatCol 2 amount]]
    freshTable tcl_pit $cols

    withRestoredRetention $::g_client 10000 {
        mongreldb::put $::g_client tcl_pit {1 1 2 1.0}
        set insertEpoch [mongreldb::lastEpoch $::g_client]
        check {$insertEpoch > 0} "expected positive insert epoch, got $insertEpoch"

        mongreldb::upsert $::g_client tcl_pit {1 1 2 9.0} {2 9.0}

        set histRows [mongreldb::sql $::g_client "SELECT id, amount FROM tcl_pit AS OF EPOCH $insertEpoch"]
        check {[llength $histRows] == 1} "expected exactly one historical row"
        set historical [lindex $histRows 0]
        check {[dict exists $historical id] && [dict get $historical id] == 1} "historical id wrong"
        check {[dict get $historical amount] == 1.0} "historical amount wrong"

        set currRows [mongreldb::sql $::g_client "SELECT id, amount FROM tcl_pit"]
        check {[llength $currRows] == 1} "expected exactly one current row"
        set current [lindex $currRows 0]
        check {[dict get $current amount] == 9.0} "current amount wrong"
    }
}

puts "\n$g_pass passed, $g_fail failed, $g_skip skipped"
exit [expr {$g_fail > 0 ? 1 : 0}]
