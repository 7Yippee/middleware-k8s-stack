#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-dev}"
NAMESPACE="${NAMESPACE:-middleware}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-aliyun-registry}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-guangzhou.aliyuncs.com}"
CREATE_IMAGE_PULL_SECRET="${CREATE_IMAGE_PULL_SECRET:-auto}"
MIRROR_IMAGES="${MIRROR_IMAGES:-false}"

usage() {
  cat <<'EOF'
Usage:
  scripts/quickstart.sh [all|zookeeper|kafka|redis|rabbitmq ...]

Environment:
  ENVIRONMENT                Values environment, default: dev
  NAMESPACE                  Kubernetes namespace, default: middleware
  STORAGE_CLASS              StorageClass override. Optional
  MIRROR_IMAGES              Mirror images before deploy, default: false
  CREATE_IMAGE_PULL_SECRET   auto, true, or false. Default: auto
  IMAGE_PULL_SECRET          Pull secret name, default: aliyun-registry
  ALIYUN_REGISTRY            Registry server, default: registry.cn-guangzhou.aliyuncs.com
  ALIYUN_USERNAME            Required when creating pull secret
  ALIYUN_PASSWORD            Required when creating pull secret

Examples:
  scripts/quickstart.sh all
  NAMESPACE=middleware-dev STORAGE_CLASS=local-path scripts/quickstart.sh all
  ENVIRONMENT=prod NAMESPACE=middleware-prod STORAGE_CLASS=huawei-sc scripts/quickstart.sh all
  ALIYUN_USERNAME=xxx ALIYUN_PASSWORD=xxx scripts/quickstart.sh redis rabbitmq
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- all
fi

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
}

default_storage_class() {
  awk '
    $1 == "defaultStorageClass:" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "$ROOT_DIR/envs/$ENVIRONMENT/global.yaml"
}

ensure_namespace() {
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace exists: $NAMESPACE"
  else
    kubectl create namespace "$NAMESPACE"
  fi
}

ensure_storage_class() {
  local storage_class="${STORAGE_CLASS:-$(default_storage_class)}"
  if [[ -z "$storage_class" ]]; then
    echo "No StorageClass specified; Kubernetes default StorageClass will be used."
    return 0
  fi

  if kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
    echo "StorageClass exists: $storage_class"
  else
    echo "StorageClass not found: $storage_class" >&2
    echo "Run 'kubectl get storageclass' and set STORAGE_CLASS to an existing one." >&2
    exit 1
  fi
}

ensure_pull_secret() {
  if [[ "$CREATE_IMAGE_PULL_SECRET" == "false" ]]; then
    return 0
  fi

  if [[ "$CREATE_IMAGE_PULL_SECRET" == "auto" && ( -z "${ALIYUN_USERNAME:-}" || -z "${ALIYUN_PASSWORD:-}" ) ]]; then
    if kubectl -n "$NAMESPACE" get secret "$IMAGE_PULL_SECRET" >/dev/null 2>&1; then
      echo "Image pull secret exists: $IMAGE_PULL_SECRET"
      return 0
    fi
    echo "Image pull secret not created because ALIYUN_USERNAME/ALIYUN_PASSWORD are not set."
    echo "If your registry is private, set credentials or create secret '$IMAGE_PULL_SECRET' manually."
    return 0
  fi

  if [[ -z "${ALIYUN_USERNAME:-}" || -z "${ALIYUN_PASSWORD:-}" ]]; then
    echo "ALIYUN_USERNAME and ALIYUN_PASSWORD are required to create pull secret." >&2
    exit 1
  fi

  kubectl -n "$NAMESPACE" create secret docker-registry "$IMAGE_PULL_SECRET" \
    --docker-server="$ALIYUN_REGISTRY" \
    --docker-username="$ALIYUN_USERNAME" \
    --docker-password="$ALIYUN_PASSWORD" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
}

require_command helm
require_command kubectl

if [[ ! -d "$ROOT_DIR/envs/$ENVIRONMENT" ]]; then
  echo "Environment not found: $ROOT_DIR/envs/$ENVIRONMENT" >&2
  exit 1
fi

ensure_namespace
ensure_storage_class
ensure_pull_secret

ENVIRONMENT="$ENVIRONMENT" \
NAMESPACE="$NAMESPACE" \
STORAGE_CLASS="$STORAGE_CLASS" \
MIRROR_IMAGES="$MIRROR_IMAGES" \
"$ROOT_DIR/scripts/deploy.sh" "$@"

