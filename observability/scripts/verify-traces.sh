#!/usr/bin/env bash
# =============================================================
# verify-traces.sh — Verify traces are flowing end-to-end
# Tests: App → OTel Collector → Tempo → Grafana query
# =============================================================
set -euo pipefail

NAMESPACE="observability"
ENDPOINT="${1:-http://localhost:3000}"
TEMPO_PORT=3200

echo "=== Verifying observability pipeline ==="

# ── 1. OTel Collector is running ──────────────────────────────────
echo "[1/6] Checking OTel Collector..."
COLLECTOR_PODS=$(kubectl get pods -n ${NAMESPACE} -l app=otel-collector \
  --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
echo "  Running collector pods: ${COLLECTOR_PODS}"
[ "${COLLECTOR_PODS}" -gt "0" ] || { echo "❌ No collector pods running"; exit 1; }
echo "  ✅ OTel Collector running"

# ── 2. Collector is receiving data ────────────────────────────────
echo "[2/6] Checking collector metrics..."
kubectl port-forward svc/otel-collector 8888:8888 -n ${NAMESPACE} &>/dev/null &
PF1_PID=$!
sleep 2
SPANS_RECEIVED=$(curl -sf http://localhost:8888/metrics 2>/dev/null | \
  grep "otelcol_receiver_accepted_spans" | head -1 | awk '{print $2}' || echo "0")
kill $PF1_PID 2>/dev/null || true
echo "  Spans received: ${SPANS_RECEIVED}"
[ "${SPANS_RECEIVED}" != "0" ] && echo "  ✅ Collector receiving spans" || \
  echo "  ⚠️  No spans yet — generate some traffic first"

# ── 3. Send a test request to the app ─────────────────────────────
echo "[3/6] Sending test request to generate a trace..."
TRACE_RESPONSE=$(curl -sf "${ENDPOINT}/api/items" 2>/dev/null || echo "failed")
[ "${TRACE_RESPONSE}" != "failed" ] && echo "  ✅ App responding" || \
  echo "  ⚠️  App not reachable at ${ENDPOINT}"

# ── 4. Tempo is receiving traces ──────────────────────────────────
echo "[4/6] Checking Tempo..."
kubectl port-forward svc/tempo 3200:3100 -n ${NAMESPACE} &>/dev/null &
PF2_PID=$!
sleep 3

TEMPO_READY=$(curl -sf http://localhost:${TEMPO_PORT}/ready 2>/dev/null || echo "not ready")
[ "${TEMPO_READY}" = "ready" ] && echo "  ✅ Tempo ready" || \
  echo "  ❌ Tempo not ready: ${TEMPO_READY}"

# Query Tempo for recent traces from myapp-api
TRACES=$(curl -sf \
  "http://localhost:${TEMPO_PORT}/api/search?service.name=myapp-api&limit=5" \
  2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('traces',[])))" 2>/dev/null || echo "0")
echo "  Recent traces found: ${TRACES}"
[ "${TRACES}" -gt "0" ] && echo "  ✅ Traces flowing into Tempo" || \
  echo "  ⚠️  No traces in Tempo yet — run generate-load.sh first"

kill $PF2_PID 2>/dev/null || true

# ── 5. Loki is receiving logs ─────────────────────────────────────
echo "[5/6] Checking Loki..."
kubectl port-forward svc/loki 3100:3100 -n ${NAMESPACE} &>/dev/null &
PF3_PID=$!
sleep 2

LOKI_READY=$(curl -sf "http://localhost:3100/ready" 2>/dev/null || echo "not ready")
[ "${LOKI_READY}" = "ready" ] && echo "  ✅ Loki ready" || \
  echo "  ❌ Loki not ready"

LOG_COUNT=$(curl -sf \
  'http://localhost:3100/loki/api/v1/query_range?query=%7Bapp%3D%22api%22%7D&limit=5' \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
print(sum(len(r.get('values', [])) for r in results))
" 2>/dev/null || echo "0")
echo "  Recent log lines: ${LOG_COUNT}"
[ "${LOG_COUNT}" -gt "0" ] && echo "  ✅ Logs flowing into Loki" || \
  echo "  ⚠️  No logs in Loki yet"

kill $PF3_PID 2>/dev/null || true

# ── 6. Prometheus has SLO metrics ────────────────────────────────
echo "[6/6] Checking SLO metrics in Prometheus..."
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &>/dev/null &
PF4_PID=$!
sleep 2

SLO_VALUE=$(curl -sf \
  'http://localhost:9090/api/v1/query?query=job:http_requests_success:rate5m' \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
print(results[0]['value'][1] if results else 'no data')
" 2>/dev/null || echo "no data")

kill $PF4_PID 2>/dev/null || true

[ "${SLO_VALUE}" != "no data" ] && \
  echo "  ✅ SLO metric: success rate = ${SLO_VALUE}" || \
  echo "  ⚠️  SLO recording rule not yet populated"

echo ""
echo "=== Summary ==="
echo "  OTel Collector: running"
echo "  Tempo:          ${TEMPO_READY}"
echo "  Loki:           ${LOKI_READY}"
echo "  Traces:         ${TRACES}"
echo "  Logs:           ${LOG_COUNT}"
echo "  SLO metric:     ${SLO_VALUE}"
echo ""
echo "Open Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "  http://localhost:3000 → Explore → Tempo → search service: myapp-api"
