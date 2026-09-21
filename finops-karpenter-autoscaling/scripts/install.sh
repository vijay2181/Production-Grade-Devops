#!/usr/bin/env bash
# =============================================================
# scripts/install.sh — Deploy Complete FinOps & Karpenter Stack
#
# Sequence:
#   1. Validate cluster context and AWS IAM prerequisites
#   2. Install Karpenter Controller v1.0+ via Helm
#   3. Apply Karpenter EC2NodeClass and 3-Tier NodePools
#   4. Install KEDA v2.14+ Operator & apply ScaledObjects
#   5. Install OpenCost & apply FinOps Prometheus Alert Rules
# =============================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-myapp-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
KARPENTER_VERSION="1.0.1"
KEDA_VERSION="2.14.0"

log() { echo -e "\033[1;34m[$(date -u +%H:%M:%S)]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[$(date -u +%H:%M:%S)] ✅\033[0m $*"; }
die() { echo -e "\033[1;31m[$(date -u +%H:%M:%S)] ❌ ERROR:\033[0m $*" >&2; exit 1; }

log "=== Deploying FinOps & Intelligent Autoscaling Stack on ${CLUSTER_NAME} ==="

# ── 1. Helm Repos ─────────────────────────────────────────────
log "[1/5] Updating Helm Repositories..."
helm repo add karpenter https://charts.karpenter.sh 2>/dev/null || true
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo add opencost https://opencost.github.io/opencost-helm-chart 2>/dev/null || true
helm repo update

# ── 2. Deploy Karpenter v1.0+ ─────────────────────────────────
log "[2/5] Installing Karpenter v1.0+ Controller..."
helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version "${KARPENTER_VERSION}" \
  --values helm/values/karpenter-values.yaml \
  --wait \
  --timeout 5m
ok "Karpenter Controller is Running"

log "Applying EC2NodeClass and 3-Tier NodePools..."
kubectl apply -f karpenter/nodepools/01-ec2nodeclass.yaml
kubectl apply -f karpenter/nodepools/02-nodepool-critical-ondemand.yaml
kubectl apply -f karpenter/nodepools/03-nodepool-general-spot.yaml
kubectl apply -f karpenter/nodepools/04-nodepool-ci-ephemeral.yaml
ok "Karpenter NodePools established"

# ── 3. Deploy KEDA Event-Driven Autoscaler ─────────────────────
log "[3/5] Installing KEDA v2.14+ Operator..."
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version "${KEDA_VERSION}" \
  --set watchNamespace="" \
  --wait \
  --timeout 5m
ok "KEDA Operator is Running"

log "Applying Production KEDA ScaledObjects..."
kubectl apply -f keda/scaledobjects/01-sqs-queue-scaler.yaml
kubectl apply -f keda/scaledobjects/02-prometheus-http-scaler.yaml
kubectl apply -f keda/scaledobjects/03-redis-queue-scaler.yaml
ok "KEDA ScaledObjects configured (SQS, Prometheus RPS, Redis)"

# ── 4. Deploy OpenCost FinOps Engine ──────────────────────────
log "[4/5] Installing OpenCost Engine..."
helm upgrade --install opencost opencost/opencost \
  --namespace opencost \
  --create-namespace \
  --values opencost/install.yaml \
  --wait \
  --timeout 5m
ok "OpenCost Cost Exporter is Running"

# ── 5. Apply Prometheus FinOps Alert Rules ────────────────────
log "[5/5] Deploying Prometheus FinOps Alert Rules..."
kubectl apply -f alerts/finops-prometheus-rules.yaml
ok "Prometheus FinOps Rules active"

echo ""
ok "=== Project 6: FinOps & Karpenter Stack Successfully Deployed ==="
echo ""
echo "Verify status:"
echo "  kubectl get nodepools.karpenter.sh"
echo "  kubectl get scaledobjects -n myapp-prod"
echo "  kubectl get pods -n opencost"
echo ""
echo "Run test suite:"
echo "  ./scripts/test-spot-drain.sh"
