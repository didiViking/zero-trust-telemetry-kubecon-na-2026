#!/usr/bin/env bash
# CA rotation, and observation of the gateway EXPORTER's client certificate.
#
# The backend can be told which CAs it accepts for client certificates. By making the backend trust ONLY a
# new CA (B), then checking that the gateway still delivers, we observe -- from the backend's side -- that
# the gateway's exporter is presenting a B-issued certificate, i.e. it picked up the rotated certificate.
#
# Sequence (everything temporary is snapshotted and restored on exit, including on failure):
#   0  sensitivity control: backend trusts only B while the gateway still holds an A-issued cert
#      -> delivery must STOP (otherwise the later success would prove nothing)
#   1  overlap: backend and clients trust {A,B}; A-issued gateway cert still works
#   2  re-issue the gateway certificate from B under continuous traffic (long-lived sender + fresh-connection
#      prober); measure lost records and failed handshakes
#   3  remove A: backend trusts only B and restarts (forcing the exporter to reconnect); delivery must resume
#      => the exporter is presenting the rotated certificate
# Limits: a single run; one CA pair; leaf and CA changed together; no revocation; says nothing about
# exporter behaviour on other Collector versions.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
require_cmds kubectl jq base64 openssl
guard_lab_context
init_run
T="$(basename "$0")"
use_test_namespace "$NS_CLIENT"; use_test_namespace "$NS_GATEWAY"
WINDOW="${CAR_WINDOW_SECONDS:-170}"
PROBE_NAME=zt-test-car-prober
CA_B_ISSUER=zt-test-ca-b

snapshot_obj "$NS_GATEWAY" deploy otel-backend
snapshot_obj "$NS_GATEWAY" certificate otel-gateway
snapshot_obj "$NS_CLIENT" cm telemetry-trust-bundle

restore_ca_state() {
  restore_snapshots                                   # backend trust volume, gateway issuerRef, clients bundle
  trigger_reissue "$NS_GATEWAY" otel-gateway
  local i=0
  while [ "$i" -lt 60 ] && ! gw_secret_issuer | grep -q 'zt-lab-root-ca'; do sleep 2; i=$((i + 2)); done
  k delete clusterissuer -l "$TEST_LABEL" --ignore-not-found --wait=false >/dev/null 2>&1
  k -n cert-manager delete certificate,secret -l "$TEST_LABEL" --ignore-not-found --wait=false >/dev/null 2>&1
  rollout_restart_wait otel-gateway otel-backend     # pods start with the restored (A-issued) Secret
}
register_cleanup "restore_ca_state"

# finish: put the lab back FIRST, then prove it is back (CAR5), then report. Used on every exit path.
finish() {
  run_cleanups
  local rid5
  rid5="$(new_run_id)"
  SEND_RUN_ID="$rid5" SEND_COUNT=2 SEND_SIGNALS=logs run_sender zt-test-car5
  if [ "$SENDER_RESULT" = succeeded ] && wait_backend_receipt "$rid5" 60; then
    record "$T" CAR5 PASS "lab restored to the A-issued baseline: end-to-end delivery works" "delivered" "delivered; gateway issuer: $(gw_secret_issuer)"
  else
    record "$T" CAR5 FAIL "lab restored to the A-issued baseline: end-to-end delivery works" "delivered" "sender=$SENDER_RESULT" "$SENDER_LOG"
  fi
  exit_with_status "$T"
}

# ---- create CA B (test-labelled) ------------------------------------------------------------------------
k apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: ${CA_B_ISSUER}-bootstrap, labels: {zt-lab/test: "true"}}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: zt-test-ca-b, namespace: cert-manager, labels: {zt-lab/test: "true"}}
spec:
  isCA: true
  commonName: zt-test-root-ca-b
  secretName: zt-test-ca-b
  secretTemplate: {labels: {zt-lab/test: "true"}}
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: ${CA_B_ISSUER}-bootstrap, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: ${CA_B_ISSUER}, labels: {zt-lab/test: "true"}}
spec: {ca: {secretName: zt-test-ca-b}}
YAML
if ! k -n cert-manager wait --for=condition=Ready certificate/zt-test-ca-b --timeout=60s >/dev/null 2>&1 \
   || ! retry 20 2 k wait --for=condition=Ready "clusterissuer/${CA_B_ISSUER}" --timeout=5s >/dev/null 2>&1; then
  for c in CAR0 CAR1 CAR2 CAR3 CAR4; do record "$T" "$c" "NOT RUN" "CA rotation case" "n/a" "could not create test CA B"; done
  finish
