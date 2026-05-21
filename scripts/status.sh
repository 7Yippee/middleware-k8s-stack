#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-middleware}"
VERBOSE="${VERBOSE:-false}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/status.sh [-v|--verbose]

Environment:
  NAMESPACE   Kubernetes namespace. Default: middleware
  VERBOSE     true|false. Print events and describe for non-Ready pods. Default: false
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -v|--verbose) VERBOSE=true ;;
esac

require_command kubectl
require_command helm

printf '\n== helm releases (ns=%s) ==\n' "$NAMESPACE"
helm list -n "$NAMESPACE"

printf '\n== workloads (ns=%s) ==\n' "$NAMESPACE"
kubectl get pods,svc,pvc,statefulset -n "$NAMESPACE" -o wide || true

if command -v kubectl >/dev/null 2>&1; then
  if kubectl top pods -n "$NAMESPACE" >/dev/null 2>&1; then
    printf '\n== resource usage ==\n'
    kubectl top pods -n "$NAMESPACE" || true
  fi
fi

if [[ "$VERBOSE" == "true" ]]; then
  printf '\n== non-Ready pods ==\n'
  mapfile -t bad < <(kubectl get pods -n "$NAMESPACE" \
    -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  # Also flag Running pods where not all containers are Ready
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    bad+=("$pod")
  done < <(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
    | awk 'BEGIN{RS="},"} /"ready": *false/ {
        match($0, /"name":[ ]*"[^"]+"/);
        if (RSTART) { s=substr($0,RSTART,RLENGTH); sub(/.*"name":[ ]*"/,"",s); sub(/".*/,"",s); print s }
      }' 2>/dev/null | sort -u)

  if [[ ${#bad[@]} -eq 0 ]]; then
    log_ok "all pods are Ready"
  else
    for pod in "${bad[@]}"; do
      printf '\n--- describe pod/%s ---\n' "$pod"
      kubectl describe pod -n "$NAMESPACE" "$pod" | tail -n 40 || true
    done
    printf '\n== recent events ==\n'
    kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 30 || true
  fi
fi
