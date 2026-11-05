#!/usr/bin/env bash
# NetworkPolicy isolation, proven with TWO kinds of evidence that must agree:
#   1. application-level: a TCP connect (and an mTLS sender) from the pod really fails/succeeds;
#   2. datapath-level: Hubble records a DROPPED flow for the denied attempt (observational only).
# Hubble is NOT proof of TLS authentication or kernel isolation; it only corroborates the verdict.
#
# Isolation of causes: TCP probes use ClusterIPs so a DNS block cannot masquerade as a connect
# failure; the untrusted source namespace has NO policies, so its egress is open and only the
# gateway's ingress policy can be the blocker; a control connect proves that open egress.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
require_cmds kubectl jq
guard_lab_context
init_run
T="$(basename "$0")"
for ns in "$NS_CLIENT" "$NS_UNTRUSTED" "$NS_GATEWAY"; do use_test_namespace "$ns"; done

GW_IP="$(gateway_cluster_ip)"; BE_IP="$(backend_cluster_ip)"
API_IP="$(k -n default get svc kubernetes -o 'jsonpath={.spec.clusterIP}')"

# tcp_script: prints one line per target: "TCP <name> rc=<n> elapsed=<s>"
tcp_script() {
  cat <<SH
probe() { s=\$(date +%s); nc -w 4 "\$2" "\$3" </dev/null >/dev/null 2>&1; rc=\$?; e=\$(( \$(date +%s) - s )); echo "TCP \$1 rc=\$rc elapsed=\$e"; }
nslookup ${GATEWAY_FQDN} >/dev/null 2>&1 && echo "DNS gateway=ok" || echo "DNS gateway=fail"
$*
SH
}

# tcp_class <log> <target-name>: CONNECTED | TIMEOUT_OR_DROP | REFUSED_OR_RESET | NO_RESULT
tcp_class() {
  local line rc el
  line="$(printf '%s\n' "$1" | grep "^TCP $2 " | head -1)"
  [ -n "$line" ] || { echo NO_RESULT; return; }
  rc="$(sed -E 's/.*rc=([0-9]+).*/\1/' <<<"$line")"; el="$(sed -E 's/.*elapsed=([0-9]+).*/\1/' <<<"$line")"
  if [ "$rc" = 0 ]; then echo CONNECTED
  elif [ "$el" -ge 3 ]; then echo TIMEOUT_OR_DROP    # silent drop => connect hangs until nc -w expires
  else echo REFUSED_OR_RESET; fi                      # fast failure => someone answered (RST/ICMP)
}

# hubble_corroborate <case> <ns/pod> <port> : record Hubble evidence as a separate case
hubble_corroborate() {
  local id="$1" pod="$2" port="$3" out="" rc=1 i=0
  while [ "$i" -lt 10 ]; do
    out="$(hubble_drops "$pod")"; rc=$?
    [ "$rc" -eq 0 ] && grep -q "DROPPED" <<<"$out" && grep -q ":$port" <<<"$out" && break
    sleep 1; i=$((i + 1))
  done
  if [ "$rc" -ne 0 ]; then
    record "$T" "$id" "NOT RUN" "Hubble shows DROPPED flow for $pod -> :$port" "n/a" "Hubble query via cilium agent failed (rc=$rc)"
  elif grep -q "DROPPED" <<<"$out" && grep -q ":$port" <<<"$out"; then
    record "$T" "$id" PASS "Hubble shows DROPPED flow for $pod -> :$port (observational corroboration)" \
      "at least one DROPPED flow on :$port" "$(grep -c DROPPED <<<"$out") DROPPED flow(s)" "$(grep DROPPED <<<"$out" | tail -3)"
  else
    record "$T" "$id" FAIL "Hubble shows DROPPED flow for $pod -> :$port (observational corroboration)" \
      "at least one DROPPED flow on :$port" "no matching DROPPED flow" "$out"
  fi
}

TOOL_WAIT=45; export TOOL_WAIT

# N1 positive control: approved namespace + exporter label
log1="$(run_tool_pod "$NS_CLIENT" zt-test-net-approved true "$BUSYBOX_IMAGE" "$(tcp_script 'probe gateway '"$GW_IP"' 4317')")"
c1="$(tcp_class "$log1" gateway)"
if [ "$c1" = CONNECTED ]; then
  record "$T" N1 PASS "approved source pod (ns telemetry-clients, telemetry-exporter=true) can connect to gateway:4317 (positive control)" \
    "TCP CONNECTED" "$c1" "$log1"