fi

PEM_A="$(k -n "$NS_GATEWAY" get cm telemetry-trust-bundle -o 'jsonpath={.data.ca\.crt}')"          # public certs only
PEM_B="$(k -n cert-manager get secret zt-test-ca-b -o 'jsonpath={.data.tls\.crt}' | base64 -d)"
mk_trust_cm() {  # mk_trust_cm <name> <pem>
  k -n "$NS_GATEWAY" create configmap "$1" --from-literal=ca.crt="$2" --dry-run=client -o yaml \
    | k label --local -f - "$TEST_LABEL" -o yaml | k apply -f - >/dev/null
}
mk_trust_cm zt-test-trust-b "$PEM_B"
mk_trust_cm zt-test-trust-ab "$(printf '%s\n%s\n' "$PEM_A" "$PEM_B")"
# clients must be able to verify a gateway certificate issued by B as well as A
k -n "$NS_CLIENT" create configmap telemetry-trust-bundle --from-literal=ca.crt="$(printf '%s\n%s\n' "$PEM_A" "$PEM_B")" \
  --dry-run=client -o yaml | k apply -f - >/dev/null

set_backend_trust() {  # set_backend_trust <configmap> : point the backend's `trust` volume at it and restart
  local idx
  idx="$(k -n "$NS_GATEWAY" get deploy otel-backend -o json | jq '.spec.template.spec.volumes | map(.name) | index("trust")')"
  k -n "$NS_GATEWAY" patch deploy otel-backend --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/${idx}/configMap/name\",\"value\":\"$1\"}]" >/dev/null \
    && k -n "$NS_GATEWAY" rollout status deploy/otel-backend --timeout=150s >/dev/null
}
send_marker() {  # send_marker <jobname> : sets MARKER; sender result in SENDER_RESULT
  MARKER="$(new_run_id)"
  SEND_RUN_ID="$MARKER" SEND_COUNT=2 SEND_SIGNALS=logs run_sender "$1"
}
wait_marker() {  # wait_marker <seconds> : 0 if backend recorded MARKER within the bound
  local i=0
  while [ "$i" -lt "$1" ]; do [ "$(backend_count "$MARKER")" -ge 1 ] && return 0; sleep 2; i=$((i + 2)); done
  return 1
}

# ---- CAR0 sensitivity control -------------------------------------------------------------------------------
if ! set_backend_trust zt-test-trust-b; then
  for c in CAR0 CAR1 CAR2 CAR3 CAR4; do record "$T" "$c" "NOT RUN" "CA rotation case" "n/a" "could not reconfigure backend trust"; done
  finish
fi
send_marker zt-test-car0
if [ "$SENDER_RESULT" = succeeded ] && ! wait_marker 25; then
  record "$T" CAR0 PASS "sensitivity control: a backend trusting only CA B rejects the gateway's A-issued client certificate" \
    "client send succeeds (gateway accepts it) but nothing reaches the backend" "sender=$SENDER_RESULT, backend_batches=$(backend_count "$MARKER") after 25 s"
else
  record "$T" CAR0 FAIL "sensitivity control: a backend trusting only CA B rejects the gateway's A-issued client certificate" \
    "sender succeeds; backend receives nothing" "sender=$SENDER_RESULT backend_batches=$(backend_count "$MARKER")" "$SENDER_LOG"
  for c in CAR1 CAR2 CAR3 CAR4; do record "$T" "$c" "NOT RUN" "CA rotation case" "n/a" "control CAR0 failed: later success would be uninterpretable"; done
  finish
fi

