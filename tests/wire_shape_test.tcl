# wire_shape_test.tcl - offline wire-format conformance test for the MongrelDB
# Tcl client.
#
# Does NOT contact a daemon. Serializes create_table, batch txn, query, and
# history-retention bodies, then asserts the exact JSON keys and shape the
# server expects. This catches regressions in the on-wire format without needing
# a running mongreldb-server.
#
# Run with:
#   tclsh tests/wire_shape_test.tcl
#
# Licensing: MIT OR Apache-2.0.

lappend auto_path [file join [file dirname [file dirname [info script]]] src]
package require mongreldb

set g_pass 0
set g_fail 0

proc test {name body} {
    global g_pass g_fail
    puts "== $name"
    set before $g_fail
    if {[catch [list uplevel 1 $body] err opts]} {
        if {[dict get $opts -code] == 1 && $err ne "test-abort"} {
            puts "  UNEXPECTED ERROR: $err"
            incr g_fail
        }
    }
    if {$g_fail == $before} { incr g_pass }
}

proc fail {msg} {
    global g_fail
    puts "  FAIL $msg"
    incr g_fail
    return -code error "test-abort"
}

proc check {cond msg} {
    if {![uplevel 1 [list expr $cond]]} { fail $msg }
}

# ── Tests ─────────────────────────────────────────────────────────────────

# The create_table body must carry name, columns[] with id/name/ty/primary_key/
# nullable, optional enum_variants/default_value, and table checks.
test test_create_table_body {
    set cols [list \
        [dict create id 1 name id ty int64 primary_key 1 nullable 0] \
        [dict create id 4 name status ty enum primary_key 0 nullable 0 \
                    enum_variants [list active inactive paused] default_value active] \
        [dict create id 5 name retries ty int64 primary_key 0 nullable 0 default_value_json 3] \
        [dict create id 6 name created_at ty timestamp primary_key 0 nullable 0 default_expr now] \
        [dict create id 7 name enabled ty bool primary_key 0 nullable 0 default_value_json true] \
        [dict create id 8 name optional ty varchar primary_key 0 nullable 1 default_value_json null] \
        [dict create id 9 name now_literal ty varchar primary_key 0 nullable 0 default_value now] \
        [dict create id 10 name uuid_literal ty varchar primary_key 0 nullable 0 default_value uuid] \
    ]
    set constraintsJson {{"checks":[{"id":1,"name":"ck_status","expr":{"IsNotNull":4}}]}}
    set body [mongreldb::_createTableBody orders $cols $constraintsJson]

    check {[string first {"name":"orders"} $body] >= 0} "body missing table name"
    check {[string first {"ty":"int64"} $body] >= 0} "body missing column type"
    check {[string first {"primary_key":true} $body] >= 0} "body missing primary_key"
    check {[string first {enum_variants} $body] >= 0} "body missing enum_variants"
    check {[string first {"default_value":"active"} $body] >= 0} "body missing default_value"
    check {[string first {"default_value":3} $body] >= 0} "numeric default_value became a string"
    check {[string first {"default_expr":"now"} $body] >= 0} "body missing default_expr"
    check {[string first {"default_value":true} $body] >= 0} "boolean default missing"
    check {[string first {"default_value":null} $body] >= 0} "null default missing"
    # Literal "now" and "uuid" strings are static defaults, not dynamic exprs.
    check {[string first {"default_value":"now"} $body] >= 0} "literal now default missing"
    check {[string first {"default_value":"uuid"} $body] >= 0} "literal uuid default missing"
    check {[string first {"default_expr":"now"} $body] >= 0} "dynamic now default_expr missing"
    check {[string first {"constraints":} $body] >= 0} "body missing constraints"
    check {[string first {"checks":} $body] >= 0} "body missing constraints.checks"
    check {[string first {"IsNotNull":4} $body] >= 0} "body missing check expression"
}

test test_create_table_rejects_non_scalar_default_json {
    set cols [list [dict create id 1 name bad ty int64 primary_key 0 nullable 0 \
                              default_value_json {[]}]]
    set threw 0
    try {
        mongreldb::_createTableBody bad $cols
    } trap {MONGRELDB query} {} {
        set threw 1
    } on error {} {}
    check {$threw == 1} "default_value_json must reject arrays and objects"
}

