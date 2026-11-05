#!/usr/bin/env bash
# Certificate rotation on the gateway (receiver) side.
#
# What is measured, and why two kinds of connection are used:
#   * A LONG-LIVED sender keeps ONE TLS connection open for the whole window. TLS certificates are
#     only consulted during a handshake, so this connection says nothing about the new certificate;
#     it measures whether an established connection survives reissuance (record loss).
#   * A FRESH-CONNECTION prober opens a NEW TLS connection every ~2s to the Service and to each gateway
#     pod IP and records the leaf-certificate fingerprint it was served. This is what shows WHEN each
#     pod starts using the new certificate, and whether any new handshake failed.
# Reissuance is triggered the way `cmctl renew` does it (Issuing condition). cert-manager updates the
# Secret in place; the kubelet then refreshes the mounted file and the Collector re-reads it on its
# reload_interval (1m in the blueprint). Nothing is modified that needs restoring.
#
# NOT claimed: zero downtime in general. ROT4 reports what happened in THIS run only.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
require_cmds kubectl jq base64 openssl
guard_lab_context
init_run
T="$(basename "$0")"
use_test_namespace "$NS_CLIENT"

WINDOW="${ROT_WINDOW_SECONDS:-240}"     # sender duration; also bounds how long we wait for reload
PROBE_NAME=zt-test-rot-prober

secret_spki() {  # sha256 of the public key (changes iff the private key was rotated)
  k -n "$NS_GATEWAY" get secret otel-gateway-tls -o 'jsonpath={.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -pubkey | openssl dgst -sha256 | awk '{print $NF}'
}

# ---- precondition: positive control ------------------------------------------------------------
SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
export SEND_COUNT=3 SEND_SIGNALS=logs
run_sender zt-test-rot-pre
if [ "$SENDER_RESULT" != succeeded ] || ! wait_backend_receipt "$SEND_RUN_ID" 30; then
  record "$T" ROT0 FAIL "pre-rotation delivery works (positive control)" "sender succeeds; backend records marker" \
    "sender=$SENDER_RESULT class=$(classify_failure "$SENDER_LOG")" "$SENDER_LOG"
  for c in ROT1 ROT2 ROT3 ROT4; do record "$T" "$c" "NOT RUN" "rotation case" "n/a" "positive control ROT0 failed"; done
  exit_with_status "$T"
fi
record "$T" ROT0 PASS "pre-rotation delivery works (positive control)" "sender succeeds; backend records marker" "ok"

POD_IPS="$(k -n "$NS_GATEWAY" get pods -l app=otel-gateway -o 'jsonpath={range .items[*]}{.status.podIP}{" "}{end}')"
set -- $POD_IPS
P1="${1:-}"; P2="${2:-}"
[ -n "$P1" ] || { record "$T" ROT1 "NOT RUN" "rotation" "n/a" "no gateway pod IPs"; exit_with_status "$T"; }
P2="${P2:-$P1}"   # tolerate a single-replica gateway
OLD_FP="$(gw_secret_fp)"; OLD_SPKI="$(secret_spki)"

# ---- start long-lived sender and fresh-connection prober -------------------------------------------
LL_RID="$(new_run_id)"
SEND_RUN_ID="$LL_RID" SEND_SIGNALS=logs SEND_DURATION="${WINDOW}s" SEND_RATE=5 SEND_BATCH_SIZE=5 \
  SEND_ALLOW_FAILURES=1 SEND_DEADLINE=$((WINDOW + 60)) SEND_NAME=zt-test-rot-longlived SEND_TEST_LABEL=1 \
  render_sender_job | k apply -f - >/dev/null
register_cleanup "k -n '$NS_CLIENT' delete job zt-test-rot-longlived --ignore-not-found --wait=false"

