#!/usr/bin/env bash
# Positive control for the whole path: approved source + valid client cert -> gateway -> backend.
# Every negative test depends on this: a rejection only means something if the same path works.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
require_cmds kubectl jq
guard_lab_context
init_run
T="$(basename "$0")"
use_test_namespace "$NS_CLIENT"

rid="$(new_run_id)"
export SEND_RUN_ID="$rid" SEND_COUNT=3
run_sender zt-test-delivery-1; res="$SENDER_RESULT"

if [ "$res" != "succeeded" ]; then
  record "$T" D1 FAIL "valid client cert via approved source delivers telemetry" \
    "sender job succeeded" "sender job $res (class=$(classify_failure "$SENDER_LOG"))" "$SENDER_LOG"
else
  if wait_backend_receipt "$rid" 30; then
    t="$(backend_count "$rid" resourceSpans)"; m="$(backend_count "$rid" resourceMetrics)"; l="$(backend_count "$rid" resourceLogs)"
    logs_n="$(backend_record_count "$rid")"
    if [ "${t:-0}" -ge 1 ] && [ "${m:-0}" -ge 1 ] && [ "${l:-0}" -ge 1 ]; then
      record "$T" D1 PASS "valid client cert via approved source delivers telemetry (all 3 signals)" \
        "backend holds traces+metrics+logs tagged $rid" "batches: traces=$t metrics=$m logs=$l; records=$logs_n"
    else
      record "$T" D1 FAIL "valid client cert via approved source delivers telemetry (all 3 signals)" \
        "traces, metrics and logs all present at backend" "traces=$t metrics=$m logs=$l"
    fi
  else
    record "$T" D1 FAIL "valid client cert via approved source delivers telemetry" \
      "backend holds records tagged $rid" "sender succeeded but backend has none" \
      "$(k -n "$NS_GATEWAY" logs deploy/otel-gateway --tail=15 2>&1)"
  fi
fi
exit_with_status "$T"
