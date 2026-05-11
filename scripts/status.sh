#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-middleware}"

helm list -n "$NAMESPACE"
kubectl get pods,svc,pvc -n "$NAMESPACE"

