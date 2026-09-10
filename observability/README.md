# Observability — End-to-End Execution Guide

> **Project 3** | Builds on Project 1 (aws-eks-migration) + Project 2 (argocd-multicluster)
> Stack: OpenTelemetry SDK · OTel Collector · Grafana Tempo · Loki · Prometheus · SLOs

---

## What Changes Compared to Projects 1 + 2

| Component | Project 1 | Project 3 (this) |
|---|---|---|
| `app/src/index.js` | prom-client metrics, console logs | + OTel SDK, structured JSON logs with traceId |
| Prometheus | basic metrics, alert rules | + SLO recording rules, exemplar storage, Tempo datasource |
| Loki | container stdout only | + JSON parsing, traceId index, derived field → Tempo |
| Grafana | request rate dashboard | + correlated Tempo + Loki datasources, SLO dashboard |
| NEW: OTel Collector | — | DaemonSet — central telemetry pipeline |
| NEW: Grafana Tempo | — | Distributed tracing backend (S3 storage) |
| NEW: SLO alerts | raw error rate | Multi-window burn rate (Google SRE model) |

---

## Prerequisites

```bash
# From Project 1: EKS cluster running with myapp deployed
# From Project 2: ArgoCD managing the cluster (optional — can deploy manually)
kubectl get pods -n myapp
# Expected: api pods Running

# Create S3 buckets for Tempo + Loki trace/log storage
aws s3 mb s3://myapp-tempo-traces --region us-east-1
aws s3 mb s3://myapp-loki-logs   --region us-east-1
```

---

## Step 1 — Update the App (add OTel instrumentation)

```bash
# Replace app/src/index.js with the instrumented version
# (this project's app/src/index.js has OTel SDK added)

# Key changes from Project 1:
#   Line 1:  require('./otel/otel')    ← MUST be first
#   Logger:  winston JSON with traceId injection
#   Spans:   manual custom spans on /api/items/:id
#   Errors:  span.recordException() + SpanStatusCode.ERROR

# Update the Deployment env var to point to OTel Collector
kubectl set env deployment/api \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317 \
  OTEL_SERVICE_NAME=myapp-api \
  OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production" \
  K8S_POD_NAME="$(kubectl get pod -l app=api -n myapp -o jsonpath='{.items[0].metadata.name}')" \
  K8S_NAMESPACE=myapp \
  -n myapp

# Rebuild and redeploy the image with OTel SDK
cd app
docker build -t myapp/api:v2.0.0-otel .
# Push to ECR and trigger ArgoCD sync (or helm upgrade)
```

---

## Step 2 — Install Observability Stack

```bash
chmod +x scripts/install.sh scripts/generate-load.sh scripts/verify-traces.sh

# Install everything (Tempo + Loki + OTel Collector + update Prometheus)
./scripts/install.sh myapp-prod

# Verify all pods are running
kubectl get pods -n observability
kubectl get pods -n monitoring | grep -E "prometheus|grafana"
```

---

## Step 3 — Generate Traffic (produce traces)

```bash
# Generate 5 min of load to populate Tempo + Loki + Prometheus
./scripts/generate-load.sh https://api.myapp.com 300

# Watch OTel Collector receiving spans in real-time
kubectl logs -l app=otel-collector -n observability -f | grep -i span
```

---

## Step 4 — Verify Pipeline End-to-End

```bash
./scripts/verify-traces.sh https://api.myapp.com

# Expected output:
#   ✅ OTel Collector running
#   ✅ Tempo ready
#   ✅ Loki ready
#   ✅ Traces flowing: 47
#   ✅ Logs flowing: 312
#   ✅ SLO metric: 0.9987
```

---

## Step 5 — Open Grafana and Verify Correlated View

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open: http://localhost:3000  (admin / prom-operator)
```

**What to check in Grafana:**

```
1. Explore → Datasource: Tempo
   → Search: service.name = myapp-api
   → Should see traces with spans: HTTP · Redis · Postgres

2. Click any trace → expand spans
   → Click "Logs for this span"
   → Loki opens with {traceId="abc123"} — shows exact log lines

