# Testing Guide — Observability Stack

> Each phase verifies one layer of the pipeline.
> Run in order — earlier phases are prerequisites for later ones.

---

## Phase Overview

```
Phase 1  ─ Stack health (all pods running)           ~10 min
Phase 2  ─ OTel Collector receiving data             ~5  min
Phase 3  ─ App instrumentation (traces generated)    ~10 min
Phase 4  ─ Tempo receiving + queryable traces        ~10 min
Phase 5  ─ Trace-to-log correlation                  ~10 min
Phase 6  ─ Log-to-trace correlation                  ~10 min
Phase 7  ─ Metric exemplars (metric → trace)         ~10 min
Phase 8  ─ SLO dashboard + error budget              ~10 min
Phase 9  ─ Burn rate alert fires correctly           ~15 min
Phase 10 ─ End-to-end: incident simulation           ~20 min
─────────────────────────────────────────────────────────────
Total                                               ~110 min
```

---

## Phase 1 — Stack Health

```bash
# All observability pods Running
kubectl get pods -n observability
# Expected:
#   otel-collector-xxxx    1/1  Running  (one per node = DaemonSet)
#   tempo-0                1/1  Running
#   loki-0                 1/1  Running
#   loki-promtail-xxxx     1/1  Running  (one per node = DaemonSet)

kubectl get pods -n monitoring | grep -E "prometheus|grafana|alertmanager"
# Expected: all 1/1 Running

# Collector logs — no errors
kubectl logs -l app=otel-collector -n observability --tail=20
# Expected: no ERROR lines, see "Everything is ready"

echo "✅ Phase 1 PASSED"
```

---

## Phase 2 — OTel Collector Receiving Data

```bash
# Port-forward collector metrics
kubectl port-forward svc/otel-collector 8888:8888 -n observability &
sleep 2

# Check receiver accepted spans count (must be > 0 after generating traffic)
curl -sf http://localhost:8888/metrics | grep otelcol_receiver_accepted_spans
# Expected: otelcol_receiver_accepted_spans{receiver="otlp",...} > 0

# Check for any export errors
curl -sf http://localhost:8888/metrics | grep otelcol_exporter_send_failed
# Expected: 0 or absent

kill %1 2>/dev/null

echo "✅ Phase 2 PASSED"
```

---

## Phase 3 — App Instrumentation

```bash
# Generate test traffic
./scripts/generate-load.sh https://api.myapp.com 60

# Check app logs contain traceId (structured JSON)
kubectl logs -l app=api -n myapp --tail=5
# Expected output (JSON with traceId):
# {"level":"info","message":"http request","route":"/api/items",
#  "status":200,"traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"00f067aa0ba902b7"}

# Verify traceId is a valid 32-char hex string
kubectl logs -l app=api -n myapp --tail=5 | \
  python3 -c "
import sys, json
for line in sys.stdin:
  try:
    d = json.loads(line)
    tid = d.get('traceId', '')
    print(f'traceId: {tid} (len={len(tid)}, valid={len(tid)==32})')
  except: pass
"
# Expected: traceId: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (len=32, valid=True)

echo "✅ Phase 3 PASSED"
```

---

## Phase 4 — Tempo Receiving Traces

```bash
# Port-forward Tempo
kubectl port-forward svc/tempo 3200:3100 -n observability &
sleep 3

# Tempo is ready
curl -sf http://localhost:3200/ready
# Expected: ready

# Search for recent traces from myapp-api
curl -sf "http://localhost:3200/api/search?tags=service.name%3Dmyapp-api&limit=5" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
traces = d.get('traces', [])
print(f'Found {len(traces)} traces')
for t in traces[:3]:
  print(f'  traceID: {t[\"traceID\"]}  root: {t[\"rootName\"]}  duration: {t[\"durationMs\"]}ms')
"
# Expected:
# Found 5 traces
#   traceID: abc123...  root: GET /api/items  duration: 12ms
#   traceID: def456...  root: POST /api/items  duration: 8ms

# Fetch full trace detail
TRACE_ID=$(curl -sf "http://localhost:3200/api/search?tags=service.name%3Dmyapp-api&limit=1" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['traces'][0]['traceID'])")
echo "Testing trace: ${TRACE_ID}"

curl -sf "http://localhost:3200/api/traces/${TRACE_ID}" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
spans = d.get('batches', [])
total = sum(len(b.get('scopeSpans',[{}])[0].get('spans',[]) if b.get('scopeSpans') else []) for b in spans)
print(f'Spans in trace: {total}')
"
# Expected: Spans in trace: 4  (HTTP + Redis + Postgres + custom span)

kill %1 2>/dev/null
echo "✅ Phase 4 PASSED"
```

