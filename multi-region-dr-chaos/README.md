# Project 7: Multi-Region Disaster Recovery & Automated Chaos Engineering

> **Project 7** | Enterprise Multi-Region DR (Warm Standby / Pilot Light), Cross-Region State Replication, Velero Backup & Restore, & Automated Chaos Mesh Game Days
> Stack: AWS Route 53 ARC · Multi-Region EKS (`us-east-1` & `us-west-2`) · Aurora Global Database · S3 Cross-Region Replication (CRR) · Velero v1.13+ · Chaos Mesh v2.6+

---

## 1. Project Overview & Business Value

Enterprise platforms cannot afford regional outages. This project provides a production-grade **Multi-Region Disaster Recovery (DR)** and **Automated Chaos Engineering framework**, moving beyond theoretical runbooks to proven, code-driven recovery:

- **RTO < 4 Minutes**: Automated failover shifts global traffic from Primary (`us-east-1`) to Warm Standby (`us-west-2`).
- **RPO < 1 Second**: AWS Aurora Global Database sub-second cross-region replication.
- **Cluster State & Volume Snapshots**: Velero v1.13+ with AWS CSI plugins taking hourly snapshots replicated to cross-region S3 with CRR.
- **Continuous Chaos Engineering**: Automated Chaos Mesh game days testing pod kills, network partitions, AZ blackholes, and DNS degradation.

---

## 2. Repository Structure

```
multi-region-dr-chaos/
├── ARCHITECTURE.md                  ← Multi-region DR models, state replication, & recovery objectives
├── DIAGRAMS.md                      ← Mermaid architecture flowcharts & failover sequence diagrams
├── TESTING-GUIDE.md                 ← 4-phase verification, disaster simulation, & chaos validation
├── README.md                        ← Executive guide & execution instructions
│
├── terraform/environments/prod/
│   ├── main.tf                      ← Multi-region S3 CRR, Route 53 failover routing, & Velero IRSA
│   ├── variables.tf
│   └── terraform.tfvars
│
├── velero/values/
│   ├── velero-primary-values.yaml   ← Velero v1.13+ Helm values for us-east-1 (Active backups)
│   └── velero-secondary-values.yaml ← Velero v1.13+ Helm values for us-west-2 (ReadOnly DR target)
│
├── chaos/experiments/
│   └── chaos-experiments.yaml       ← Chaos Mesh PodKill, NetworkLatency, AZ Blackhole, & DNS chaos
│
└── scripts/
    ├── failover-to-dr.sh            ← Automated 5-step emergency cross-region failover script
    └── run-game-day.sh              ← Automated Chaos Mesh execution & SLO verification script
```

---

## 3. Quick Start & Execution

### Step 1: Provision Multi-Region Cloud Infrastructure (Terraform)
```bash
cd terraform/environments/prod
terraform init
terraform apply
```

### Step 2: Test Backup & Restore (Velero)
```bash
# Run on-demand backup in primary region
velero backup create dr-drill-backup --include-namespaces myapp-prod --wait

# Restore in secondary region
velero restore create --from-backup dr-drill-backup --wait
```

### Step 3: Execute Regional Failover Drill
```bash
./scripts/failover-to-dr.sh
```
*Promotes Aurora DB reader to writer, scales warm standby pods to 100%, and shifts Route 53 DNS routing.*

### Step 4: Run Chaos Mesh Game Day
```bash
./scripts/run-game-day.sh
```
*Injects failure scenarios to validate that PDBs, retries, and SLO error budgets hold up under stress.*

---

## 4. Complete Integration Across the 7 Projects

```
Project 1 (AWS EKS Migration):        Core microservice architecture (myapp + Postgres + Redis)
Project 2 (ArgoCD Multi-Cluster):     GitOps engine synchronizing manifests across both regions
Project 3 (Deep Observability):       Prometheus SLO error budget rules gating Chaos Mesh experiments
Project 4 (Cluster Security):         Falco & Kyverno runtime guardrails active during failover
Project 5 (Jenkins CI Automation):    Shared Library CI pipeline triggering automated Game Days
Project 6 (FinOps & Karpenter):       Dynamic Karpenter Spot elasticity bursting DR capacity in 40s
Project 7 (Multi-Region DR & Chaos):  Cross-region warm standby, Aurora Global DB, Velero & Chaos Mesh
```
