#!/usr/bin/env bash
# =============================================================
# rollback.sh — Emergency rollback: redeploy previous Helm release
# =============================================================
set -euo pipefail

NAMESPACE="myapp"
RELEASE="myapp"
REVISION="${1:-}"   # pass specific revision or leave empty for previous

echo "=== Rolling back $RELEASE in $NAMESPACE ==="

if [[ -n "$REVISION" ]]; then
  helm rollback "$RELEASE" "$REVISION" --namespace "$NAMESPACE" --wait
else
  echo "Available revisions:"
  helm history "$RELEASE" --namespace "$NAMESPACE"
  echo ""
  echo "Rolling back to previous revision..."
  helm rollback "$RELEASE" --namespace "$NAMESPACE" --wait
fi

echo ""
echo "=== Current pod status ==="
kubectl get pods -n "$NAMESPACE"

echo ""
echo "=== Deployment history ==="
kubectl rollout history deployment/myapp-myapp -n "$NAMESPACE"
