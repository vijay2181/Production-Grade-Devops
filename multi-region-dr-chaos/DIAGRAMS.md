# Project 7: Multi-Region DR & Chaos Engineering Diagrams

> Mermaid architecture, state replication, and chaos experiment sequence diagrams.

---

## 1. Multi-Region Warm Standby & Routing Flow

```mermaid
flowchart TD
    CLIENT["Global User / API Traffic"] --> R53["AWS Route 53 (Failover Routing)"]

    subgraph EAST["Primary: us-east-1 (Active)"]
        ALB_EAST["ALB (Primary)"]
        EKS_EAST["EKS Cluster (15 Replicas)"]
        DB_EAST[("Aurora PostgreSQL (Writer)")]
        S3_EAST[("S3 Velero Backups")]
    end

    subgraph WEST["Secondary: us-west-2 (Warm Standby)"]
        ALB_WEST["ALB (Standby)"]
        EKS_WEST["EKS Cluster (Pilot Light 2 Replicas)"]
        DB_WEST[("Aurora PostgreSQL (Reader)")]
        S3_WEST[("S3 Replicated Backups")]
    end

    R53 -->|Normal Routing (Healthy)| ALB_EAST
    R53 -.->|Failover Routing (Outage)| ALB_WEST

    ALB_EAST --> EKS_EAST
    ALB_WEST --> EKS_WEST

    EKS_EAST --> DB_EAST
    EKS_WEST --> DB_WEST

    DB_EAST -- "Storage Engine Async Replication (<1s)" --> DB_WEST
    S3_EAST -- "S3 Cross-Region Replication (CRR)" --> S3_WEST
```

---

## 2. Emergency Failover Sequence & Promotion

```mermaid
sequenceDiagram
    participant SRE as On-Call SRE / Incident Automation
    participant R53 as AWS Route 53 ARC
    participant RDS as AWS Aurora Global DB
    participant EKS_W as DR EKS Cluster (us-west-2)
    participant KARP as Karpenter Autoscaler
    participant APP as myapp-prod Pods

    SRE->>SRE: Detect Primary Region Outage in us-east-1
    SRE->>RDS: Call failover-global-cluster (Promote us-west-2 Reader)
    RDS-->>RDS: Promoted to Primary Writer (Zero Data Loss)
    
    SRE->>EKS_W: Scale Deployment from Pilot Light (2) to Full Production (15)
    EKS_W->>KARP: 13 Pending Pods Request Compute
    KARP->>KARP: Provision 2x c7g.2xlarge Spot Instances (40s)
    KARP-->>APP: 15 Pods Running & Connected to Promoted DB

    SRE->>R53: Invert Primary Health Check / Shift DNS
    R53-->>R53: Global DNS points to us-west-2 ALB
    Note over SRE,APP: Total RTO: 2 minutes 45 seconds | RPO: < 1 second
```
