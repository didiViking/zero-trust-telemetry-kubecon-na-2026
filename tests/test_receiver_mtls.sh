#!/usr/bin/env bash
# Client -> gateway authentication. All negative cases run from the SAME approved source pod spec as
# the positive control, so the only variable is the TLS credential, never the network path.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
require_cmds kubectl jq base64
guard_lab_context
init_run
T="$(basename "$0")"
use_test_namespace "$NS_CLIENT"

# expect_rejected <case> <desc> <expected_class> <job-name> : run sender with the current SEND_* env,
# assert it FAILED with the expected TLS class AND the backend never saw the run marker.
expect_rejected() {
  local id="$1" desc="$2" want="$3" job="$4" res cls n
  run_sender "$job"; res="$SENDER_RESULT"
  cls="$(classify_failure "$SENDER_LOG")"
  n="$(backend_count "$SEND_RUN_ID")"
  wnote=""
  if [ "$cls" = PEER_RESET ]; then
    # The Go client can lose the race against the gateway closing after a TLS alert and see only a reset.
    # An independent openssl witness with the SAME credential must observe the explicit alert.
    w="$(tls_witness "$NS_CLIENT" "$GATEWAY_FQDN" "${SEND_SECRET-traffic-generator-tls}")"
    wcls="$(classify_failure "$w")"; wnote=" (client saw reset; witness_class=$wcls)"
    [ "$wcls" = "$want" ] && cls="$want"
    SENDER_LOG="witness: $w | client: $SENDER_LOG"
  fi
  if [ "$res" = "failed" ] && [ "$cls" = "$want" ] && [ "${n:-0}" -eq 0 ]; then
    record "$T" "$id" PASS "$desc" "sender fails with $want; backend receives nothing" \
      "sender=$res class=$cls backend_batches=$n$wnote" "$SENDER_LOG"
  else
    record "$T" "$id" FAIL "$desc" "sender fails with $want; backend receives nothing" \
      "sender=$res class=$cls backend_batches=$n$wnote" "$SENDER_LOG"
  fi
}

# R1 positive control (gate for everything below)
SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
export SEND_COUNT=3 SEND_SIGNALS=logs
run_sender zt-test-recv-pos; res="$SENDER_RESULT"
if [ "$res" = "succeeded" ] && wait_backend_receipt "$SEND_RUN_ID" 30; then
  record "$T" R1 PASS "trusted client certificate is accepted (positive control)" \
    "sender succeeds and backend records the marker" "sender=$res, backend_batches=$(backend_count "$SEND_RUN_ID")"
else
  record "$T" R1 FAIL "trusted client certificate is accepted (positive control)" \
    "sender succeeds and backend records the marker" "sender=$res class=$(classify_failure "$SENDER_LOG")" "$SENDER_LOG"
  for c in R2 R3 R4 R5; do
    record "$T" "$c" "NOT RUN" "negative receiver case" "n/a" "positive control R1 failed; a rejection would be uninterpretable"
  done
  exit_with_status "$T"
fi

# R2 no client certificate
SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
export SEND_SECRET=""
expect_rejected R2 "missing client certificate is rejected by the gateway" TLS_CLIENT_CERT_REQUIRED zt-test-recv-nocert

# R3 certificate from an untrusted CA (same CN as the legitimate client)
if ensure_rogue_pki "$NS_CLIENT"; then
  SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
  export SEND_SECRET="zt-test-rogue-client-tls"
  expect_rejected R3 "client certificate from an untrusted CA is rejected" TLS_CLIENT_CERT_REJECTED zt-test-recv-rogue

  # R4 client trusts only the rogue CA -> must refuse the gateway's certificate (server auth direction)
  SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
  export SEND_SECRET="traffic-generator-tls" SEND_CA_CM="zt-test-rogue-ca-bundle"
  expect_rejected R4 "client refuses a gateway certificate not issued by its trusted CA" TLS_SERVER_CERT_UNTRUSTED zt-test-recv-wrongca
  unset SEND_CA_CM
else
  record "$T" R3 "NOT RUN" "untrusted-CA client certificate" "n/a" "could not provision rogue test CA"
  record "$T" R4 "NOT RUN" "client rejects untrusted gateway CA" "n/a" "could not provision rogue test CA"
fi

# R5 hostname/SAN mismatch: dial the Service IP, which is not in the gateway certificate's SANs
SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
SEND_ENDPOINT="$(gateway_cluster_ip):4317"; export SEND_ENDPOINT
export SEND_SECRET="traffic-generator-tls"
expect_rejected R5 "client refuses gateway when dialed name is not in certificate SANs" TLS_SERVER_NAME_MISMATCH zt-test-recv-badname
unset SEND_ENDPOINT

exit_with_status "$T"
