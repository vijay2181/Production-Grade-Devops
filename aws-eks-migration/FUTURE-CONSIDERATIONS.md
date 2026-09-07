# Future Considerations — Post-Migration Roadmap

> This file covers what comes AFTER you are stable on EKS.
> These are not required for the initial migration.
> Implement them in order — each one builds on the previous.

---

## Priority Order

```
Phase A  ─ Cost optimisation          (do this first — saves money immediately)
Phase B  ─ GitOps with ArgoCD         (replaces manual Helm deploys)
Phase C  ─ Karpenter                  (smarter node autoscaling)
Phase D  ─ KEDA                       (event-driven pod autoscaling)
Phase E  ─ Service Mesh (Istio)       (advanced traffic + security)
Phase F  ─ Multi-region DR            (disaster recovery)
Phase G  ─ Platform Engineering       (internal developer platform)
```

---

## Phase A — Cost Optimisation

### A1. Spot Instances for Application Node Group

Right now the app node group uses On-Demand `t3.large` at ~$60/node/month.
Spot instances are the same hardware at ~70% discount.

```yaml
# In terraform/environments/prod/resources.tf
# Add to the "app" managed node group:

eks_managed_node_groups = {
  app = {
    instance_types = ["t3.large", "t3a.large", "m5.large", "m5a.large"]
    capacity_type  = "SPOT"          # ← change ON_DEMAND to SPOT

    # Multiple instance types = more Spot pool diversity = fewer interruptions
  }
}
```

**Saving:** 3 nodes × $60 → 3 nodes × $18 = **save ~$126/month**

### A2. Savings Plans for Stable Workloads

For the system node group (always-on), buy a 1-year Compute Savings Plan:
- On-Demand: ~$60/node/month
- 1-year no-upfront Savings Plan: ~$38/node/month
- **Save ~$44/month per stable node**

### A3. Karpenter (see Phase C) — Biggest Cost Win

Karpenter provisions exactly the right node size for pending pods and
terminates nodes the moment they are empty. Cluster Autoscaler cannot do this.

**Typical saving: 30–50% on EC2 costs.**

### A4. Scale to Zero at Night (non-prod)

```bash
# Scale down dev cluster at 8pm, back up at 8am
# Add to a cron job or GitHub Actions scheduled workflow:

# Scale down
kubectl scale deployment myapp-myapp --replicas=0 -n myapp-dev

# Scale up
kubectl scale deployment myapp-myapp --replicas=1 -n myapp-dev
```

Or use a Kubernetes CronJob with `kubectl`:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-down-dev
  namespace: myapp-dev
spec:
  schedule: "0 20 * * 1-5"      # 8pm weekdays
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scaler-sa
          containers:
            - name: kubectl
              image: bitnami/kubectl
              command:
                - kubectl
                - scale
                - deployment/myapp-myapp
                - --replicas=0
                - -n
                - myapp-dev
          restartPolicy: Never
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-up-dev
  namespace: myapp-dev
spec:
  schedule: "0 8 * * 1-5"       # 8am weekdays
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scaler-sa
          containers:
            - name: kubectl
              image: bitnami/kubectl
              command:
                - kubectl
                - scale
                - deployment/myapp-myapp
                - --replicas=1
                - -n
                - myapp-dev
          restartPolicy: Never
```

**Saving on dev:** ~$130/month (nodes idle 128 hours/week)

### A5. Right-size with VPA (Vertical Pod Autoscaler)

Most teams set resource requests too high "to be safe". VPA watches actual
usage and recommends (or automatically sets) the right values.

```bash
# Install VPA
helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm install vpa fairwinds-stable/vpa --namespace kube-system

# Run in recommendation mode first (no auto-apply)
kubectl apply -f - <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api-vpa
  namespace: myapp
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: myapp-myapp
  updatePolicy:
    updateMode: "Off"    # Recommendation only — change to "Auto" when confident
