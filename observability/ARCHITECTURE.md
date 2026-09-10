# Observability Deep Dive — Production Grade

> **Project 3** | Builds on: `aws-eks-migration` (Project 1) + `argocd-multicluster` (Project 2)
> Stack: OpenTelemetry · Prometheus · Grafana Tempo · Loki · Alertmanager · SLOs

---

## Why Observability?

### The Business Case

Every production system will break. The question is not **if** — it is **how fast you find it and how fast you fix it**.

```
Without observability:
  User reports error → engineer SSH's into pods → grep logs →
  no context → guess the cause → apply a fix → hope it works
  Mean Time To Resolution (MTTR): 2–4 hours

With observability:
  Alert fires automatically → engineer opens Grafana →
  sees metric spike → clicks exemplar → sees exact trace →
  identifies slow Postgres query in 30 seconds →
  fixes the query → deploys → alert resolves
  Mean Time To Resolution (MTTR): 5–15 minutes
```

**That difference — 4 hours vs 15 minutes — is the value of observability.**

### Real Incidents Observability Prevents or Shortens

| Incident | Without observability | With observability |
|---|---|---|
| DB query suddenly slow | Users complain → 2h to find the query | Trace shows exact SQL + duration in 30s |
| Memory leak after deploy | OOM kills pods randomly | VPA + metrics show memory climbing → caught before crash |
| Redis cache not working | Users see slow responses, no idea why | Trace shows cache misses spiking → Redis connection issue visible |
| Canary deploy breaking 5% of users | You don't know until 10% of users complain | Error budget burn rate alert fires at 2% impact |
| Intermittent 500s at 3am | Nobody notices until morning | Alertmanager pages on-call within 2 minutes |

### The Cost Argument

```
Observability stack cost:   ~$30–55/month (Tempo + Loki S3 storage)
One production outage:      $thousands in lost revenue + engineering time
One missed SLA breach:      $thousands in penalties

ROI: The stack pays for itself the first time it cuts a 4-hour
     incident to 15 minutes.
```

### Why NOT just use CloudWatch?

```
CloudWatch:
  ✅ Native AWS, no setup
  ✅ Logs from all AWS services automatically
  ❌ No distributed tracing
  ❌ No trace-to-log correlation
  ❌ No SLO / error budget model
  ❌ Expensive at scale ($0.50/GB ingested, no compression)
  ❌ Vendor lock-in — can't use same stack on GCP or on-prem
  ❌ No TraceQL — limited query capability

OpenTelemetry + Tempo + Loki + Prometheus:
  ✅ Full distributed tracing
  ✅ Trace ↔ log ↔ metric correlation
  ✅ SLO error budget model (Google SRE standard)
  ✅ S3 storage (~$0.023/GB — 20x cheaper than CloudWatch)
  ✅ Vendor-neutral — same stack on AWS, GCP, Azure, on-prem
  ✅ TraceQL — powerful query language for traces
  ✅ Open source — no per-seat licensing
```

### Why OpenTelemetry specifically?

```
Before OpenTelemetry:
  Datadog agent  → Datadog only
  Jaeger agent   → Jaeger only
  Zipkin agent   → Zipkin only
  Switch vendor? → Reinstrument every service

With OpenTelemetry:
  ONE SDK in your app → exports to ANY backend
  Switch from Tempo to Jaeger? Change one Helm value.
  Switch from Loki to Datadog? Change one exporter config.
  Your instrumentation code NEVER changes.

OpenTelemetry is the CNCF standard. It is vendor-neutral by design.
Adopted by: Google, Microsoft, AWS, Datadog, Splunk, Dynatrace.
```

---

## The Three Pillars of Observability

```
Pillar 1 — METRICS  (Prometheus)
  → What is broken? Numbers over time.
  → "Error rate is 12% for the last 5 minutes"

Pillar 2 — LOGS     (Loki)
  → What did the error say? Text events.
  → "connection timeout: postgres:5432 after 30s"

Pillar 3 — TRACES   (Grafana Tempo)
  → Where exactly did it break? Request journey.
  → "Request abc123 spent 8s in postgres SELECT query"
```

Without all three correlated together, you are guessing during incidents.
This project wires all three into a single Grafana view.

---

## What Was Missing in Projects 1 and 2

### Project 1 gave you:
```
✅ Prometheus metrics (CPU, memory, HTTP request count)
✅ Loki logs (container stdout)
✅ Grafana dashboard (request rate, error rate, latency)
✅ Alertmanager (error rate > 5%, p95 > 2s)
```

