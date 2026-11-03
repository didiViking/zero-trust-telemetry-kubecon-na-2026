#!/usr/bin/env bash
# Run the executable security tests against the lab cluster and write machine-readable evidence:
#   evidence/runs/<UTC timestamp>/{meta.json,results.jsonl,results.json}
# Exit codes: 0 no FAIL and no UNEXPECTED NOT RUN | 1 at least one FAIL | 3 no FAIL but an unexpected NOT RUN
# (e.g. a positive control failed) | 2 prerequisite missing.
# NOT RUN is never reported as PASS. Cases that are documented permanent gaps (known_gap=true: not implemented
# or not observable in this lab) stay listed as NOT RUN in results.json and the summary but do not by
# themselves make the exit code non-zero.
# Selection: TESTS="test_receiver_mtls.sh test_exporter_mtls.sh" tests/run-all.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/harness.sh"
require_cmds kubectl jq openssl base64 git
guard_lab_context

ZT_RUN_DIR="$REPO_ROOT/evidence/runs/$(date -u +%Y%m%dT%H%M%SZ)"
export ZT_RUN_DIR
mkdir -p "$ZT_RUN_DIR"
write_meta
: > "$ZT_RUN_DIR/results.jsonl"
log "evidence directory: ${ZT_RUN_DIR#"$REPO_ROOT"/}"

DEFAULT_TESTS="test_telemetry_delivery.sh test_receiver_mtls.sh test_exporter_mtls.sh test_network_isolation.sh test_certificate_rotation.sh ../scenarios/poisoned-log/test.sh"
overall=0
for t in ${TESTS:-$DEFAULT_TESTS}; do
  log "==== $t"
  bash "$HERE/$t"; rc=$?
  case "$rc" in
    0) ;;
    1) overall=1 ;;
    3) [ "$overall" -eq 0 ] && overall=3 ;;
    *) overall=1; record "$t" RUNNER FAIL "test script exited unexpectedly" "exit 0, 1 or 3" "exit $rc" ;;
  esac
done

# shellcheck disable=SC2034  # read by finalize_results
RESULTS_FILE="$ZT_RUN_DIR/results.jsonl"
out="$(finalize_results)"
jq -r '.summary | "SUMMARY: PASS=\(.pass) FAIL=\(.fail) NOT RUN=\(.not_run) (of which documented known gaps: \(.not_run_known_gap))"' "$out" >&2
log "results: ${out#"$REPO_ROOT"/}"
exit "$overall"
