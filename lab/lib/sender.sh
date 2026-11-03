#!/usr/bin/env bash
# Synthetic-telemetry sender and backend-receipt helpers. Source after common.sh.
# shellcheck shell=bash

new_run_id() { printf 'run-%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 6)"; }

# render_sender_job: print a Job manifest that runs telemetrygen (synthetic data only).
# Env (all optional):
#   SEND_NAME      job/pod name                    (default telemetrygen-<random>)
#   SEND_NS        namespace                       (default telemetry-clients)
#   SEND_EXPORTER  value of label telemetry-exporter (default "true")
#   SEND_SIGNALS   space list of traces/metrics/logs (default all three)
#   SEND_SECRET    client-cert Secret name; empty => no client certificate presented
#   SEND_CA_CM     ConfigMap holding ca.crt        (default telemetry-trust-bundle)
#   SEND_ENDPOINT  host:port                       (default gateway FQDN:4317)
#   SEND_RUN_ID    unique marker written into every record
#   SEND_COUNT     items per signal                (default 3)
#   SEND_BODY      log body text                   (default synthetic marker)
#   SEND_DEADLINE  activeDeadlineSeconds           (default 60)
#   SEND_SERVICE   service.name resource attribute (default zt-lab-synthetic)
#   SEND_SEVERITY_TEXT / SEND_SEVERITY_NUMBER  log severity (e.g. Error / 17)
#   SEND_DURATION  e.g. 240s: send continuously at --rate for this long over ONE long-lived
#                  connection (replaces SEND_COUNT)
#   SEND_RATE      items/second                    (default 5)
#   SEND_BATCH_SIZE records per export (telemetrygen default 100 would delay the first connection)
#   SEND_ALLOW_FAILURES  "1" => keep going on export errors and log each (rotation test)
render_sender_job() {
  local name="${SEND_NAME:-telemetrygen-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)}"
  local ns="${SEND_NS:-$NS_CLIENT}"
  local exporter="${SEND_EXPORTER:-true}"
  local signals="${SEND_SIGNALS:-traces metrics logs}"
  local secret="${SEND_SECRET-traffic-generator-tls}"
  local ca_cm="${SEND_CA_CM:-telemetry-trust-bundle}"
  local endpoint="${SEND_ENDPOINT:-${GATEWAY_FQDN}:4317}"
  local run_id="${SEND_RUN_ID:?SEND_RUN_ID required}"
  local count="${SEND_COUNT:-3}"
  local body="${SEND_BODY:-synthetic telemetry ${run_id}}"
  local deadline="${SEND_DEADLINE:-60}"
  local s sq tl_job="" tl_pod=""
  # Test-created objects carry zt-lab/test so test cleanup removes only what tests created.
  if [ -n "${SEND_TEST_LABEL:-}" ]; then
    tl_job="$(printf '\n    zt-lab/test: "true"')"
    tl_pod="$(printf '\n        zt-lab/test: "true"')"
  fi

  cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: ${LAB_PART_OF}
    zt-lab/run-id: ${run_id}${tl_job}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${deadline}
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: ${LAB_PART_OF}
        telemetry-exporter: "${exporter}"
        zt-lab/run-id: ${run_id}${tl_pod}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile: {type: RuntimeDefault}
      containers:
YAML
  for s in $signals; do
    cat <<YAML
      - name: ${s}
        image: ${TELEMETRYGEN_IMAGE}
        args:
        - ${s}
        - --otlp-endpoint=${endpoint}
        - --ca-cert=/trust/ca.crt
YAML
    if [ -n "$secret" ]; then
      cat <<YAML
        - --mtls
        - --client-cert=/client/tls.crt
        - --client-key=/client/tls.key
YAML
    fi
    cat <<YAML
        - --rate=${SEND_RATE:-5}
        - --service=${SEND_SERVICE:-zt-lab-synthetic}
        - '--otlp-attributes=lab.run_id="${run_id}"'
        - '--otlp-attributes=lab.synthetic=true'
YAML
    if [ -n "${SEND_DURATION:-}" ]; then
      echo "        - --duration=${SEND_DURATION}"
    else
      echo "        - --${s}=${count}"
    fi
    if [ -n "${SEND_BATCH_SIZE:-}" ]; then
      echo "        - --batch-size=${SEND_BATCH_SIZE}"
    fi
    if [ "${SEND_ALLOW_FAILURES:-0}" = "1" ]; then
      echo "        - --allow-export-failures"
    fi
    if [ "$s" = "logs" ]; then
      # YAML single-quoted scalar: a literal ' is written as ''. The body is DATA; it is never
      # interpolated into a shell command (container args are exec'd directly, no shell).
      sq="'"
      printf '        - %s\n' "'--body=${body//$sq/$sq$sq}'"
      if [ -n "${SEND_SEVERITY_TEXT:-}" ]; then
        echo "        - --severity-text=${SEND_SEVERITY_TEXT}"
        echo "        - --severity-number=${SEND_SEVERITY_NUMBER:-9}"
      fi
    fi
    cat <<YAML
        resources:
          requests: {cpu: 10m, memory: 32Mi}
          limits: {cpu: 200m, memory: 128Mi}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: {drop: [ALL]}
        volumeMounts:
        - {name: trust, mountPath: /trust, readOnly: true}
YAML
    if [ -n "$secret" ]; then
      echo "        - {name: client, mountPath: /client, readOnly: true}"
    fi
  done
  echo "      volumes:"
  echo "      - name: trust"
  echo "        configMap: {name: ${ca_cm}}"
  if [ -n "$secret" ]; then
    echo "      - name: client"
    echo "        secret: {secretName: ${secret}}"
  fi
}

# wait_job_finished <ns> <job> <timeout-seconds>  -> prints "succeeded" | "failed" | "timeout"
wait_job_finished() {
  local ns="$1" job="$2" timeout="$3" i=0 st
  while [ "$i" -lt "$timeout" ]; do
    st="$(k -n "$ns" get job "$job" -o 'jsonpath={.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
    case "$st" in
      1/*) echo succeeded; return 0 ;;
      */1|*/[2-9]) echo failed; return 0 ;;
    esac
    sleep 2; i=$((i + 2))
  done
  echo timeout; return 0
}

# Print the received-telemetry file from the backend (application-level evidence). May be large.
backend_dump() {
  k -n "$NS_GATEWAY" exec deploy/otel-backend -c evidence-reader -- cat /data/otlp.jsonl 2>/dev/null || true
}

# backend_count <run_id> [resourceSpans|resourceMetrics|resourceLogs] : number of received batches
# carrying the marker (and, optionally, of the given signal type).
backend_count() {
  local run_id="$1" sig="${2:-}"
  if [ -n "$sig" ]; then
    backend_dump | grep -F "\"$run_id\"" | grep -c "\"$sig\"" || true
  else
    backend_dump | grep -cF "\"$run_id\"" || true
  fi
}

# wait_backend_receipt <run_id> <timeout-seconds> : bounded poll, no fixed sleep.
wait_backend_receipt() {
  local run_id="$1" timeout="${2:-30}" i=0 n
  while [ "$i" -lt "$timeout" ]; do
    n="$(backend_count "$run_id")"
    [ "${n:-0}" -ge 1 ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}
