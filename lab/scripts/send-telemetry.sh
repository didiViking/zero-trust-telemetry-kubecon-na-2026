#!/usr/bin/env bash
# Send synthetic OTLP telemetry (traces, metrics, logs) over mTLS from an APPROVED source pod
# through the gateway, then prove receipt at the backend. Exit 0 only if the backend recorded
# the unique run marker for every requested signal.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
. "$LAB_DIR/lib/sender.sh"
require_cmds kubectl
guard_lab_context

RUN_ID="${SEND_RUN_ID:-$(new_run_id)}"
export SEND_RUN_ID="$RUN_ID"
export SEND_NAME="telemetrygen-${RUN_ID//[^a-z0-9]/-}"
SEND_NAME="$(printf '%s' "$SEND_NAME" | tr 'A-Z' 'a-z' | cut -c1-60)"
signals="${SEND_SIGNALS:-traces metrics logs}"

log "sending synthetic telemetry run_id=$RUN_ID via $GATEWAY_FQDN (mTLS client cert: traffic-generator-tls)"
render_sender_job | k apply -f - >/dev/null
result="$(wait_job_finished "$NS_CLIENT" "$SEND_NAME" 90)"
if [ "$result" != "succeeded" ]; then
  log "sender job result: $result"
  k -n "$NS_CLIENT" logs "job/$SEND_NAME" --all-containers --tail=30 2>&1 | sanitize >&2 || true
  die "sender did not complete successfully (this is a SEND failure, not proof of rejection)"
fi

wait_backend_receipt "$RUN_ID" 30 || {
  log "gateway logs (tail):"; k -n "$NS_GATEWAY" logs deploy/otel-gateway --tail=20 2>&1 | sanitize >&2 || true
  die "sender succeeded but the backend never recorded run_id=$RUN_ID"
}

rc=0
for s in $signals; do
  case "$s" in traces) sig=resourceSpans ;; metrics) sig=resourceMetrics ;; logs) sig=resourceLogs ;; *) die "bad signal $s" ;; esac
  # Signals arrive via separate exports, so wait (bounded) for each one rather than checking once.
  n=0
  for _ in $(seq 1 30); do
    n="$(backend_count "$RUN_ID" "$sig")"
    [ "${n:-0}" -ge 1 ] && break
    sleep 1
  done
  if [ "${n:-0}" -ge 1 ]; then log "PASS  backend received $s ($n batch(es))"; else log "FAIL  backend did not record $s"; rc=1; fi
done
[ "$rc" -eq 0 ] && log "backend receipt proven for run_id=$RUN_ID"
exit "$rc"
