#!/usr/bin/env bash
# Read-only prerequisite check with install hints. Changes nothing, contacts no cluster.
set -uo pipefail
USER_KUBECONFIG="${KUBECONFIG:-}"   # remember the caller's value: common.sh pins KUBECONFIG to the lab file
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

bad=0
ok()   { printf '  ok       %-9s %s\n' "$1" "$2"; }
warn() { printf '  WARNING  %-9s %s\n' "$1" "$2"; }
miss() { printf '  MISSING  %-9s %s\n' "$1" "$2"; bad=1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

echo "Checking prerequisites (nothing is installed or changed):"
for t in kubectl helm jq openssl; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t" "$(command -v "$t")"; else miss "$t" "not found"; fi
done

if command -v kind >/dev/null 2>&1; then
  kv="$(kind version | sed -E 's/^kind v([0-9.]+).*/\1/')"
  if ver_ge "$kv" "$KIND_MIN_VERSION"; then ok kind "v$kv"; else miss kind "v$kv is older than required v$KIND_MIN_VERSION"; fi
else
  miss kind "not found"
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    gib="$(docker info --format '{{.MemTotal}}' | awk '{printf "%.1f", $1/1024/1024/1024}')"
    if awk -v g="$gib" 'BEGIN{exit !(g>=6)}'; then ok docker "daemon running, ${gib} GiB available to Docker"
    else warn docker "only ${gib} GiB available to Docker; the lab uses ~2 GiB and 6+ is recommended (Docker Desktop > Settings > Resources)"; fi
  else
    miss docker "installed but the daemon is not running -- start Docker Desktop (or the docker service)"
  fi
else
  miss docker "not found"
fi

if [ -n "$USER_KUBECONFIG" ]; then ctx="$(KUBECONFIG="$USER_KUBECONFIG" kubectl config current-context 2>/dev/null || true)"
else ctx="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null || true)"; fi
[ -n "$ctx" ] && echo "  note     your current kubectl context is '$ctx'. The lab uses its own kubeconfig and will NOT touch it."

if [ "$bad" -ne 0 ]; then
  cat <<'HINT'

Install what is missing:
  macOS (Homebrew):  brew bundle --file=Brewfile     # then start Docker Desktop
  Linux:             install Docker Engine, then kubectl, kind (>= 0.30.0), helm, jq from your
                     distro or the projects' release pages. (Linux has not been tested with this lab.)
HINT
  exit 2
fi
echo "All prerequisites present. Next: make quickstart"