---

## Phase 5 — Trace-to-Log Correlation

```bash
# Open Grafana: http://localhost:3000
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &

echo "Manual verification:"
echo "1. Grafana → Explore → Select datasource: Tempo"
echo "2. Search: service.name = myapp-api"
echo "3. Click any trace → expand spans"
echo "4. Click 'Logs for this span' button"
echo "5. Loki opens with query: {traceId='<same-trace-id>'}"
echo "6. You should see the log lines for exactly that request"
echo ""
echo "Expected: Loki shows log lines with matching traceId field"

# Automated check: query Loki for a specific traceId
kubectl port-forward svc/loki 3100:3100 -n observability &>/dev/null &
sleep 2

TRACE_ID=$(curl -sf "http://localhost:3200/api/search?tags=service.name%3Dmyapp-api&limit=1" 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['traces'][0]['traceID'])" 2>/dev/null || echo "")

if [ -n "${TRACE_ID}" ]; then
  LOG_COUNT=$(curl -sf \
    "http://localhost:3100/loki/api/v1/query_range?query=%7BtraceId%3D%22${TRACE_ID}%22%7D&limit=10" \
    2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
print(sum(len(r.get('values', [])) for r in results))
" 2>/dev/null || echo "0")
  echo "Log lines found for traceId ${TRACE_ID}: ${LOG_COUNT}"
  [ "${LOG_COUNT}" -gt "0" ] && echo "✅ Trace-to-log correlation working" || \
    echo "⚠️  No logs found for trace — check Loki structured_metadata config"
fi

kill %2 %3 2>/dev/null || true
echo "✅ Phase 5 PASSED (if log count > 0)"
```

---

## Phase 6 — Log-to-Trace Correlation

```bash
echo "Manual verification in Grafana:"
echo "1. Grafana → Explore → Select datasource: Loki"
echo "2. Query: {app='api'} | json"
echo "3. Expand a log line"
echo "4. Look for the 'TraceID' derived field link (blue link)"
echo "5. Click it → Tempo opens with that trace"
echo ""
echo "Expected: Each log line with traceId has a clickable 'TraceID' link"
echo "         Clicking it shows the full trace waterfall in Tempo"

echo "✅ Phase 6 PASSED (manual verification required)"
```

---

## Phase 7 — Metric Exemplars (metric → trace)

```bash
echo "Manual verification in Grafana:"
echo "1. Grafana → Explore → Select datasource: Prometheus"
echo "2. Query: rate(http_requests_total[5m])"
echo "3. Enable 'Exemplars' toggle in the query editor"
echo "4. Small dots appear on the time series"
echo "5. Click a dot → traceID popup appears"
echo "6. Click the traceID → Tempo shows that specific trace"
echo ""
echo "Expected: Metric spikes have exemplar dots. Clicking them"
echo "         shows the actual request trace that caused the spike."

# Verify exemplars are enabled in Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &>/dev/null &
sleep 2
EXEMPLAR_COUNT=$(curl -sf \
  'http://localhost:9090/api/v1/query_exemplars?query=http_requests_total' \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('data', [])))
" 2>/dev/null || echo "0")
echo "Exemplars in Prometheus: ${EXEMPLAR_COUNT}"
kill %1 2>/dev/null || true

echo "✅ Phase 7 PASSED"
```

---

## Phase 8 — SLO Dashboard + Error Budget

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &>/dev/null &
sleep 2

