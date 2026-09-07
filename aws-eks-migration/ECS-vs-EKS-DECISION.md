# ECS vs EKS — Why We Chose EKS (Honest Decision Record)

> This document records the technology decision between AWS ECS and AWS EKS.
> ECS is a valid choice. This file explains why EKS was selected for this project
> and when you should pick ECS instead.

---

## TL;DR

| | ECS (Fargate) | EKS |
|---|---|---|
| Setup time | 30 minutes | 2–4 hours |
| Learning curve | Low | High |
| Ops overhead | Near zero | Medium |
| Cost (small app) | ~$200/month | ~$400–500/month |
| AWS lock-in | 100% | Partial |
| Multi-cloud portability | ❌ | ✅ |
| Helm ecosystem | ❌ | ✅ |
| GitOps (ArgoCD / Flux) | ❌ | ✅ |
| Service mesh (Istio, Cilium) | Limited | ✅ |
| CNCF ecosystem | ❌ | ✅ |
| Jobs market / community | Smaller | Massive |

---

## ECS is Genuinely Good — Don't Dismiss It

ECS (especially Fargate) is one of the best managed container platforms available.
AWS handles the control plane, node provisioning, and OS patching entirely.
You define a Task Definition, create a Service, attach an ALB, and you're done.

```
ECS mental model (4 concepts):
  Task Definition → Service → Cluster → ALB
```

For a small team deploying on AWS, this is legitimately the right answer.

---

## EKS is More Complex — Acknowledge It Honestly

```
EKS / Kubernetes mental model (20+ concepts):
  Pod → ReplicaSet → Deployment → Service →
  Ingress → IngressClass → HPA → PDB →
  NetworkPolicy → ServiceAccount → RBAC →
  StorageClass → PVC → PV → ConfigMap →
  Secret → Namespace → LimitRange → ResourceQuota
```

Kubernetes has a real learning cliff. If your team does not already know it,
you are adding months of ramp-up time before you become productive.
That is a real cost that must be factored in.

---

## Cost Reality Check

### ECS Fargate (3 tasks: 0.5 vCPU / 1 GB RAM each)

```
3x Fargate tasks               ~$45/month
RDS Multi-AZ (db.t3.medium)   ~$100/month
ElastiCache (cache.t3.micro)   ~$30/month
ALB                            ~$25/month
─────────────────────────────────────────
Total                          ~$200/month
```

### EKS (same workload)

```
EKS control plane (managed)    ~$73/month   ← you pay this, ECS does not charge it
3x t3.large worker nodes        ~$180/month  ← you manage these
RDS Multi-AZ (db.t3.medium)    ~$100/month
ElastiCache (cache.t3.micro)    ~$30/month
ALB                             ~$25/month
─────────────────────────────────────────
Total                           ~$408/month
```

**ECS saves ~$200/month for a small application.** That is real money, especially
for a startup or a cost-sensitive project. EKS also has hidden costs:
cluster upgrade windows, node group patching, add-on management (LBC, CA, CSI),
and the engineering hours to operate all of it.

---

## Why We Still Chose EKS — The Specific Reasons

### 1. Kubernetes-Native: One Skill, Every Cloud

```
Kubernetes manifest:
  kubectl apply -f deployment.yaml
  └─ Runs on EKS        (AWS)
  └─ Runs on GKE        (GCP)
  └─ Runs on AKS        (Azure)
  └─ Runs on on-prem    (kubeadm, k3s, Rancher, OpenShift)
  └─ Runs on laptop     (kind, minikube, Docker Desktop)

ECS task definition:
  Works ONLY on AWS ECS.
  Move to GCP?     Rewrite from scratch.
  Go hybrid?       Not possible.
  Run locally?     Limited (no full ECS emulator).
```

If AWS raises prices, the company gets acquired, or the team moves to hybrid
cloud — with EKS you pick up your YAML files and redeploy. With ECS you rewrite.

### 2. Portability = Negotiating Power

Vendor lock-in is not just a technical risk — it is a business risk.
When 100% of your container infrastructure is ECS-specific, AWS knows you
cannot leave cheaply. Kubernetes-native workloads give you a credible exit option,
which keeps your cloud costs negotiable.

### 3. The CNCF Ecosystem

EKS gives you access to the entire Cloud Native Computing Foundation (CNCF)
ecosystem out of the box. None of these work natively with ECS:

```
GitOps          ArgoCD, Flux
Service Mesh    Istio, Linkerd, Cilium
Secrets         External Secrets Operator, Sealed Secrets, Vault Agent
Policy          OPA Gatekeeper, Kyverno
Networking      Cilium eBPF, Calico
Observability   Prometheus, Grafana, Loki, Tempo, OpenTelemetry
Ingress         Nginx, Traefik, Kong, Envoy Gateway
Autoscaling     KEDA (event-driven), VPA, Karpenter
```

With ECS, you are limited to what AWS builds and what the AWS marketplace offers.