# ---- CAR1 overlap -------------------------------------------------------------------------------------------------
set_backend_trust zt-test-trust-ab
send_marker zt-test-car1
if [ "$SENDER_RESULT" = succeeded ] && wait_marker 60; then
  record "$T" CAR1 PASS "with overlapping trust {A,B} the backend still accepts the A-issued gateway certificate" \
    "marker delivered end to end" "delivered"
else
  record "$T" CAR1 FAIL "with overlapping trust {A,B} the backend still accepts the A-issued gateway certificate" \
    "marker delivered end to end" "sender=$SENDER_RESULT backend_batches=$(backend_count "$MARKER")" "$SENDER_LOG"
  for c in CAR2 CAR3 CAR4; do record "$T" "$c" "NOT RUN" "CA rotation case" "n/a" "overlap precondition CAR1 failed"; done
  finish
fi

# ---- CAR2/CAR3: re-issue the gateway certificate from B under continuous traffic --------------------------------
POD_IPS="$(k -n "$NS_GATEWAY" get pods -l app=otel-gateway -o 'jsonpath={range .items[*]}{.status.podIP}{" "}{end}')"
set -- $POD_IPS; P1="${1:-}"; P2="${2:-$1}"
OLD_FP="$(gw_secret_fp)"
LL_RID="$(new_run_id)"
SEND_RUN_ID="$LL_RID" SEND_SIGNALS=logs SEND_DURATION="${WINDOW}s" SEND_RATE=5 SEND_BATCH_SIZE=5 SEND_ALLOW_FAILURES=1 \
  SEND_DEADLINE=$((WINDOW + 60)) SEND_NAME=zt-test-car-longlived SEND_TEST_LABEL=1 render_sender_job | k apply -f - >/dev/null
register_cleanup "k -n '$NS_CLIENT' delete job zt-test-car-longlived --ignore-not-found --wait=false"

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

i=0; base_ok=0
while [ "$i" -lt 60 ]; do
  l="$(probe_lines)"
  if grep -q " p1 OK $OLD_FP\$" <<<"$l" && grep -q " p2 OK $OLD_FP\$" <<<"$l" && grep -q " svc OK $OLD_FP\$" <<<"$l"; then base_ok=1; break; fi
  sleep 2; i=$((i + 2))
done
if [ "$base_ok" -ne 1 ]; then
  for c in CAR2 CAR3 CAR4; do record "$T" "$c" "NOT RUN" "CA rotation case" "n/a" "prober never saw the baseline certificate on all targets" "$(probe_lines | tail -4)"; done
  finish
fi

T_TRIGGER="$(date +%s)"
k -n "$NS_GATEWAY" patch certificate otel-gateway --type=merge -p "{\"spec\":{\"issuerRef\":{\"name\":\"${CA_B_ISSUER}\",\"kind\":\"ClusterIssuer\"}}}" >/dev/null
trigger_reissue "$NS_GATEWAY" otel-gateway
NEW_FP="$OLD_FP"; i=0
while [ "$i" -lt 90 ]; do NEW_FP="$(gw_secret_fp)"; [ "$NEW_FP" != "$OLD_FP" ] && break; sleep 2; i=$((i + 2)); done
issuer_now="$(gw_secret_issuer)"

seen_p1=""; seen_p2=""; seen_svc=""; deadline=$((T_TRIGGER + WINDOW - 5))
while [ "$(date +%s)" -lt "$deadline" ]; do
  l="$(probe_lines)"
  [ -z "$seen_p1" ]  && seen_p1="$(awk -v f="$NEW_FP" '$2=="p1" && $3=="OK" && $4==f {print $1; exit}' <<<"$l")"
  [ -z "$seen_p2" ]  && seen_p2="$(awk -v f="$NEW_FP" '$2=="p2" && $3=="OK" && $4==f {print $1; exit}' <<<"$l")"
  [ -z "$seen_svc" ] && seen_svc="$(awk -v f="$NEW_FP" '$2=="svc" && $3=="OK" && $4==f {print $1; exit}' <<<"$l")"
  [ -n "$seen_p1" ] && [ -n "$seen_p2" ] && [ -n "$seen_svc" ] && break
  sleep 3
