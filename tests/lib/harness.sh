#!/usr/bin/env bash
# Test harness: result recording (PASS / FAIL / NOT RUN), evidence metadata, guaranteed cleanup,
# and failure classification. Source from a test script; do not execute.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by scripts that source this file

TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$TESTS_LIB_DIR/.." && pwd)"
. "$TESTS_DIR/../lab/lib/common.sh"
. "$TESTS_DIR/../lab/lib/sender.sh"

# ---------- results ----------------------------------------------------------------------
# RUN_DIR is shared when launched via tests/run-all.sh; otherwise a standalone run creates its own.
init_run() {
  if [ -z "${ZT_RUN_DIR:-}" ]; then
    ZT_RUN_DIR="$REPO_ROOT/evidence/runs/$(date -u +%Y%m%dT%H%M%SZ)"
    export ZT_RUN_DIR
    ZT_STANDALONE=1
    mkdir -p "$ZT_RUN_DIR"
    write_meta
  fi
  mkdir -p "$ZT_RUN_DIR"
  RESULTS_FILE="$ZT_RUN_DIR/results.jsonl"
  touch "$RESULTS_FILE"
}

# write_meta: git commit, component versions, cluster identity, time. No secrets are read.
write_meta() {
  local commit dirty ctx_uid
  commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  dirty=false
  [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ] && dirty=true
  ctx_uid="$(k get ns kube-system -o 'jsonpath={.metadata.uid}' 2>/dev/null || echo unknown)"
  {
    k version -o json 2>/dev/null | jq -c '{kubernetes_server: .serverVersion.gitVersion}' || echo '{}'
  } > "$ZT_RUN_DIR/.kver.json"
  jq -n \
    --arg commit "$commit" --argjson dirty "$dirty" \
    --arg started "$(date -u +%FT%TZ)" \
    --arg context "$LAB_CONTEXT" \
    --arg server "$(kubectl --kubeconfig "$LAB_KUBECONFIG" config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)" \
    --arg cluster_uid "$ctx_uid" \
    --arg nodes "$(k get nodes -o 'jsonpath={.items[*].metadata.name}' 2>/dev/null)" \
    --slurpfile kver "$ZT_RUN_DIR/.kver.json" \
    --arg helm "$(helmk list -A -o json 2>/dev/null | jq -c '[.[] | {name, chart, app_version}]' 2>/dev/null || echo '[]')" \
    --arg images "$(k get deploy -A -o 'jsonpath={range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -E 'opentelemetry|busybox|openssl|telemetrygen' | tr '\n' ' ')" \
    --arg pinned "$(grep -E '^[A-Z_]+=' "$LAB_DIR/versions.env" | tr '\n' ' ')" \
    '{git_commit:$commit, working_tree_dirty:$dirty, started_utc:$started,
      cluster:({context:$context, api_server:$server, kube_system_ns_uid:$cluster_uid, nodes:$nodes} + $kver[0]),
      components:{helm_releases:($helm|fromjson), deployed_images:$images, pinned_versions_env:$pinned}}' \
    > "$ZT_RUN_DIR/meta.json"
  rm -f "$ZT_RUN_DIR/.kver.json"
}

_trunc() { head -c "${2:-1500}" <<<"$1"; }

# record <test_file> <case_id> <PASS|FAIL|NOT RUN> <description> <expected> <actual> [diagnostic]
# KNOWN_GAP=1 marks a NOT RUN that is a documented, permanent gap (not implemented / not observable in this
# lab). It is still reported as NOT RUN -- never as PASS -- but does not turn the overall exit code non-zero;
# an UNEXPECTED NOT RUN (e.g. a positive control failed) always does.
record() {
  local test="$1" id="$2" status="$3" desc="$4" expected="$5" actual="$6" diag="${7:-}" gap=false
  [ "${KNOWN_GAP:-0}" = "1" ] && gap=true
  diag="$(printf '%s' "$diag" | sanitize | head -c 1500)"
  jq -cn --arg test "$test" --arg id "$id" --arg status "$status" --arg desc "$desc" \
        --arg expected "$expected" --arg actual "$actual" --arg diag "$diag" --arg t "$(date -u +%FT%TZ)" \
        --argjson gap "$gap" \
     '{test:$test, case:$id, status:$status, known_gap:$gap, time_utc:$t, description:$desc, expected:$expected, actual:$actual, diagnostic:$diag}' \
     >> "$RESULTS_FILE"
  printf '%-8s %-26s %s\n' "[$status]" "$id" "$desc" >&2
  if [ "$status" = "FAIL" ]; then printf '         expected: %s\n         actual:   %s\n' "$expected" "$actual" >&2; fi
  if [ "$status" = "NOT RUN" ]; then printf '         reason:   %s\n' "$actual" >&2; fi
}

