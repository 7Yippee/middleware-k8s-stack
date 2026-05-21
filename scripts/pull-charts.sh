#!/usr/bin/env bash
# Download Helm charts declared in config/components.txt into ./charts/ as .tgz
# files so deploy.sh can run offline.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

CHART_REGISTRY="${CHART_REGISTRY:-oci://registry-1.docker.io/bitnamicharts}"
CHARTS_DIR="${CHARTS_DIR:-$ROOT_DIR/charts}"
FORCE="${FORCE:-false}"

usage() {
  cat <<'EOF'
Usage:
  scripts/pull-charts.sh [all|<component> ...]

Environment:
  CHART_REGISTRY   OCI chart registry, default: oci://registry-1.docker.io/bitnamicharts
  CHARTS_DIR       Local cache directory, default: ./charts
  FORCE            Re-download even if tgz exists, default: false

Examples:
  scripts/pull-charts.sh all
  scripts/pull-charts.sh kafka redis
  FORCE=true scripts/pull-charts.sh all
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command helm

if [[ $# -eq 0 ]]; then
  set -- all
fi

mkdir -p "$CHARTS_DIR"

SERVICES=()
while IFS= read -r s; do SERVICES+=("$s"); done < <(expand_services "$@")

for service in "${SERVICES[@]}"; do
  version="$(component_version "$service")"
  target="$CHARTS_DIR/$service-$version.tgz"

  if [[ -f "$target" && "$FORCE" != "true" ]]; then
    log_info "SKIP   $service-$version (already cached)"
    continue
  fi

  log_info "PULL   $service chart=$version"
  # helm pull puts the tgz into the current directory; --destination targets a dir.
  helm pull "$CHART_REGISTRY/$service" --version "$version" --destination "$CHARTS_DIR"
done

log_ok "Chart cache ready at: $CHARTS_DIR"