done
d() { [ -n "$1" ] && echo "$(( $1 - T_TRIGGER ))s" || echo "NOT OBSERVED"; }
if [ "$NEW_FP" != "$OLD_FP" ] && grep -q 'zt-test-root-ca-b' <<<"$issuer_now" && [ -n "$seen_p1" ] && [ -n "$seen_p2" ] && [ -n "$seen_svc" ]; then
  record "$T" CAR2 PASS "gateway certificate re-issued by CA B is served by both pods on fresh connections (clients trust {A,B})" \
    "B-issued fingerprint observed on pod1, pod2 and Service within ${WINDOW}s" "after trigger: pod1=$(d "$seen_p1") pod2=$(d "$seen_p2") service=$(d "$seen_svc")"
else
  record "$T" CAR2 FAIL "gateway certificate re-issued by CA B is served by both pods on fresh connections" \
    "B-issued fingerprint observed on pod1, pod2 and Service within ${WINDOW}s" \
    "issuer=[$issuer_now] pod1=$(d "$seen_p1") pod2=$(d "$seen_p2") service=$(d "$seen_svc")" "$(probe_lines | tail -6)"
fi

res="$(wait_job_finished "$NS_CLIENT" zt-test-car-longlived $(( WINDOW + 70 )))"
LL_LOG="$(k -n "$NS_CLIENT" logs job/zt-test-car-longlived --tail=400 2>&1 || true)"
sent="$(grep -E 'logs generated' <<<"$LL_LOG" | tail -1 | sed -E 's/.*"logs": ?([0-9]+).*/\1/')"
export_fail="$(grep -cE 'failed to export|[[:space:]]ERROR[[:space:]]' <<<"$LL_LOG")"
sleep 2; delivered="$(backend_record_count "$LL_RID")"
l="$(probe_lines)"; hs_ok="$(grep -c ' OK ' <<<"$l")"; hs_fail="$(grep -c ' FAIL ' <<<"$l")"
if [ -z "$sent" ]; then
  record "$T" CAR3 "NOT RUN" "continuity during CA B re-issuance with overlapping trust" "n/a" "could not parse sent count (job: $res)" "$(tail -4 <<<"$LL_LOG")"
else
  lost=$(( sent - delivered )); summary="sent=$sent delivered=$delivered lost=$lost export_errors=$export_fail fresh_handshakes ok=$hs_ok failed=$hs_fail"
  if [ "$lost" -eq 0 ] && [ "$hs_fail" -eq 0 ] && [ "$export_fail" -eq 0 ]; then
    record "$T" CAR3 PASS "OBSERVED in this run: re-issuing from a new CA with overlapping trust lost no records and failed no fresh handshakes (single run; not a guarantee)" \
      "lost=0, failed_handshakes=0" "$summary"
  else
    record "$T" CAR3 FAIL "OBSERVED in this run: re-issuing from a new CA with overlapping trust lost no records and failed no fresh handshakes" \
      "lost=0, failed_handshakes=0" "$summary" "$(grep ' FAIL ' <<<"$l" | head -4)"
  fi
fi

# ---- CAR4: remove A; the exporter must reconnect presenting the B-issued certificate --------------------------------
set_backend_trust zt-test-trust-b
send_marker zt-test-car4
if [ "$SENDER_RESULT" = succeeded ] && wait_marker 120; then
  record "$T" CAR4 PASS "gateway EXPORTER presents the rotated certificate: delivery works after the backend (restarted) trusts only CA B" \
    "marker delivered although the backend rejects A-issued client certificates (shown by CAR0)" "delivered; backend accepts only B, so the exporter used a B-issued cert"
else
  record "$T" CAR4 FAIL "gateway EXPORTER presents the rotated certificate after the backend trusts only CA B" \
    "marker delivered" "sender=$SENDER_RESULT backend_batches=$(backend_count "$MARKER")" "$(k -n "$NS_GATEWAY" logs deploy/otel-gateway --tail=8 2>&1 | cut -c1-300)"
fi

finish
