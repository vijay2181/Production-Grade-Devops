# Multi-Cluster GitOps with ArgoCD — End-to-End Execution Guide

> **Project 2** | Builds on: `aws-eks-migration`
> Stack: ArgoCD · Argo Rollouts · ApplicationSets · Image Updater · Kustomize · Terraform · GitHub Actions

---

## Prerequisites

```bash
# Tools required
brew install awscli kubectl argocd helm terraform
brew install argoproj/tap/kubectl-argo-rollouts

# Verify
argocd version --client
kubectl argo rollouts version
```

---

## Step 1 — Provision all clusters with Terraform

```bash
# Create hub cluster (runs ArgoCD only)
cd terraform/environments/hub
terraform init && terraform apply -auto-approve
cd ../../..

# Create spoke clusters (dev, staging, prod)
for ENV in dev staging prod; do
  cd terraform/environments/${ENV}
  terraform init && terraform apply -auto-approve
  cd ../../..
done
```

---

## Step 2 — Bootstrap hub cluster

```bash
chmod +x scripts/bootstrap-hub.sh
./scripts/bootstrap-hub.sh us-east-1 myapp-hub

# This script:
#   1. Updates kubeconfig for all 4 clusters
#   2. Installs ArgoCD + Image Updater + Argo Rollouts on hub
#   3. Registers all 3 spoke clusters into ArgoCD
#   4. Applies AppProject (RBAC + sync windows)
#   5. Applies App of Apps (bootstraps all ApplicationSets)
```

---

## Step 3 — Verify ArgoCD UI

```bash
kubectl port-forward svc/argocd-server 8080:443 -n argocd
# Open: https://localhost:8080

ADMIN_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' | base64 -d)
echo "Password: ${ADMIN_PASS}"

# You should see 3 Applications:
#   myapp-dev     → Synced   Healthy
#   myapp-staging → Synced   Healthy
#   myapp-prod    → Synced   Healthy
```

---

## Step 4 — Configure GitHub Secrets (CI only)

```bash
# In GitHub → Settings → Secrets → Actions:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_ACCOUNT_ID
#   AWS_REGION

# NOTE: No KUBE_CONFIG_DATA needed — CI never touches the cluster.
# ArgoCD Image Updater handles deploys.
```

---

## Step 5 — Configure ArgoCD Notifications (Slack)

```bash
# Create Slack app + bot token: https://api.slack.com/apps
# Then:
kubectl create secret generic argocd-notifications-secret \
  --from-literal=slack-token=xoxb-your-slack-bot-token \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f argocd/notifications/notifications-cm.yaml

# Add notification subscriptions to each Application:
kubectl annotate application myapp-prod -n argocd \
  notifications.argoproj.io/subscribe.on-deployed.slack="#deployments" \
  notifications.argoproj.io/subscribe.on-sync-failed.slack="#alerts-prod" \
  notifications.argoproj.io/subscribe.on-health-degraded.slack="#alerts-prod"
```

---

## Step 6 — Configure ArgoCD Image Updater (ECR)

```bash
# Grant Image Updater access to ECR via IRSA
# (Already configured in Terraform via serviceAccount annotation)

# Create ECR credentials secret
kubectl create secret generic argocd-image-updater-secret \
  --from-literal=aws-access-key-id=${AWS_ACCESS_KEY_ID} \
  --from-literal=aws-secret-access-key=${AWS_SECRET_ACCESS_KEY} \
  -n argocd

# Verify Image Updater can see ECR
kubectl logs -l app.kubernetes.io/name=argocd-image-updater \
  -n argocd --tail=20
# Expected: ... Successfully logged into registry

# Test: push a new image to ECR
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
docker build -t ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0 \
  ../aws-eks-migration/app/
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0

# Wait 2-5 min, then check if Image Updater committed back to Git:
git pull
cat apps/myapp/overlays/dev/kustomization.yaml | grep newTag
# Expected: newTag: v1.1.0
```

---

## Step 7 — Deploy Canary Rollout to Prod

```bash
kubectl config use-context myapp-prod

# Apply canary Rollout (replaces standard Deployment in prod)
kubectl apply -f argo-rollouts/canary/rollout.yaml -n myapp-prod
kubectl apply -f argo-rollouts/canary/services.yaml -n myapp-prod
kubectl apply -f argo-rollouts/canary/analysis-template.yaml -n myapp-prod

# Verify Rollout is healthy
kubectl argo rollouts get rollout myapp-api -n myapp-prod
# Expected: Status: Healthy, replicas: 5, all stable

# Trigger a new canary deploy
kubectl argo rollouts set image myapp-api \
  api=123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0 \
  -n myapp-prod

# Watch it progress: 10% → analysis → 50% → analysis → 100%
kubectl argo rollouts get rollout myapp-api -n myapp-prod --watch
```

