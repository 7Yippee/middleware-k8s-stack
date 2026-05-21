#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-middleware}"
DELETE_PVC="${DELETE_PVC:-false}"
DELETE_SECRETS="${DELETE_SECRETS:-false}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/uninstall.sh [all|<component> ...]

Components are read from config/components.txt (single source of truth).

Environment:
  NAMESPACE        Kubernetes namespace, default: middleware
  DELETE_PVC       Delete PVCs after uninstall (DATA LOSS). Default: false
  DELETE_SECRETS   Delete generated auth secrets (rabbitmq-auth, redis-auth). Default: false

Examples:
  scripts/uninstall.sh all
  scripts/uninstall.sh redis rabbitmq
  DELETE_PVC=true scripts/uninstall.sh all
  DELETE_SECRETS=true DELETE_PVC=true scripts/uninstall.sh all
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command helm
require_command kubectl

if [[ $# -eq 0 ]]; then
  set -- all
fi

SERVICES=()
while IFS= read -r service; do
  SERVICES+=("$service")
done < <(expand_services "$@")

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  log_error "No services to uninstall."
  exit 1
fi

for service in "${SERVICES[@]}"; do
  log_info "UNINSTALL [$NAMESPACE] $service"
  helm uninstall "$service" -n "$NAMESPACE" --ignore-not-found
done

if [[ "$DELETE_PVC" == "true" ]]; then
  for service in "${SERVICES[@]}"; do
    log_warn "Deleting PVCs for $service (data will be lost)"
    kubectl delete pvc -n "$NAMESPACE" \
      -l "app.kubernetes.io/instance=$service" --ignore-not-found
  done
fi

if [[ "$DELETE_SECRETS" == "true" ]]; then
  for name in rabbitmq-auth redis-auth; do
    if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
      log_warn "Deleting secret $name (ns=$NAMESPACE)"
      kubectl -n "$NAMESPACE" delete secret "$name" --ignore-not-found
    fi
  done
fi

log_ok "Uninstall completed."