3. Explore → Datasource: Loki
   → Query: {app="api"} | json
   → Expand a log line
   → Click the blue "TraceID" link
   → Tempo opens with that trace

4. Explore → Datasource: Prometheus
   → Query: rate(http_requests_total[5m])
   → Toggle "Exemplars" ON
   → Dots appear on the chart — click one
   → TraceID popup → click → Tempo trace

5. Dashboards → MyApp Observability
   → SLO panel: success rate %, error budget remaining
   → Latency panel: p50 / p95 / p99
   → Top slow spans: which DB queries are slowest
```

---

## Step 6 — Apply SLO Alert Rules

```bash
kubectl apply -f alerts/slo-rules.yaml

# Verify rules loaded
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &>/dev/null &
sleep 2
curl -sf 'http://localhost:9090/api/v1/rules' | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
for group in d.get('data',{}).get('groups',[]):
  if 'slo' in group['name'].lower():
    print(f'Group: {group[\"name\"]}')
    for rule in group['rules']:
      print(f'  {rule[\"type\"]}: {rule[\"name\"]}')
"
# Expected:
#   Group: myapp.slo.recording
#     recording: job:http_requests_success:rate5m
#     recording: job:slo_error_budget_remaining:ratio
#   Group: myapp.slo.alerts
#     alerting: SLOBurnRateCritical
#     alerting: SLOBurnRateHigh
```

---

## Step 7 — Link to ArgoCD (Project 2 integration)

```bash
# Add observability stack as an ArgoCD-managed addon
# ArgoCD will deploy + keep it in sync across all clusters

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-stack
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-deployed.slack: "#platform"
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/myapp
    targetRevision: main
    path: observability/kubernetes/base
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF

# ArgoCD now manages the observability stack as GitOps
argocd app get observability-stack
```

---

## Step 8 — Extend Canary Analysis (Project 2 integration)

```bash
# Update Project 2's AnalysisTemplate to use SLO metrics instead of raw error rate
# This is more meaningful — you're checking error budget burn, not just error count

cat > /tmp/slo-analysis.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: slo-burn-rate
  namespace: myapp-prod
spec:
  metrics:
    - name: slo-burn-rate-ok
      interval: 1m
      count: 5
      # Canary fails if SLO burn rate > 2x during rollout
      successCondition: result[0] >= (1 - 2 * (1 - 0.999))
      failureLimit: 1
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
          query: job:http_requests_success:rate5m
EOF

kubectl apply -f /tmp/slo-analysis.yaml

echo "✅ Canary rollout now checks SLO burn rate — not just raw error count"
```

---

## Key Commands Reference

```bash
# Watch traces arriving in Tempo
kubectl port-forward svc/tempo 3200:3100 -n observability
curl http://localhost:3200/api/search?tags=service.name%3Dmyapp-api

# Search traces by TraceQL (Tempo query language)
curl 'http://localhost:3200/api/search?q={span.http.route="/api/items" && duration>100ms}'

# Watch collector metrics
kubectl port-forward svc/otel-collector 8888:8888 -n observability
curl http://localhost:8888/metrics | grep -E "accepted|refused|failed"

# Query SLO metrics
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
curl 'http://localhost:9090/api/v1/query?query=job:slo_error_budget_remaining:ratio'

# Check alerts firing
kubectl get prometheusrule -n monitoring
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring
curl http://localhost:9093/api/v2/alerts | python3 -m json.tool

# Restart collector if it's stuck
kubectl rollout restart daemonset/otel-collector -n observability
```

---

## Cost of Running This Stack

| Component | Spec | Est. cost/month |
|---|---|---|
| Grafana Tempo | 1 pod + S3 traces | ~$5-15 (S3 costs) |
| Loki | 1 pod + S3 logs | ~$10-30 (S3 costs) |
| OTel Collector | DaemonSet (3 nodes) | ~$5 (small pods) |
| Prometheus extra storage | +50GB gp3 EBS | ~$5 |
| **Total added cost** | | **~$25-55/month** |

The observability stack adds only ~$25-55/month on top of your existing cluster cost. The value of finding a 3-second database query causing p95 degradation — in 30 seconds instead of 3 hours — is worth it.