else
  record "$T" N1 FAIL "approved source pod can connect to gateway:4317 (positive control)" "TCP CONNECTED" "$c1" "$log1"
  for c in N2 N2h N3 N3h N4 N4h N4b N4bh N5 N6; do record "$T" "$c" "NOT RUN" "network denial case" "n/a" "positive control N1 failed"; done
  exit_with_status "$T"
fi

# N2 unauthorized namespace: control proves egress is open, so the gateway ingress policy is the blocker
log2="$(run_tool_pod "$NS_UNTRUSTED" zt-test-net-untrusted true "$BUSYBOX_IMAGE" "$(tcp_script "probe apiserver $API_IP 443; probe gateway $GW_IP 4317")")"
ctl="$(tcp_class "$log2" apiserver)"; c2="$(tcp_class "$log2" gateway)"
if [ "$ctl" != CONNECTED ]; then
  record "$T" N2 "NOT RUN" "unauthorized-namespace source is blocked by the gateway ingress policy" "n/a" \
    "egress control to kube-apiserver was $ctl, so a gateway failure would not be attributable to the gateway policy" "$log2"
  record "$T" N2h "NOT RUN" "Hubble corroboration for N2" "n/a" "N2 control failed"
elif [ "$c2" = TIMEOUT_OR_DROP ]; then
  record "$T" N2 PASS "unauthorized-namespace pod (egress proven open) cannot reach gateway:4317" \
    "control CONNECTED; gateway TIMEOUT_OR_DROP" "control=$ctl gateway=$c2" "$log2"
  hubble_corroborate N2h "$NS_UNTRUSTED/zt-test-net-untrusted" 4317
else
  record "$T" N2 FAIL "unauthorized-namespace pod (egress proven open) cannot reach gateway:4317" \
    "control CONNECTED; gateway TIMEOUT_OR_DROP" "control=$ctl gateway=$c2" "$log2"
  record "$T" N2h "NOT RUN" "Hubble corroboration for N2" "n/a" "N2 failed"
fi

# N3 pod in approved namespace WITHOUT the exporter label (blocked by source egress default-deny and/or gateway ingress)
log3="$(run_tool_pod "$NS_CLIENT" zt-test-net-unlabelled - "$BUSYBOX_IMAGE" "$(tcp_script 'probe gateway '"$GW_IP"' 4317')")"
c3="$(tcp_class "$log3" gateway)"
if [ "$c3" = TIMEOUT_OR_DROP ]; then
  record "$T" N3 PASS "unlabelled pod in the approved namespace cannot reach gateway:4317" "TIMEOUT_OR_DROP" "$c3" "$log3"
  hubble_corroborate N3h "$NS_CLIENT/zt-test-net-unlabelled" 4317
else
  record "$T" N3 FAIL "unlabelled pod in the approved namespace cannot reach gateway:4317" "TIMEOUT_OR_DROP" "$c3" "$log3"
  record "$T" N3h "NOT RUN" "Hubble corroboration for N3" "n/a" "N3 failed"
fi

# N4 approved source cannot bypass the gateway and talk to the backend directly
log4="$(run_tool_pod "$NS_CLIENT" zt-test-net-bypass true "$BUSYBOX_IMAGE" "$(tcp_script 'probe backend '"$BE_IP"' 4317')")"
c4="$(tcp_class "$log4" backend)"
if [ "$c4" = TIMEOUT_OR_DROP ]; then
  record "$T" N4 PASS "approved source pod cannot connect directly to backend:4317 (gateway bypass blocked)" "TIMEOUT_OR_DROP" "$c4" "$log4"
  hubble_corroborate N4h "$NS_CLIENT/zt-test-net-bypass" 4317
else
  record "$T" N4 FAIL "approved source pod cannot connect directly to backend:4317" "TIMEOUT_OR_DROP" "$c4" "$log4"
  record "$T" N4h "NOT RUN" "Hubble corroboration for N4" "n/a" "N4 failed"
fi

