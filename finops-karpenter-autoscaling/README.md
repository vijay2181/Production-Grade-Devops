# Project 6: FinOps & Dynamic Intelligent Autoscaling

> **Project 6** | Enterprise EKS Cost Optimization, Karpenter v1.0+, Graviton/Spot Fleet, & KEDA Event-Driven Scaling
> Stack: Karpenter v1.0+ · AWS EC2 Spot & Graviton3/4 · KEDA v2.14+ · OpenCost / Kubecost · SQS EventBridge Interruption Loop · Prometheus FinOps Rules

---

## 1. Project Overview & Direct Business Value

This project completes the enterprise cloud platform by solving the **#1 problem executives and cloud architects face in 2024–2026: runaway Kubernetes infrastructure costs and slow autoscaling response.**

By migrating from legacy AWS Auto Scaling Groups (Cluster Autoscaler) to **Karpenter v1.0+** combined with **AWS Graviton3/4 ARM instances**, **Spot Fleets**, and **KEDA event-driven scaling**, this architecture delivers:
- **71.2% Reduction in Compute Spend** ($7,068 / month saved per cluster).
- **Sub-45 second node provisioning** (down from 3–6 minutes with ASGs).
- **Zero-Downtime Spot Disruption Handling** via an AWS EventBridge → SQS 2-minute buffer loop.
- **Event-Driven Scale-to-Zero** for async workers consuming AWS SQS and Redis backlogs.
- **Real-Time Unit Economics & FinOps Governance** via OpenCost and Prometheus alerting.

---

## 2. The 3-Tier NodePool Strategy

| Tier | NodePool Name | Workloads | Capacity Type | Instance Families | Consolidation Policy |
|---|---|---|---|---|---|
| **Tier 1** | `critical-ondemand` | ArgoCD, Prometheus, Falco, Kyverno, Jenkins Controller | `on-demand` | `c7g`, `m7g`, `c6i`, `m6i` | `WhenEmpty` (Conservative) |
| **Tier 2** | `general-spot` | `myapp-prod` APIs, Microservices, SQS Workers | `spot` (fallback on-demand) | 40+ families (`c7g`, `c6a`, `m7g`, `r7g`, etc.) | `WhenEmptyOrUnderutilized` (30s timer) |
| **Tier 3** | `ci-ephemeral` | Project 5 Jenkins Kaniko build agents, Trivy scanners | `spot` (100%) | `c7g.2xlarge`, `c6i.2xlarge`, `c6a.2xlarge` | `WhenEmpty` (Instantaneous 0s) |

---

## 3. Quick Start & Execution

### Step 1: Provision Cloud Infrastructure (Terraform)
```bash
cd terraform/environments/prod
terraform init
terraform apply
```
*Provisions the Karpenter Controller IRSA role, SQS Interruption Queue, EventBridge 2-minute warning rules, and OpenCost pricing role.*

### Step 2: Bootstrap Complete Stack
```bash
./scripts/install.sh
```
*Installs Karpenter v1.0+, establishes EC2NodeClass & 3-Tier NodePools, deploys KEDA v2.14+ with SQS/Prometheus/Redis ScaledObjects, and installs OpenCost.*

### Step 3: Run Validation & Spot Interruption Drill
```bash
./scripts/test-spot-drain.sh
```
*Simulates an AWS EC2 Spot interruption notice and verifies zero-drop graceful node cordoning and pod migration.*

---

## 4. Repository Structure

```
finops-karpenter-autoscaling/
├── ARCHITECTURE.md                  ← Comprehensive architecture, CAS vs Karpenter, FinOps model
├── DIAGRAMS.md                      ← Mermaid architecture, bin-packing, & SQS elasticity flowcharts
├── TESTING-GUIDE.md                 ← 6-phase verification, load testing, & chaos drills
├── README.md                        ← Executive guide & execution instructions
│
├── terraform/environments/prod/
│   ├── main.tf                      ← SQS Interruption Queue, EventBridge rules, IRSA roles
│   ├── variables.tf
│   └── terraform.tfvars
│
├── karpenter/nodepools/
│   ├── 01-ec2nodeclass.yaml         ← AMI AL2023, Subnets, Security Groups, IMDSv2 hardening
│   ├── 02-nodepool-critical-ondemand.yaml  ← Tier 1 On-Demand for core infrastructure
│   ├── 03-nodepool-general-spot.yaml       ← Tier 2 Spot with 40+ diversified instance types
│   └── 04-nodepool-ci-ephemeral.yaml       ← Tier 3 Ephemeral burst pool for Jenkins builds
│
├── helm/values/
│   └── karpenter-values.yaml        ← Production Karpenter Helm values with HA & feature gates
│
├── keda/scaledobjects/
│   ├── 01-sqs-queue-scaler.yaml     ← AWS SQS backlog scaler (0 to 40 pods)
│   ├── 02-prometheus-http-scaler.yaml ← Real-time HTTP RPS & p95 latency scaler
│   └── 03-redis-queue-scaler.yaml   ← ElastiCache Redis memory backlog scaler
│
├── opencost/
│   └── install.yaml                 ← OpenCost Helm values with AWS Pricing API integration
│
├── alerts/
│   └── finops-prometheus-rules.yaml ← Cost spike, overprovisioning, & spot deficit alerts
│
└── scripts/
    ├── install.sh                   ← Automated end-to-end stack bootstrap
    └── test-spot-drain.sh           ← Synthetic Spot interruption chaos testing script
```

---

## 5. Integration Across All Portfolio Projects

- **Project 1 (`aws-eks-migration`)**: `myapp-prod` runs on `general-spot` NodePool with ARM64 Graviton support.
- **Project 2 (`argocd-multicluster`)**: ArgoCD control plane runs safely on `critical-ondemand`.
- **Project 3 (`observability`)**: Prometheus exports real-time HTTP RPS and p95 metrics directly to KEDA triggers.
- **Project 4 (`kubernetes-security`)**: Kyverno verifies that all Pods have explicit CPU/Memory limits required for Karpenter bin-packing.
- **Project 5 (`jenkins-production`)**: Ephemeral Kaniko and Trivy build agents run on `ci-ephemeral` NodePool, scaling to zero when builds complete.