### 4. Helm — The Package Manager for Infrastructure

```bash
# Install a full PostgreSQL HA cluster on EKS:
helm install postgresql bitnami/postgresql-ha

# Install cert-manager (automatic TLS):
helm install cert-manager jetstack/cert-manager

# Install Redis Sentinel:
helm install redis bitnami/redis

# Install Kafka:
helm install kafka bitnami/kafka
```

ECS has no equivalent. Every dependency must be configured manually through
AWS-specific services or CloudFormation.

### 5. GitOps with ArgoCD / Flux

```
Git repo (source of truth)
    │
    ▼
ArgoCD watches the repo
    │
    ▼
Detects drift between Git and cluster
    │
    ▼
Auto-syncs — cluster always matches Git
```

This means:
- Every change is a Git commit — full audit trail
- Rollback = `git revert` — instant, no manual steps
- Dev/staging/prod managed from the same repo with overlays
- No human ever runs `kubectl apply` in production manually

ECS does not have a native GitOps story. You can approximate it with
CodePipeline + CloudFormation, but it is not the same.

### 6. Advanced Autoscaling

```
ECS autoscaling:
  CloudWatch metric → Application Auto Scaling → adjust task count
  (works, but limited to AWS metrics)

EKS autoscaling options:
  HPA    → CPU / memory / custom Prometheus metrics
  VPA    → Right-size resource requests automatically
  KEDA   → Scale on ANY event: SQS depth, Kafka lag,
            Redis list length, Prometheus query, cron schedule
  Karpenter → Node-level autoscaling, provisions exactly the
              right instance type for the pending pod in ~30s
```

### 7. Fine-Grained Security

```
NetworkPolicy:
  api pods → can reach redis:6379
  api pods → can reach RDS:5432
  redis pods → cannot reach RDS
  All other traffic → BLOCKED by default
```

ECS has Security Groups at the task level, which is good but coarser.
Kubernetes NetworkPolicy gives you pod-level micro-segmentation with
label selectors, making lateral movement nearly impossible even if one
service is compromised.

### 8. Multi-Tenancy

EKS Namespaces + RBAC allows multiple teams to share one cluster safely:

```
team-frontend   namespace → frontend devs have access
team-backend    namespace → backend devs have access
team-data       namespace → data engineers have access
monitoring      namespace → platform team only
```

Each team gets resource quotas, limit ranges, and network isolation.
ECS does not have an equivalent namespace + RBAC model.

---

## When You Should Choose ECS Instead

Be honest with yourself. Choose ECS if:

```
✅ Team is 1–5 engineers
✅ You are deploying only on AWS, with no plans to change
✅ You have fewer than 10 services
✅ Nobody on the team knows Kubernetes
✅ You are a startup — speed to market beats flexibility
✅ Monthly infra budget is under $300
✅ You want AWS to manage everything (Fargate = serverless containers)
✅ You do not need Helm, ArgoCD, service mesh, or KEDA
```

ECS Fargate is genuinely excellent for this profile. It is not a compromise —
it is the right tool for that job.

---

## When You Should Choose EKS

Choose EKS if:

```
✅ Team already has Kubernetes knowledge
✅ You have 10+ microservices
✅ Multi-cloud or hybrid cloud is in the roadmap
✅ You need GitOps (ArgoCD / Flux)
✅ You need Helm charts from the ecosystem
✅ You need KEDA, Karpenter, or VPA
✅ You need a service mesh (Istio, Cilium)
✅ You are in a regulated industry (PCI, HIPAA) needing fine-grained RBAC + audit
✅ You run on-prem too and want the same manifests everywhere
✅ A platform team will manage infra for multiple product teams
✅ Vendor portability is a strategic requirement
```

---

## The Migration Path

It is also not a permanent choice. A common pattern:

```
Stage 1 (0–6 months):   Docker Compose on a single VM
                         → Fast to start, zero infra cost

Stage 2 (6–18 months):  Migrate to ECS Fargate
                         → Managed, scalable, no Kubernetes learning cost

Stage 3 (18+ months):   Migrate from ECS to EKS
                         → When you hit ECS limits, need portability,
                           or team has grown into Kubernetes
```

You do not have to go directly from Docker Compose to EKS.
ECS is a perfectly valid intermediate step.

---

## Final Decision Summary for This Project

We chose **EKS** for the following concrete reasons:

1. **Team is Kubernetes-native** — existing knowledge, no ramp-up cost
2. **Multi-cloud roadmap** — GCP evaluation is on the 12-month plan
3. **ArgoCD** is already used for another project — consistent GitOps story
4. **KEDA** is needed for event-driven scaling from an SQS queue
5. **Karpenter** will reduce node costs by ~40% vs fixed node groups
6. **Platform team** manages 6 product teams — namespaces + RBAC is essential
7. **Portability** — the same Helm charts will run in the DR environment on-prem

If none of those 7 reasons apply to your situation, **ECS Fargate is the better choice**.
