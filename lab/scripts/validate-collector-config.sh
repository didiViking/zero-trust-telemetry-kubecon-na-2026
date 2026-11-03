#!/usr/bin/env bash
# Validate the Collector configs embedded in the rendered manifests with the PINNED Collector image
# (`otelcol-contrib validate`). Needs Docker + kubectl; no cluster. `validate` checks component names and
# config keys; it does not prove the TLS files exist or that the pipeline works at runtime.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_cmds kubectl docker
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
"$LAB_DIR/scripts/render-check.sh" "$work/rendered.yaml" >/dev/null

rc=0
for cm in otel-gateway-config otel-backend-config; do
  # split the multi-doc stream, keep only the named ConfigMap, read data.config.yaml offline
  awk -v RS='\n---\n' -v want="name: $cm" -v out="$work/cm.yaml" 'index($0, want) && index($0, "kind: ConfigMap") { print $0 > out }' "$work/rendered.yaml"
  kubectl create --dry-run=client -f "$work/cm.yaml" -o 'jsonpath={.data.config\.yaml}' > "$work/$cm.yaml"
  [ -s "$work/$cm.yaml" ] || die "could not extract $cm"
  if docker run --rm -v "$work:/w:ro" "$OTELCOL_IMAGE" validate --config="/w/$cm.yaml" >"$work/out.txt" 2>&1; then
    log "PASS  $cm validates with $OTELCOL_IMAGE"
  else
    log "FAIL  $cm"; sed 's/^/    /' "$work/out.txt" >&2; rc=1
  fi
  rm -f "$work/cm.yaml"
done
exit "$rc"