PROBE_SCRIPT=$(cat <<SH
end=\$(( \$(date +%s) + $((WINDOW + 20)) ))
while [ "\$(date +%s)" -lt "\$end" ]; do
  for t in "svc|${GATEWAY_FQDN}" "p1|${P1}" "p2|${P2}"; do
    name=\${t%%|*}; host=\${t##*|}; extra=""
    [ "\$name" = svc ] && extra="-verify_hostname ${GATEWAY_FQDN}"
    ts=\$(date +%s)
    out=\$(printf x | timeout 6 openssl s_client -connect "\$host:4317" -CAfile /trust/ca.crt -cert /client/tls.crt -key /client/tls.key -verify_return_error \$extra -alpn h2 2>&1)
    fp=\$(printf '%s\n' "\$out" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    if printf '%s' "\$out" | grep -q 'Verify return code: 0 (ok)' && ! printf '%s' "\$out" | grep -qi 'alert'; then res=OK; else res=FAIL; fi
    echo "\$ts \$name \$res \${fp:--}"
  done
  sleep 2
done
SH
)
TOOL_NOWAIT=1 TOOL_DEADLINE=$((WINDOW + 90)) run_tool_pod "$NS_CLIENT" "$PROBE_NAME" true "$OPENSSL_IMAGE" "$PROBE_SCRIPT" traffic-generator-tls >/dev/null

probe_lines() { k -n "$NS_CLIENT" logs "$PROBE_NAME" 2>/dev/null | grep -E '^[0-9]+ (svc|p1|p2) '; }

# baseline: every target answers OK with the OLD fingerprint (bounded wait)
i=0; base_ok=0
while [ "$i" -lt 60 ]; do
  l="$(probe_lines)"
  if [ "$(grep -c " OK $OLD_FP\$" <<<"$l")" -ge 3 ] && grep -q " p1 OK $OLD_FP\$" <<<"$l" && grep -q " p2 OK $OLD_FP\$" <<<"$l" && grep -q " svc OK $OLD_FP\$" <<<"$l"; then base_ok=1; break; fi
  sleep 2; i=$((i + 2))
done
if [ "$base_ok" -ne 1 ]; then
  record "$T" ROT1 "NOT RUN" "rotation" "n/a" "prober never observed baseline fingerprint $OLD_FP on all targets" "$(probe_lines | tail -6)"
  for c in ROT2 ROT3 ROT4; do record "$T" "$c" "NOT RUN" "rotation case" "n/a" "baseline not established"; done
  exit_with_status "$T"
fi

# ---- trigger reissuance ------------------------------------------------------------------------------
T_TRIGGER="$(date +%s)"
trigger_reissue "$NS_GATEWAY" otel-gateway \
  || record "$T" ROT1 FAIL "could not trigger re-issuance" "status patch accepted" "patch rejected"

NEW_FP="$OLD_FP"; i=0
while [ "$i" -lt 90 ]; do
  NEW_FP="$(gw_secret_fp)"; [ "$NEW_FP" != "$OLD_FP" ] && break
  sleep 2; i=$((i + 2))
done
T_ISSUED="$(date +%s)"; NEW_SPKI="$(secret_spki)"
if [ "$NEW_FP" != "$OLD_FP" ] && [ "$NEW_SPKI" != "$OLD_SPKI" ]; then
  record "$T" ROT1 PASS "cert-manager re-issued the gateway certificate with a NEW private key (rotationPolicy: Always)" \
    "Secret leaf fingerprint and public-key hash both change" "issued $((T_ISSUED - T_TRIGGER))s after trigger; fp ${OLD_FP:0:11}.. -> ${NEW_FP:0:11}..; spki changed"
else
  record "$T" ROT1 FAIL "cert-manager re-issued the gateway certificate with a NEW private key" \
    "fingerprint and public key change" "fp_changed=$([ "$NEW_FP" != "$OLD_FP" ] && echo yes || echo no) spki_changed=$([ "$NEW_SPKI" != "$OLD_SPKI" ] && echo yes || echo no)"
fi

# ---- wait (bounded by WINDOW) until every target serves the new certificate --------------------------
seen_p1=""; seen_p2=""; seen_svc=""
deadline=$((T_TRIGGER + WINDOW - 5))
while [ "$(date +%s)" -lt "$deadline" ]; do
  l="$(probe_lines)"
  [ -z "$seen_p1" ]  && seen_p1="$(awk -v f="$NEW_FP" '$2=="p1" && $3=="OK" && $4==f {print $1; exit}' <<<"$l")"
  [ -z "$seen_p2" ]  && seen_p2="$(awk -v f="$NEW_FP" '$2=="p2" && $3=="OK" && $4==f {print $1; exit}' <<<"$l")"
  [ -z "$seen_svc" ] && seen_svc="$(awk -v f="$NEW_FP" '$2=="svc" && $3=="OK" && $4==f {print $1; exit}' <<<"$l")"
  [ -n "$seen_p1" ] && [ -n "$seen_p2" ] && [ -n "$seen_svc" ] && break
  sleep 3
done
d() { [ -n "$1" ] && echo "$(( $1 - T_TRIGGER ))s" || echo "NOT OBSERVED"; }
if [ -n "$seen_p1" ] && [ -n "$seen_p2" ] && [ -n "$seen_svc" ]; then
  record "$T" ROT2 PASS "each gateway pod (and the Service) starts SERVING the new certificate on fresh connections" \
    "new fingerprint observed on pod1, pod2 and Service within ${WINDOW}s" \
    "after trigger: pod1=$(d "$seen_p1") pod2=$(d "$seen_p2") service=$(d "$seen_svc") (blueprint reload_interval=1m + kubelet Secret refresh)"
else
  record "$T" ROT2 FAIL "each gateway pod (and the Service) starts SERVING the new certificate on fresh connections" \
    "new fingerprint observed on pod1, pod2 and Service within ${WINDOW}s" \
    "after trigger: pod1=$(d "$seen_p1") pod2=$(d "$seen_p2") service=$(d "$seen_svc")" "$(probe_lines | tail -9)"
fi

# ---- let the long-lived sender finish, then collect ---------------------------------------------------
res="$(wait_job_finished "$NS_CLIENT" zt-test-rot-longlived $(( WINDOW + 70 )))"
LL_LOG="$(k -n "$NS_CLIENT" logs job/zt-test-rot-longlived --tail=400 2>&1 || true)"
sent="$(grep -E 'logs generated' <<<"$LL_LOG" | tail -1 | sed -E 's/.*"logs": ?([0-9]+).*/\1/')"
# telemetrygen logs failed exports at ERROR level ("failed to export ..."); the start-up config line
# also contains the word "ExportFailures", so match the level/phrase precisely.
export_fail="$(grep -cE 'failed to export|[[:space:]]ERROR[[:space:]]' <<<"$LL_LOG")"
sleep 2
delivered="$(backend_record_count "$LL_RID")"
l="$(probe_lines)"
hs_total="$(grep -c ' OK ' <<<"$l")"; hs_fail="$(grep -c ' FAIL ' <<<"$l")"
other_fp="$(awk -v o="$OLD_FP" -v n="$NEW_FP" '$3=="OK" && $4!=o && $4!=n {c++} END{print c+0}' <<<"$l")"

# ---- ROT3: a brand-new connection after reload, end to end ----------------------------------------------
SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
export SEND_COUNT=3 SEND_SIGNALS=logs SEND_DURATION="" SEND_BATCH_SIZE="" SEND_ALLOW_FAILURES=0 SEND_RATE=5
run_sender zt-test-rot-post
if [ "$SENDER_RESULT" = succeeded ] && wait_backend_receipt "$SEND_RUN_ID" 30; then
  record "$T" ROT3 PASS "a new client connection after rotation completes end to end (client -> gateway -> backend)" \
    "sender succeeds and backend records marker" "ok"
else
  record "$T" ROT3 FAIL "a new client connection after rotation completes end to end" \
    "sender succeeds and backend records marker" "sender=$SENDER_RESULT class=$(classify_failure "$SENDER_LOG")" "$SENDER_LOG"
fi

# ---- ROT4: what happened to traffic during the window in THIS run (measurement, not a guarantee) --------
if [ -z "$sent" ]; then
  record "$T" ROT4 "NOT RUN" "continuity measurement" "n/a" "could not parse sent-count from long-lived sender (job result: $res)" "$(tail -5 <<<"$LL_LOG")"
else
  lost=$(( sent - delivered ))
  summary="window=${WINDOW}s long-lived: sent=$sent delivered=$delivered lost=$lost export_errors=$export_fail; fresh handshakes: ok=$hs_total failed=$hs_fail unexpected_third_fp=$other_fp"
  if [ "$lost" -eq 0 ] && [ "$hs_fail" -eq 0 ] && [ "$export_fail" -eq 0 ] && [ "$other_fp" -eq 0 ]; then
    record "$T" ROT4 PASS "OBSERVED in this run: no lost records and no failed fresh handshakes across the rotation window (single run; not a zero-downtime guarantee)" \
      "lost=0, failed_handshakes=0" "$summary" "failures: $(grep ' FAIL ' <<<"$l" | head -3)"
  else
    record "$T" ROT4 FAIL "OBSERVED in this run: no lost records and no failed fresh handshakes across the rotation window" \
      "lost=0, failed_handshakes=0" "$summary" "failures: $(grep ' FAIL ' <<<"$l" | head -5) | sender: $(grep -iE 'fail' <<<"$LL_LOG" | head -3)"
  fi
fi

# Exporter (gateway -> backend) certificate pickup and CA rotation are covered by test_ca_rotation.sh (CAR0-CAR5).

exit_with_status "$T"
