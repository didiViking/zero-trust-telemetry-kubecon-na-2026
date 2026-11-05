#!/usr/bin/env bash
# Guided ~1 minute demo against a deployed lab. Shows: (1) telemetry accepted, (2) rejected by mTLS,
# (3) blocked by NetworkPolicy -- two DIFFERENT controls, (4) an authenticated-but-poisoned log whose
# unsafe action is denied. Exits non-zero if any step does not behave as narrated.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../tests/lib/harness.sh"
require_cmds kubectl jq
guard_lab_context
init_run
use_test_namespace "$NS_CLIENT"; use_test_namespace "$NS_UNTRUSTED"
fail=0
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "1/4  A trusted client sends telemetry over mTLS"
echo "     client cert from our lab CA -> gateway -> backend; we then look for the unique run id in the backend."
"$HERE/send-telemetry.sh" || fail=1

say "2/4  The same client WITHOUT its certificate is rejected by TLS"
SEND_RUN_ID="$(new_run_id)"; export SEND_RUN_ID
SEND_SECRET="" SEND_SIGNALS=logs SEND_COUNT=1 SEND_DEADLINE=40 run_sender demo-nocert
cls="$(classify_failure "$SENDER_LOG")"; n="$(backend_count "$SEND_RUN_ID")"
echo "     error seen by the client: $(grep -m1 -oE 'tls: [a-z ]+' <<<"$SENDER_LOG")"
if [ "$cls" = TLS_CLIENT_CERT_REQUIRED ] && [ "${n:-0}" -eq 0 ]; then
  echo "     OK: the gateway demanded a client certificate; nothing reached the backend."
else echo "     UNEXPECTED: class=$cls backend_batches=$n"; fail=1; fi

say "3/4  A pod in the wrong namespace is blocked by NetworkPolicy (a different control than TLS)"
GW_IP="$(gateway_cluster_ip)"; API_IP="$(k -n default get svc kubernetes -o 'jsonpath={.spec.clusterIP}')"
TOOL_WAIT=45; export TOOL_WAIT
out="$(run_tool_pod "$NS_UNTRUSTED" demo-wrongns true "$BUSYBOX_IMAGE" "
t() { s=\$(date +%s); nc -w 4 \$2 \$3 </dev/null >/dev/null 2>&1; echo \"\$1 rc=\$? elapsed=\$((\$(date +%s)-s))\"; }
t apiserver $API_IP 443; t gateway $GW_IP 4317")"
echo "$out" | sed 's/^/     /'
if grep -q '^apiserver rc=0' <<<"$out" && grep -qE '^gateway rc=[1-9][0-9]* elapsed=([3-9]|[1-9][0-9])' <<<"$out"; then
  echo "     OK: this pod can reach the API server (so its network works) but connecting to the gateway just hangs."
  echo "     That is a silent DROP by policy, not a TLS error. Hubble sees it too:"
  hubble_drops "$NS_UNTRUSTED/demo-wrongns" | grep DROPPED | tail -1 | sed 's/^/     /'
else echo "     UNEXPECTED result"; fail=1; fi

say "4/4  Authenticated != trustworthy: a poisoned log is accepted, but the dangerous action is denied"
"$HERE/../../scenarios/poisoned-log/test.sh" 2>&1 | grep -E 'S[1-7]' | cut -c1-150 || true
last="$(ls -dt "$REPO_ROOT"/evidence/runs/*/scenario-poisoned-log 2>/dev/null | head -1)"
if [ -n "$last" ]; then
  echo "     decisions recorded:"
  jq -r '.decisions[] | "       \(.proposal.verb) \(.proposal.kind) -> \(.effect | ascii_upcase)  (\(.reason_code))"' "$last/decisions.json"
  jq -e '[.decisions[]|select(.proposal.verb=="delete" and .effect=="allow")]|length==0' "$last/decisions.json" >/dev/null || fail=1
else fail=1; fi

echo
if [ "$fail" -eq 0 ]; then
  say "Demo complete: accepted, rejected-by-TLS, blocked-by-network, denied-by-policy all behaved as expected."
  echo "Next: lab/GETTING-STARTED.md (explore it yourself) or 'make test-quick'."
else say "Demo found unexpected behaviour -- see messages above."; fi
exit "$fail"