# N4b backend ingress policy IN ISOLATION. N4 above is blocked by two layers (the source's egress allow-list AND
# the backend's ingress policy), so it cannot tell which one works. Here the source namespace has no policies
# (egress open, proven by the control), so only the backend's ingress policy can stop the connection.
log4b="$(run_tool_pod "$NS_UNTRUSTED" zt-test-net-bypass-open true "$BUSYBOX_IMAGE" "$(tcp_script "probe apiserver $API_IP 443; probe backend $BE_IP 4317")")"
ctl4b="$(tcp_class "$log4b" apiserver)"; c4b="$(tcp_class "$log4b" backend)"
if [ "$ctl4b" != CONNECTED ]; then
  record "$T" N4b "NOT RUN" "backend ingress policy blocks a source with open egress" "n/a" "egress control was $ctl4b" "$log4b"
  record "$T" N4bh "NOT RUN" "Hubble corroboration for N4b" "n/a" "N4b control failed"
elif [ "$c4b" = TIMEOUT_OR_DROP ]; then
  record "$T" N4b PASS "a source with open egress (control proven) still cannot connect to backend:4317 (backend ingress policy in isolation)" \
    "control CONNECTED; backend TIMEOUT_OR_DROP" "control=$ctl4b backend=$c4b" "$log4b"
  hubble_corroborate N4bh "$NS_UNTRUSTED/zt-test-net-bypass-open" 4317
else
  record "$T" N4b FAIL "a source with open egress (control proven) still cannot connect to backend:4317" \
    "control CONNECTED; backend TIMEOUT_OR_DROP" "control=$ctl4b backend=$c4b" "$log4b"
  record "$T" N4bh "NOT RUN" "Hubble corroboration for N4b" "n/a" "N4b failed"
fi

# N5 egress allow-list: approved source cannot reach an arbitrary in-cluster destination
log5="$(run_tool_pod "$NS_CLIENT" zt-test-net-egress true "$BUSYBOX_IMAGE" "$(tcp_script 'probe apiserver '"$API_IP"' 443')")"
c5="$(tcp_class "$log5" apiserver)"
if [ "$c5" = TIMEOUT_OR_DROP ]; then
  record "$T" N5 PASS "approved source pod cannot reach kube-apiserver:443 (egress allow-list only permits gateway + DNS)" "TIMEOUT_OR_DROP" "$c5" "$log5"
else
  record "$T" N5 FAIL "approved source pod cannot reach kube-apiserver:443" "TIMEOUT_OR_DROP" "$c5" "$log5"
fi

# N6 stolen-credential scenario: a VALID client certificate used from an unauthorized network location.
# The failure class must be a network timeout, NOT a TLS rejection: network policy denial is a different
# control from mTLS and must not be reported as one.
if issue_client_cert "$NS_UNTRUSTED" zt-test-untrusted-client; then
  SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
  export SEND_NS="$NS_UNTRUSTED" SEND_SECRET="zt-test-untrusted-client-tls" SEND_SIGNALS=logs SEND_COUNT=2 SEND_DEADLINE=50 SEND_WAIT=60
  run_sender zt-test-net-stolen
  cls="$(classify_failure "$SENDER_LOG")"; n="$(backend_count "$SEND_RUN_ID")"
  if [ "$SENDER_RESULT" = failed ] && [ "$cls" = NETWORK_TIMEOUT ] && [ "${n:-0}" -eq 0 ]; then
    record "$T" N6 PASS "valid client certificate used from an unauthorized namespace fails at the NETWORK layer (timeout), not TLS" \
      "sender fails with NETWORK_TIMEOUT; backend none" "sender=$SENDER_RESULT class=$cls backend_batches=$n" "$SENDER_LOG"
  else
    record "$T" N6 FAIL "valid client certificate used from an unauthorized namespace fails at the NETWORK layer (timeout), not TLS" \
      "sender fails with NETWORK_TIMEOUT; backend none" "sender=$SENDER_RESULT class=$cls backend_batches=$n" "$SENDER_LOG"
  fi
  unset SEND_NS SEND_SECRET SEND_SIGNALS SEND_COUNT SEND_DEADLINE SEND_WAIT
else
  record "$T" N6 "NOT RUN" "valid cert from unauthorized namespace" "n/a" "could not issue test client certificate in $NS_UNTRUSTED"
fi

exit_with_status "$T"