EOF

# After 24 hours, check recommendations:
kubectl describe vpa api-vpa -n myapp
# Shows: Lower Bound, Target, Upper Bound for CPU and Memory
```

---

## Phase B — GitOps with ArgoCD

### What changes

Today: GitHub Actions runs `helm upgrade` directly → **push-based deploy**
With ArgoCD: ArgoCD watches Git, detects drift, auto-syncs → **pull-based GitOps**

```
Current flow:
  git push → GitHub Actions → helm upgrade → EKS

ArgoCD flow:
  git push → ArgoCD detects change → ArgoCD syncs → EKS
             (ArgoCD runs INSIDE the cluster, pulls from Git)
```

### Why it is better

- **Drift detection** — if someone runs `kubectl apply` manually, ArgoCD detects
  the drift and alerts or auto-reverts
- **No kubeconfig in CI** — GitHub Actions no longer needs cluster access
- **Full audit trail** — every sync event recorded in ArgoCD UI
- **One-click rollback** — rollback in the ArgoCD UI = git revert

### Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s

# Get initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d

# Port-forward UI
kubectl port-forward svc/argocd-server 8080:443 -n argocd
# Open: https://localhost:8080  (admin / <password above>)
```

### Create ArgoCD Application

```yaml
# argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/myapp
    targetRevision: main
    path: helm/charts/myapp
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: image.tag
          value: "v1.0.0"    # ArgoCD Image Updater will keep this in sync
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual kubectl changes
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
```

```bash
kubectl apply -f argocd/application.yaml
# ArgoCD will now auto-deploy on every push to main
```

### ArgoCD Image Updater (auto-update image tag)

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# Annotate the ArgoCD Application to watch ECR:
kubectl annotate application myapp-prod -n argocd \
  argocd-image-updater.argoproj.io/image-list="api=123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api" \
  argocd-image-updater.argoproj.io/api.update-strategy="semver" \
  argocd-image-updater.argoproj.io/write-back-method="git"
```

Now when CI pushes a new image to ECR → Image Updater detects it →
updates the Git repo → ArgoCD deploys automatically. Full GitOps loop.

---

## Phase C — Karpenter (Smarter Node Autoscaling)

### Problem with Cluster Autoscaler

```
Cluster Autoscaler:
  - Checks every 10s if pods are unschedulable
  - Picks a node group and adds a node of FIXED size (e.g. always t3.large)
  - Waits ~2-3 minutes for node to be ready
  - Cannot bin-pack efficiently
  - Slow to scale down (10 min default wait)
```

### What Karpenter does differently

```
Karpenter:
  - Detects unschedulable pod immediately
  - Calculates EXACTLY what instance type fits the pod's requests
  - Provisions that specific instance in ~30 seconds
  - Bins multiple pods onto the cheapest possible combination
  - Terminates nodes aggressively when empty
  - Supports Spot interruption handling natively
```

### Install Karpenter

```bash
# Install via Helm
helm repo add karpenter https://charts.karpenter.sh
helm repo update

helm upgrade --install karpenter karpenter/karpenter \
  --namespace kube-system \
  --set settings.clusterName=myapp-prod \
  --set settings.interruptionQueue=myapp-prod-karpenter \
  --wait
```

### NodePool definition

```yaml
# karpenter/nodepool.yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "t"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      nodeClassRef:
        name: default
  limits:
    cpu: 100        # max 100 vCPUs in this pool
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s    # aggressively reclaim empty nodes
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: KarpenterNodeRole-myapp-prod
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: myapp-prod
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: myapp-prod
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
```

---

## Phase D — KEDA (Event-Driven Autoscaling)

### What HPA cannot do

HPA scales on CPU and memory. But many real scaling needs are:
- **SQS queue depth** — 1000 messages waiting → spin up more workers
- **Kafka consumer lag** — lag > 10000 → add more consumers
- **Cron schedule** — scale to 10 pods at 9am, back to 3 at 6pm
- **Prometheus query** — custom business metric drives scaling

KEDA handles all of these.

### Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait
```

