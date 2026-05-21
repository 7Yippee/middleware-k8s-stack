#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
NAMESPACE="${NAMESPACE:-middleware}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-aliyun-registry}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-guangzhou.aliyuncs.com}"
CREATE_IMAGE_PULL_SECRET="${CREATE_IMAGE_PULL_SECRET:-auto}"
MIRROR_IMAGES="${MIRROR_IMAGES:-false}"
GEN_SECRETS="${GEN_SECRETS:-false}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/quickstart.sh [all|<component> ...]

Environment:
  ENVIRONMENT                dev, prod. Default: dev
  NAMESPACE                  Kubernetes namespace. Default: middleware
  STORAGE_CLASS              StorageClass override. Optional
  MIRROR_IMAGES              Mirror images before deploy. Default: false
  GEN_SECRETS                Generate random auth secrets before deploy. Default: false
  CREATE_IMAGE_PULL_SECRET   auto|true|false. Default: auto
  IMAGE_PULL_SECRET          Pull secret name. Default: aliyun-registry
  ALIYUN_REGISTRY            Registry server. Default: registry.cn-guangzhou.aliyuncs.com
  ALIYUN_USERNAME            Required when creating pull secret
  ALIYUN_PASSWORD            Required when creating pull secret
                             Alternatively: ALIYUN_PASSWORD_FILE=/path/to/file

Examples:
  scripts/quickstart.sh all
  NAMESPACE=middleware-dev STORAGE_CLASS=local-path scripts/quickstart.sh all
  ENVIRONMENT=prod NAMESPACE=middleware-prod STORAGE_CLASS=huawei-sc scripts/quickstart.sh all
  GEN_SECRETS=true scripts/quickstart.sh all
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- all
fi

require_command helm
require_command kubectl

if [[ ! -d "$ROOT_DIR/envs/$ENVIRONMENT" ]]; then
  log_error "Environment not found: $ROOT_DIR/envs/$ENVIRONMENT"
  exit 1
fi

default_storage_class() {
  awk '
    $1 == "defaultStorageClass:" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "$ROOT_DIR/envs/$ENVIRONMENT/global.yaml"
}

ensure_storage_class() {
  local sc="${STORAGE_CLASS:-$(default_storage_class)}"
  if [[ -z "$sc" ]]; then
    log_warn "No StorageClass specified; Kubernetes default StorageClass will be used."
    return 0
  fi
  if kubectl get storageclass "$sc" >/dev/null 2>&1; then
    log_info "StorageClass exists: $sc"
  else
    log_error "StorageClass not found: $sc"
    log_error "Run 'kubectl get storageclass' and set STORAGE_CLASS to an existing one."
    exit 1
  fi
}

# Read password from env, file, or stdin. Echoes to stdout.
resolve_aliyun_password() {
  if [[ -n "${ALIYUN_PASSWORD:-}" ]]; then
    printf '%s' "$ALIYUN_PASSWORD"
    return 0
  fi
  if [[ -n "${ALIYUN_PASSWORD_FILE:-}" && -r "$ALIYUN_PASSWORD_FILE" ]]; then
    cat "$ALIYUN_PASSWORD_FILE"
    return 0
  fi
  return 1
}

ensure_pull_secret() {
  if [[ "$CREATE_IMAGE_PULL_SECRET" == "false" ]]; then
    return 0
  fi

  if kubectl -n "$NAMESPACE" get secret "$IMAGE_PULL_SECRET" >/dev/null 2>&1; then
    log_info "Image pull secret exists: $IMAGE_PULL_SECRET"
    return 0
  fi

  local password username="${ALIYUN_USERNAME:-}"
  if ! password="$(resolve_aliyun_password)"; then
    if [[ "$CREATE_IMAGE_PULL_SECRET" == "auto" ]]; then
      log_warn "Image pull secret not created (ALIYUN_USERNAME / ALIYUN_PASSWORD not set)."
      log_warn "If your registry is private, create secret '$IMAGE_PULL_SECRET' manually."
      return 0
    fi
    log_error "ALIYUN_USERNAME and ALIYUN_PASSWORD (or ALIYUN_PASSWORD_FILE) are required."
    exit 1
  fi

  if [[ -z "$username" ]]; then
    log_error "ALIYUN_USERNAME is required to create pull secret."
    exit 1
  fi

  log_info "creating image pull secret: $IMAGE_PULL_SECRET (ns=$NAMESPACE)"
  kubectl -n "$NAMESPACE" create secret docker-registry "$IMAGE_PULL_SECRET" \
    --docker-server="$ALIYUN_REGISTRY" \
    --docker-username="$username" \
    --docker-password="$password" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
  # Wipe variable immediately.
  password=""
}

ensure_namespace "$NAMESPACE"
ensure_storage_class
ensure_pull_secret

if [[ "$GEN_SECRETS" == "true" ]]; then
  NAMESPACE="$NAMESPACE" "$ROOT_DIR/scripts/gen-secrets.sh"
fi

ENVIRONMENT="$ENVIRONMENT" \
NAMESPACE="$NAMESPACE" \
STORAGE_CLASS="$STORAGE_CLASS" \
MIRROR_IMAGES="$MIRROR_IMAGES" \
"$ROOT_DIR/scripts/deploy.sh" "$@"
