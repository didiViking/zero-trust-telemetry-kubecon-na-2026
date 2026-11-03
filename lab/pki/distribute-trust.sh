#!/usr/bin/env bash
# LAB TRUST BOOTSTRAP (explicit, one-way): copy the PUBLIC lab root CA certificate out of the
# cert-manager Secret and render ConfigMaps named `telemetry-trust-bundle` for the namespaces
# that need it. Only the public certificate (never tls.key) is read or written.
#
# Trust flows from the PKI owner (this script, run by the operator) to workloads -- never from
# a telemetry sender. Output: lab/.work/trust-bundles.yaml (gitignored; consumed by lab/deploy).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_cmds kubectl openssl base64
guard_lab_context

out="$LAB_WORK_DIR/trust-bundles.yaml"
mkdir -p "$LAB_WORK_DIR"

# Read ONLY the tls.crt field of the root CA secret (jsonpath keeps the private key out of this process).
ca_pem="$(k -n cert-manager get secret lab-root-ca -o 'jsonpath={.data.tls\.crt}' | base64 -d)"
[ -n "$ca_pem" ] || die "lab-root-ca secret has no tls.crt; is the lab PKI ready?"
printf '%s\n' "$ca_pem" | openssl x509 -noout >/dev/null 2>&1 || die "tls.crt is not a valid certificate"
printf '%s\n' "$ca_pem" | openssl x509 -noout -text | grep -q 'CA:TRUE' || die "certificate is not a CA"
fp="$(printf '%s\n' "$ca_pem" | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)"

: > "$out"
for ns in "$NS_GATEWAY" "$NS_CLIENT" "$NS_UNTRUSTED"; do
  {
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: telemetry-trust-bundle"
    echo "  namespace: $ns"
    echo "  labels: {app.kubernetes.io/part-of: $LAB_PART_OF}"
    echo "data:"
    echo "  ca.crt: |"
    printf '%s\n' "$ca_pem" | sed 's/^/    /'
    echo "---"
  } >> "$out"
done
log "trust bundle rendered to ${out#"$REPO_ROOT"/}"
log "lab root CA sha256 fingerprint: $fp"
