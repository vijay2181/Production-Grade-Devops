#!/usr/bin/env bash
# =============================================================
# install.sh — Install full observability stack on EKS
# Installs: OTel Collector + Tempo + Loki + kube-prometheus-stack
#
# Connects to Projects 1 + 2:
#   - Extends Project 1's monitoring namespace
#   - Deployable via ArgoCD (Project 2) as a cluster addon
#
# Usage: ./scripts/install.sh [cluster-context]
# =============================================================
set -euo pipefail

CONTEXT="${1:-myapp-prod}"
kubectl config use-context "${CONTEXT}"

echo "=== Installing observability stack on ${CONTEXT} ==="

# ── Add Helm repos ────────────────────────────────────────────────
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry       https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# ── Create namespace ──────────────────────────────────────────────
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# ── Create S3 buckets for Tempo + Loki (Terraform manages this) ───
echo "[1/6] Verifying S3 buckets..."
aws s3 ls s3://myapp-tempo-traces 2>/dev/null || \
  aws s3 mb s3://myapp-tempo-traces --region us-east-1
aws s3 ls s3://myapp-loki-logs 2>/dev/null || \
  aws s3 mb s3://myapp-loki-logs --region us-east-1

# ── Install Grafana Tempo ──────────────────────────────────────────
echo "[2/6] Installing Grafana Tempo..."
helm upgrade --install tempo \
  grafana/tempo-distributed \
  --namespace observability \
  --values helm/values/tempo-values.yaml \
  --wait \
  --timeout 10m

# ── Install Loki + Promtail ────────────────────────────────────────
echo "[3/6] Installing Loki + Promtail..."
helm upgrade --install loki \
  grafana/loki-stack \
  --namespace observability \
  --values helm/values/loki-values.yaml \
  --wait \
  --timeout 10m

# ── Apply OTel Collector DaemonSet ────────────────────────────────
echo "[4/6] Deploying OTel Collector DaemonSet..."
# Merge collector config into ConfigMap
kubectl create configmap otel-collector-config \
  --from-file=config.yaml=kubernetes/base/collector/otel-collector-config.yaml \
  -n observability \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f kubernetes/base/collector/daemonset.yaml

# Wait for DaemonSet to be ready
kubectl rollout status daemonset/otel-collector -n observability --timeout=5m

# ── Install/upgrade kube-prometheus-stack ─────────────────────────
echo "[5/6] Upgrading kube-prometheus-stack with observability config..."
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values helm/values/prometheus-values.yaml \
  --wait \
  --timeout 10m

# ── Apply SLO rules ───────────────────────────────────────────────
kubectl apply -f alerts/slo-rules.yaml

# ── Apply Grafana dashboards ──────────────────────────────────────
echo "[6/6] Importing Grafana dashboards..."
kubectl create configmap observability-dashboards \
  --from-file=dashboards/ \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label configmap observability-dashboards \
  grafana_dashboard=1 \
  -n monitoring \
  --overwrite

echo ""
echo "=== Observability stack installed ==="
echo ""
echo "Port-forward Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo ""
echo "Port-forward Tempo (direct query):"
echo "  kubectl port-forward svc/tempo 3200:3100 -n observability"
echo ""
echo "Verify OTel Collector:"
echo "  kubectl logs -l app=otel-collector -n observability --tail=20"
