#!/usr/bin/env bash
# Create (or re-converge) the disposable lab cluster: kind + Cilium/Hubble + cert-manager + lab PKI.
# Safe to re-run. Never touches the caller's ~/.kube/config or current-context.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmds docker kind kubectl helm openssl jq base64
docker info >/dev/null 2>&1 || die "docker daemon is not reachable"

# Version gate: kind older than the pinned node image's release may not know its config.
kind_ver="$(kind version | sed -E 's/^kind v([0-9.]+).*/\1/')"
if [ "$(printf '%s\n%s\n' "$KIND_MIN_VERSION" "$kind_ver" | sort -V | head -1)" != "$KIND_MIN_VERSION" ]; then
  die "kind $kind_ver < required $KIND_MIN_VERSION"
fi

docker_mem_gib="$(docker info --format '{{.MemTotal}}' | awk '{printf "%.1f", $1/1024/1024/1024}')"
log "docker memory available: ${docker_mem_gib} GiB (lab estimate: needs ~3 GiB free; see lab/README.md)"

mkdir -p "$LAB_WORK_DIR" "$(dirname "$LAB_KUBECONFIG")"
created_marker="$LAB_WORK_DIR/cluster-created-by-lab"

cluster_exists() { kind get clusters 2>/dev/null | grep -Fxq "$LAB_CLUSTER_NAME"; }

if cluster_exists; then
  log "kind cluster '$LAB_CLUSTER_NAME' already exists; verifying it is lab-owned"
  [ -f "$LAB_KUBECONFIG" ] || kind export kubeconfig --name "$LAB_CLUSTER_NAME" --kubeconfig "$LAB_KUBECONFIG"
  owner="$(k get ns "$LAB_OWNER_NS" -o 'jsonpath={.metadata.labels.zt-lab/owner}' 2>/dev/null || true)"
  if [ "$owner" != "$LAB_OWNER_LABEL_VAL" ] && [ ! -f "$created_marker" ]; then
    die "a kind cluster named '$LAB_CLUSTER_NAME' exists but is not marked as owned by this lab; refusing to adopt it"
  fi
else
  log "creating kind cluster '$LAB_CLUSTER_NAME' (default CNI disabled; Cilium is installed next)"
  # --wait 0s: nodes stay NotReady until a CNI exists, so waiting here would only time out.
  kind create cluster --name "$LAB_CLUSTER_NAME" --config "$LAB_DIR/kind-config.yaml" \
    --kubeconfig "$LAB_KUBECONFIG" --wait 0s
  date -u +%FT%TZ > "$created_marker"
fi
chmod 600 "$LAB_KUBECONFIG"

# Confirm the kubeconfig really targets the lab cluster before any apply.
[ "$(kubectl --kubeconfig "$LAB_KUBECONFIG" config current-context)" = "$LAB_CONTEXT" ] \
  || die "unexpected context in lab kubeconfig"
retry 30 2 k get --raw=/readyz >/dev/null 2>&1 || die "API server did not become ready"

# Ownership marker first, so teardown works even if a later step fails.
k create namespace "$LAB_OWNER_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
k label namespace "$LAB_OWNER_NS" "$LAB_OWNER_LABEL_KEY=$LAB_OWNER_LABEL_VAL" \
  "app.kubernetes.io/part-of=$LAB_PART_OF" --overwrite >/dev/null
guard_lab_context

log "installing Cilium $CILIUM_VERSION (Hubble + Relay enabled)"
if ! helmk upgrade --install cilium cilium --repo "$CILIUM_CHART_REPO" --version "$CILIUM_VERSION" \
     --namespace kube-system -f "$LAB_DIR/cilium-values.yaml" --wait --timeout 10m; then
  diagnose kube-system; die "Cilium install failed"
fi
k -n kube-system rollout status ds/cilium --timeout=300s
k -n kube-system rollout status deploy/hubble-relay --timeout=300s
k wait --for=condition=Ready nodes --all --timeout=300s
log "waiting for CoreDNS (needs the CNI before it can schedule)"
k -n kube-system rollout status deploy/coredns --timeout=300s

log "installing cert-manager $CERT_MANAGER_VERSION"
if ! helmk upgrade --install cert-manager cert-manager --repo "$CERT_MANAGER_CHART_REPO" \
     --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
     -f "$LAB_DIR/cert-manager-values.yaml" --wait --timeout 10m; then
  diagnose cert-manager; die "cert-manager install failed"
fi

log "creating lab PKI (LAB ONLY; see lab/pki/README.md)"
# The webhook can lag the Deployment becoming Available; bounded retry instead of a blind sleep.
retry 20 3 k apply -f "$LAB_DIR/pki/issuers.yaml" >/dev/null || { diagnose cert-manager; die "could not apply issuers"; }
k -n cert-manager wait --for=condition=Ready certificate/lab-root-ca --timeout=120s
k wait --for=condition=Ready clusterissuer/telemetry-ca --timeout=120s

"$LAB_DIR/pki/distribute-trust.sh"

log "lab cluster is up. Next: make deploy"
