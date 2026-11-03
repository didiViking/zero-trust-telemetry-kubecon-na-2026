#!/usr/bin/env bash
# Read-only overview of the lab (no secrets printed).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
guard_lab_context
k get nodes -o wide
for ns in kube-system cert-manager "$NS_GATEWAY" "$NS_CLIENT" "$NS_UNTRUSTED"; do echo "== $ns"; k -n "$ns" get pods 2>&1; done
echo "== certificates"; k get certificate -A
echo "== networkpolicies"; k get networkpolicy -A