# ---------- guaranteed cleanup ------------------------------------------------------------
CLEANUP_CMDS=()
register_cleanup() { CLEANUP_CMDS+=("$*"); }
run_cleanups() {
  local i
  for ((i=${#CLEANUP_CMDS[@]}-1; i>=0; i--)); do
    eval "${CLEANUP_CMDS[$i]}" >/dev/null 2>&1 || log "cleanup step failed (ignored): ${CLEANUP_CMDS[$i]}"
  done
  CLEANUP_CMDS=()
}
trap 'run_cleanups' EXIT
trap 'exit 130' INT TERM

# ---------- failure classification --------------------------------------------------------
# classify_failure <text>: map client/exporter error text to ONE class so that an authentication
# rejection is never confused with DNS, refused connection, timeout/drop, or a generic failure.
#   TLS_CLIENT_CERT_REQUIRED  server demanded a client cert, none sent
#   TLS_CLIENT_CERT_REJECTED  server rejected the presented client cert (untrusted/bad)
#   TLS_SERVER_CERT_UNTRUSTED client could not chain the server cert to its CA
#   TLS_SERVER_NAME_MISMATCH  server cert valid but not for the name/IP dialed
#   DNS_FAILURE | CONN_REFUSED | PEER_RESET | NETWORK_TIMEOUT | OTHER | NONE
#   PEER_RESET (RST after TCP connect) is NOT accepted as proof of an auth rejection on its own: the
#   Go client can lose the race against the server closing after a TLS alert. It must be paired with
#   an openssl witness that observed the explicit alert.
classify_failure() {
  local t="$1"
  case "$t" in
    *"tls: certificate required"*|*"alert certificate required"*)          echo TLS_CLIENT_CERT_REQUIRED ;;
    *"tls: bad certificate"*|*"tls: unknown certificate authority"*|*"tls: certificate unknown"*|*"tls: unknown certificate"*|*"tls: handshake failure"*|*"alert bad certificate"*|*"alert unknown ca"*|*"alert certificate unknown"*|*"alert handshake failure"*) echo TLS_CLIENT_CERT_REJECTED ;;
    *"x509: certificate signed by unknown authority"*)                      echo TLS_SERVER_CERT_UNTRUSTED ;;
    *"x509: certificate is valid for"*|*"doesn't contain any IP SANs"*|*"x509: cannot validate certificate for"*) echo TLS_SERVER_NAME_MISMATCH ;;
    *"no such host"*|*"Temporary failure in name resolution"*|*"server misbehaving"*|*"NXDOMAIN"*) echo DNS_FAILURE ;;
    *"connection refused"*)                                                 echo CONN_REFUSED ;;
    *"connection reset by peer"*)                                           echo PEER_RESET ;;   # ambiguous alone: needs a TLS witness
    *"i/o timeout"*|*"context deadline exceeded"*|*"DeadlineExceeded"*|*"exporter export timeout"*) echo NETWORK_TIMEOUT ;;
    "")                                                                     echo NONE ;;
    *)                                                                      echo OTHER ;;
  esac
}

# ---------- helpers -------------------------------------------------------------------------
# run_sender <name> : render + apply + wait. MUST be called directly (not inside $(...)) because it
# sets globals and registers cleanup. Sets SENDER_RESULT (succeeded|failed|timeout) and SENDER_LOG.
SENDER_RESULT=""; SENDER_LOG=""
run_sender() {
  local name="$1" ns="${SEND_NS:-$NS_CLIENT}"
  # Unique name per invocation: Job specs are immutable, so a fixed name collides with leftovers.
  name="$name-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
  register_cleanup "k -n '$ns' delete job '$name' --ignore-not-found --wait=false"
  if ! SEND_NAME="$name" SEND_TEST_LABEL=1 render_sender_job | k apply -f - >/dev/null 2>"$ZT_RUN_DIR/.apply.err"; then
    SENDER_RESULT="apply-failed"; SENDER_LOG="$(cat "$ZT_RUN_DIR/.apply.err")"; return 0
  fi
  SENDER_RESULT="$(wait_job_finished "$ns" "$name" "${SEND_WAIT:-70}")"
  SENDER_LOG="$(k -n "$ns" logs "job/$name" --all-containers --tail=40 2>&1 || true)"
}

