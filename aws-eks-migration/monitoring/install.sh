# ============================================================
# Monitoring Stack Install Script
# Tools: Prometheus + Grafana + Loki + Alertmanager (kube-prometheus-stack)
# ============================================================

# ── 1. Add Helm repos ─────────────────────────────────────────────
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana               https://grafana.github.io/helm-charts
helm repo update

# ── 2. Create monitoring namespace ────────────────────────────────
kubectl create namespace monitoring

# ── 3. Install kube-prometheus-stack ──────────────────────────────
# (includes: Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics)
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values prometheus/values.yaml \
  --wait \
  --timeout 10m

# ── 4. Install Loki + Promtail ────────────────────────────────────
helm upgrade --install loki \
  grafana/loki-stack \
  --namespace monitoring \
  --values loki/values.yaml \
  --wait

# ── 5. Verify ─────────────────────────────────────────────────────
kubectl get pods -n monitoring
kubectl get svc  -n monitoring

# ── 6. Port-forward Grafana locally (dev access) ──────────────────
# kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Default credentials: admin / prom-operator
