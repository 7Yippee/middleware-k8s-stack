#!/usr/bin/env bash
# Tail logs for a component's pods.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-middleware}"
TAIL_LINES="${TAIL_LINES:-200}"
FOLLOW="${FOLLOW:-true}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/logs.sh <component>

Environment:
  NAMESPACE     Kubernetes namespace. Default: middleware
  TAIL_LINES    Number of lines to show. Default: 200
  FOLLOW        true|false. Stream logs. Default: true

Examples:
  scripts/logs.sh rabbitmq
  NAMESPACE=middleware-prod TAIL_LINES=500 FOLLOW=false scripts/logs.sh kafka
USAGE
}

if [[ $# -ne 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 1
fi

component="$1"
require_command kubectl

if ! is_valid_component "$component"; then
  log_error "Unknown component: $component"
  exit 1
fi

args=(-n "$NAMESPACE" -l "app.kubernetes.io/instance=$component" --tail="$TAIL_LINES" --prefix=true --all-containers=true)
[[ "$FOLLOW" == "true" ]] && args+=(--follow)

log_info "logs for $component in ns=$NAMESPACE (follow=$FOLLOW tail=$TAIL_LINES)"
kubectl logs "${args[@]}"
