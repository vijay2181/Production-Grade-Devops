#!/usr/bin/env bash
# =============================================================
# register-clusters.sh — Register spoke clusters into ArgoCD hub
#
# Run AFTER:
#   1. Hub cluster is up + ArgoCD installed
#   2. All spoke clusters (dev, staging, prod) are up
#   3. kubectl contexts are configured for all clusters
#
# Usage: ./scripts/register-clusters.sh
# =============================================================
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-myapp-hub}"
DEV_CONTEXT="${DEV_CONTEXT:-myapp-dev}"
STAGING_CONTEXT="${STAGING_CONTEXT:-myapp-staging}"
PROD_CONTEXT="${PROD_CONTEXT:-myapp-prod}"
ARGOCD_SERVER="${ARGOCD_SERVER:-localhost:8080}"

echo "=== Registering spoke clusters into ArgoCD hub ==="

# ── 1. Switch to hub context ──────────────────────────────────────
kubectl config use-context ${HUB_CONTEXT}

# ── 2. Port-forward ArgoCD (if not exposed via ingress) ───────────
kubectl port-forward svc/argocd-server 8080:443 -n argocd &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null" EXIT

# ── 3. Login to ArgoCD CLI ────────────────────────────────────────
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' | base64 -d)

argocd login ${ARGOCD_SERVER} \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --insecure

echo "✅ Logged into ArgoCD"

# ── 4. Register each spoke cluster ────────────────────────────────
for CONTEXT in "${DEV_CONTEXT}" "${STAGING_CONTEXT}" "${PROD_CONTEXT}"; do
  echo ""
  echo "[*] Registering cluster: ${CONTEXT}"

  argocd cluster add "${CONTEXT}" \
    --name "${CONTEXT}" \
    --yes 2>/dev/null && echo "  ✅ ${CONTEXT} registered" || \
  echo "  ℹ️  ${CONTEXT} already registered — skipping"
done

# ── 5. Verify all clusters are connected ─────────────────────────
echo ""
echo "=== Registered clusters ==="
argocd cluster list

# ── 6. Apply AppProject ───────────────────────────────────────────
echo ""
echo "=== Applying AppProject ==="
kubectl apply -f argocd/projects/myapp-project.yaml -n argocd

# ── 7. Bootstrap App of Apps ──────────────────────────────────────
echo ""
echo "=== Bootstrapping App of Apps ==="
kubectl apply -f argocd/applicationsets/app-of-apps.yaml -n argocd

echo ""
echo "=== Done! ArgoCD will now deploy all apps from Git ==="
echo "Watch: kubectl get applications -n argocd -w"
echo "UI:    https://localhost:8080"
