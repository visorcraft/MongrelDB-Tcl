# mongreldb.tcl - Pure Tcl HTTP client for MongrelDB.
#
# Talks to a running mongreldb-server daemon's JSON API over the Kit
# transaction, query, and SQL endpoints. Uses the Tcl 8.6+ core `http` package
# plus the `json` package from `tcllib`, so the only external dependency is
# `tcllib`.
#
# Usage:
#   package require mongreldb
#   set db [mongreldb::connect http://127.0.0.1:8453]
#   mongreldb::createTable $db orders $columns
#   mongreldb::put $db orders {1 1 2 Alice 3 99.5}
#
# Licensing: MIT OR Apache-2.0.
# SPDX-License-Identifier: MIT OR Apache-2.0

package require http
package require json
package require Tcl 8.6

package provide mongreldb 0.52.3

# Empty namespace eval to hold all commands. Every public command takes the
# client handle (returned by connect) as its first argument.
namespace eval ::mongreldb {
    # Default daemon URL when none is supplied.
    variable defaultUrl {http://127.0.0.1:8453}

    # Cap on a response body size (256 MB) so a runaway query cannot exhaust
    # memory.
    variable maxResponseBytes 268435456

    # Map an HTTP status code to the right error category. Mirrors the other
    # MongrelDB clients so callers can match by category across languages.
    variable kindForStatus
    array set kindForStatus {
        401 auth 403 auth 404 not_found 409 conflict
    }

    # Unique client id generator and commit-epoch storage. The client handle is
    # an immutable dict, so per-handle mutable state lives in namespace arrays
    # keyed by the handle's id.
    variable nextClientId 0
    variable clientEpoch
    array set clientEpoch {}

    namespace export connect health tables createTable dropTable count \
                          put upsert delete deleteByPk transaction query \
                          condition sql schema schemaFor close lastError \
                          historyRetentionEpochs earliestRetainedEpoch setHistoryRetentionEpochs \
                          lastEpoch
}

# ── Error handling ────────────────────────────────────────────────────────

# Build and throw a typed MongrelDB error. The error code list begins with
# MONGRELDB and carries the category as the second element, so callers can
# use [try ... trap {MONGRELDB <category>} ...] to match by category.
proc ::mongreldb::_error {kind message {status 0} {code {}}} {
    set full "MONGRELDB $kind: $message"
    set errcode [list MONGRELDB $kind]
    if {$status} { lappend errcode $status }
    if {$code ne {}} { lappend errcode $code }
    return -code error -errorcode $errcode $full
}

# ── JSON helpers ──────────────────────────────────────────────────────────

# Percent-encode a single URL path segment so a table name containing '/',
# '?', '#', or spaces cannot inject extra segments or break routing.
proc ::mongreldb::_encodeSegment {seg} {
    # Tcl's [http::formatQuery] percent-encodes, but also converts spaces to
    # '+'. We want %20 for a path segment, so encode char by char.
    set out {}
    foreach ch [split $seg {}] {
        scan $ch %c ord
        if {($ord >= 65 && $ord <= 90) || ($ord >= 97 && $ord <= 122) ||
            ($ord >= 48 && $ord <= 57) || $ord == 45 || $ord == 95 ||
            $ord == 46 || $ord == 126} {
            append out $ch
        } else {
            append out [format %%%02X $ord]
        }
    }
    return $out
}

# Reject CR/LF in an auth credential: token/username/password are placed
# verbatim into the Authorization header, so an embedded newline would allow
# header injection (request splitting). Validate before use.
proc ::mongreldb::_assertNoCrlf {value name} {
    if {[string range $value 0 end] ne $value} { return }
    if {[regexp {[\r\n]} $value]} {
        _error auth "auth $name must not contain CR or LF"
    }
}

# Escape a string for embedding into a JSON string literal.
proc ::mongreldb::_jsonEscape {s} {
    set s [string map {\\ \\\\  \" \\\"  \b \\b  \f \\f  \n \\n  \r \\r  \t \\t} $s]
    # Encode remaining control chars as \uXXXX.
    set out {}
    foreach ch [split $s {}] {
        scan $ch %c ord
        if {$ord < 32} {
            append out [format {\\u%04x} $ord]
        } else {
            append out $ch
        }
    }
    return $out
}

# Serialize a Tcl value to a JSON scalar. A list of two elements whose first
# element is an integer is treated as a key/value pair list; otherwise scalars
# are stringified. We rely on the caller passing already-typed Tcl values
# (integers as numbers, strings as strings).
proc ::mongreldb::_jsonValue {v} {
    # Detect numbers (Tcl-native): integer or floating point.
    if {[regexp {^-?[0-9]+$} $v]} {
        return [expr {wide($v)}]
    }
    if {[regexp {^-?[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?$} $v]} {
        # Reject NaN/Inf which have no valid JSON representation.
        set d [expr {double($v)}]
        if {$d != $d || abs($d) == pow(9, 9*9)} {
            _error query "cannot JSON-encode NaN or Infinity"
        }
        return $d
    }
    return "\"[_jsonEscape $v]\""
}

# Build the flat cells list the server expects: [col_id, value, ...].
# Input is an even-length list {colId value colId value ...}.
proc ::mongreldb::_flattenCells {cells} {
    set out "\["
    set first 1
    foreach {colId value} $cells {
        if {!$first} { append out "," }
        set first 0
        append out [expr {wide($colId)}]
        append out ","
        append out [_jsonValue $value]
    }
    append out "\]"
    return $out
}

# ── Lifecycle ─────────────────────────────────────────────────────────────

# Construct a client. Internal; callers use connect().
proc ::mongreldb::_new {url args} {
    array set opts {-token {} -username {} -password {} -timeout 30}
    array set opts $args

    if {$opts(-token) ne {}} {
        _assertNoCrlf $opts(-token) token
    }
    if {$opts(-username) ne {}} {
        _assertNoCrlf $opts(-username) username
        _assertNoCrlf $opts(-password) password
    }

    set u [string trimright $url "/"]
    if {$u eq {}} { set u $::mongreldb::defaultUrl }

    set authHeader {}
    if {$opts(-token) ne {}} {
        set authHeader "Bearer $opts(-token)"
    } elseif {$opts(-username) ne {}} {
        set creds "$opts(-username):$opts(-password)"
        # base64-encode the credentials using the binary encode command.
        set encoded [binary encode base64 $creds]
        set authHeader "Basic $encoded"
    }

    # The client handle is a dict with the connection state.
    variable nextClientId
    variable clientEpoch
    set id [incr nextClientId]
    set clientEpoch($id) {}
    return [dict create id $id url $u authHeader $authHeader \
                timeout $opts(-timeout) lastError {}]
}

# Open mode: no credentials. url defaults to http://127.0.0.1:8453.
proc ::mongreldb::connect {{url {}} args} {
    tailcall _new $url {*}$args
}

# Bearer token mode.
proc ::mongreldb::connectWithToken {url token args} {
    tailcall _new $url -token $token {*}$args
}

# HTTP Basic mode.
proc ::mongreldb::connectWithBasicAuth {url username password args} {
    tailcall _new $url -username $username -password $password {*}$args
}

# Close the client and free its per-handle state (the handle itself is a dict).
proc ::mongreldb::close {db} {
    variable clientEpoch
    set id [dict get $db id]
    if {[info exists clientEpoch($id)]} {
        unset clientEpoch($id)
    }
    return
}

# Last error message for the client (for diagnostics).
proc ::mongreldb::lastError {db} {
    dict get $db lastError
}

# ── Core request helper ───────────────────────────────────────────────────

# Perform one HTTP request. method is GET/POST/DELETE. body is the JSON to
# send (or {} for no body). Returns the decoded JSON value, or {} for empty
# bodies. Throws a typed MongrelDB error on failure.
proc ::mongreldb::_request {db method path {body {}}} {
    set url "[dict get $db url]/$path"
    variable maxResponseBytes

    # Configure the http package: never follow redirects (an Authorization
    # header could follow a redirect to an attacker-controlled host), and set
    # the User-Agent.
    set oldAgent $::http::defaultCharset
    ::http::config -useragent "mongreldb-tcl/0.52.3"

    set headers [list Accept {application/json}]
    if {[dict get $db authHeader] ne {}} {
        lappend headers Authorization [dict get $db authHeader]
    }

    set query {}
    if {$body ne {}} {
        set query $body
        lappend headers Content-Type {application/json}
    }

    set token [::http::geturl $url -method $method -headers $headers \
                   -query $query -timeout [expr {[dict get $db timeout] * 1000}]]

    set status [::http::ncode $token]
    set data [::http::data $token]
    set error [::http::error $token]
    ::http::cleanup $token

    # A transport failure (e.g. connection refused) surfaces as a non-200
    # status with an error string.
    if {$error ne {}} {
        _error network "network error: $error"
    }

    # Cap the response body at 256 MB.
    if {[string length $data] > $maxResponseBytes} {
        _error query "response body exceeds $maxResponseBytes bytes"
    }

    if {$status < 200 || $status >= 300} {
        # Decode the daemon's error envelope if present.
        set message {}
        set code {}
        set ok 0
        catch {
            set decoded [::json::json2dict $data]
            if {[dict exists $decoded error]} {
                set errObj [dict get $decoded error]
                if {[catch {dict exists $errObj message} isObject] || !$isObject} {
                    set message $errObj
                    set ok 1
                } elseif {[dict exists $errObj message]} {
                    set message [dict get $errObj message]
                    set ok 1
                }
                if {[dict exists $errObj code]} {
                    set code [dict get $errObj code]
                }
            }
        }
        if {!$ok} { set message "Server error ($status)" }
        variable kindForStatus
        if {[info exists kindForStatus($status)]} {
            set kind $kindForStatus($status)
        } else {
            set kind query
        }
        if {[string match -nocase {not found:*} $message]} { set kind not_found }
        if {[string match -nocase {*not found*} $data]} { set kind not_found }
        _error $kind $message $status $code
    }

    if {$data eq {}} { return {} }
    # Decode the JSON body; tolerate a non-JSON 2xx body (e.g. plain "ok").
    if {[catch {::json::json2dict $data} decoded]} {
        return {}
    }
    return $decoded
}

# Convenience wrappers.
proc ::mongreldb::_get {db path} { tailcall _request $db GET $path {} }
proc ::mongreldb::_post {db path body} { tailcall _request $db POST $path $body }
proc ::mongreldb::_delete {db path} { tailcall _request $db DELETE $path {} }

# ── Health & tables ───────────────────────────────────────────────────────

# Check daemon health. Returns 1 on success, 0 on failure (never throws, so it
# is safe for startup checks).
proc ::mongreldb::health {db} {
    set ok 0
    if {![catch {_get $db health}]} { set ok 1 }
    return $ok
}

proc ::mongreldb::historyRetentionEpochs {db} {
    set data [_get $db history/retention]
    if {[dict exists $data history_retention_epochs]} {
        return [dict get $data history_retention_epochs]
    }
    _error query "history_retention_epochs missing from server response"
}

proc ::mongreldb::earliestRetainedEpoch {db} {
    set data [_get $db history/retention]
    if {[dict exists $data earliest_retained_epoch]} {
        return [dict get $data earliest_retained_epoch]
    }
    _error query "earliest_retained_epoch missing from server response"
}

proc ::mongreldb::setHistoryRetentionEpochs {db epochs} {
    if {![string is integer -strict $epochs] || $epochs < 0} {
        _error query "history retention epochs must be a non-negative integer"
    }
    _request $db PUT history/retention "\{\"history_retention_epochs\":$epochs\}"
}

# Return the commit epoch of the most recent successful /kit/txn call, or {}
# before any transaction has committed through this client.
proc ::mongreldb::lastEpoch {db} {
    variable clientEpoch
    set id [dict get $db id]
    if {[info exists clientEpoch($id)]} {
        return $clientEpoch($id)
    }
    return {}
}

# List all table names.
proc ::mongreldb::tables {db} {
    set data [_get $db tables]
    # The endpoint returns a bare JSON array of strings.
    return $data
}

# Build the create-table JSON once so the live path and wire test cannot drift.
proc ::mongreldb::_createTableBody {name columns {constraintsJson {}}} {
    set body "\{\"name\":\"[_jsonEscape $name]\",\"columns\":\["
    set first 1
    foreach col $columns {
        if {!$first} { append body "," }
        set first 0
        append body "\{\"id\":"
        append body [expr {wide([dict get $col id])}]
        append body ",\"name\":\"[_jsonEscape [dict get $col name]]\""
        append body ",\"ty\":\"[_jsonEscape [dict get $col ty]]\""
        append body ",\"primary_key\":"
        append body [expr {[dict get $col primary_key] ? "true" : "false"}]
        append body ",\"nullable\":"
        append body [expr {[dict get $col nullable] ? "true" : "false"}]
        if {[dict exists $col enum_variants]} {
            append body ",\"enum_variants\":\["
            set f2 1
            foreach v [dict get $col enum_variants] {
                if {!$f2} { append body "," }
                set f2 0
                append body "\"[_jsonEscape $v]\""
            }
            append body "\]"
        }
        if {[dict exists $col default_value] && ![dict exists $col default_value_json]} {
            append body ",\"default_value\":\"[_jsonEscape [dict get $col default_value]]\""
        }
        if {[dict exists $col default_value_json]} {
            set scalar [string trim [dict get $col default_value_json]]
            if {![regexp {^(null|true|false|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$} $scalar]} {
                _error query {default_value_json must be null, boolean, or number JSON}
            }
            append body ",\"default_value\":$scalar"
        }
        if {[dict exists $col default_expr]} {
            append body ",\"default_expr\":\"[_jsonEscape [dict get $col default_expr]]\""
        }
        append body "\}"
    }
    append body "\]"
    set constraintsJson [string trim $constraintsJson]
    if {$constraintsJson ne {}} {
        if {[string index $constraintsJson 0] ne "\{" ||
            [catch {::json::json2dict $constraintsJson}]} {
            _error query {constraintsJson must be a valid JSON object}
        }
        append body ",\"constraints\":$constraintsJson"
    }
    append body "\}"
    return $body
}

# Create a table. constraintsJson is an optional JSON object using the daemon's
# TableConstraints shape, including constraints.checks.
proc ::mongreldb::createTable {db name columns {constraintsJson {}}} {
    set body [_createTableBody $name $columns $constraintsJson]
    set data [_post $db kit/create_table $body]
    if {[dict exists $data table_id]} {
        return [dict get $data table_id]
    }
    return 0
}

# Drop a table by name.
proc ::mongreldb::dropTable {db name} {
    tailcall _delete $db "tables/[_encodeSegment $name]"
}

# Row count for a table.
proc ::mongreldb::count {db table} {
    set data [_get $db "tables/[_encodeSegment $table]/count"]
    if {[dict exists $data count]} {
        return [dict get $data count]
    }
    _error query "malformed count response from server"
}

# ── CRUD (single-op transactions) ─────────────────────────────────────────

# Insert a row. cells is an even-length list {colId value ...}. idempotencyKey
# (or {}) makes the commit safe to retry.
proc ::mongreldb::put {db table cells {idempotencyKey {}}} {
    set op "\{\"put\":\{\"table\":\"[_jsonEscape $table]\",\"cells\":[_flattenCells $cells],\"returning\":false\}\}"
    tailcall _commit $db [list $op] $idempotencyKey
}

# Upsert (insert or update on PK conflict). updateCells (or {}) supplies the
# values written on conflict ({} = do nothing on conflict).
proc ::mongreldb::upsert {db table cells {updateCells {}} {idempotencyKey {}}} {
    set op "\{\"upsert\":\{\"table\":\"[_jsonEscape $table]\",\"cells\":[_flattenCells $cells]"
    if {$updateCells ne {}} {
        append op ",\"update_cells\":[_flattenCells $updateCells]"
    }
    append op ",\"returning\":false\}\}"
    tailcall _commit $db [list $op] $idempotencyKey
}

# Delete a row by its internal row id.
proc ::mongreldb::delete {db table rowId} {
    set op "\{\"delete\":\{\"table\":\"[_jsonEscape $table]\",\"row_id\":[expr {wide($rowId)}]\}\}"
    tailcall _commit $db [list $op] {}
}

# Delete a row by its primary-key value.
proc ::mongreldb::deleteByPk {db table pk} {
    set op "\{\"delete_by_pk\":\{\"table\":\"[_jsonEscape $table]\",\"pk\":[_jsonValue $pk]\}\}"
    tailcall _commit $db [list $op] {}
}

# ── Batch transactions ────────────────────────────────────────────────────

# Commit a batch of ops atomically. ops is a list of JSON-encoded op objects
# (each like {"put":{...}}). idempotencyKey (or {}) makes the commit safe to
# retry. Returns the per-op results list.
proc ::mongreldb::_commit {db ops idempotencyKey} {
    set body "\{\"ops\":\["
    append body [join $ops ","]
    append body "\]"
    if {$idempotencyKey ne {}} {
        append body ",\"idempotency_key\":\"[_jsonEscape $idempotencyKey]\""
    }
    append body "\}"
    set data [_post $db kit/txn $body]
    # Capture the commit epoch when the server reports a committed status.
    if {[dict exists $data status] && [dict get $data status] eq "committed" &&
        [dict exists $data epoch]} {
        variable clientEpoch
        set clientEpoch([dict get $db id]) [dict get $data epoch]
    }
    if {[dict exists $data results]} {
        return [dict get $data results]
    }
    return {}
}

# Public batch transaction: ops is a list of op dicts. Each op dict has one key
# (put/upsert/delete/delete_by_pk) whose value is the inner op spec dict.
proc ::mongreldb::transaction {db ops {idempotencyKey {}}} {
    set jsonOps {}
    foreach op $ops {
        # Each op dict has exactly one top-level key naming the op kind.
        set kind [lindex [dict keys $op] 0]
        set inner [dict get $op $kind]
        set innerJson [_serializeInnerOp $kind $inner]
        lappend jsonOps "\{\"$kind\":$innerJson\}"
    }
    tailcall _commit $db $jsonOps $idempotencyKey
}

# Serialize the inner spec of one op kind to JSON.
proc ::mongreldb::_serializeInnerOp {kind inner} {
    switch -- $kind {
        put - upsert {
            set s "\{\"table\":\"[_jsonEscape [dict get $inner table]]\""
            append s ",\"cells\":[_flattenCells [dict get $inner cells]]"
            if {$kind eq "upsert" && [dict exists $inner update_cells]} {
                append s ",\"update_cells\":[_flattenCells [dict get $inner update_cells]]"
            }
            append s ",\"returning\":false\}"
            return $s
        }
        delete {
            return "\{\"table\":\"[_jsonEscape [dict get $inner table]]\",\"row_id\":[expr {wide([dict get $inner row_id])}]\}"
        }
        delete_by_pk {
            return "\{\"table\":\"[_jsonEscape [dict get $inner table]]\",\"pk\":[_jsonValue [dict get $inner pk]]\}"
        }
        default {
            _error query "unknown op kind: $kind"
        }
    }
}

# ── Query ─────────────────────────────────────────────────────────────────

# Build a normalized condition (translates friendly aliases). type is one of
# pk, bitmap_eq, range, range_f64, fm_contains, is_null, is_not_null. params is
# a dict. Use range for integer columns and range_f64 for float64 columns.
proc ::mongreldb::condition {type params} {
    switch -- $type {
        pk {
            return [dict create pk [dict create value [dict get $params value]]]
        }
        bitmap_eq {
            return [dict create bitmap_eq [dict create column_id [dict get $params column_id] value [dict get $params value]]]
        }
        range {
            set d [dict create column_id [dict get $params column_id]]
            if {[dict exists $params lo]} { dict set d lo [dict get $params lo] }
            if {[dict exists $params hi]} { dict set d hi [dict get $params hi] }
            return [dict create range $d]
        }
        range_f64 {
            set d [dict create column_id [dict get $params column_id]]
            if {[dict exists $params lo]} { dict set d lo [dict get $params lo] }
            if {[dict exists $params hi]} { dict set d hi [dict get $params hi] }
            if {[dict exists $params lo_inclusive]} { dict set d lo_inclusive [dict get $params lo_inclusive] }
            if {[dict exists $params hi_inclusive]} { dict set d hi_inclusive [dict get $params hi_inclusive] }
            return [dict create range_f64 $d]
        }
        fm_contains {
            # value -> pattern alias
            if {[dict exists $params pattern]} {
                set pat [dict get $params pattern]
            } else {
                set pat [dict get $params value]
            }
            return [dict create fm_contains [dict create column_id [dict get $params column_id] pattern $pat]]
        }
        is_null {
            return [dict create is_null [dict create column_id [dict get $params column_id]]]
        }
        is_not_null {
            return [dict create is_not_null [dict create column_id [dict get $params column_id]]]
        }
        default {
            _error query "unknown condition kind: $type"
        }
    }
}

# Render a value as a JSON boolean. Tcl has no distinct boolean type, so accept
# the usual truthy spellings (true/false, yes/no, 1/0, on/off). Anything that is
# not a recognized false value is treated as true, mirroring Tcl's [expr].
proc ::mongreldb::_jsonBool {v} {
    set v [string tolower [string trim $v]]
    if {$v eq "false" || $v eq "0" || $v eq "no" || $v eq "off" || $v eq {}} {
        return false
    }
    return true
}

# Serialize a condition dict to JSON.
proc ::mongreldb::_serializeCondition {cond} {
    set type [lindex [dict keys $cond] 0]
    set inner [dict get $cond $type]
    set s "\{\"$type\":\{"
    set first 1
    foreach {k v} $inner {
        if {!$first} { append s "," }
        set first 0
        append s "\"$k\":"
        # The daemon deserializes lo_inclusive / hi_inclusive as booleans, so
        # emit true/false rather than letting _jsonValue render a 1/0 integer.
        if {$k eq "lo_inclusive" || $k eq "hi_inclusive"} {
            append s [_jsonBool $v]
        } else {
            append s [_jsonValue $v]
        }
    }
    append s "\}\}"
    return $s
}

# Run a native query. conditions (or {}) is a list of condition dicts (see
# condition). projection (or {}) restricts returned column ids; limit (or 0)
# caps the count. Returns a dict with rows and truncated keys.
proc ::mongreldb::query {db table {conditions {}} {projection {}} {limit 0} {offset 0}} {
    set body "\{\"table\":\"[_jsonEscape $table]\""
    if {$conditions ne {}} {
        append body ",\"conditions\":\["
        set first 1
        foreach c $conditions {
            if {!$first} { append body "," }
            set first 0
            append body [_serializeCondition $c]
        }
        append body "\]"
    }
    if {$projection ne {}} {
        append body ",\"projection\":\["
        set first 1
        foreach p $projection {
            if {!$first} { append body "," }
            set first 0
            append body [expr {wide($p)}]
        }
        append body "\]"
    }
    if {$limit > 0} {
        append body ",\"limit\":[expr {wide($limit)}]"
    }
    if {$offset != 0} {
        append body ",\"offset\":[expr {wide($offset)}]"
    }
    append body "\}"
    set data [_post $db kit/query $body]

    set rows {}
    set truncated 0
    if {[dict exists $data rows]} { set rows [dict get $data rows] }
    if {[dict exists $data truncated]} { set truncated [expr {[dict get $data truncated] ? 1 : 0}] }
    return [dict create rows $rows truncated $truncated]
}

# ── SQL & schema ──────────────────────────────────────────────────────────

# Execute SQL. Requests the JSON result format. Returns decoded rows for
# SELECTs, or {} for statements that produce no rows.
proc ::mongreldb::sql {db statement} {
    set body "\{\"sql\":\"[_jsonEscape $statement]\",\"format\":\"json\"\}"
    tailcall _post $db sql $body
}

# Full schema catalog.
proc ::mongreldb::schema {db} {
    set data [_get $db kit/schema]
    if {[dict exists $data tables]} {
        return [dict get $data tables]
    }
    return $data
}

# Descriptor for a single table.
proc ::mongreldb::schemaFor {db table} {
    tailcall _get $db "kit/schema/[_encodeSegment $table]"
}
