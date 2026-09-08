#!/usr/bin/env bash
# =============================================================
# promote-canary.sh — Manually promote or abort a canary rollout
#
# Usage:
#   ./scripts/promote-canary.sh promote   ← advance to next step
#   ./scripts/promote-canary.sh abort     ← rollback to stable
#   ./scripts/promote-canary.sh status    ← show current state
#
# Requires: kubectl-argo-rollouts plugin
#   brew install argoproj/tap/kubectl-argo-rollouts
# =============================================================
set -euo pipefail

ACTION="${1:-status}"
NAMESPACE="${NAMESPACE:-myapp-prod}"
ROLLOUT_NAME="${ROLLOUT_NAME:-myapp-api}"
PROD_CONTEXT="${PROD_CONTEXT:-myapp-prod}"

kubectl config use-context ${PROD_CONTEXT}

case "${ACTION}" in
  status)
    echo "=== Rollout status: ${ROLLOUT_NAME} ==="
    kubectl argo rollouts get rollout ${ROLLOUT_NAME} -n ${NAMESPACE} --watch=false
    echo ""
    echo "=== Current analysis runs ==="
    kubectl get analysisrun -n ${NAMESPACE}
    ;;

  promote)
    echo "=== Promoting canary: ${ROLLOUT_NAME} ==="
    kubectl argo rollouts promote ${ROLLOUT_NAME} -n ${NAMESPACE}
    echo ""
    echo "Watching rollout..."
    kubectl argo rollouts get rollout ${ROLLOUT_NAME} -n ${NAMESPACE} --watch
    ;;

  full-promote)
    echo "=== FULL promote (skip all remaining steps): ${ROLLOUT_NAME} ==="
    read -rp "Are you sure you want to skip analysis and fully promote? [y/N] " confirm
    [[ "${confirm}" == "y" ]] || { echo "Aborted."; exit 0; }
    kubectl argo rollouts promote ${ROLLOUT_NAME} -n ${NAMESPACE} --full
    kubectl argo rollouts get rollout ${ROLLOUT_NAME} -n ${NAMESPACE} --watch
    ;;

  abort)
    echo "=== ABORTING canary — rolling back to stable ==="
    kubectl argo rollouts abort ${ROLLOUT_NAME} -n ${NAMESPACE}
    echo ""
    echo "Watching rollback..."
    kubectl argo rollouts get rollout ${ROLLOUT_NAME} -n ${NAMESPACE} --watch
    ;;

  *)
    echo "Usage: $0 [status|promote|full-promote|abort]"
    exit 1
    ;;
esac