### Example: Scale on SQS queue depth

```yaml
# keda/scaledobject-sqs.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: api-sqs-scaler
  namespace: myapp
spec:
  scaleTargetRef:
    name: myapp-myapp
  minReplicaCount: 1
  maxReplicaCount: 50
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456789/myapp-jobs
        queueLength: "10"      # 1 pod per 10 messages
        awsRegion: us-east-1
        identityOwner: operator
```

### Example: Scale on Kafka consumer lag

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: api-kafka-scaler
  namespace: myapp
spec:
  scaleTargetRef:
    name: myapp-myapp
  minReplicaCount: 3
  maxReplicaCount: 30
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka.myapp.svc:9092
        consumerGroup: myapp-consumer-group
        topic: myapp-events
        lagThreshold: "100"    # 1 pod per 100 messages of lag
```

### Example: Cron-based scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: api-cron-scaler
  namespace: myapp
spec:
  scaleTargetRef:
    name: myapp-myapp
  triggers:
    - type: cron
      metadata:
        timezone: Asia/Kolkata
        start: "0 9 * * 1-5"      # 9am weekdays → scale up
        end:   "0 18 * * 1-5"     # 6pm weekdays → scale down
        desiredReplicas: "10"
```

---

## Phase E — Service Mesh with Istio

### What it adds

```
Without service mesh:
  pod A → pod B  (plain TCP, no observability, no mTLS)

With Istio:
  pod A → sidecar proxy → encrypted mTLS → sidecar proxy → pod B
           ↓                                    ↓
      metrics, traces                    metrics, traces
      traffic control                    circuit breaking
```

**Key features:**
- **mTLS everywhere** — all pod-to-pod traffic encrypted automatically
- **Traffic splitting** — send 10% of traffic to canary, 90% to stable
- **Circuit breaking** — stop sending traffic to unhealthy pods immediately
- **Distributed tracing** — end-to-end request traces across all services
- **Retry + timeout policies** — declarative, no code changes needed

### Install Istio

```bash
# Install istioctl
curl -L https://istio.io/downloadIstio | sh -
export PATH=$PWD/istio-*/bin:$PATH

# Install Istio on cluster
istioctl install --set profile=production -y

# Enable sidecar injection for myapp namespace
kubectl label namespace myapp istio-injection=enabled

# All new pods will now get an Envoy sidecar automatically
kubectl rollout restart deployment/myapp-myapp -n myapp
```

### Canary deployment with Istio

```yaml
# istio/virtualservice.yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: api-vs
  namespace: myapp
spec:
  hosts:
    - api
  http:
    - route:
        - destination:
            host: api
            subset: stable
          weight: 90
        - destination:
            host: api
            subset: canary
          weight: 10     # Send 10% to new version
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: api-dr
  namespace: myapp
spec:
  host: api
  subsets:
    - name: stable
      labels:
        version: "1.0.0"
    - name: canary
      labels:
        version: "1.1.0"
```

---

## Phase F — Multi-Region Disaster Recovery

### Architecture

```
Primary Region (us-east-1)          DR Region (us-west-2)
─────────────────────────           ─────────────────────
EKS cluster (active)                EKS cluster (standby)
RDS primary                         RDS read replica (promoted on failover)
ElastiCache primary                 ElastiCache replica
Route53 health check → primary      Route53 failover → DR if primary fails
```

### RDS Cross-Region Replica

```hcl
# terraform/environments/dr/resources.tf
resource "aws_db_instance" "rds_replica" {
  identifier             = "myapp-postgres-dr"
  replicate_source_db    = "arn:aws:rds:us-east-1:123456789:db:myapp-postgres"
  instance_class         = "db.t3.medium"
  availability_zone      = "us-west-2a"
  skip_final_snapshot    = false
  backup_retention_period = 7

  # On failover, promote this to standalone:
  # aws rds promote-read-replica --db-instance-identifier myapp-postgres-dr
}
```

