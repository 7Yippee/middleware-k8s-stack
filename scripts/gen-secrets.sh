#!/usr/bin/env bash
# Generate or rotate auth secrets for middleware components.
# Creates k8s Secrets that the Helm values reference via existingSecret.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-middleware}"
ROTATE="${ROTATE:-false}"
DRY_RUN="${DRY_RUN:-false}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-24}"

# Optional explicit overrides. When empty, a random value is generated.
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-}"
RABBITMQ_ERLANG_COOKIE="${RABBITMQ_ERLANG_COOKIE:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/gen-secrets.sh [rabbitmq|redis ...]

Creates (or rotates) Kubernetes Secrets consumed by the Helm releases:
  - Secret: rabbitmq-auth   (keys: rabbitmq-password, rabbitmq-erlang-cookie)
  - Secret: redis-auth      (keys: redis-password)

Environment:
  NAMESPACE           Target namespace. Default: middleware
  ROTATE              If true, overwrite existing secrets. Default: false
  DRY_RUN             Print manifests only. Default: false
  PASSWORD_LENGTH     Random password length. Default: 24
  RABBITMQ_PASSWORD   Override generated value
  RABBITMQ_ERLANG_COOKIE Override generated value
  REDIS_PASSWORD      Override generated value

Examples:
  scripts/gen-secrets.sh                  # create both, skip if exist
  ROTATE=true scripts/gen-secrets.sh      # rotate both
  scripts/gen-secrets.sh redis            # only redis
  DRY_RUN=true scripts/gen-secrets.sh     # preview manifests
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

require_command kubectl

TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(rabbitmq redis)

apply_secret() {
  local name="$1"; shift
  local kv_args=("$@")

  if [[ "$DRY_RUN" != "true" ]] && [[ "$ROTATE" != "true" ]] \
     && kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    log_info "SKIP   secret '$name' exists (set ROTATE=true to overwrite)"
    return 0
  fi

  local manifest
  manifest="$(kubectl -n "$NAMESPACE" create secret generic "$name" \
      "${kv_args[@]}" --dry-run=client -o yaml)"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '%s\n---\n' "$manifest"
    return 0
  fi

  printf '%s' "$manifest" | kubectl apply -f -
  log_ok "applied secret: $name"
}

ensure_namespace "$NAMESPACE"

for tgt in "${TARGETS[@]}"; do
  case "$tgt" in
    rabbitmq)
      pw="${RABBITMQ_PASSWORD:-$(gen_password "$PASSWORD_LENGTH")}"
      cookie="${RABBITMQ_ERLANG_COOKIE:-$(gen_password 32)}"
      apply_secret rabbitmq-auth \
        "--from-literal=rabbitmq-password=$pw" \
        "--from-literal=rabbitmq-erlang-cookie=$cookie"
      unset pw cookie
      ;;
    redis)
      pw="${REDIS_PASSWORD:-$(gen_password "$PASSWORD_LENGTH")}"
      apply_secret redis-auth \
        "--from-literal=redis-password=$pw"
      unset pw
      ;;
    *)
      log_error "Unknown target: $tgt (expected: rabbitmq|redis)"
      exit 1
      ;;
  esac
done

if [[ "$DRY_RUN" != "true" ]]; then
  log_ok "secrets ready in ns=$NAMESPACE"
  log_info "values already reference these via auth.existingSecret; run scripts/deploy.sh"
fi
