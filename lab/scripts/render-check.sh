#!/usr/bin/env bash
# Offline check (no cluster, no Docker): render the lab overlay with a THROW-AWAY CA certificate standing
# in for the trust bundle, then fail if rendering fails or expected objects are missing.
# Writes the rendered manifests to the path in $1 (default: a temp file) so other checks can reuse them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_cmds kubectl openssl
out="${1:-$(mktemp)}"

# Do not clobber a real trust bundle if the lab is up: render from a private copy of the overlay inputs.
backup=""
if [ -f "$LAB_WORK_DIR/trust-bundles.yaml" ]; then backup="$(mktemp)"; cp "$LAB_WORK_DIR/trust-bundles.yaml" "$backup"; fi
mkdir -p "$LAB_WORK_DIR"
tmp="$(mktemp -d)"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=render-check-throwaway" \
  -days 1 -keyout "$tmp/k.pem" -out "$tmp/ca.pem" 2>/dev/null
: > "$LAB_WORK_DIR/trust-bundles.yaml"
for ns in "$NS_GATEWAY" "$NS_CLIENT" "$NS_UNTRUSTED"; do
  { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: telemetry-trust-bundle\n  namespace: %s\ndata:\n  ca.crt: |\n' "$ns"
    sed 's/^/    /' "$tmp/ca.pem"; echo '---'; } >> "$LAB_WORK_DIR/trust-bundles.yaml"
done
restore() { rm -rf "$tmp"; if [ -n "$backup" ]; then cp "$backup" "$LAB_WORK_DIR/trust-bundles.yaml"; rm -f "$backup"; else rm -f "$LAB_WORK_DIR/trust-bundles.yaml"; fi; }
trap restore EXIT

kubectl kustomize --load-restrictor=LoadRestrictionsNone "$LAB_DIR/deploy" > "$out"
for want in "kind: Deployment" "kind: Certificate" "kind: NetworkPolicy" "name: otel-backend-allow" "name: telemetry-trust-bundle"; do
  grep -q "$want" "$out" || die "rendered manifests are missing: $want"
done
log "overlay renders: $(grep -c '^kind:' "$out") objects ($out)"
