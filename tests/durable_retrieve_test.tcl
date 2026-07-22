#!/usr/bin/env tclsh
# Offline unit tests for 0.64 durable HLC recovery parsers.

set scriptDir [file dirname [file normalize [info script]]]
lappend auto_path [file join $scriptDir ../src]
source [file join $scriptDir ../src/mongreldb.tcl]

set failures 0
set passed 0

proc check {name body} {
    global failures passed
    if {[catch {uplevel 1 $body} err]} {
        incr failures
        puts "FAIL $name: $err"
    } else {
        incr passed
        puts -nonewline "."
        flush stdout
    }
}

proc assert_eq {a b {msg equal}} {
    if {$a ne $b} {
        error "$msg: got {$a} expected {$b}"
    }
}

set fixture [dict create \
    query_id abcdefabcdefabcdefabcdefabcdefab \
    status committed \
    state completed \
    server_state completed \
    terminal_state committed \
    committed true \
    committed_statements 1 \
    last_commit_epoch 17 \
    last_commit_hlc [dict create physical_micros 1700000000000000 logical 3 node_tiebreaker 7] \
    outcome [dict create \
        committed true \
        last_commit_epoch 17 \
        last_commit_hlc [dict create physical_micros 1700000000000000 logical 3 node_tiebreaker 7] \
        serialization succeeded \
        serialization_state succeeded \
        terminal_state committed] \
    durable [dict create \
        committed true \
        last_commit_epoch 17 \
        last_commit_hlc [dict create physical_micros 1700000000000000 logical 3 node_tiebreaker 7] \
        serialization succeeded \
        serialization_state succeeded \
        terminal_state committed]]

check parse_query_status {
    set status [mongreldb::parseQueryStatus $fixture]
    assert_eq [dict get $status committed] true committed
    set hlc [mongreldb::queryStatusCommitHlc $status]
    assert_eq [dict get $hlc physical_micros] 1700000000000000 phys
    assert_eq [dict get $hlc logical] 3 logical
    assert_eq [dict get $hlc node_tiebreaker] 7 node
    assert_eq [mongreldb::queryStatusSerializationState $status] succeeded ser
    assert_eq [dict get [dict get $status outcome] last_commit_epoch] 17 epoch
}

check parse_commit_hlc_absent {
    assert_eq [mongreldb::parseCommitHlc {}] {} nil
    assert_eq [mongreldb::parseCommitHlc [dict create logical 1]] {} missing
}

puts ""
puts "$passed passed, $failures failed"
if {$failures > 0} { exit 1 }
