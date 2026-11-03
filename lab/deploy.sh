#!/usr/bin/env bash
# Deploy the gateway blueprint (manifests/), the lab backend and the client namespace into the lab
# cluster, then wait for readiness with bounded timeouts. Idempotent (kubectl apply).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_cmds kubectl openssl
guard_lab_context

ctx_server="$(kubectl --kubeconfig "$LAB_KUBECONFIG" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')"
log "target context: $LAB_CONTEXT ($ctx_server) -- default-deny NetworkPolicies will be applied here ONLY"

# Re-render the trust bundle from the current lab root CA (explicit trust bootstrap).
"$LAB_DIR/pki/distribute-trust.sh"

rendered="$LAB_WORK_DIR/rendered.yaml"
kubectl kustomize --load-restrictor=LoadRestrictionsNone "$LAB_DIR/deploy" > "$rendered"
log "rendered $(grep -c '^kind:' "$rendered") objects to ${rendered#"$REPO_ROOT"/}"

# Server-side dry run catches schema/admission errors before anything changes. It can only run
# once the namespaces exist (a dry run does not create them), so it is skipped on the first deploy.
if k get ns "$NS_GATEWAY" "$NS_CLIENT" "$NS_UNTRUSTED" >/dev/null 2>&1; then
  k apply --dry-run=server -f "$rendered" >/dev/null || die "server-side dry-run failed"
else
  log "first deploy: namespaces absent, skipping server-side dry-run"
fi
k apply -f "$rendered"

log "waiting for certificates to be issued"
for c in "$NS_GATEWAY/otel-gateway" "$NS_GATEWAY/otel-backend" "$NS_CLIENT/traffic-generator"; do
  k -n "${c%%/*}" wait --for=condition=Ready "certificate/${c##*/}" --timeout=120s \
    || { diagnose "${c%%/*}" cert-manager; die "certificate $c not Ready"; }
done

log "waiting for workloads"
for d in otel-backend otel-gateway; do
  k -n "$NS_GATEWAY" rollout status "deploy/$d" --timeout=180s \
    || { diagnose "$NS_GATEWAY"; k -n "$NS_GATEWAY" logs "deploy/$d" --tail=30 2>&1 | sanitize >&2 || true; die "deploy/$d not ready"; }
done

log "deployed. NetworkPolicies:"
k get networkpolicy -A -l 'app.kubernetes.io/part-of=zero-trust-telemetry-lab' --no-headers 2>/dev/null || true
log "next: make send-telemetry"
