#!/usr/bin/env bash
# Exporter -> backend authentication (the gateway's outbound leg).
#
# METHOD / LIMITATION: the live gateway is NOT modified. A throw-away probe Collector (same image as
# the gateway) is given an `otlp` exporter whose TLS block mirrors the gateway's, with retries and
# queueing disabled so a rejection is observable immediately. Each case changes exactly ONE variable
# from the positive control. The probe is allowed through NetworkPolicy by temporary, test-labelled
# policies; the live backend policy is never edited.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"
require_cmds kubectl jq base64
guard_lab_context
init_run
T="$(basename "$0")"
NS="$NS_GATEWAY"
use_test_namespace "$NS"

setup_probe_prereqs() {
  issue_client_cert "$NS" zt-test-exporter-probe || return 1
  ensure_rogue_pki "$NS" || return 1
  k apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: zt-test-probe-egress, namespace: ${NS}, labels: {zt-lab/test: "true"}}
spec:
  podSelector: {matchLabels: {zt-lab/probe: exporter-mtls}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app: otel-backend}}}]
    ports: [{protocol: TCP, port: 4317}]
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: zt-test-backend-ingress-probe, namespace: ${NS}, labels: {zt-lab/test: "true"}}
spec:
  podSelector: {matchLabels: {app: otel-backend}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {zt-lab/probe: exporter-mtls}}}]
    ports: [{protocol: TCP, port: 4317}]
YAML
}

# probe_case <name> <endpoint> <ca_configmap> <client_secret or ""> : sets PROBE_LOG, PROBE_RID
probe_case() {
  local name="$1" endpoint="$2" ca_cm="$3" secret="$4" i=0 tls_client="" mounts_client="" vol_client=""
  PROBE_RID="$(new_run_id)"
  if [ -n "$secret" ]; then
    # Indentation matters: each variable is interpolated at column 0 of its heredoc line.
    tls_client="          cert_file: /client/tls.crt
          key_file: /client/tls.key"
    mounts_client="    - {name: client, mountPath: /client, readOnly: true}"
    vol_client="  - {name: client, secret: {secretName: ${secret}}}"
  fi
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata: {name: ${name}, namespace: ${NS}, labels: {zt-lab/test: "true"}}
data:
  probe.log: |
    synthetic exporter probe ${PROBE_RID}
  config.yaml: |
    receivers:
      filelog:
        include: [/input/probe.log]
        start_at: beginning
    processors:
      resource:
        attributes:
        - {key: lab.run_id, value: "${PROBE_RID}", action: upsert}
        - {key: lab.synthetic, value: true, action: upsert}
    exporters:
      otlp:
        endpoint: ${endpoint}
        timeout: 5s
        retry_on_failure: {enabled: false}
        sending_queue: {enabled: false}
        tls:
          ca_file: /ca/ca.crt
${tls_client}
    service:
      telemetry: {metrics: {level: none}}
      pipelines:
        logs: {receivers: [filelog], processors: [resource], exporters: [otlp]}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels: {zt-lab/test: "true", zt-lab/probe: exporter-mtls, app.kubernetes.io/part-of: ${LAB_PART_OF}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  activeDeadlineSeconds: 120
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: collector
    image: ${OTELCOL_IMAGE}
    args: ["--config=/conf/config.yaml"]
    resources: {requests: {cpu: 20m, memory: 64Mi}, limits: {cpu: 300m, memory: 192Mi}}
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    volumeMounts:
    - {name: cfg, mountPath: /conf, readOnly: true}
    - {name: cfg, mountPath: /input/probe.log, subPath: probe.log, readOnly: true}
    - {name: ca, mountPath: /ca, readOnly: true}
${mounts_client}
  volumes:
  - {name: cfg, configMap: {name: ${name}}}
  - {name: ca, configMap: {name: ${ca_cm}}}
${vol_client}
YAML
  # Bounded wait for either a delivered record or an export failure line (no fixed sleep).
  while [ "$i" -lt 45 ]; do
    PROBE_LOG="$(k -n "$NS" logs "$name" 2>&1 || true)"
    case "$PROBE_LOG" in *"Exporting failed"*|*"export failed"*|*"Dropping data"*) break ;; esac
    [ "$(backend_count "$PROBE_RID")" -ge 1 ] && break
    sleep 1; i=$((i + 1))
  done
  # Keep only error-bearing lines, trimmed: the full startup log would push the evidence out of the
  # (size-capped) diagnostic field.
  PROBE_LOG="$(k -n "$NS" logs "$name" 2>&1 | grep -Ei 'error|fail|x509|tls:' | sed -E 's/\{"resource".*"otelcol.signal": "logs"\}//' | tail -6 | cut -c1-600 || true)"
  k -n "$NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
}

if ! setup_probe_prereqs; then
  for c in E1 E2 E3 E4 E5; do record "$T" "$c" "NOT RUN" "exporter case" "n/a" "could not provision probe prerequisites (certs/policies)"; done
  exit_with_status "$T"
fi

