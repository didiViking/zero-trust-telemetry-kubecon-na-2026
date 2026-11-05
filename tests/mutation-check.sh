#!/usr/bin/env bash
# Mutation check: deliberately BREAK one control at a time in the LAB cluster and confirm that the test
# which claims to cover it goes red (FAIL) while its positive control stays green. A test that cannot fail
# proves nothing. Every mutated object is snapshotted first and restored on exit (also on failure/Ctrl-C).
#
# Scope: lab cluster only (guard_lab_context). Takes ~6 minutes. Not part of `make test`; run: make mutation-check
# Result per mutation: PASS = broken control was DETECTED; FAIL = NOT detected (the test is blind to it);
# NOT RUN = could not apply the mutation or run the test.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/harness.sh"
require_cmds kubectl jq
guard_lab_context

ZT_RUN_DIR="$REPO_ROOT/evidence/runs/$(date -u +%Y%m%dT%H%M%SZ)-mutation"
export ZT_RUN_DIR
# shellcheck disable=SC2034  # read by exit_with_status in the sourced harness
ZT_STANDALONE=1
write_meta
RESULTS_FILE="$ZT_RUN_DIR/results.jsonl"; : > "$RESULTS_FILE"
T=mutation-check

# ---- snapshot / restore (helpers live in lib/harness.sh) ---------------------------------------------------
restore_all() { restore_snapshots; rollout_restart_wait otel-gateway otel-backend >/dev/null 2>&1; }
register_cleanup "restore_all"

strip_client_ca() {  # strip_client_ca <configmap> : remove receiver client-CA lines => no client-cert verification
  k -n "$NS_GATEWAY" get cm "$1" -o json \
   | jq '.data["config.yaml"] |= (split("\n") | map(select(test("client_ca_file")|not)) | join("\n")) | del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields)' \
   | k replace -f - >/dev/null
}
open_ingress() { k -n "$1" patch networkpolicy "$2" --type=json -p '[{"op":"replace","path":"/spec/ingress","value":[{}]}]' >/dev/null; }
open_egress()  { k -n "$1" patch networkpolicy "$2" --type=json -p '[{"op":"replace","path":"/spec/egress","value":[{}]}]' >/dev/null; }

# ---- one mutation ---------------------------------------------------------------------------------------
# run_mutation <id> <description> <test-file> "<cases that MUST fail>" "<cases that MUST still pass>" <apply-fn...>
run_mutation() {
  local id="$1" desc="$2" testfile="$3" must_fail="$4" must_pass="$5"; shift 5
  local sub="$ZT_RUN_DIR/$id" c st bad="" ok=1
  mkdir -p "$sub"
  log "---- $id: $desc"
  if ! "$@"; then
    record "$T" "$id" "NOT RUN" "$desc" "mutation applied" "could not apply mutation"; restore_all; return
  fi
  ZT_RUN_DIR="$sub" bash "$HERE/$testfile" >"$sub/test.out" 2>&1
  for c in $must_fail; do
    st="$(jq -rs --arg c "$c" '[.[]|select(.case==$c)|.status][0] // "ABSENT"' "$sub/results.jsonl")"
    [ "$st" = FAIL ] || { ok=0; bad="$bad $c(expected FAIL, got $st)"; }
  done
  for c in $must_pass; do
    st="$(jq -rs --arg c "$c" '[.[]|select(.case==$c)|.status][0] // "ABSENT"' "$sub/results.jsonl")"
    [ "$st" = PASS ] || { ok=0; bad="$bad $c(expected PASS, got $st)"; }
  done
  if [ "$ok" -eq 1 ]; then
    record "$T" "$id" PASS "mutation DETECTED: $desc" "$testfile: [$must_fail] FAIL, [$must_pass] PASS" "as expected"
  else
    record "$T" "$id" FAIL "mutation NOT detected as expected: $desc" "$testfile: [$must_fail] FAIL, [$must_pass] PASS" "$bad" "$(grep -E 'FAIL|PASS' "$sub/test.out" | head -12)"
  fi
  restore_all
}

snapshot_obj "$NS_GATEWAY" cm otel-backend-config
snapshot_obj "$NS_GATEWAY" cm otel-gateway-config
snapshot_obj "$NS_GATEWAY" networkpolicy otel-gateway-allow
snapshot_obj "$NS_GATEWAY" networkpolicy otel-backend-allow
snapshot_obj "$NS_CLIENT"  networkpolicy exporter-egress

m1() { strip_client_ca otel-backend-config && rollout_restart_wait otel-backend; }
m2() { strip_client_ca otel-gateway-config && rollout_restart_wait otel-gateway; }
m3() { open_ingress "$NS_GATEWAY" otel-gateway-allow; }
m4() { open_ingress "$NS_GATEWAY" otel-backend-allow; }
m5() { open_egress  "$NS_CLIENT"  exporter-egress; }

run_mutation M1 "backend no longer requires client certificates" test_exporter_mtls.sh "E4 E5" "E1 E2 E3" m1
run_mutation M2 "gateway no longer requires client certificates" test_receiver_mtls.sh "R2 R3" "R1 R4 R5" m2
# N3 intentionally stays PASS under M3: the source namespace default-deny egress still blocks it (defense in depth).
# N4 stays PASS under M4 for the same reason (source egress allow-list); N4b isolates the backend ingress policy.
run_mutation M3 "gateway ingress policy opened to all sources" test_network_isolation.sh "N2 N6" "N1 N3 N4 N4b N5" m3
run_mutation M4 "backend ingress policy opened to all sources (gateway bypass)" test_network_isolation.sh "N4b" "N1 N2 N3 N4" m4
run_mutation M5 "approved-source egress allow-list opened to all destinations" test_network_isolation.sh "N5" "N1 N2 N3 N4" m5

# ---- prove the lab is back to baseline -------------------------------------------------------------------
restore_all
mkdir -p "$ZT_RUN_DIR/baseline"
# A passing delivery test is NOT enough to show restoration (it also passes on a broken lab), so verify the
# objects themselves against the snapshots AND re-run the security tests that the mutations targeted.
diffs="$(verify_snapshots)"
ZT_RUN_DIR="$ZT_RUN_DIR/baseline" bash "$HERE/test_receiver_mtls.sh" >"$ZT_RUN_DIR/baseline/test.out" 2>&1
ZT_RUN_DIR="$ZT_RUN_DIR/baseline" bash "$HERE/test_network_isolation.sh" >>"$ZT_RUN_DIR/baseline/test.out" 2>&1
nbad="$(jq -s '[.[]|select(.status=="FAIL")]|length' "$ZT_RUN_DIR/baseline/results.jsonl")"
npass="$(jq -s '[.[]|select(.status=="PASS")]|length' "$ZT_RUN_DIR/baseline/results.jsonl")"
if [ -z "$diffs" ] && [ "$nbad" -eq 0 ] && [ "$npass" -gt 0 ]; then
  record "$T" BASELINE PASS "lab restored: live objects equal their snapshots and the receiver + network tests pass again" "no diffs; no FAIL" "no diffs; $npass PASS, 0 FAIL"
else
  record "$T" BASELINE FAIL "lab restored: live objects equal their snapshots and the receiver + network tests pass again" "no diffs; no FAIL" "diffs=[$diffs] fail=$nbad pass=$npass" "$(grep -E 'FAIL' "$ZT_RUN_DIR/baseline/test.out" | head -8)"
fi
exit_with_status "$T"
