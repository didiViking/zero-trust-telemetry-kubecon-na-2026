#!/usr/bin/env bash
# Shared helpers for lab scripts and tests. Source it; do not execute it.
# Compatible with bash 3.2 (macOS default) -- no associative arrays, mapfile, or ${var,,}.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by scripts that source this file

LAB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$LAB_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/.." && pwd)"
LAB_WORK_DIR="$LAB_DIR/.work"
LAB_KUBECONFIG="$LAB_DIR/.kube/config"

# shellcheck source=../versions.env
. "$LAB_DIR/versions.env"

LAB_OWNER_NS=zt-lab-system
LAB_OWNER_LABEL_KEY=zt-lab/owner
LAB_OWNER_LABEL_VAL=zero-trust-telemetry-kubecon-na-2026
LAB_PART_OF=zero-trust-telemetry-lab

NS_GATEWAY=telemetry-secure   # gateway + backend (from manifests/)
NS_CLIENT=telemetry-clients   # approved source namespace (label telemetry-client=true)
NS_UNTRUSTED=telemetry-untrusted
GATEWAY_FQDN="otel-gateway.${NS_GATEWAY}.svc.cluster.local"
BACKEND_FQDN="otel-backend.${NS_GATEWAY}.svc.cluster.local"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

require_cmds() {
  local c missing=0
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log "missing prerequisite: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || exit 2
}

# SAFETY: every kubectl/helm call in the lab goes through these wrappers, which pin BOTH the
# kubeconfig file and the context. The user's ~/.kube/config and current-context are never read
# or modified, so a stray `make` cannot hit another cluster (e.g. a different kind cluster).
export KUBECONFIG="$LAB_KUBECONFIG"
k()    { kubectl --kubeconfig "$LAB_KUBECONFIG" --context "$LAB_CONTEXT" "$@"; }
helmk() { helm --kubeconfig "$LAB_KUBECONFIG" --kube-context "$LAB_CONTEXT" "$@"; }

# Refuse to continue unless the target is the lab cluster AND carries our ownership marker.
guard_lab_context() {
  [ -f "$LAB_KUBECONFIG" ] || die "no lab kubeconfig at $LAB_KUBECONFIG -- run 'make lab-up' first"
  local ctx
  ctx="$(kubectl --kubeconfig "$LAB_KUBECONFIG" config current-context 2>/dev/null || true)"
  [ "$ctx" = "$LAB_CONTEXT" ] || die "lab kubeconfig current-context is '$ctx', expected '$LAB_CONTEXT'"
  local owner
  owner="$(k get ns "$LAB_OWNER_NS" -o "jsonpath={.metadata.labels.zt-lab/owner}" 2>/dev/null || true)"
  [ "$owner" = "$LAB_OWNER_LABEL_VAL" ] || \
    die "cluster '$LAB_CONTEXT' lacks ownership marker (ns/$LAB_OWNER_NS label $LAB_OWNER_LABEL_KEY); refusing to act"
}

# retry <attempts> <sleep-seconds> <cmd...> : bounded retry, returns last exit code.
retry() {
  local n="$1" s="$2" i=1 rc=0
  shift 2
  while [ "$i" -le "$n" ]; do
    "$@" && return 0
    rc=$?
    [ "$i" -lt "$n" ] && sleep "$s"
    i=$((i + 1))
  done
  return "$rc"
}

# sanitize: strip anything that looks like key material or bearer tokens from diagnostic output.
# Portable to BSD (macOS) and GNU userland.
sanitize() {
  awk '
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/ { print "[REDACTED PRIVATE KEY]"; skip=1; next }
    /-----END [A-Z ]*PRIVATE KEY-----/   { skip=0; next }
    skip { next }
    { print }' |
  sed -E \
    -e 's/([Bb]earer) +[A-Za-z0-9._~+\/=-]+/\1 [REDACTED]/g' \
    -e 's/([Tt]oken|[Pp]assword|[Ss]ecret)(["'"'"' :=]+)[A-Za-z0-9._~+\/=-]{8,}/\1\2[REDACTED]/g'
}

# Diagnostics printed on failure of a bootstrap/deploy step. Never prints Secret contents.
diagnose() {
  local ns
  log "---- diagnostics (sanitized) ----"
  for ns in "$@"; do
    k -n "$ns" get pods -o wide 2>&1 | sanitize || true
    k -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -15 | sanitize || true
  done
}
