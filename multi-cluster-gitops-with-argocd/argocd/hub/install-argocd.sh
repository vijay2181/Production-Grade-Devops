#!/usr/bin/env bash
# =============================================================
# install-argocd.sh — Install ArgoCD on hub cluster
# Run ONCE after hub EKS cluster is ready.
# Usage: ./argocd/hub/install-argocd.sh
# =============================================================
set -euo pipefail

ARGOCD_VERSION="v2.10.0"
ARGOCD_NAMESPACE="argocd"
ARGOCD_HOSTNAME="argocd.internal.myapp.com"

echo "=== Installing ArgoCD ${ARGOCD_VERSION} on hub cluster ==="

# ── 1. Namespace ──────────────────────────────────────────────────
kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# ── 2. Install ArgoCD ─────────────────────────────────────────────
kubectl apply -n ${ARGOCD_NAMESPACE} \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

# ── 3. Wait for ArgoCD pods ───────────────────────────────────────
echo "Waiting for ArgoCD pods..."
kubectl wait --for=condition=Ready pods --all \
  -n ${ARGOCD_NAMESPACE} \
  --timeout=300s

# ── 4. Apply custom config ────────────────────────────────────────
kubectl apply -f argocd/hub/argocd-cm.yaml
kubectl apply -f argocd/hub/argocd-rbac-cm.yaml

# ── 5. Install ArgoCD CLI ─────────────────────────────────────────
if ! command -v argocd &>/dev/null; then
  echo "Installing argocd CLI..."
  brew install argocd 2>/dev/null || \
  curl -sSL -o /usr/local/bin/argocd \
    https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64 && \
  chmod +x /usr/local/bin/argocd
fi

# ── 6. Install ArgoCD Image Updater ──────────────────────────────
echo "Installing ArgoCD Image Updater..."
kubectl apply -n ${ARGOCD_NAMESPACE} \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# ── 7. Install Argo Rollouts ──────────────────────────────────────
echo "Installing Argo Rollouts..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Install rollouts kubectl plugin
brew install argoproj/tap/kubectl-argo-rollouts 2>/dev/null || true

# ── 8. Get initial admin password ────────────────────────────────
echo ""
echo "=== ArgoCD installed successfully ==="
echo ""
ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n ${ARGOCD_NAMESPACE} \
  -o jsonpath='{.data.password}' | base64 -d)
echo "Admin password: ${ADMIN_PASSWORD}"
echo ""
echo "Port-forward to access UI:"
echo "  kubectl port-forward svc/argocd-server 8080:443 -n argocd"
echo "  Open: https://localhost:8080  (admin / ${ADMIN_PASSWORD})"
echo ""
echo "Next: run ./scripts/register-clusters.sh"
