#!/usr/bin/env bash
# Mirror container images declared in config/images.txt.
#
# Supported backends (BACKEND env):
#   auto    - detect skopeo > crane > docker buildx imagetools > docker pull/push
#   skopeo  - skopeo copy (no docker daemon required)
#   crane   - go-containerregistry crane (fast, multi-arch)
#   docker  - docker buildx imagetools create with fallback to pull/tag/push
#
# Offline modes:
#   EXPORT_DIR=./offline-bundle    Save images as OCI layouts, no push.
#   IMPORT_FROM=./offline-bundle   Load images from offline dir and push to target.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

IMAGE_LIST="${IMAGE_LIST:-$ROOT_DIR/config/images.txt}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-guangzhou.aliyuncs.com}"
ALIYUN_NAMESPACE="${ALIYUN_NAMESPACE:-tools_y}"
PLATFORM="${PLATFORM:-linux/amd64}"
CHECK_EXISTING="${CHECK_EXISTING:-true}"
DRY_RUN="${DRY_RUN:-false}"
BACKEND="${BACKEND:-auto}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-true}"
EXPORT_DIR="${EXPORT_DIR:-}"
IMPORT_FROM="${IMPORT_FROM:-}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/mirror-images.sh [all|<component> ...|shared]

When a specific component is given, 'shared' images are included automatically.

Environment:
  ALIYUN_REGISTRY    Target registry. Default: registry.cn-guangzhou.aliyuncs.com
  ALIYUN_NAMESPACE   Target namespace. Default: tools_y
  PLATFORM           Pull platform when using docker backend. Default: linux/amd64
  CHECK_EXISTING     Skip target images that already exist. Default: true
  DRY_RUN            Print actions only. Default: false
  BACKEND            auto|skopeo|crane|docker. Default: auto
  CONTINUE_ON_ERROR  Continue after one image fails. Default: true
  EXPORT_DIR         Save images to this dir instead of pushing (offline bundle)
  IMPORT_FROM        Push from a previously-exported bundle directory

Examples:
  scripts/mirror-images.sh all
  scripts/mirror-images.sh kafka redis
  BACKEND=skopeo scripts/mirror-images.sh all
  EXPORT_DIR=./offline-bundle scripts/mirror-images.sh all
  IMPORT_FROM=./offline-bundle scripts/mirror-images.sh all
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

if [[ ! -f "$IMAGE_LIST" ]]; then
  log_error "Image list not found: $IMAGE_LIST"
  exit 1
fi

# Resolve effective backend.
resolve_backend() {
  if [[ -n "$EXPORT_DIR" || -n "$IMPORT_FROM" ]]; then
    # Offline modes prefer skopeo, then crane.
    if command -v skopeo >/dev/null; then echo skopeo; return; fi
    if command -v crane  >/dev/null; then echo crane;  return; fi
    log_error "offline mode requires skopeo or crane"
    exit 1
  fi
  case "$BACKEND" in
    skopeo|crane|docker) echo "$BACKEND" ;;
    auto)
      if   command -v skopeo >/dev/null; then echo skopeo
      elif command -v crane  >/dev/null; then echo crane
      elif command -v docker >/dev/null; then echo docker
      else log_error "need one of: skopeo, crane, docker"; exit 1
      fi
      ;;
    *) log_error "unknown BACKEND: $BACKEND"; exit 1 ;;
  esac
}
EFFECTIVE_BACKEND="$(resolve_backend)"
log_info "backend: $EFFECTIVE_BACKEND${EXPORT_DIR:+  export=$EXPORT_DIR}${IMPORT_FROM:+  import=$IMPORT_FROM}"

case "$EFFECTIVE_BACKEND" in
  skopeo) require_command skopeo ;;
  crane)  require_command crane  ;;
  docker) require_command docker ;;
esac

if [[ "$EFFECTIVE_BACKEND" == "docker" && "$DRY_RUN" != "true" && -z "$IMPORT_FROM" ]]; then
  if ! docker info >/dev/null 2>&1; then
    log_error "docker daemon not reachable"
    exit 1
  fi
fi

[[ $# -eq 0 ]] && set -- all

# Which buckets are selected. "shared" always gets included when components are picked.
declare -a SELECTED=()
for arg in "$@"; do
  case "$arg" in
    all) SELECTED=(all); break ;;
    shared) SELECTED+=(shared) ;;
    *)
      if is_valid_component "$arg"; then
        SELECTED+=("$arg")
      else
        log_error "Unknown component: $arg"; exit 1
      fi
      ;;
  esac
