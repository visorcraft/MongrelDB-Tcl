#!/usr/bin/env tclsh
# Offline unit tests for structural HLC / query-status parsers (no tcllib required).
set scriptDir [file dirname [info script]]
source [file join $scriptDir ../src/durable.tcl]

proc assert_eq {a b label} {
    if {$a ne $b} {
        puts "FAIL $label: got {$a} want {$b}"
        exit 1
    }
}

set fixture [dict create \
    query_id abcdefabcdefabcdefabcdefabcdefab \
    status committed \
    state completed \
    server_state completed \
    committed 1 \
    last_commit_hlc [dict create physical_micros 1700000000000000 logical 3 node_tiebreaker 7] \
    outcome [dict create \
        committed 1 \
        last_commit_epoch 17 \
        last_commit_hlc [dict create physical_micros 1700000000000000 logical 3 node_tiebreaker 7] \
        serialization succeeded \
        serialization_state succeeded \
    ] \
    durable [dict create \
        committed 1 \
        last_commit_epoch 17 \
        last_commit_hlc [dict create physical_micros 1700000000000000 logical 3 node_tiebreaker 7] \
        serialization succeeded \
        serialization_state succeeded \
    ] \
]

set status [mongreldb::parseQueryStatus $fixture]
set hlc [mongreldb::queryStatusCommitHlc $status]
assert_eq [dict get $hlc physical_micros] 1700000000000000 phys
assert_eq [dict get $hlc logical] 3 logical
assert_eq [dict get $hlc node_tiebreaker] 7 node
assert_eq [mongreldb::queryStatusSerializationState $status] succeeded ser
assert_eq [mongreldb::parseCommitHlc {}] {} nil
assert_eq [mongreldb::parseCommitHlc [dict create logical 1]] {} missing

puts "OK durable_retrieve_test (6 checks)"
