#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-dev}"
NAMESPACE="${NAMESPACE:-middleware}"
CHART_REGISTRY="${CHART_REGISTRY:-oci://registry-1.docker.io/bitnamicharts}"
MIRROR_IMAGES="${MIRROR_IMAGES:-false}"
TIMEOUT="${TIMEOUT:-10m}"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy.sh [all|zookeeper|kafka|redis|rabbitmq ...]

Environment:
  ENVIRONMENT     Values environment, default: dev
  NAMESPACE       Kubernetes namespace, default: middleware
  MIRROR_IMAGES   Run scripts/mirror-images.sh before deploy, default: false
  TIMEOUT         Helm wait timeout, default: 10m

Examples:
  scripts/deploy.sh all
  scripts/deploy.sh redis rabbitmq
  ENVIRONMENT=prod NAMESPACE=middleware-prod scripts/deploy.sh kafka
  MIRROR_IMAGES=true scripts/deploy.sh all
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- all
fi

if [[ ! -d "$ROOT_DIR/envs/$ENVIRONMENT" ]]; then
  echo "Environment not found: $ROOT_DIR/envs/$ENVIRONMENT" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required." >&2
  exit 1
fi

expand_services() {
  for item in "$@"; do
    if [[ "$item" == "all" ]]; then
      printf '%s\n' zookeeper kafka redis rabbitmq
    else
      printf '%s\n' "$item"
    fi
  done
}

chart_version() {
  case "$1" in
    kafka) echo "32.4.3" ;;
    redis) echo "25.5.2" ;;
    rabbitmq) echo "16.0.14" ;;
    zookeeper) echo "13.8.7" ;;
    *) echo "Unsupported service: $1" >&2; return 1 ;;
  esac
}

deploy_one() {
  local service="$1"
  local version
  version="$(chart_version "$service")"

  echo "DEPLOY [$ENVIRONMENT/$NAMESPACE] $service chart=$version"
  helm upgrade --install "$service" "$CHART_REGISTRY/$service" \
    --version "$version" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout "$TIMEOUT" \
    -f "$ROOT_DIR/envs/$ENVIRONMENT/global.yaml" \
    -f "$ROOT_DIR/envs/$ENVIRONMENT/$service.yaml"
}

SERVICES=()
while IFS= read -r service; do
  SERVICES+=("$service")
done < <(expand_services "$@")

if [[ "$MIRROR_IMAGES" == "true" ]]; then
  "$ROOT_DIR/scripts/mirror-images.sh" "${SERVICES[@]}"
fi

for service in "${SERVICES[@]}"; do
  deploy_one "$service"
done

echo "Deploy completed."
