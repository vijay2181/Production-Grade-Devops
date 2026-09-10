# Project 3 — Observability Architecture Diagrams

---

## 1. Full Observability Pipeline

```mermaid
flowchart TD
    subgraph APP["Node.js API Pod"]
        SDK["OpenTelemetry SDK\nauto-instruments:\nHTTP · Express · pg · ioredis"]
        APP_CODE["app code\nindex.js"]
        APP_CODE --> SDK
    end

    subgraph COLLECTOR["OTel Collector DaemonSet\n(one per node)"]
        RCV["Receivers\notlp · filelog · hostmetrics"]
        PROC["Processors\nbatch · k8sattributes\nresourcedetection · transform"]
        EXP["Exporters"]
        RCV --> PROC --> EXP
    end

    subgraph BACKENDS["Backends"]
        TEMPO["Grafana Tempo\n(traces → S3)"]
        PROM["Prometheus\n(metrics)"]
        LOKI["Loki\n(logs → S3)"]
    end

    subgraph GRAFANA["Grafana"]
        DS["Datasources\nPrometheus · Tempo · Loki"]
        CORR["Correlated View\nmetric → trace → log"]
        DS --> CORR
    end

    SDK -->|"OTLP gRPC :4317\ntraces + metrics + logs"| RCV
    EXP -->|"OTLP traces"| TEMPO
    EXP -->|"remote_write"| PROM
    EXP -->|"push logs"| LOKI
    TEMPO --> DS
    PROM  --> DS
    LOKI  --> DS
```

---

## 2. Distributed Trace — One Request Waterfall

```mermaid
gantt
    title Trace: GET /api/items (TraceID: abc123)
    dateFormat x
    axisFormat %L ms

    section HTTP Layer
    express route handler     :0, 12

    section Cache
    redis GET items (miss)    :1, 2

    section Database
    pg connect                :3, 1
    pg query SELECT items     :4, 8

    section Cache Write
    redis SET items EX 60     :12, 1
```

---

## 3. Three Pillars Correlated in Grafana

```mermaid
flowchart LR
    subgraph INCIDENT["Incident at 14:32"]
        M["📊 Prometheus\nMetric spike\nerror rate = 12%\np95 = 3.2s"]
        L["📄 Loki\nLog line:\nconnection timeout\ntraceId: abc123"]
        T["🔍 Tempo\nTrace: abc123\nspan: pg SELECT\nduration: 3.1s\ndb.statement: slow query"]
    end

    M -->|"click spike\n→ see exemplars"| T
    L -->|"click traceId\n→ jump to trace"| T
    T -->|"click service\n→ see logs"| L
    T -->|"click service\n→ see metrics"| M

    style T fill:#f0f4ff,stroke:#3b82d4
    style M fill:#fff8f0,stroke:#f59e0b
    style L fill:#f0fff4,stroke:#38a169
```

---

## 4. SLO Error Budget Model

```mermaid
flowchart TD
    SLO["SLO: 99.9% availability\n30-day rolling window"]
    BUDGET["Error Budget\n= 0.1% of requests allowed to fail\n= 43.8 min downtime/month"]
    SLO --> BUDGET

    BUDGET --> B1["Burn Rate 1x\n✅ Safe — consuming\nbudget at normal pace"]
    BUDGET --> B2["Burn Rate 6x\n⚠️ Warning — budget\nexhausted in ~5 days"]
    BUDGET --> B3["Burn Rate 14x\n🚨 Critical — budget\nexhausted in ~2 hours\nPage on-call NOW"]

    B3 --> ALERT["AlertManager\nSLOBurnRateCritical\n→ PagerDuty + Slack"]
    B2 --> WARN["AlertManager\nSLOBurnRateHigh\n→ Slack ticket"]

    style B1 fill:#f0fff4,stroke:#38a169
    style B2 fill:#fffbf0,stroke:#f59e0b
    style B3 fill:#fff0f0,stroke:#e53e3e
    style ALERT fill:#fff0f0,stroke:#e53e3e
```

---

## 5. OpenTelemetry Collector Pipeline Detail

```mermaid
flowchart LR
    subgraph IN["Receivers"]
        R1["otlp/grpc :4317\n← app spans, metrics, logs"]
        R2["filelog\n← /var/log/pods/**"]
        R3["hostmetrics\n← CPU, mem, disk, net"]
    end

    subgraph PROC["Processors (in order)"]
        P1["memory_limiter\n512MB max"]
        P2["k8sattributes\n+ pod, namespace,\ndeployment labels"]
        P3["resourcedetection\n+ AWS region, AZ,\ninstance type"]
        P4["transform\n+ environment label"]
        P5["batch\n1000 spans / 5s"]
        P1 --> P2 --> P3 --> P4 --> P5
    end

    subgraph OUT["Exporters"]
        E1["otlp/tempo\n→ traces"]
        E2["prometheusremotewrite\n→ metrics"]
        E3["loki\n→ logs"]
    end

    IN --> PROC --> OUT
```

---

## 6. Links to Project 1 and Project 2

```mermaid
flowchart TD
    subgraph P1["Project 1 — aws-eks-migration"]
        P1A["app/src/index.js"]
        P1B["monitoring/prometheus/values.yaml"]
        P1C["kubernetes/base/"]
    end

    subgraph P3["Project 3 — observability (THIS)"]
        P3A["app/src/index.js\n+ OpenTelemetry SDK\n+ structured logging"]
        P3B["helm/values/prometheus-values.yaml\n+ Tempo + Loki datasources\n+ SLO recording rules\n+ exemplar storage"]
        P3C["kubernetes/base/collector/\nOTel Collector DaemonSet"]
    end

    subgraph P2["Project 2 — argocd-multicluster"]
        P2A["argocd/applicationsets/\ncluster-addons-applicationset.yaml"]
        P2B["argo-rollouts/canary/\nanalysis-template.yaml"]
    end

    P1A -->|"extends"| P3A
    P1B -->|"extends"| P3B
    P1C -->|"adds to"| P3C

    P3C -->|"ArgoCD deploys\ncollector to all clusters"| P2A
    P3B -->|"SLO metrics used\nin canary analysis"| P2B
```

---

## 7. Deployment Topology (all 3 projects combined)

```mermaid
graph TB
    subgraph HUB["HUB CLUSTER"]
        ACD["ArgoCD\n(manages everything)"]
    end

    subgraph PROD["PROD CLUSTER"]
        APP_POD["myapp-api pods\n+ OTel SDK"]
        COLLECTOR_DS["OTel Collector\nDaemonSet"]
        subgraph OBS["observability namespace"]
            TEMPO_P["Tempo"]
            LOKI_P["Loki"]
        end
        subgraph MON["monitoring namespace"]
            PROM_P["Prometheus\n+ SLO rules"]
            GRAFANA_P["Grafana\nCorrelated view"]
        end
        APP_POD -->|"OTLP :4317"| COLLECTOR_DS
        COLLECTOR_DS --> TEMPO_P
        COLLECTOR_DS --> LOKI_P
        COLLECTOR_DS --> PROM_P
        TEMPO_P --> GRAFANA_P
        LOKI_P  --> GRAFANA_P
        PROM_P  --> GRAFANA_P
    end

    ACD -->|"GitOps sync"| PROD
```