### Route53 Failover

```hcl
resource "aws_route53_health_check" "primary" {
  fqdn              = "api.myapp.com"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 10
}

resource "aws_route53_record" "primary" {
  zone_id = var.hosted_zone_id
  name    = "api.myapp.com"
  type    = "CNAME"
  ttl     = 60

  failover_routing_policy {
    type = "PRIMARY"
  }
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id
  records         = [var.primary_alb_dns]
}

resource "aws_route53_record" "dr" {
  zone_id = var.hosted_zone_id
  name    = "api.myapp.com"
  type    = "CNAME"
  ttl     = 60

  failover_routing_policy {
    type = "SECONDARY"
  }
  set_identifier = "dr"
  records        = [var.dr_alb_dns]
}
```

**RTO (Recovery Time Objective):** ~5 minutes (Route53 health check + DNS TTL)
**RPO (Recovery Point Objective):** ~1 minute (RDS replica lag)

---

## Phase G — Internal Developer Platform

### The Problem at Scale

When you have 5+ teams all deploying to the same EKS cluster:
- Each team writes their own Helm charts (duplication)
- Each team manages their own CI/CD pipelines (drift)
- No standards for resource limits, security, naming
- Platform team becomes a bottleneck for every new service

### Solution: Backstage + Golden Paths

```
Developer experience:
  1. Developer goes to internal portal (Backstage)
  2. Clicks "Create new service"
  3. Fills in: service name, language, team, environment
  4. Portal generates: GitHub repo + Helm chart + CI/CD + Grafana dashboard
  5. Developer pushes code → auto-deployed to EKS in 10 minutes
  6. Zero platform team involvement
```

### Tools

```
Backstage        Internal developer portal (service catalog + templates)
Crossplane       Provision AWS resources (RDS, S3) via Kubernetes CRDs
OPA Gatekeeper   Policy enforcement (deny pods without resource limits)
Kyverno          Policy engine (auto-inject labels, security contexts)
Falco            Runtime security — detect unexpected syscalls in pods
Velero           Cluster backup and restore
Goldilocks       VPA-based right-sizing recommendations dashboard
Kubecost         Per-namespace, per-team cost visibility
```

---

## Summary — Implementation Timeline

```
Month 1   Phase A — Cost optimisation
            ├── Spot instances for app node group      (1 day)
            ├── VPA recommendations                    (1 day)
            └── Dev scale-to-zero                      (2 hours)

Month 2   Phase B — ArgoCD GitOps
            ├── Install ArgoCD                         (1 day)
            ├── Migrate pipelines off helm-in-CI       (2 days)
            └── ArgoCD Image Updater                   (1 day)

Month 3   Phase C — Karpenter
            ├── Replace Cluster Autoscaler             (2 days)
            └── NodePool tuning                        (1 day)

Month 4   Phase D — KEDA
            ├── Identify event-driven scaling needs    (1 day)
            └── Deploy ScaledObjects per workload      (2 days)

Month 5+  Phase E — Istio (when you have 5+ services)
Month 6+  Phase F — Multi-region DR (when SLA demands it)
Month 9+  Phase G — Internal developer platform (when team > 20 devs)
```

---

## What NOT to Do Prematurely

```
❌ Do NOT install Istio on day 1
   — Adds complexity and latency before you need it

❌ Do NOT build an internal developer platform for < 5 teams
   — Over-engineering. Direct Helm + ArgoCD is fine.

❌ Do NOT set up multi-region DR before you have SLA requirements
   — Doubles your infra cost for a failure mode that may never happen

❌ Do NOT enable KEDA before you understand your scaling triggers
   — HPA on CPU is correct for most workloads

❌ Do NOT rush all phases at once
   — Get stable first, then optimise
```