done
if [[ ${#SELECTED[@]} -gt 0 && "${SELECTED[0]}" != "all" ]]; then
  has_shared=0
  for s in "${SELECTED[@]}"; do [[ "$s" == "shared" ]] && has_shared=1; done
  [[ $has_shared -eq 0 ]] && SELECTED+=(shared)
fi

contains_bucket() {
  local item="$1" s
  for s in "${SELECTED[@]}"; do
    [[ "$s" == "all" || "$s" == "$item" ]] && return 0
  done
  return 1
}

# ---- target existence check ------------------------------------------------
target_exists() {
  local target="$1"
  case "$EFFECTIVE_BACKEND" in
    skopeo) skopeo inspect "docker://$target" >/dev/null 2>&1 ;;
    crane)  crane manifest "$target" >/dev/null 2>&1 ;;
    docker) docker manifest inspect "$target" >/dev/null 2>&1 ;;
  esac
}

# ---- copy primitives -------------------------------------------------------
# target_slug converts registry/ns/name:tag to a filesystem-safe dir name.
target_slug() { printf '%s' "$1" | tr '/:' '__'; }

copy_remote() {
  local source="$1" target="$2"
  case "$EFFECTIVE_BACKEND" in
    skopeo)
      skopeo copy --all "docker://$source" "docker://$target"
      ;;
    crane)
      crane copy "$source" "$target"
      ;;
    docker)
      if docker buildx version >/dev/null 2>&1 \
         && docker buildx imagetools create -t "$target" "$source"; then
        return 0
      fi
      log_warn "buildx remote copy failed, falling back to docker pull/tag/push"
      docker pull --platform "$PLATFORM" "$source"
      docker tag  "$source" "$target"
      docker push "$target"
      ;;
  esac
}

copy_to_bundle() {
  local source="$1" target="$2" bundle="$3"
  local slug; slug="$(target_slug "$target")"
  local dst="$bundle/$slug"
  mkdir -p "$dst"
  case "$EFFECTIVE_BACKEND" in
    skopeo) skopeo copy --all "docker://$source" "oci:$dst:$target" ;;
    crane)  crane pull "$source" "$dst/image.tar" ;;
  esac
  printf '%s %s\n' "$slug" "$target" >> "$bundle/manifest.txt"
}

copy_from_bundle() {
  local target="$1" bundle="$2"
  local slug; slug="$(target_slug "$target")"
  local src="$bundle/$slug"
  if [[ ! -d "$src" && ! -f "$src/image.tar" ]]; then
    log_error "bundle entry missing for $target (looked in $src)"
    return 1
  fi
  case "$EFFECTIVE_BACKEND" in
    skopeo) skopeo copy --all "oci:$src:$target" "docker://$target" ;;
    crane)  crane push "$src/image.tar" "$target" ;;
  esac
}

# ---- main ------------------------------------------------------------------
mirror_one() {
  local bucket="$1" source_image="$2" target_repository="$3" target_tag="$4"
  local target="$ALIYUN_REGISTRY/$ALIYUN_NAMESPACE/$target_repository:$target_tag"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "PLAN   [$bucket] $source_image -> $target"
    return 0
  fi

  if [[ -n "$EXPORT_DIR" ]]; then
    log_info "EXPORT [$bucket] $source_image -> $EXPORT_DIR/$(target_slug "$target")"
    copy_to_bundle "$source_image" "$target" "$EXPORT_DIR"
    return $?
  fi

  if [[ -n "$IMPORT_FROM" ]]; then
    if [[ "$CHECK_EXISTING" == "true" ]] && target_exists "$target"; then
      log_info "SKIP   [$bucket] existing $target"
      return 0
    fi
    log_info "IMPORT [$bucket] bundle -> $target"
    copy_from_bundle "$target" "$IMPORT_FROM"
    return $?
  fi

  if [[ "$CHECK_EXISTING" == "true" ]] && target_exists "$target"; then
    log_info "SKIP   [$bucket] existing $target"
    return 0
  fi

  log_info "MIRROR [$bucket] $source_image -> $target"
  copy_remote "$source_image" "$target"
}

[[ -n "$EXPORT_DIR" ]] && mkdir -p "$EXPORT_DIR" && : > "$EXPORT_DIR/manifest.txt"

FAILED=0
while read -r bucket source_image target_repository target_tag _; do
  [[ -z "${bucket:-}" || "$bucket" == \#* ]] && continue
  if contains_bucket "$bucket"; then
    if ! mirror_one "$bucket" "$source_image" "$target_repository" "$target_tag"; then
      FAILED=1
      log_error "FAILED [$bucket] $source_image"
      [[ "$CONTINUE_ON_ERROR" == "true" ]] || exit 1
    fi
  fi
done < "$IMAGE_LIST"

if [[ "$FAILED" -eq 0 ]]; then
  log_ok "image mirror completed."
  if [[ -n "$EXPORT_DIR" ]]; then
    log_info "bundle ready: $EXPORT_DIR"
  fi
  exit 0
else
  log_error "image mirror completed with failures. Re-run to retry."
  exit 1
fi
