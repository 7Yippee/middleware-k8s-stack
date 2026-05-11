#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_LIST="${IMAGE_LIST:-$ROOT_DIR/config/images.txt}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-guangzhou.aliyuncs.com}"
ALIYUN_NAMESPACE="${ALIYUN_NAMESPACE:-tools_y}"
PLATFORM="${PLATFORM:-linux/amd64}"
CHECK_EXISTING="${CHECK_EXISTING:-true}"
DRY_RUN="${DRY_RUN:-false}"
COPY_MODE="${COPY_MODE:-auto}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-true}"

usage() {
  cat <<'EOF'
Usage:
  scripts/mirror-images.sh [all|kafka|redis|rabbitmq|zookeeper ...]

Environment:
  ALIYUN_REGISTRY    Target registry, default: registry.cn-guangzhou.aliyuncs.com
  ALIYUN_NAMESPACE   Target namespace, default: tools_y
  PLATFORM           Docker pull platform, default: linux/amd64
  CHECK_EXISTING     Skip target images that already exist, default: true
  DRY_RUN            Print actions only, default: false
  COPY_MODE          auto, remote, or pull-push. Default: auto
  CONTINUE_ON_ERROR  Continue after one image fails, default: true

Examples:
  scripts/mirror-images.sh all
  scripts/mirror-images.sh kafka redis
  ALIYUN_NAMESPACE=tools_y PLATFORM=linux/arm64 scripts/mirror-images.sh rabbitmq
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$IMAGE_LIST" ]]; then
  echo "Image list not found: $IMAGE_LIST" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required." >&2
  exit 1
fi

if [[ "$DRY_RUN" != "true" ]] && ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running. Start Docker Desktop first." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  set -- all
fi

contains_service() {
  local item="$1"
  shift
  for selected in "$@"; do
    [[ "$selected" == "all" || "$selected" == "$item" ]] && return 0
  done
  return 1
}

mirror_one() {
  local component="$1"
  local source_image="$2"
  local target_repository="$3"
  local target_tag="$4"
  local target_image="${ALIYUN_REGISTRY}/${ALIYUN_NAMESPACE}/${target_repository}:${target_tag}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "PLAN [$component] $source_image -> $target_image"
    return 0
  fi

  if [[ "$CHECK_EXISTING" == "true" ]] && docker manifest inspect "$target_image" >/dev/null 2>&1; then
    echo "SKIP existing: $target_image"
    return 0
  fi

  echo "MIRROR [$component] $source_image -> $target_image"

  if [[ "$COPY_MODE" == "remote" || "$COPY_MODE" == "auto" ]]; then
    if docker buildx version >/dev/null 2>&1; then
      if docker buildx imagetools create -t "$target_image" "$source_image"; then
        return 0
      fi
      [[ "$COPY_MODE" == "remote" ]] && return 1
      echo "Remote copy failed, falling back to docker pull/tag/push."
    elif [[ "$COPY_MODE" == "remote" ]]; then
      echo "docker buildx is required for COPY_MODE=remote." >&2
      return 1
    fi
  fi

  docker pull --platform "$PLATFORM" "$source_image"
  docker tag "$source_image" "$target_image"
  docker push "$target_image"
}

FAILED=0

while read -r component source_image target_repository target_tag _; do
  [[ -z "${component:-}" || "$component" == \#* ]] && continue
  if contains_service "$component" "$@"; then
    if ! mirror_one "$component" "$source_image" "$target_repository" "$target_tag"; then
      FAILED=1
      echo "FAILED [$component] $source_image" >&2
      [[ "$CONTINUE_ON_ERROR" == "true" ]] || exit 1
    fi
  fi
done < "$IMAGE_LIST"

if [[ "$FAILED" -eq 0 ]]; then
  echo "Image mirror completed."
else
  echo "Image mirror completed with failures. Re-run the same command to retry missing images." >&2
  exit 1
fi