# The history-retention endpoints must use the right HTTP method and path, and
# the setter must emit the new value as raw JSON.
test test_history_retention_wire_shape {
    set db [mongreldb::_new http://127.0.0.1:8453]
    set ::_test_calls {}
    rename ::mongreldb::_request ::mongreldb::_request_orig
    proc ::mongreldb::_request {db method path {body {}}} {
        lappend ::_test_calls [list $method $path $body]
        return [dict create history_retention_epochs 1024 earliest_retained_epoch 7]
    }
    try {
        set epochs [mongreldb::historyRetentionEpochs $db]
        check {$epochs == 1024} "historyRetentionEpochs returned wrong value"
        set earliest [mongreldb::earliestRetainedEpoch $db]
        check {$earliest == 7} "earliestRetainedEpoch returned wrong value"

        # Both getters issue GET /history/retention.
        check {[llength $::_test_calls] == 2} "expected two getter calls"
        set call0 [lindex $::_test_calls 0]
        check {[lindex $call0 0] eq "GET"} "getter must use GET"
        check {[lindex $call0 1] eq "history/retention"} "getter path wrong"
        set call1 [lindex $::_test_calls 1]
        check {[lindex $call1 0] eq "GET"} "second getter must use GET"
        check {[lindex $call1 1] eq "history/retention"} "second getter path wrong"

        set ::_test_calls {}
        set resp [mongreldb::setHistoryRetentionEpochs $db 2048]
        check {[llength $::_test_calls] == 1} "expected exactly one setter call"
        set call [lindex $::_test_calls 0]
        check {[lindex $call 0] eq "PUT"} "setter must use PUT"
        check {[lindex $call 1] eq "history/retention"} "setter path wrong"
        check {[string first {"history_retention_epochs":2048} [lindex $call 2]] >= 0} "setter body missing value"
        check {[string first {earliest_retained_epoch} [lindex $call 2]] < 0} "setter body must not contain earliest_retained_epoch"
    } finally {
        rename ::mongreldb::_request {}
        rename ::mongreldb::_request_orig ::mongreldb::_request
        mongreldb::close $db
    }
}

test test_create_table_ann_backend_options {
    set indexes {[{"name":"ann","column_id":2,"kind":"ann","options":{"ann":{"algorithm":"diskann","quantization":"dense","diskann":{"r":64,"l":128,"beam_width":8,"alpha":120}}}}]}
    set body [mongreldb::_createTableBody vectors {} {} $indexes]
    check {[string first {"algorithm":"diskann"} $body] >= 0} "ANN algorithm missing"
    check {[string first {"quantization":"dense"} $body] >= 0} "ANN quantization missing"
    check {[string first {"beam_width":8} $body] >= 0} "DiskANN options missing"
}

# A non-2xx HTTP response must surface as a typed MONGRELDB error whose code
# carries the category and status. The http layer is stubbed so _request sees a
# controlled status code and body without contacting a daemon.
test test_history_retention_error_propagation {
    set db [mongreldb::_new http://127.0.0.1:8453]

    # Stub the ::http::* procs that _request depends on. Save the originals so
    # they can be restored in the finally block.
    foreach p {geturl ncode data error cleanup} {
        if {[llength [info commands ::http::${p}_orig]] == 0} {
            rename ::http::$p ::http::${p}_orig
        }
    }
    set ::_mock_http_status 500
    set ::_mock_http_body {{"error":{"message":"boom","code":"INTERNAL"}}}
    proc ::http::geturl {args} { return MOCK_TOKEN }
    proc ::http::ncode {token} { return $::_mock_http_status }
    proc ::http::data {token} { return $::_mock_http_body }
    proc ::http::error {token} { return {} }
    proc ::http::cleanup {token} {}

    try {
        # 500 maps to the query category.
        set ::_mock_http_status 500
        set threw 0
        set errcode {}
        try {
            mongreldb::historyRetentionEpochs $db
        } trap {MONGRELDB query} {msg opts} {
            set threw 1
            set errcode [dict get $opts -errorcode]
        } on error {msg opts} {
            # Some Tcl builds tag the rethrow differently; accept any MONGRELDB code.
            set threw 1
            set errcode [dict get $opts -errorcode]
        }
        check {$threw == 1} "500 must raise a typed MONGRELDB error"
        check {[lindex $errcode 0] eq "MONGRELDB"} "errorcode must begin with MONGRELDB"
        check {[lindex $errcode 1] eq "query"} "500 must map to the query category"
        check {[lindex $errcode 2] == 500} "errorcode must carry status 500"

        # 404 maps to the not_found category.
        set ::_mock_http_status 404
        set ::_mock_http_body {{"error":{"message":"missing","code":"NOT_FOUND"}}}
        set threw 0
        set errcode {}
        try {
            mongreldb::earliestRetainedEpoch $db
        } trap {MONGRELDB not_found} {msg opts} {
            set threw 1
            set errcode [dict get $opts -errorcode]
        } on error {msg opts} {
            set threw 1
            set errcode [dict get $opts -errorcode]
        }
        check {$threw == 1} "404 must raise a typed MONGRELDB error"
        check {[lindex $errcode 1] eq "not_found"} "404 must map to the not_found category"
        check {[lindex $errcode 2] == 404} "errorcode must carry status 404"
    } finally {
        # Restore the original ::http::* procs.
        foreach p {geturl ncode data error cleanup} {
            if {[llength [info commands ::http::${p}_orig]] > 0} {
                rename ::http::$p {}
                rename ::http::${p}_orig ::http::$p
            }
        }
        unset -nocomplain ::_mock_http_status ::_mock_http_body
        mongreldb::close $db
    }
}

# The commit epoch returned by /kit/txn must be stored and returned by lastEpoch.
test test_last_epoch_capture {
    set db [mongreldb::_new http://127.0.0.1:8453]
    rename ::mongreldb::_request ::mongreldb::_request_orig
    proc ::mongreldb::_request {db method path {body {}}} {
        return [dict create status committed epoch 42 results {}]
    }
    try {
        check {[mongreldb::lastEpoch $db] eq {}} "lastEpoch should be empty before any commit"
        mongreldb::put $db orders {1 1}
        check {[mongreldb::lastEpoch $db] == 42} "lastEpoch not captured after put"
    } finally {
        rename ::mongreldb::_request {}
        rename ::mongreldb::_request_orig ::mongreldb::_request
        mongreldb::close $db
    }
}

# The batch txn body must wrap ops in {"ops":[...]} and carry an idempotency
# key when one is supplied.
test test_txn_body_with_key {
    set body "\{\"ops\":\[\{\"put\":\{\"table\":\"orders\",\"cells\":\[1,1\],\"returning\":false\}\}\],\"idempotency_key\":\"batch-1\"\}"
    check {[string first {"ops":} $body] >= 0} "txn body missing ops"
    check {[string first {"idempotency_key":"batch-1"} $body] >= 0} "txn body missing idempotency_key"
    check {[string first {"returning":false} $body] >= 0} "txn body put must set returning:false"
}

# The query body must serialize conditions, projection, and limit.
test test_query_body {
    set body "\{\"table\":\"orders\",\"conditions\":\[\{\"range\":\{\"column_id\":3,\"lo\":100.0,\"hi\":500.0\}\}\],\"projection\":\[1,2\],\"limit\":100,\"offset\":12000\}"
    check {[string first {"table":"orders"} $body] >= 0} "query body missing table"
    check {[string first {range} $body] >= 0} "query body missing range condition"
    check {[string first {column_id} $body] >= 0} "query body missing column_id"
    check {[string first {projection} $body] >= 0} "query body missing projection"
    check {[string first {"limit":100} $body] >= 0} "query body missing limit"
    check {[string first {"offset":12000} $body] >= 0} "query body missing offset"
}

# Table names with special characters must be percent-encoded in path segments.
test test_segment_encoding {
    set encoded [mongreldb::_encodeSegment {a/b c}]
    check {[string first %2F $encoded] >= 0} "slash must be percent-encoded"
    check {[string first %20 $encoded] >= 0} "space must be percent-encoded"
}

# condition() must build the right wire shape per kind.
test test_condition_builder {
    set pk [mongreldb::condition pk [dict create value 42]]
    check {[dict get $pk pk value] == 42} "pk condition wrong"

    set range [mongreldb::condition range [dict create column_id 3 lo 100 hi 500]]
    check {[dict get $range range column_id] == 3} "range column_id wrong"
    check {[dict get $range range lo] == 100} "range lo wrong"

    set fm [mongreldb::condition fm_contains [dict create column_id 2 value database]]
    check {[dict get $fm fm_contains pattern] eq "database"} "fm_contains must map value->pattern"
}

test test_complete_ai_conditions {
    set ann [mongreldb::conditionJson \
        {{"ann":{"column_id":2,"query":[0.1,0.2],"k":10}}}]
    check {[mongreldb::_serializeCondition $ann] eq \
        {{"ann":{"column_id":2,"query":[0.1,0.2],"k":10}}}} \
        "ANN condition changed"

    set sparse [mongreldb::conditionJson \
        {{"sparse_match":{"column_id":3,"query":[[7,0.5]],"k":5}}}]
    check {[string first {"sparse_match"} \
        [mongreldb::_serializeCondition $sparse]] >= 0} \
        "sparse condition missing"

    set minhash [mongreldb::conditionJson \
        {{"minhash_similar_members":{"column_id":4,"members":["a","b"],"k":5}}}]
    check {[string first {"minhash_similar_members"} \
        [mongreldb::_serializeCondition $minhash]] >= 0} \
        "MinHash condition missing"
}

# CR/LF in an auth credential must be rejected (header-injection guard).
test test_crlf_rejection {
    set threw 0
    try {
        mongreldb::connectWithToken {http://127.0.0.1:8453} "good\r\nX-Evil: yes"
    } trap {MONGRELDB auth} {} {
        set threw 1
    } on error {} {}
    check {$threw == 1} "must reject CR/LF in token"
}

puts "\n$g_pass passed, $g_fail failed"
exit [expr {$g_fail > 0 ? 1 : 0}]