# E1 positive control
probe_case zt-test-probe-e1 "${BACKEND_FQDN}:4317" telemetry-trust-bundle zt-test-exporter-probe-tls
n="$(backend_count "$PROBE_RID")"
if [ "${n:-0}" -ge 1 ]; then
  record "$T" E1 PASS "exporter with trusted CA, correct name and valid client cert delivers (positive control)" \
    "backend records marker" "backend_batches=$n"
else
  record "$T" E1 FAIL "exporter with trusted CA, correct name and valid client cert delivers (positive control)" \
    "backend records marker" "backend_batches=$n class=$(classify_failure "$PROBE_LOG")" "$PROBE_LOG"
  for c in E2 E3 E4 E5; do record "$T" "$c" "NOT RUN" "exporter negative case" "n/a" "positive control E1 failed; rejection would be uninterpretable"; done
  exit_with_status "$T"
fi

expect_exporter_rejected() {  # <case> <desc> <want-class> ; uses PROBE_LOG / PROBE_RID
  local id="$1" desc="$2" want="$3" cls n
  cls="$(classify_failure "$PROBE_LOG")"; n="$(backend_count "$PROBE_RID")"
  if [ "$cls" = "$want" ] && [ "${n:-0}" -eq 0 ]; then
    record "$T" "$id" PASS "$desc" "exporter error class $want; backend receives nothing" "class=$cls backend_batches=$n" "$PROBE_LOG"
  else
    record "$T" "$id" FAIL "$desc" "exporter error class $want; backend receives nothing" "class=$cls backend_batches=$n" "$PROBE_LOG"
  fi
}

probe_case zt-test-probe-e2 "${BACKEND_FQDN}:4317" zt-test-rogue-ca-bundle zt-test-exporter-probe-tls
expect_exporter_rejected E2 "exporter rejects a backend whose certificate is not issued by its trusted CA" TLS_SERVER_CERT_UNTRUSTED

probe_case zt-test-probe-e3 "$(backend_cluster_ip):4317" telemetry-trust-bundle zt-test-exporter-probe-tls
expect_exporter_rejected E3 "exporter rejects a backend when the dialed name/IP is not in the certificate SANs" TLS_SERVER_NAME_MISMATCH

# E4: the exporter may observe either the explicit TLS alert or a TCP reset (race between its write and
# the server closing). The reset alone is ambiguous, so an openssl witness from the same network position
# must independently observe the explicit "certificate required" alert after a SUCCESSFUL server-cert verification.
probe_case zt-test-probe-e4 "${BACKEND_FQDN}:4317" telemetry-trust-bundle ""
cls4="$(classify_failure "$PROBE_LOG")"; n4="$(backend_count "$PROBE_RID")"
TOOL_LABELS='zt-lab/probe: exporter-mtls'; TOOL_WAIT=40; export TOOL_LABELS TOOL_WAIT
witness_out="$(run_tool_pod "$NS" zt-test-witness-e4 - "$OPENSSL_IMAGE" \
  "printf x | timeout 8 openssl s_client -connect ${BACKEND_FQDN}:4317 -CAfile /trust/ca.crt -verify_hostname ${BACKEND_FQDN} -verify_return_error -alpn h2 2>&1 | grep -E 'Verify return|alert|error|Protocol|Cipher' | head -10")"
unset TOOL_LABELS TOOL_WAIT
wcls="$(classify_failure "$witness_out")"
if { [ "$cls4" = TLS_CLIENT_CERT_REQUIRED ] || [ "$cls4" = PEER_RESET ]; } && [ "$wcls" = TLS_CLIENT_CERT_REQUIRED ] && [ "${n4:-0}" -eq 0 ]; then
  record "$T" E4 PASS "backend rejects an exporter that presents no client certificate" \
    "exporter fails (alert or reset), witness sees 'certificate required' alert, backend receives nothing" \
    "exporter_class=$cls4 witness_class=$wcls backend_batches=$n4" "witness: $witness_out | exporter: $PROBE_LOG"
else
  record "$T" E4 FAIL "backend rejects an exporter that presents no client certificate" \
    "exporter fails (alert or reset), witness sees 'certificate required' alert, backend receives nothing" \
    "exporter_class=$cls4 witness_class=$wcls backend_batches=$n4" "witness: $witness_out | exporter: $PROBE_LOG"
fi

probe_case zt-test-probe-e5 "${BACKEND_FQDN}:4317" telemetry-trust-bundle zt-test-rogue-client-tls
expect_exporter_rejected E5 "backend rejects an exporter presenting a client certificate from an untrusted CA" TLS_CLIENT_CERT_REJECTED

# E6 transport protection: the witness negotiated a modern TLS version with the backend (observed, not assumed)
if grep -qE 'Protocol *: *TLSv1\.[23]' <<<"$witness_out"; then
  record "$T" E6 PASS "backend connection negotiates TLS 1.2+ (transport protection observed by the openssl witness)" \
    "Protocol: TLSv1.2 or TLSv1.3" "$(grep -E 'Protocol|Cipher' <<<"$witness_out" | tr '\n' ' ')"
else
  record "$T" E6 FAIL "backend connection negotiates TLS 1.2+ (transport protection observed by the openssl witness)" \
    "Protocol: TLSv1.2 or TLSv1.3" "no Protocol line in witness output" "$witness_out"
fi

exit_with_status "$T"
