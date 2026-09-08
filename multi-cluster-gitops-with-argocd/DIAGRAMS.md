# Project 2 — Architecture Diagrams (Mermaid)

---

## 1. Hub-Spoke Cluster Model

```mermaid
graph TB
    subgraph GitHub["GitHub Repository"]
        GIT["📁 apps/myapp/overlays/<br/>dev · staging · prod"]
    end

    subgraph Hub["HUB CLUSTER (EKS)"]
        ARGOCD["ArgoCD"]
        IU["Image Updater"]
        AR["Argo Rollouts Controller"]
        ARGOCD --> IU
        ARGOCD --> AR
    end

    subgraph Dev["DEV CLUSTER"]
        DEV_APP["myapp-dev<br/>1 replica<br/>auto-sync"]
    end

    subgraph Staging["STAGING CLUSTER"]
        STG_APP["myapp-staging<br/>2 replicas<br/>Blue/Green"]
    end

    subgraph Prod["PROD CLUSTER"]
        PRD_APP["myapp-prod<br/>5 replicas<br/>Canary 10→50→100%"]
    end

    ECR["AWS ECR<br/>📦 myapp/api:v1.x.x"]

    CI["GitHub Actions CI<br/>(build + push only)"]
    DEV["👩‍💻 Developer"]

    DEV -->|git push| GitHub
    GitHub -->|code change| CI
    CI -->|docker push| ECR
    IU -->|polls ECR| ECR
    IU -->|commits new tag| GitHub
    ARGOCD -->|polls Git every 3min| GitHub
    ARGOCD -->|syncs| Dev
    ARGOCD -->|syncs| Staging
    ARGOCD -->|syncs| Prod
```

---

## 2. Full GitOps Loop (end to end)

```mermaid
sequenceDiagram
    participant Dev as 👩‍💻 Developer
    participant GH as GitHub
    participant CI as GitHub Actions CI
    participant ECR as AWS ECR
    participant IU as Image Updater
    participant ACD as ArgoCD
    participant K8S as EKS Clusters

    Dev->>GH: git push (feature branch → main)
    GH->>CI: trigger workflow
    CI->>CI: npm test + trivy scan
    CI->>ECR: docker push myapp/api:v1.2.3
    CI-->>GH: ✅ build passed (no kubectl, no helm)

    loop every 2 min
        IU->>ECR: check for new tags
        ECR-->>IU: new tag: v1.2.3
    end

    IU->>GH: commit — update image tag to v1.2.3
    GH-->>ACD: webhook / poll detects change

    ACD->>ACD: compute diff (Git vs cluster state)
    Note over ACD: OutOfSync detected

    ACD->>K8S: apply new manifests (dev auto, prod manual)
    K8S-->>ACD: sync successful

    ACD->>Dev: Slack — ✅ myapp v1.2.3 deployed
```

---

## 3. Canary Rollout Flow (Prod)

```mermaid
flowchart TD
    START([New image tag detected]) --> STEP1

    STEP1["Set canary weight: 10%<br/>Stable: 90% · Canary: 10%"]
    STEP1 --> PAUSE1[Wait 2 min]
    PAUSE1 --> ANALYSIS1

    ANALYSIS1{{"AnalysisRun<br/>error rate < 5%?<br/>p95 latency < 500ms?"}}
    ANALYSIS1 -->|✅ PASS| STEP2
    ANALYSIS1 -->|❌ FAIL| ROLLBACK

    STEP2["Set canary weight: 50%<br/>Stable: 50% · Canary: 50%"]
    STEP2 --> PAUSE2[Wait 2 min]
    PAUSE2 --> ANALYSIS2

    ANALYSIS2{{"AnalysisRun<br/>error rate < 5%?<br/>p95 latency < 500ms?"}}
    ANALYSIS2 -->|✅ PASS| STEP3
    ANALYSIS2 -->|❌ FAIL| ROLLBACK

    STEP3["Set canary weight: 100%<br/>Full promotion ✅"]
    STEP3 --> NOTIFY_OK["Slack — 🚀 v1.2.3 promoted to 100%"]
    NOTIFY_OK --> DONE([Rollout complete])

    ROLLBACK["Auto rollback to stable<br/>Canary pods terminated"]
    ROLLBACK --> NOTIFY_FAIL["Slack — 🚨 Canary FAILED — rolled back"]
    NOTIFY_FAIL --> DONE2([Stable restored])

    style ANALYSIS1 fill:#f0f4ff,stroke:#3b82d4
    style ANALYSIS2 fill:#f0f4ff,stroke:#3b82d4
    style ROLLBACK fill:#fff0f0,stroke:#e53e3e
    style STEP3 fill:#f0fff4,stroke:#38a169
```

