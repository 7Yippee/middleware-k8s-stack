#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-middleware}"

usage() {
  cat <<'EOF'
Usage:
  scripts/uninstall.sh [all|rabbitmq|redis|kafka|zookeeper ...]

Environment:
  NAMESPACE       Kubernetes namespace, default: middleware
  DELETE_PVC      Delete PVCs after uninstall, default: false
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- all
fi

expand_services() {
  for item in "$@"; do
    if [[ "$item" == "all" ]]; then
      printf '%s\n' rabbitmq redis kafka zookeeper
    else
      printf '%s\n' "$item"
    fi
  done
}

SERVICES=()
while IFS= read -r service; do
  SERVICES+=("$service")
done < <(expand_services "$@")

for service in "${SERVICES[@]}"; do
  echo "UNINSTALL [$NAMESPACE] $service"
  helm uninstall "$service" -n "$NAMESPACE" --ignore-not-found
done

if [[ "${DELETE_PVC:-false}" == "true" ]]; then
  for service in "${SERVICES[@]}"; do
    kubectl delete pvc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$service" --ignore-not-found
  done
fi

echo "Uninstall completed."