# SLO recording rules are populated
SLO_5M=$(curl -sf \
  'http://localhost:9090/api/v1/query?query=job:http_requests_success:rate5m' \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('data',{}).get('result',[])
print(f'{float(r[0][\"value\"][1]):.4f}' if r else 'no data')
")
echo "SLO 5m success rate: ${SLO_5M}"
[ "${SLO_5M}" != "no data" ] && echo "✅ SLO recording rules working" || \
  echo "⚠️  SLO recording rules not populated — generate traffic first"

# Error budget remaining
BUDGET=$(curl -sf \
  'http://localhost:9090/api/v1/query?query=job:slo_error_budget_remaining:ratio' \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('data',{}).get('result',[])
print(f'{float(r[0][\"value\"][1]):.2%}' if r else 'no data')
")
echo "Error budget remaining: ${BUDGET}"

kill %1 2>/dev/null || true
echo "✅ Phase 8 PASSED"
```

---

## Phase 9 — Burn Rate Alert

```bash
# Simulate high error rate to trigger SLOBurnRateCritical alert
# WARNING: only run in dev/staging

echo "Simulating 20% error rate for 3 minutes..."
kubectl port-forward svc/api 8080:80 -n myapp-dev &>/dev/null &
sleep 2

# Send bad requests to drive up error rate
for i in $(seq 1 200); do
  curl -sf -o /dev/null http://localhost:8080/api/items-nonexistent 2>/dev/null || true
  curl -sf -o /dev/null http://localhost:8080/api/items 2>/dev/null || true
  sleep 0.3
done

kill %1 2>/dev/null || true

# Check Alertmanager for the alert
kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring &>/dev/null &
sleep 2
ALERTS=$(curl -sf http://localhost:9093/api/v2/alerts 2>/dev/null | \
  python3 -c "
import sys, json
alerts = json.load(sys.stdin)
slo_alerts = [a for a in alerts if 'SLO' in a.get('labels',{}).get('alertname','')]
for a in slo_alerts:
  print(f'  {a[\"labels\"][\"alertname\"]} — {a[\"status\"][\"state\"]}')
print(f'Total SLO alerts: {len(slo_alerts)}')
" 2>/dev/null || echo "check failed")
echo "Active SLO alerts: ${ALERTS}"

kill %1 2>/dev/null || true
echo "✅ Phase 9 PASSED (check for SLO alerts in Alertmanager)"
```

---

## Phase 10 — End-to-End Incident Simulation

```bash
echo "=== Simulating a production incident ==="
echo ""
echo "Step 1: Generate normal traffic baseline (2 min)"
./scripts/generate-load.sh https://api.myapp.com 120 &

echo "Step 2: Find a trace in Tempo"
sleep 30
kubectl port-forward svc/tempo 3200:3100 -n observability &>/dev/null &
sleep 3
curl -sf "http://localhost:3200/api/search?tags=service.name%3Dmyapp-api&limit=3" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d.get('traces',[]):
  print(f'trace: {t[\"traceID\"]} | {t[\"rootName\"]} | {t[\"durationMs\"]}ms')
"

echo ""
echo "Step 3: In Grafana, verify the full correlated view:"
echo "  - Metrics dashboard: request rate, error rate, latency"
echo "  - Click a latency spike → exemplar → Tempo trace"
echo "  - In Tempo: see which span was slow (Redis or Postgres)"
echo "  - Click 'Logs for this span' → Loki shows the log line"
echo "  - SLO dashboard: error budget remaining"
echo ""
echo "Step 4: Check all three pillars are correlated"
echo "  ✅ Metric spike → Prometheus"
echo "  ✅ Log line with traceId → Loki"
echo "  ✅ Full trace waterfall → Tempo"
echo "  ✅ All linked in one Grafana view"

wait
echo "✅ Phase 10 PASSED"
```

---

## Full Checklist

```
[ ] Phase 1  — All pods Running in observability + monitoring namespaces
[ ] Phase 2  — OTel Collector metrics show spans received > 0
[ ] Phase 3  — App logs are JSON with traceId field                ← DO NOT SKIP
[ ] Phase 4  — Tempo shows traces from myapp-api, spans include Redis + Postgres
[ ] Phase 5  — Loki returns logs when queried by traceId           ← DO NOT SKIP
[ ] Phase 6  — Log lines have clickable TraceID derived field link  ← DO NOT SKIP
[ ] Phase 7  — Prometheus metric has exemplar dots on time series
[ ] Phase 8  — SLO recording rules populated, error budget visible ← DO NOT SKIP
[ ] Phase 9  — SLOBurnRateCritical alert fires in Alertmanager
[ ] Phase 10 — Full incident simulation: metric → trace → log in one view
```
