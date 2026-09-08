# Multi-Cluster GitOps with ArgoCD

> **Project 2** — builds directly on `aws-eks-migration`.
> You already have one EKS cluster running your app with Helm.
> This project adds: ArgoCD hub-spoke model, ApplicationSets,
> Argo Rollouts (canary + blue/green), notifications, and full GitOps loop.

---

## What This Project Builds

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GitHub Repository                            │
│   apps/myapp/overlays/dev      ← dev manifests                     │
│   apps/myapp/overlays/staging  ← staging manifests                 │
│   apps/myapp/overlays/prod     ← prod manifests                    │
└───────────────────────┬─────────────────────────────────────────────┘
                        │  git push triggers
                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    HUB CLUSTER (EKS)                                │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                      ArgoCD                                  │  │
│  │   ApplicationSet watches Git → deploys to all clusters       │  │
│  │   Image Updater watches ECR → updates Git tag automatically  │  │
│  │   Notifications → Slack on sync / fail / health change       │  │
│  └──────────┬──────────────┬──────────────────┬─────────────────┘  │
└─────────────┼──────────────┼──────────────────┼────────────────────┘
              │              │                  │
    ┌─────────▼──┐  ┌────────▼───┐  ┌──────────▼──┐
    │ DEV cluster│  │STAGING clus│  │ PROD cluster │
    │  myapp-dev │  │myapp-staging│  │  myapp-prod  │
    │  1 replica │  │  2 replicas│  │  5 replicas  │
    │  no canary │  │  canary 20%│  │  canary 10%  │
    └────────────┘  └────────────┘  └─────────────┘
```

---

## Key Concepts

| Concept | What it does |
|---|---|
| **Hub cluster** | Runs ArgoCD. Manages all other clusters. No app workloads. |
| **Spoke cluster** | Runs app workloads. Managed BY ArgoCD on hub. |
| **Application** | ArgoCD CRD: one app, one cluster, one namespace |
| **ApplicationSet** | One template → generates Applications for all clusters automatically |
| **App of Apps** | ArgoCD Application that deploys other Applications (bootstrap pattern) |
| **Argo Rollouts** | Progressive delivery controller: canary, blue/green, analysis |
| **Image Updater** | Watches ECR, updates image tag in Git, triggers sync automatically |
| **Sync Waves** | Control ORDER of resource deployment (e.g. CRDs before Deployments) |

---

## Architecture: Hub-Spoke Model

```
Why hub-spoke instead of one ArgoCD per cluster?

One ArgoCD per cluster:
  ✗ 4 clusters × ArgoCD = 4 places to configure, update, monitor
  ✗ No central view of all deployments
  ✗ Each ArgoCD manages only itself

Hub-spoke (this project):
  ✓ ONE ArgoCD on hub manages ALL clusters
  ✓ Single pane of glass — see all apps across all clusters
  ✓ Spoke clusters do NOT need ArgoCD installed
  ✓ Scale to 100 clusters from one hub
  ✓ Hub cluster can be locked down — only ArgoCD has cluster-admin on spokes
```

---

## GitOps Flow (end to end)

```
1. Developer pushes code to GitHub (feature branch)
         │
2. GitHub Actions runs:
   - npm test
   - docker build
   - trivy scan
   - docker push → ECR (tagged: v1.2.3-abc1234)
         │
3. ArgoCD Image Updater detects new ECR tag
   - Updates apps/myapp/overlays/prod/kustomization.yaml
   - Commits back to Git: image.tag = v1.2.3-abc1234
         │
4. ArgoCD detects Git change (polls every 3 min or webhook)
   - ApplicationSet generates/updates Application for prod cluster
   - ArgoCD syncs: applies new manifests to prod cluster
         │
5. Argo Rollouts takes over (in prod):
   - Deploys new version to 10% of pods (canary)
   - Waits 5 min, checks Prometheus metrics
   - If error rate OK → promote to 50% → 100%
   - If error rate high → auto rollback
         │
6. ArgoCD Notification fires:
   - Slack: "✅ myapp v1.2.3 promoted to 100% in prod"
   - or: "🚨 myapp v1.2.3 canary FAILED — rolled back"
```

---

## Folder Structure

```
argocd-multicluster/
├── ARCHITECTURE.md                   ← this file
├── README.md                         ← step-by-step execution
├── TESTING-GUIDE.md
│
├── apps/myapp/                       ← application manifests
│   ├── base/                         ← shared across all envs
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── argocd/
│   ├── hub/                          ← ArgoCD install + config
│   ├── projects/                     ← AppProjects (RBAC boundaries)
│   ├── applicationsets/              ← ApplicationSets (multi-cluster deploy)
│   ├── notifications/                ← Slack + email alerts
│   └── rbac/                         ← Who can deploy what
│
├── argo-rollouts/
│   ├── canary/                       ← Canary Rollout + AnalysisTemplate
│   └── bluegreen/                    ← Blue/Green Rollout
│
├── terraform/
│   ├── modules/                      ← Reusable VPC + EKS modules
│   └── environments/
│       ├── hub/                      ← Hub cluster (ArgoCD only)
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── helm/myapp/                       ← Helm chart (same as project 1)
├── cicd/.github/workflows/           ← Build + push only (no helm deploy)
├── monitoring/                       ← ArgoCD metrics + dashboards
└── scripts/                          ← bootstrap-hub, register-cluster, promote
```