---

## 4. Blue/Green Rollout Flow (Staging)

```mermaid
flowchart LR
    subgraph Before["Before Promotion"]
        direction TB
        LB1["ALB<br/>100% traffic"]
        BLUE["Blue pods<br/>v1.0.0 (active)"]
        GREEN["Green pods<br/>v1.1.0 (preview)"]
        LB1 -->|all traffic| BLUE
        LB1 -.->|preview only| GREEN
    end

    subgraph Analysis["Pre-Promotion Analysis"]
        direction TB
        QA["QA hits preview service"]
        PROM["Prometheus checks<br/>error rate + latency"]
        QA --> PROM
    end

    subgraph After["After Promotion"]
        direction TB
        LB2["ALB<br/>100% traffic"]
        BLUE2["Blue pods<br/>v1.0.0 (scale down in 5min)"]
        GREEN2["Green pods<br/>v1.1.0 (now active)"]
        LB2 -->|all traffic| GREEN2
        LB2 -.->|kept alive 5min| BLUE2
    end

    Before --> Analysis
    Analysis -->|✅ approved| After
```

---

## 5. ApplicationSet — One YAML → 3 Clusters

```mermaid
flowchart TD
    AS["ApplicationSet<br/>myapp-applicationset.yaml"]

    AS -->|generates| APP1["Application: myapp-dev<br/>cluster: dev<br/>namespace: myapp-dev<br/>sync: automated<br/>replicas: 1"]

    AS -->|generates| APP2["Application: myapp-staging<br/>cluster: staging<br/>namespace: myapp-staging<br/>sync: automated<br/>replicas: 2"]

    AS -->|generates| APP3["Application: myapp-prod<br/>cluster: prod<br/>namespace: myapp-prod<br/>sync: manual (sync window)<br/>replicas: 5"]

    APP1 -->|deploys to| DEV["DEV EKS"]
    APP2 -->|deploys to| STG["STAGING EKS"]
    APP3 -->|deploys to| PRD["PROD EKS"]
```

---

## 6. RBAC — Who Can Deploy What

```mermaid
flowchart LR
    subgraph Teams
        PT["👥 Platform Team<br/>(myorg:platform)"]
        BT["👥 Backend Team<br/>(myorg:backend)"]
        FT["👥 Frontend Team<br/>(myorg:frontend)"]
        CI["🤖 CI Bot"]
    end

    subgraph Permissions
        DEV_P["✅ Deploy → Dev"]
        STG_P["✅ Deploy → Staging"]
        PRD_P["✅ Deploy → Prod"]
        ALL_P["✅ All permissions<br/>(delete, override)"]
    end

    PT --> ALL_P
    BT --> DEV_P
    BT --> STG_P
    FT --> DEV_P
    CI --> DEV_P
    CI --> STG_P

    style PRD_P fill:#fff0f0,stroke:#e53e3e
    style ALL_P fill:#f0fff4,stroke:#38a169
```

---

## 7. Sync Windows — When Can You Deploy to Prod?

```mermaid
gantt
    title Prod Sync Windows (Mon–Fri only)
    dateFormat HH:mm
    axisFormat %H:%M

    section Blocked
    No deploys allowed     :crit, 00:00, 09:00
    No deploys allowed     :crit, 17:00, 24:00

    section Allowed
    Prod deploy window     :active, 09:00, 17:00
```
