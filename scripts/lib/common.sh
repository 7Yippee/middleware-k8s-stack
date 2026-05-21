#!/usr/bin/env bash
# Common helpers shared across scripts.
# Source this file from any script: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -Eeuo pipefail

# ROOT_DIR must be set by the caller; fall back to two levels up from this file.
if [[ -z "${ROOT_DIR:-}" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

COMPONENTS_FILE="${COMPONENTS_FILE:-$ROOT_DIR/config/components.txt}"

# ---- logging ----------------------------------------------------------------

_is_tty() { [[ -t 1 ]]; }

if _is_tty; then
  _C_BLUE=$'\033[1;34m'; _C_YELLOW=$'\033[1;33m'; _C_RED=$'\033[1;31m'
  _C_GREEN=$'\033[1;32m'; _C_DIM=$'\033[2m'; _C_RESET=$'\033[0m'
else
  _C_BLUE=; _C_YELLOW=; _C_RED=; _C_GREEN=; _C_DIM=; _C_RESET=
fi

log_info()  { printf '%s[INFO]%s  %s\n'  "$_C_BLUE"   "$_C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n'  "$_C_RED"    "$_C_RESET" "$*" >&2; }
log_ok()    { printf '%s[OK]%s    %s\n'  "$_C_GREEN"  "$_C_RESET" "$*"; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && printf '%s[DEBUG]%s %s\n' "$_C_DIM" "$_C_RESET" "$*" >&2 || true; }

# ---- system helpers ---------------------------------------------------------

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    log_error "$name is required but not installed."
    exit 1
  fi
}

# Check a list of commands, return non-zero if any missing (no exit).
check_commands() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_warn "missing: $cmd"
      missing=1
    fi
  done
  return $missing
}

# ---- component registry (reads config/components.txt) ----------------------
# File format (whitespace separated, '#' comments allowed):
#   <component> <chart_name> <chart_version> [chart_registry]
# When chart_registry is omitted the caller's default CHART_REGISTRY applies.

list_components() {
  [[ -f "$COMPONENTS_FILE" ]] || { log_error "Components file not found: $COMPONENTS_FILE"; return 1; }
  awk '$1 !~ /^#/ && NF >= 3 { print $1 }' "$COMPONENTS_FILE"
}

component_chart() {
  local component="$1"
  awk -v c="$component" '$1 !~ /^#/ && $1 == c { print $2; exit }' "$COMPONENTS_FILE"
}

component_version() {
  local component="$1"
  awk -v c="$component" '$1 !~ /^#/ && $1 == c { print $3; exit }' "$COMPONENTS_FILE"
}

# Optional 4th column: per-component chart registry override. Empty if absent.
component_registry() {
  local component="$1"
  awk -v c="$component" '$1 !~ /^#/ && $1 == c { if (NF >= 4) print $4; exit }' "$COMPONENTS_FILE"
}

is_valid_component() {
  local component="$1"
  [[ -n "$(component_chart "$component")" ]]
}

# Expand "all" to the full component list in declaration order.
# Unknown args are reported and cause non-zero return.
expand_services() {
  local arg has_invalid=0
  for arg in "$@"; do
    if [[ "$arg" == "all" ]]; then
      list_components
    elif is_valid_component "$arg"; then
      printf '%s\n' "$arg"
    else
      log_error "Unknown component: $arg"
      has_invalid=1
    fi
  done
  return $has_invalid
}

# ---- k8s helpers ------------------------------------------------------------

ensure_namespace() {
  local ns="$1"
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    log_info "namespace exists: $ns"
  else
    log_info "creating namespace: $ns"
    kubectl create namespace "$ns"
  fi
}

# Generate a URL-safe random password.
gen_password() {
  local len="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=\n' | head -c "$len"
  else
    # fallback: tr from /dev/urandom
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
  fi
}