---

## Step 8 — Deploy Blue/Green to Staging

```bash
kubectl config use-context myapp-staging

kubectl apply -f argo-rollouts/bluegreen/rollout.yaml -n myapp-staging

# Trigger blue/green deploy
kubectl argo rollouts set image myapp-api-bluegreen \
  api=123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0 \
  -n myapp-staging

# Watch green come up (preview service)
kubectl argo rollouts get rollout myapp-api-bluegreen -n myapp-staging --watch

# Test green via preview service before promoting
# (see TESTING-GUIDE.md Phase 7)

# Promote green → active
./scripts/promote-canary.sh promote
```

---

## Step 9 — Install Monitoring

```bash
# Install kube-prometheus-stack on hub (monitors all clusters via remote_write)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.additionalScrapeConfigs[0].job_name=argocd \
  --wait

# Import ArgoCD Grafana dashboard
kubectl create configmap argocd-grafana-dashboard \
  --from-file=monitoring/grafana/argocd-dashboard.json \
  -n monitoring

# Port-forward Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open: http://localhost:3000 → Dashboards → ArgoCD Multi-Cluster Overview
```

---

## Step 10 — Verify Full GitOps Loop

```bash
# Make a change, push, watch ArgoCD deploy automatically
echo "# $(date)" >> apps/myapp/overlays/dev/patch.yaml
git add . && git commit -m "test: verify gitops loop" && git push origin develop

# Watch ArgoCD detect and sync
watch -n5 "argocd app get myapp-dev | grep -E 'Sync|Health|Revision'"

# Expected within 3 min:
#   Sync Status:   Synced
#   Health Status: Healthy
#   Revision:      <your commit sha>
```

---

## Day-2 Operations

```bash
# See all applications across all clusters
argocd app list

# Check which apps are OutOfSync
argocd app list | grep OutOfSync

# Manually sync prod (after review)
argocd app sync myapp-prod

# Promote a paused canary
./scripts/promote-canary.sh promote

# Abort a canary (emergency rollback)
./scripts/promote-canary.sh abort

# Scale prod manually (will be reverted by ArgoCD selfHeal if enabled)
kubectl scale deployment api --replicas=10 -n myapp-prod --context=myapp-prod

# See rollout history
kubectl argo rollouts history rollout myapp-api -n myapp-prod

# Rollback to a specific revision
kubectl argo rollouts undo myapp-api --to-revision=3 -n myapp-prod
```

---

## Folder Structure

```
argocd-multicluster/
├── ARCHITECTURE.md              ← hub-spoke model, GitOps flow diagram
├── README.md                    ← this file
├── TESTING-GUIDE.md             ← 10-phase test guide
├── apps/myapp/
│   ├── base/                    ← shared: Deployment, Service, HPA, PDB, NetworkPolicy
│   └── overlays/
│       ├── dev/                 ← 1 replica, debug logging, dev DB
│       ├── staging/             ← 2 replicas, blue/green Rollout
│       └── prod/                ← 5 replicas, canary Rollout, Image Updater managed
├── argocd/
│   ├── hub/                     ← ArgoCD install, argocd-cm, RBAC config
│   ├── projects/                ← AppProject (RBAC + sync windows)
│   ├── applicationsets/         ← App of Apps + myapp + cluster-addons
│   └── notifications/           ← Slack templates + triggers
├── argo-rollouts/
│   ├── canary/                  ← Rollout + 2 Services + 3 AnalysisTemplates
│   └── bluegreen/               ← Rollout + active/preview Services
├── terraform/
│   └── environments/
│       ├── hub/                 ← t3.medium × 2 nodes (ArgoCD only)
│       ├── dev/                 ← t3.small × 2 nodes (spot)
│       ├── staging/             ← t3.medium × 2 nodes (spot)
│       └── prod/                ← t3.large × 3-20 nodes (spot + system)
├── cicd/.github/workflows/
│   └── ci.yml                   ← Build + push ONLY (no cluster access)
├── monitoring/
│   ├── prometheus/              ← ArgoCD scrape config + alert rules
│   └── grafana/                 ← Multi-cluster ArgoCD dashboard
└── scripts/
    ├── bootstrap-hub.sh         ← Full one-shot hub setup
    ├── register-clusters.sh     ← Register spokes into ArgoCD
    ├── promote-canary.sh        ← promote/abort/status
    └── (rollback from project1 still works)
```
