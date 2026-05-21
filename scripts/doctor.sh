#!/usr/bin/env bash
# Pre-flight health check for a target Kubernetes cluster + local tools.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-middleware}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-aliyun-registry}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-guangzhou.aliyuncs.com}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/doctor.sh

Environment:
  NAMESPACE           Namespace to check (default: middleware)
  ENVIRONMENT         Values environment (default: dev)
  IMAGE_PULL_SECRET   Secret name to verify (default: aliyun-registry)
  ALIYUN_REGISTRY     Registry to resolve (default: registry.cn-guangzhou.aliyuncs.com)
USAGE
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

FAILED=0
pass() { log_ok   "$*"; }
fail() { log_error "$*"; FAILED=1; }
warn() { log_warn "$*"; }

printf '\n== local tools ==\n'
for cmd in kubectl helm; do
  if command -v "$cmd" >/dev/null; then pass "$cmd: $(command -v "$cmd")"; else fail "$cmd not found"; fi
done
for cmd in docker skopeo crane; do
  if command -v "$cmd" >/dev/null; then pass "$cmd: $(command -v "$cmd")"; else warn "$cmd not found (optional)"; fi
done

printf '\n== cluster ==\n'
if kubectl cluster-info >/dev/null 2>&1; then
  pass "kubectl can reach cluster"
  kubectl version --short 2>/dev/null || kubectl version 2>/dev/null | head -n 4 || true
else
  fail "kubectl cannot reach cluster (check kubeconfig)"
fi

printf '\n== nodes ==\n'
if kubectl get nodes >/dev/null 2>&1; then
  kubectl get nodes -o wide
  ARCHES=$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}' | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
  log_info "node architectures: $ARCHES"
else
  fail "cannot list nodes"
fi

printf '\n== storage classes ==\n'
if kubectl get storageclass >/dev/null 2>&1; then
  kubectl get storageclass
  DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
  if [[ -n "$DEFAULT_SC" ]]; then pass "default StorageClass: $DEFAULT_SC"; else warn "no default StorageClass"; fi
else
  fail "cannot list StorageClasses"
fi

printf '\n== namespace %s ==\n' "$NAMESPACE"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  pass "namespace exists"
else
  warn "namespace does not exist (will be created on deploy)"
fi

printf '\n== image pull secret ==\n'
if kubectl -n "$NAMESPACE" get secret "$IMAGE_PULL_SECRET" >/dev/null 2>&1; then
  pass "pull secret '$IMAGE_PULL_SECRET' exists in ns=$NAMESPACE"
else
  warn "pull secret '$IMAGE_PULL_SECRET' not found; pods may fail to pull private images"
fi

printf '\n== registry reachability ==\n'
if command -v curl >/dev/null; then
  if curl -sSf -m 5 "https://$ALIYUN_REGISTRY/v2/" -o /dev/null; then
    pass "registry $ALIYUN_REGISTRY reachable"
  elif curl -sS -m 5 "https://$ALIYUN_REGISTRY/v2/" -o /dev/null; then
    pass "registry $ALIYUN_REGISTRY reachable (auth required)"
  else
    warn "cannot reach $ALIYUN_REGISTRY over HTTPS"
  fi
else
  warn "curl not found, skip registry check"
fi

printf '\n== values files ==\n'
if [[ -d "$ROOT_DIR/envs/$ENVIRONMENT" ]]; then
  pass "envs/$ENVIRONMENT exists"
  for svc in $(list_components); do
    f="$ROOT_DIR/envs/$ENVIRONMENT/$svc.yaml"
    if [[ -f "$f" ]]; then pass "  $svc.yaml"; else fail "  missing: $f"; fi
  done
else
  fail "envs/$ENVIRONMENT not found"
fi

printf '\n== summary ==\n'
if [[ $FAILED -eq 0 ]]; then
  log_ok "doctor: ready to deploy"
else
  log_error "doctor: fix the issues above before deploying"
  exit 1
fi
