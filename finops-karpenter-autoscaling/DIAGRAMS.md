# Project 6: FinOps & Karpenter Diagrams

> Architecture and sequence diagrams rendered in Mermaid format.

---

## 1. Overall Cluster Topology & NodePool Segregation

```mermaid
graph TB
    subgraph INGRESS["Ingress Traffic"]
        ALB["AWS ALB (TLS Termination)"]
    end

    subgraph K8S["EKS Cluster (myapp-prod)"]
        subgraph TIER1["Tier 1: critical-ondemand (On-Demand only)"]
            ARGO["ArgoCD Controller"]
            PROM["Prometheus + Tempo + Loki"]
            SEC["Falco + Kyverno Webhook"]
            JENK["Jenkins Controller (StatefulSet)"]
        end

        subgraph TIER2["Tier 2: general-spot (70%+ Spot Fleet)"]
            API1["myapp-prod Pod A"]
            API2["myapp-prod Pod B"]
            WORKER["KEDA SQS Worker Pods (0 → 40)"]
            REDIS_POD["Redis Cache Warmer (0 → 20)"]
        end

        subgraph TIER3["Tier 3: ci-ephemeral (100% Burst Spot)"]
            KANIKO["Kaniko Builder Pods"]
            TRIVY["Trivy Security Scanners"]
        end

        subgraph CONTROLLER["FinOps & Scaling Control Plane"]
            KARP["Karpenter Controller v1.0+"]
            KEDA["KEDA Autoscaler Controller"]
            COST["OpenCost Metrics Engine"]
        end
    end

    subgraph AWS["AWS Cloud Infrastructure"]
        EC2_FLEET["AWS EC2 Fleet API"]
        EB["Amazon EventBridge"]
        SQS["Spot Interruption SQS Queue"]
        PRICE["AWS Pricing API"]
    end

    ALB --> API1
    ALB --> API2
    KEDA --> WORKER
    KEDA --> REDIS_POD
    KARP -- "ec2:CreateFleet" --> EC2_FLEET
    EB -- "2-min warning" --> SQS
    SQS --> KARP
    COST -- "pricing:GetProducts" --> PRICE
```

---

## 2. Dynamic Node Bin-Packing & Active Consolidation

```mermaid
flowchart TD
    POLL["Karpenter Evaluates Cluster State (every 10s)"] --> CHECK{"Any Underutilized Nodes?"}
    
    CHECK -->|Yes| EVAL["Evaluate Candidate Nodes:\nNode A (25% CPU) + Node B (30% CPU)"]
    CHECK -->|No| SLEEP["Sleep 10s"]
    
    EVAL --> CALC["Simulate Bin-Packing:\nCan all Pods fit into 1 smaller c7g.xlarge Spot?"]
    
    CALC -->|Yes| PDB_CHECK{"Are PDBs respected for all candidate Pods?"}
    CALC -->|No| SLEEP
    
    PDB_CHECK -->|Pass| LAUNCH["Launch Replacement Node: c7g.xlarge Spot (40s)"]
    PDB_CHECK -->|Blocked| SLEEP
    
    LAUNCH --> READY["Replacement Node Ready & Registered"]
    READY --> CORDON["Cordon & Drain Node A + Node B"]
    CORDON --> MIGRATE["Pods safely rescheduled onto replacement node"]
    MIGRATE --> TERM["Terminate Node A + Node B\n(Immediate Cost Reduction)"]
```

---

## 3. End-to-End SQS Event-Driven Elasticity Loop

```mermaid
sequenceDiagram
    participant BIZ as Business Application
    participant SQS as AWS SQS Order Queue
    participant KEDA as KEDA Operator
    participant HPA as Kubernetes HPA
    participant KARP as Karpenter v1.0+
    participant AWS as AWS EC2 Spot Fleet
    participant WRK as Worker Pods (0 → 40)

    Note over WRK: Cluster is idle (0 worker pods running, 0 compute cost)
    BIZ->>SQS: Ingest 5,000 Order Processing Messages
    KEDA->>SQS: Poll ApproximateNumberOfMessagesVisible (every 15s)
    KEDA->>HPA: Update HPA Target (Calculates: 40 Pods Required)
    HPA->>WRK: Scale Deployment from 0 → 40 Pods
    Note over WRK: 40 Pods enter Pending state (Insufficient CPU)
    
    KARP->>KARP: Detect 40 Pending Pods (Total Req: 40 CPU, 80GB)
    KARP->>AWS: Request 2x c7g.4xlarge Spot Instances (Graviton3)
    AWS-->>KARP: 2x Spot Nodes Bootstrapped & Joined (42 seconds)
    KARP->>WRK: 40 Pods Scheduled & Running
    WRK->>SQS: Process & drain all 5,000 messages (3 minutes)
    
    KEDA->>SQS: Backlog is 0
    KEDA->>HPA: Scale Deployment back to 0 Pods
    WRK->>WRK: Pods terminate gracefully
    KARP->>KARP: Nodes are now completely empty
    KARP->>AWS: Terminate 2x Spot Nodes (Compute scales back to $0)
```
