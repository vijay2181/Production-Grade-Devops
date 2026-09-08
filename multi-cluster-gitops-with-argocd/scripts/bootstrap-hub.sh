#!/usr/bin/env bash
# =============================================================
# bootstrap-hub.sh — Full hub cluster bootstrap
# Run after terraform apply on hub cluster.
# =============================================================
set -euo pipefail

AWS_REGION="${1:-us-east-1}"
HUB_CLUSTER_NAME="${2:-myapp-hub}"

echo "=== Bootstrapping ArgoCD hub cluster ==="

# ── 1. Update kubeconfig ──────────────────────────────────────────
aws eks update-kubeconfig --region ${AWS_REGION} --name ${HUB_CLUSTER_NAME}
kubectl config rename-context \
  "arn:aws:eks:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/${HUB_CLUSTER_NAME}" \
  myapp-hub 2>/dev/null || true

# ── 2. Update kubeconfigs for spoke clusters ──────────────────────
for ENV in dev staging prod; do
  aws eks update-kubeconfig \
    --region ${AWS_REGION} \
    --name "myapp-${ENV}" 2>/dev/null && \
  kubectl config rename-context \
    "arn:aws:eks:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/myapp-${ENV}" \
    "myapp-${ENV}" 2>/dev/null || \
  echo "  ℹ️  myapp-${ENV} cluster not found — skipping"
done

# ── 3. Switch to hub ──────────────────────────────────────────────
kubectl config use-context myapp-hub

# ── 4. Install ArgoCD ─────────────────────────────────────────────
bash argocd/hub/install-argocd.sh

# ── 5. Register spoke clusters ────────────────────────────────────
bash scripts/register-clusters.sh

echo ""
echo "=== Hub bootstrap complete ==="
echo ""
echo "ArgoCD UI: kubectl port-forward svc/argocd-server 8080:443 -n argocd"
echo "Watch apps: kubectl get applications -n argocd -w"
