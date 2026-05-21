#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
NAMESPACE="${NAMESPACE:-middleware}"
CHART_REGISTRY="${CHART_REGISTRY:-oci://registry-1.docker.io/bitnamicharts}"
CHARTS_DIR="${CHARTS_DIR:-$ROOT_DIR/charts}"
MIRROR_IMAGES="${MIRROR_IMAGES:-false}"
TIMEOUT="${TIMEOUT:-10m}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
USE_LOCAL_CHARTS="${USE_LOCAL_CHARTS:-auto}"
DRY_RUN="${DRY_RUN:-false}"
EXTRA_VALUES="${EXTRA_VALUES:-}"
HARDENING="${HARDENING:-auto}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy.sh [all|<component> ...]

Components are read from config/components.txt.

Environment:
  ENVIRONMENT        Values environment, default: dev
  NAMESPACE          Kubernetes namespace, default: middleware
  STORAGE_CLASS      Override global.defaultStorageClass for this deployment
  MIRROR_IMAGES      Run scripts/mirror-images.sh before deploy, default: false
  TIMEOUT            Helm wait timeout, default: 10m
  USE_LOCAL_CHARTS   auto|true|false. Default: auto
  CHARTS_DIR         Local chart cache directory, default: ./charts
  DRY_RUN            Only render manifests, do not apply. Default: false
  EXTRA_VALUES       Colon-separated extra values files, applied last.
  HARDENING          auto|on|off. Apply envs/<env>/_hardening.yaml when it exists.
                     Default: auto (applied for prod, skipped for dev)

Examples:
  scripts/deploy.sh all
  scripts/deploy.sh redis rabbitmq
  ENVIRONMENT=prod NAMESPACE=middleware-prod scripts/deploy.sh kafka
  NAMESPACE=middleware-dev STORAGE_CLASS=local-path scripts/deploy.sh all
  MIRROR_IMAGES=true scripts/deploy.sh all
  DRY_RUN=true scripts/deploy.sh all
  EXTRA_VALUES=envs/prod/rabbitmq.local.yaml scripts/deploy.sh rabbitmq
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  set -- all
fi

if [[ ! -d "$ROOT_DIR/envs/$ENVIRONMENT" ]]; then
  log_error "Environment not found: $ROOT_DIR/envs/$ENVIRONMENT"
  exit 1
fi

require_command helm

# Resolve chart location: prefer local tgz if USE_LOCAL_CHARTS allows.
resolve_chart() {
  local service="$1" version="$2" registry="$3"
  local local_path="$CHARTS_DIR/$service-$version.tgz"

  case "$USE_LOCAL_CHARTS" in
    true)
      if [[ -f "$local_path" ]]; then
        printf '%s' "$local_path"
      else
        log_error "USE_LOCAL_CHARTS=true but chart not found: $local_path"
        log_error "Run scripts/pull-charts.sh to download charts first."
        return 1
      fi
      ;;
    auto)
      if [[ -f "$local_path" ]]; then
        printf '%s' "$local_path"
      else
        printf '%s/%s' "$registry" "$(component_chart "$service")"
      fi
      ;;
    false|*)
      printf '%s/%s' "$registry" "$(component_chart "$service")"
      ;;
  esac
}

should_apply_hardening() {
  local file="$ROOT_DIR/envs/$ENVIRONMENT/_hardening.yaml"
  [[ -f "$file" ]] || return 1
  case "$HARDENING" in
    on)   return 0 ;;
    off)  return 1 ;;
    auto) [[ "$ENVIRONMENT" == "prod" ]] ;;
  esac
}

deploy_one() {
  local service="$1"
  local version registry chart_ref helm_args=()
  version="$(component_version "$service")"
  if [[ -z "$version" ]]; then
    log_error "No chart version configured for: $service"
    return 1
  fi
  registry="$(component_registry "$service")"
  [[ -z "$registry" ]] && registry="$CHART_REGISTRY"
  chart_ref="$(resolve_chart "$service" "$version" "$registry")" || return 1

  helm_args=(
    --version "$version"
    --namespace "$NAMESPACE"
    --create-namespace
    -f "$ROOT_DIR/envs/$ENVIRONMENT/global.yaml"
    -f "$ROOT_DIR/envs/$ENVIRONMENT/$service.yaml"
  )

  if should_apply_hardening; then
    helm_args+=(-f "$ROOT_DIR/envs/$ENVIRONMENT/_hardening.yaml")
    log_debug "applying hardening overlay for $service"
  fi

  # Local overrides (gitignored): envs/<env>/<service>.local.yaml
  local local_override="$ROOT_DIR/envs/$ENVIRONMENT/$service.local.yaml"
  if [[ -f "$local_override" ]]; then
    helm_args+=(-f "$local_override")
    log_info "using local override: envs/$ENVIRONMENT/$service.local.yaml"
  fi

  # Explicit extra values files (colon separated), applied last.
  if [[ -n "$EXTRA_VALUES" ]]; then
    local IFS=':'
    for f in $EXTRA_VALUES; do
      [[ -z "$f" ]] && continue
      helm_args+=(-f "$f")
    done
  fi

  if [[ -n "$STORAGE_CLASS" ]]; then
    helm_args+=(--set-string "global.defaultStorageClass=$STORAGE_CLASS")
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "DRY-RUN [$ENVIRONMENT/$NAMESPACE] $service chart=$version ref=$chart_ref"
    if helm template "$service" "$chart_ref" "${helm_args[@]}" >/dev/null; then
      log_ok "template rendered: $service"
      return 0
    fi
    return 1
  fi

  log_info "DEPLOY  [$ENVIRONMENT/$NAMESPACE] $service chart=$version ref=$chart_ref"
  if helm upgrade --install "$service" "$chart_ref" \
    --wait \
    --timeout "$TIMEOUT" \
    "${helm_args[@]}"; then
    return 0
  fi
  return 1
}

SERVICES=()
while IFS= read -r service; do
  SERVICES+=("$service")
done < <(expand_services "$@")

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  log_error "No services to deploy."
  exit 1
fi

if [[ "$MIRROR_IMAGES" == "true" ]]; then
  "$ROOT_DIR/scripts/mirror-images.sh" "${SERVICES[@]}"
fi

FAILED=()
for service in "${SERVICES[@]}"; do
  if ! deploy_one "$service"; then
    FAILED+=("$service")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  log_error "deploy failed for: ${FAILED[*]}"
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log_ok "Dry-run completed. No changes applied."
else
  log_ok "Deploy completed."
fi
