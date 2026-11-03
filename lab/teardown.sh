#!/usr/bin/env bash
# Remove ONLY what this lab created: the kind cluster 'zt-telemetry-lab' plus lab/.kube and lab/.work.
# Does not touch other kind clusters, other kube contexts, Docker images, or Helm repo config.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_cmds kind

created_marker="$LAB_WORK_DIR/cluster-created-by-lab"
if kind get clusters 2>/dev/null | grep -Fxq "$LAB_CLUSTER_NAME"; then
  owned=0
  [ -f "$created_marker" ] && owned=1
  if [ -f "$LAB_KUBECONFIG" ]; then
    owner="$(k get ns "$LAB_OWNER_NS" -o 'jsonpath={.metadata.labels.zt-lab/owner}' 2>/dev/null || true)"
    [ "$owner" = "$LAB_OWNER_LABEL_VAL" ] && owned=1
  fi
  [ "$owned" -eq 1 ] || die "cluster '$LAB_CLUSTER_NAME' has no lab ownership evidence; refusing to delete it"
  log "deleting kind cluster '$LAB_CLUSTER_NAME'"
  kind delete cluster --name "$LAB_CLUSTER_NAME" --kubeconfig "$LAB_KUBECONFIG"
else
  log "kind cluster '$LAB_CLUSTER_NAME' not present; nothing to delete"
fi
rm -rf "$LAB_DIR/.kube" "$LAB_WORK_DIR"
log "lab state removed"