### What was still missing:
```
❌ You see error rate spike at 14:32 — but which service caused it?
❌ You see "connection timeout" in logs — but which query was slow?
❌ You see p95 = 3s — but where did those 3 seconds go?
❌ You can't correlate: click a log line → jump to the trace for that request
❌ No SLOs — no error budget — no burn rate alerts
❌ No structured logs (JSON parsing, trace ID in logs)
```

### This project adds:
```
✅ Distributed traces — full request waterfall across API → Redis → Postgres
✅ Trace-to-log correlation — click trace → see logs for that request
✅ Log-to-trace correlation — click log line → jump to trace
✅ Metric-to-trace exemplars — click a metric spike → see real traces
✅ SLO dashboards — error budget, burn rate, remaining budget
✅ Structured JSON logs with traceID injected automatically
✅ OpenTelemetry Collector as a central pipeline
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Node.js API Pod                                  │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  OpenTelemetry SDK (auto-instrumentation)                    │   │
│  │  - Traces: every HTTP req, DB query, Redis call              │   │
│  │  - Metrics: histogram, counter, gauge                        │   │
│  │  - Logs: JSON structured, traceID injected automatically     │   │
│  └───────────────────────┬──────────────────────────────────────┘   │
└──────────────────────────┼──────────────────────────────────────────┘
                           │ OTLP gRPC :4317
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│              OpenTelemetry Collector (DaemonSet)                    │
│                                                                      │
│  Receivers:  otlp (grpc+http), prometheus, filelog                   │
│  Processors: batch, memory_limiter, resourcedetection, k8sattributes │
│  Exporters:  → Tempo (traces)                                        │
│              → Prometheus remote_write (metrics)                     │
│              → Loki (logs)                                           │
└──────────┬────────────────┬──────────────────┬──────────────────────┘
           │                │                  │
           ▼                ▼                  ▼
     ┌──────────┐    ┌──────────────┐   ┌─────────┐
     │  Tempo   │    │  Prometheus  │   │  Loki   │
     │ (traces) │    │  (metrics)   │   │  (logs) │
     └────┬─────┘    └──────┬───────┘   └────┬────┘
          │                 │                │
          └─────────────────┼────────────────┘
                            │
                            ▼
                     ┌────────────┐
                     │  Grafana   │
                     │            │
                     │  Datasources:       │
                     │  - Prometheus       │
                     │  - Tempo            │
                     │  - Loki             │
                     │                    │
                     │  Correlated view:  │
                     │  metric → trace    │
                     │  log → trace       │
                     │  trace → log       │
                     └────────────┘
```

---

## How It Links to Project 1 and Project 2

### Links to Project 1 (aws-eks-migration)

```
app/src/index.js         → ADD OpenTelemetry SDK instrumentation
kubernetes/base/         → ADD OTel Collector DaemonSet
kubernetes/base/         → ADD Tempo + Loki Helm releases
monitoring/prometheus/   → EXTEND with SLO recording rules
monitoring/grafana/      → EXTEND with correlated dashboards
```

The same Node.js app from Project 1 gets instrumented.
No new application — just deeper visibility into the existing one.

### Links to Project 2 (argocd-multicluster)

```
argocd/applicationsets/  → ADD observability-stack ApplicationSet
                            ArgoCD deploys Tempo + Loki + Collector
                            to all 3 clusters (dev/staging/prod)

argo-rollouts/canary/    → EXTEND AnalysisTemplates with SLO metrics
                            Canary analysis now checks error BUDGET
                            not just raw error rate
```

The observability stack becomes a GitOps-managed addon,
deployed and updated by ArgoCD across all clusters.

---

## Key Concepts

| Concept | What it means in practice |
|---|---|
| **Span** | One unit of work (e.g. one DB query). Has start time, end time, attributes. |
| **Trace** | A collection of spans for one request. Shows the full journey. |
| **TraceID** | Unique ID shared across all spans of one request. Injected into logs too. |
| **Exemplar** | A real trace ID attached to a Prometheus metric data point. Click metric → open trace. |
| **SLO** | Service Level Objective. "99.9% of requests succeed over 30 days." |
| **Error Budget** | How much failure you are allowed. 99.9% SLO = 43.8 min/month downtime budget. |
| **Burn Rate** | How fast you are consuming error budget. Burn rate 2 = using budget 2× faster than allowed. |
| **OTel Collector** | A vendor-neutral agent that receives, processes, and exports telemetry data. |
| **OTLP** | OpenTelemetry Protocol. The wire format for sending telemetry data. |