# Hubble lives in the Cilium agent on the node that hosts the observed pod. hubble_drops <ns/pod>
# prints DROPPED flows involving that pod (either direction), newest last. Observational only.
hubble_drops() {
  local pod_ref="$1" node agent
  node="$(k -n "${pod_ref%%/*}" get pod "${pod_ref##*/}" -o 'jsonpath={.spec.nodeName}' 2>/dev/null)"
  [ -n "$node" ] || return 1
  agent="$(k -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=$node" -o 'jsonpath={.items[0].metadata.name}')"
  k -n kube-system exec "$agent" -c cilium-agent -- hubble observe --pod "$pod_ref" --verdict DROPPED --last 100 -o compact 2>/dev/null
}

# jq: count log records / spans carrying a run marker, from the backend JSONL.
backend_record_count() {
  local run_id="$1"
  backend_dump | jq -s --arg rid "$run_id" '
    [ .[] | (.resourceLogs[]?, .resourceSpans[]?, .resourceMetrics[]?)
      | select([.resource.attributes[]? | select(.key=="lab.run_id" and .value.stringValue==$rid)] | length > 0)
      | (.scopeLogs[]?.logRecords[]?, .scopeSpans[]?.spans[]?, .scopeMetrics[]?.metrics[]?) ] | length' 2>/dev/null || echo 0
}

finalize_results() {
  local out="$ZT_RUN_DIR/results.json"
  jq -s --slurpfile meta "$ZT_RUN_DIR/meta.json" '
    { meta: $meta[0],
      summary: { pass:   (map(select(.status=="PASS"))   | length),
                 fail:   (map(select(.status=="FAIL"))   | length),
                 not_run:(map(select(.status=="NOT RUN"))| length),
                 not_run_known_gap:(map(select(.status=="NOT RUN" and .known_gap))| length) },
      results: . }' "$RESULTS_FILE" > "$out"
  printf '%s\n' "$out"
}

# exit_with_status <test_basename>: exit 1 on any FAIL, 3 if none failed but some UNEXPECTED NOT RUN, else 0.
# A standalone invocation also writes results.json.
exit_with_status() {
  local test="$1" f nr
  f="$(jq -s --arg t "$test" '[.[]|select(.test==$t and .status=="FAIL")]|length' "$RESULTS_FILE")"
  nr="$(jq -s --arg t "$test" '[.[]|select(.test==$t and .status=="NOT RUN" and (.known_gap|not))]|length' "$RESULTS_FILE")"
  if [ "${ZT_STANDALONE:-0}" = "1" ]; then finalize_results >&2; fi
  run_cleanups
  if [ "$f" -gt 0 ]; then exit 1; fi
  if [ "$nr" -gt 0 ]; then exit 3; fi
  exit 0
}

# ---------- test-owned resources ------------------------------------------------------------
# Everything a test creates carries zt-lab/test=true so cleanup (also run BEFORE a test, to clear
# leftovers of an interrupted run) removes only test-created objects, never lab infrastructure.
TEST_LABEL='zt-lab/test=true'
clean_test_objects() {
  local ns="$1"
  k -n "$ns" delete job,pod,networkpolicy,certificate,issuer,configmap,secret \
    -l "$TEST_LABEL" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
use_test_namespace() {  # use_test_namespace <ns> : pre-clean + register post-clean
  clean_test_objects "$1"
  register_cleanup "clean_test_objects '$1'"
}

# ensure_rogue_pki <ns>: a SECOND, untrusted CA living in <ns>, plus a client cert it issues and a
# ConfigMap carrying its public cert. Not in any lab trust bundle => used as the "untrusted" identity.
# The rogue CA deliberately REUSES the lab root CA's subject name (CN=zt-lab-root-ca) with a different
# key. A TLS server advertises the DNs of the CAs it accepts, and a Go client silently declines to
# present a certificate whose issuer DN is not in that list -- the server then reports "certificate
# required" instead of rejecting the presented certificate. Matching the DN forces the client to PRESENT
# the rogue certificate, so the server's signature verification is what actually rejects it.
ensure_rogue_pki() {
  local ns="$1"
  k apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: zt-test-rogue-selfsigned, namespace: ${ns}, labels: {zt-lab/test: "true"}}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: zt-test-rogue-ca, namespace: ${ns}, labels: {zt-lab/test: "true"}}
