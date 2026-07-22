# Structural durable recovery parsers (0.64+). Pure Tcl dicts; no tcllib.
namespace eval ::mongreldb {}

# Structural durable recovery parsers (0.64+). Pure Tcl dicts; no tcllib.
# Sourced by mongreldb.tcl and by offline unit tests.

# ── SQL control / durable recovery / retrieve_text (0.64+) ────────────────

# Structural HLC from durable recovery. Returns {} when absent.
proc ::mongreldb::parseCommitHlc {raw} {
    if {$raw eq {} || ![dict exists $raw physical_micros]} {
        return {}
    }
    set logical 0
    set node 0
    if {[dict exists $raw logical]} { set logical [dict get $raw logical] }
    if {[dict exists $raw node_tiebreaker]} { set node [dict get $raw node_tiebreaker] }
    return [dict create \
        physical_micros [dict get $raw physical_micros] \
        logical $logical \
        node_tiebreaker $node]
}

proc ::mongreldb::_parseDurableOutcome {raw} {
    if {$raw eq {}} {
        return [dict create committed {} last_commit_epoch {} last_commit_hlc {} \
            serialization {} serialization_state {} terminal_state {}]
    }
    set hlc {}
    if {[dict exists $raw last_commit_hlc]} {
        set hlc [parseCommitHlc [dict get $raw last_commit_hlc]]
    }
    set committed {}
    if {[dict exists $raw committed]} { set committed [dict get $raw committed] }
    set epoch {}
    if {[dict exists $raw last_commit_epoch]} { set epoch [dict get $raw last_commit_epoch] }
    set ser {}
    if {[dict exists $raw serialization]} { set ser [dict get $raw serialization] }
    set serState {}
    if {[dict exists $raw serialization_state]} { set serState [dict get $raw serialization_state] }
    set term {}
    if {[dict exists $raw terminal_state]} { set term [dict get $raw terminal_state] }
    return [dict create \
        committed $committed \
        last_commit_epoch $epoch \
        last_commit_hlc $hlc \
        serialization $ser \
        serialization_state $serState \
        terminal_state $term]
}

# Decode GET /queries/{id} body into a structural status dict (0.64+).
# Use [queryStatusCommitHlc $status] and [queryStatusSerializationState $status].
proc ::mongreldb::parseQueryStatus {raw} {
    if {$raw eq {}} { set raw [dict create] }
    set outcome {}
    if {[dict exists $raw outcome]} {
        set outcome [_parseDurableOutcome [dict get $raw outcome]]
    } else {
        set outcome [_parseDurableOutcome {}]
    }
    set durable {}
    if {[dict exists $raw durable]} {
        set durable [_parseDurableOutcome [dict get $raw durable]]
    }
    set topHlc {}
    if {[dict exists $raw last_commit_hlc]} {
        set topHlc [parseCommitHlc [dict get $raw last_commit_hlc]]
    }
    set qid {}
    if {[dict exists $raw query_id]} { set qid [dict get $raw query_id] }
    set st {}
    if {[dict exists $raw status]} { set st [dict get $raw status] }
    set state {}
    if {[dict exists $raw state]} { set state [dict get $raw state] }
    set serverState $state
    if {[dict exists $raw server_state]} { set serverState [dict get $raw server_state] }
    set committed {}
    if {[dict exists $raw committed]} { set committed [dict get $raw committed] }
    set epoch {}
    if {[dict exists $raw last_commit_epoch]} { set epoch [dict get $raw last_commit_epoch] }
    return [dict create \
        query_id $qid \
        status $st \
        state $state \
        server_state $serverState \
        committed $committed \
        last_commit_epoch $epoch \
        last_commit_hlc $topHlc \
        outcome $outcome \
        durable $durable \
        raw $raw]
}

proc ::mongreldb::queryStatusCommitHlc {status} {
    if {[dict exists $status durable]} {
        set d [dict get $status durable]
        if {$d ne {} && [dict exists $d last_commit_hlc]} {
            set h [dict get $d last_commit_hlc]
            if {$h ne {}} { return $h }
        }
    }
    if {[dict exists $status outcome]} {
        set o [dict get $status outcome]
        if {$o ne {} && [dict exists $o last_commit_hlc]} {
            set h [dict get $o last_commit_hlc]
            if {$h ne {}} { return $h }
        }
    }
    if {[dict exists $status last_commit_hlc]} {
        return [dict get $status last_commit_hlc]
    }
    return {}
}

proc ::mongreldb::queryStatusSerializationState {status} {
    if {[dict exists $status durable]} {
        set d [dict get $status durable]
        if {$d ne {}} {
            if {[dict exists $d serialization_state]} {
                set s [dict get $d serialization_state]
                if {$s ne {}} { return $s }
            }
            if {[dict exists $d serialization]} {
                set s [dict get $d serialization]
                if {$s ne {}} { return $s }
            }
        }
    }
    if {[dict exists $status outcome]} {
        set o [dict get $status outcome]
        if {$o ne {}} {
            if {[dict exists $o serialization_state]} {
                set s [dict get $o serialization_state]
                if {$s ne {}} { return $s }
            }
            if {[dict exists $o serialization]} {
                return [dict get $o serialization]
            }
        }
    }
    return {}
}

# Text → embed → ANN retrieve (POST kit/retrieve_text, 0.64+).
proc ::mongreldb::retrieveText {db table embeddingColumn text {k 0} {deadlineMs 0} {maxWork 0}} {
    if {$table eq {}} { _error query {table is required} }
    if {$text eq {}} { _error query {text is required} }
    set body "\{\"table\":\"[_jsonEscape $table]\",\"embedding_column\":[expr {wide($embeddingColumn)}],\"text\":\"[_jsonEscape $text]\""
    if {$k > 0} { append body ",\"k\":[expr {wide($k)}]" }
    if {$deadlineMs > 0} { append body ",\"deadline_ms\":[expr {wide($deadlineMs)}]" }
    if {$maxWork > 0} { append body ",\"max_work\":[expr {wide($maxWork)}]" }
    append body "\}"
    set data [_post $db kit/retrieve_text $body]
    if {![dict exists $data hits]} {
        return [dict create hits {} provenance {}]
    }
    set provenance {}
    if {[dict exists $data provenance]} { set provenance [dict get $data provenance] }
    return [dict create hits [dict get $data hits] provenance $provenance]
}

# Retained SQL status for durable recovery (GET queries/{query_id}).
proc ::mongreldb::queryStatus {db queryId} {
    if {$queryId eq {}} { _error query {query_id is required} }
    set data [_get $db "queries/[_encodeSegment $queryId]"]
    return [parseQueryStatus $data]
}

# Request cancellation of a running SQL query.
proc ::mongreldb::cancelQuery {db queryId} {
    if {$queryId eq {}} { _error query {query_id is required} }
    set data [_post $db "queries/[_encodeSegment $queryId]/cancel" "{}"]
    return $data
}