spec:
  isCA: true
  commonName: zt-lab-root-ca    # spoofed issuer name, different key (see comment above)
  secretName: zt-test-rogue-ca-tls
  secretTemplate: {labels: {zt-lab/test: "true"}}
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: zt-test-rogue-selfsigned, kind: Issuer}
YAML
  k -n "$ns" wait --for=condition=Ready certificate/zt-test-rogue-ca --timeout=60s >/dev/null || return 1
  k apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: zt-test-rogue-issuer, namespace: ${ns}, labels: {zt-lab/test: "true"}}
spec: {ca: {secretName: zt-test-rogue-ca-tls}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: zt-test-rogue-client, namespace: ${ns}, labels: {zt-lab/test: "true"}}
spec:
  commonName: lab-traffic-generator   # same CN as the legitimate client: identity != CN
  secretName: zt-test-rogue-client-tls
  secretTemplate: {labels: {zt-lab/test: "true"}}
  usages: [client auth]
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: zt-test-rogue-issuer, kind: Issuer}
YAML
  k -n "$ns" wait --for=condition=Ready certificate/zt-test-rogue-client --timeout=60s >/dev/null || return 1
  local pem
  pem="$(k -n "$ns" get secret zt-test-rogue-ca-tls -o 'jsonpath={.data.tls\.crt}' | base64 -d)"   # public cert only
  k -n "$ns" create configmap zt-test-rogue-ca-bundle --from-literal=ca.crt="$pem" \
    --dry-run=client -o yaml | k label --local -f - "$TEST_LABEL" -o yaml | k apply -f - >/dev/null
}

# issue_client_cert <ns> <name> : legitimate client cert from telemetry-ca (used for non-approved sources).
issue_client_cert() {
  local ns="$1" name="$2"
  k apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: ${name}, namespace: ${ns}, labels: {zt-lab/test: "true"}}
spec:
  commonName: lab-test-${name}
  secretName: ${name}-tls
  secretTemplate: {labels: {zt-lab/test: "true"}}
  usages: [client auth]
  privateKey: {algorithm: ECDSA, size: 256}
  issuerRef: {name: telemetry-ca, kind: ClusterIssuer}
YAML
  k -n "$ns" wait --for=condition=Ready "certificate/${name}" --timeout=60s >/dev/null
}

# run_tool_pod <ns> <name> <exporter-label-value|-> <image> <script> [secret] : one-shot pod running
# `sh -c <script>`; waits (bounded) for it to finish; prints its logs. Restricted-PSA compliant.
run_tool_pod() {
  local ns="$1" name="$2" exporter="$3" image="$4" script="$5" secret="${6:-}" phase i=0
  local extra_labels="zt-lab/role: tool" mounts="" vols=""
  [ "$exporter" != "-" ] && extra_labels="telemetry-exporter: \"${exporter}\", zt-lab/role: tool"
  # TOOL_LABELS: additional flow-style labels, e.g. 'zt-lab/probe: exporter-mtls' (used to match test policies)
  [ -n "${TOOL_LABELS:-}" ] && extra_labels="${extra_labels}, ${TOOL_LABELS}"
  mounts="        - {name: trust, mountPath: /trust, readOnly: true}"
  vols="      - {name: trust, configMap: {name: telemetry-trust-bundle}}"
  if [ -n "$secret" ]; then
    mounts="$mounts
        - {name: client, mountPath: /client, readOnly: true}"
    vols="$vols
      - {name: client, secret: {secretName: ${secret}}}"
  fi
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
  labels: {zt-lab/test: "true", app.kubernetes.io/part-of: ${LAB_PART_OF}, ${extra_labels}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: ${TOOL_DEADLINE:-120}
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: tool
    image: ${image}
    command: ["sh", "-c"]
    args:
    - |
$(printf '%s\n' "$script" | sed 's/^/      /')
    resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 200m, memory: 64Mi}}
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    volumeMounts:
${mounts}
  volumes:
${vols}
YAML
  [ -n "${TOOL_NOWAIT:-}" ] && return 0
  while [ "$i" -lt "${TOOL_WAIT:-90}" ]; do
    phase="$(k -n "$ns" get pod "$name" -o 'jsonpath={.status.phase}' 2>/dev/null)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2; i=$((i + 2))
  done
  TOOL_PHASE="$phase"
  k -n "$ns" logs "$name" 2>&1
}

# gateway_cluster_ip: IP of the gateway Service (used to provoke a hostname mismatch).
gateway_cluster_ip() { k -n "$NS_GATEWAY" get svc otel-gateway -o 'jsonpath={.spec.clusterIP}'; }
backend_cluster_ip() { k -n "$NS_GATEWAY" get svc otel-backend -o 'jsonpath={.spec.clusterIP}'; }
