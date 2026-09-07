# Docker Compose → AWS EKS: Complete Production Migration

> **Stack:** Node.js API · PostgreSQL (RDS) · Redis (ElastiCache) · Nginx → ALB  
> **Platform:** AWS EKS · Terraform · Helm · GitHub Actions · Prometheus + Grafana + Loki

---

## Repository Structure

```
aws-eks-migration/
├── MIGRATION-PLAN.md              # Why migrate + phase checklist
├── app/                           # Node.js Express API source
│   ├── Dockerfile                 # Multi-stage, non-root, read-only FS
│   ├── package.json
│   └── src/index.js               # Express + prom-client metrics endpoint
├── docker-compose/                # Original setup (baseline)
│   ├── docker-compose.yml
│   └── nginx.conf
├── kubernetes/                    # Raw Kubernetes manifests (Kustomize)
│   ├── base/
│   │   ├── app/
│   │   │   ├── deployment.yaml    # Prod-grade: anti-affinity, spread, probes
│   │   │   ├── service.yaml
│   │   │   ├── hpa.yaml           # CPU+Memory HPA
│   │   │   └── pdb.yaml           # minAvailable: 2
│   │   ├── database/
│   │   │   ├── configmap.yaml     # Non-sensitive config (RDS host etc.)
│   │   │   └── secret.yaml        # Structure only — use ESO in prod
│   │   ├── redis/
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   ├── ingress/
│   │   │   ├── ingress.yaml       # AWS ALB with HTTPS + WAF
│   │   │   └── networkpolicy.yaml # Micro-segmentation
│   │   └── monitoring/
│   │       └── servicemonitor.yaml
│   └── overlays/
│       ├── prod/                  # 5 replicas, larger limits
│       └── dev/                   # 1 replica, smaller limits
├── terraform/
│   ├── cluster.eksctl.yaml        # eksctl ClusterConfig (alternative)
│   └── environments/prod/
│       ├── main.tf                # Provider + backend config
│       ├── resources.tf           # VPC, EKS, RDS, ElastiCache, ECR
│       └── outputs.tf
├── helm/charts/myapp/             # Helm chart (preferred for prod)
│   ├── Chart.yaml
│   ├── values.yaml                # All knobs documented
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       └── service.yaml           # Service + HPA + PDB + Ingress + SM
├── cicd/.github/workflows/
│   └── cicd.yml                   # Test → Build → ECR → Deploy (rolling)
├── monitoring/
│   ├── install.sh                 # helm install kube-prometheus-stack + Loki
│   ├── prometheus/values.yaml     # Alerts: error rate, latency, crash-loop
│   ├── loki/values.yaml
│   └── grafana/myapp-dashboard.json
└── scripts/
    ├── bootstrap.sh               # One-time cluster setup (LBC, CA, ESO…)
    ├── inject-secrets.sh          # Push creds to Secrets Manager + ESO sync
    ├── cutover.sh                 # DNS switch Route53 → ALB
    └── rollback.sh                # helm rollback
```

---

## Prerequisites

```bash
brew install awscli kubectl eksctl helm terraform
aws configure   # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, region
```

---

## Step-by-Step Execution

### Step 1 — Build the Docker image locally

```bash
cd app
docker build -t myapp/api:v1.0.0 .
docker run -p 3000:3000 \
  -e DB_HOST=localhost -e DB_PORT=5432 \
  -e DB_NAME=myapp -e DB_USER=myuser -e DB_PASSWORD=pass \
  -e REDIS_HOST=localhost -e REDIS_PORT=6379 \
  myapp/api:v1.0.0

curl http://localhost:3000/health
# {"status":"ok","ts":"..."}
```

### Step 2 — Test with docker-compose (validate before migrating)

```bash
cd docker-compose
docker-compose up -d
curl http://localhost/health
curl http://localhost/api/items
docker-compose down
```

### Step 3 — Provision infrastructure with Terraform

```bash
# Create S3 bucket for state (one-time)
aws s3 mb s3://myapp-terraform-state --region us-east-1
aws dynamodb create-table \
  --table-name myapp-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

cd terraform/environments/prod
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Note the outputs — you'll need these:
terraform output rds_endpoint
terraform output redis_endpoint
terraform output ecr_api_url
```

### Step 4 — Push image to ECR

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_URL

docker build -t ${ECR_URL}/myapp/api:v1.0.0 app/
docker push ${ECR_URL}/myapp/api:v1.0.0
```

### Step 5 — Bootstrap the cluster (one-time)

```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name myapp-prod

# Run bootstrap (installs LBC, CA, Metrics Server, ESO, StorageClass)
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh myapp-prod us-east-1
```

### Step 6 — Inject secrets

```bash
chmod +x scripts/inject-secrets.sh
./scripts/inject-secrets.sh
# Follow prompts: enter DB_USER and DB_PASSWORD
# Secrets go to AWS Secrets Manager, then ESO syncs them as k8s Secrets
```

### Step 7 — Update ConfigMap with real endpoints

```bash
# Edit kubernetes/base/database/configmap.yaml:
# Replace placeholder RDS/Redis endpoints with terraform output values

RDS_ENDPOINT=$(cd terraform/environments/prod && terraform output -raw rds_endpoint)
REDIS_ENDPOINT=$(cd terraform/environments/prod && terraform output -raw redis_endpoint)

sed -i "s|myapp-rds.xxxxxxxxxxxx.*|${RDS_ENDPOINT}|" \
  kubernetes/base/database/configmap.yaml
sed -i "s|myapp-redis.xxxxxx.*|${REDIS_ENDPOINT}|" \
  kubernetes/base/database/configmap.yaml
```

### Step 8 — Deploy via Helm

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

helm upgrade --install myapp helm/charts/myapp \
  --namespace myapp \
  --create-namespace \
  --set image.repository="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/myapp/api" \
  --set image.tag="v1.0.0" \
  --set config.DB_HOST="${RDS_ENDPOINT}" \
  --set config.REDIS_HOST="${REDIS_ENDPOINT}" \
  --wait \
  --timeout 10m

# Verify
kubectl get pods -n myapp
kubectl get ingress -n myapp
```

### Step 9 — Verify everything is running

```bash
# All pods Running
kubectl get pods -n myapp -o wide

# HPA status
kubectl get hpa -n myapp

# PDB status
kubectl get pdb -n myapp

# Ingress + ALB DNS
kubectl get ingress myapp-myapp -n myapp

# API health check via ALB
ALB_DNS=$(kubectl get ingress myapp-myapp -n myapp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl https://${ALB_DNS}/health
curl https://${ALB_DNS}/api/items

# Check logs
kubectl logs -l app.kubernetes.io/name=myapp -n myapp --tail=50

# Check events
kubectl get events -n myapp --sort-by='.lastTimestamp'
```

### Step 10 — Set up monitoring

```bash
bash monitoring/install.sh

# Port-forward Grafana to localhost:3000
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open: http://localhost:3000  (admin / prom-operator)
# Import dashboard: monitoring/grafana/myapp-dashboard.json
```

### Step 11 — Configure CI/CD

```bash
# In GitHub → Settings → Secrets → Actions, add:
# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY
# AWS_ACCOUNT_ID
# AWS_REGION
# KUBE_CONFIG_DATA_PROD  (base64 of ~/.kube/config for prod cluster)
# KUBE_CONFIG_DATA_DEV
# SLACK_WEBHOOK_URL

# Generate kubeconfig secret:
cat ~/.kube/config | base64 | tr -d '\n'
# Paste output as KUBE_CONFIG_DATA_PROD secret

# Now any push to main → auto-builds → deploys to EKS with zero downtime
```

### Step 12 — DNS Cutover

```bash
# Lower Route53 TTL to 60s (do this 30 min before cutover!)
# Then run cutover script:
HOSTED_ZONE_ID="Z1234567890ABCD"   # your Route53 zone
DOMAIN="api.myapp.com"

chmod +x scripts/cutover.sh
./scripts/cutover.sh $HOSTED_ZONE_ID $DOMAIN
```

---

## Rollback

```bash
# Option A: Helm rollback (fastest)
./scripts/rollback.sh        # rolls back to previous Helm revision

# Option B: Kubectl rollout undo
kubectl rollout undo deployment/myapp-myapp -n myapp

# Option C: Redeploy specific tag
helm upgrade myapp helm/charts/myapp \
  --namespace myapp \
  --set image.tag="v1.0.0" \
  --wait

# Option D: DNS back to old server (last resort)
# Update Route53 CNAME back to old server IP
```

---

## Production Hardening Checklist

| Area | What's implemented |
|---|---|
| Zero-downtime deploys | `maxUnavailable: 0` rolling update |
| Auto-scaling | HPA on CPU (60%) + Memory (70%), min 3 / max 20 pods |
| Self-healing | Liveness + Readiness + Startup probes |
| AZ spread | `topologySpreadConstraints` across 3 AZs |
| Node spread | `podAntiAffinity` prevents same-node collisions |
| Availability during maintenance | PDB `minAvailable: 2` |
| Secrets management | AWS Secrets Manager + External Secrets Operator |
| Container security | non-root, readOnlyRootFilesystem, drop ALL caps |
| Network segmentation | NetworkPolicy: only allowed pod-to-pod traffic |
| Ingress security | HTTPS + ACM cert + WAF + ALB access logs |
| Observability | Prometheus metrics, Grafana dashboards, Loki logs |
| Alerting | Error rate >5%, p95 latency >2s, crash-loop, HPA maxed |
| Database HA | RDS Multi-AZ + automated backups + deletion protection |
| Cache HA | ElastiCache Redis with automatic failover |
| Cost governance | Resource requests/limits + Cluster Autoscaler |
| Image security | ECR scan-on-push + Trivy in CI pipeline |
| IaC | All infra in Terraform with remote state + lock |

---

## Key Commands Reference

```bash
# Scale manually
kubectl scale deployment myapp-myapp --replicas=5 -n myapp

# Watch rolling update
kubectl rollout status deployment/myapp-myapp -n myapp

# Exec into a pod
kubectl exec -it $(kubectl get pod -l app.kubernetes.io/name=myapp \
  -n myapp -o jsonpath='{.items[0].metadata.name}') -n myapp -- sh

# Top pods (requires metrics-server)
kubectl top pods -n myapp

# Port-forward API locally
kubectl port-forward svc/myapp-myapp 8080:80 -n myapp

# View HPA in real-time
kubectl get hpa myapp-myapp -n myapp -w

# Get all resources
kubectl get all -n myapp
```

---

## Cost Estimation (us-east-1, ~3-20 pods)

| Resource | Spec | Est. monthly |
|---|---|---|
| EKS control plane | managed | ~$73 |
| EC2 nodes (app group, 3× t3.large) | on-demand | ~$180 |
| RDS PostgreSQL (db.t3.medium, Multi-AZ) | | ~$100 |
| ElastiCache Redis (cache.t3.micro, 2 nodes) | | ~$30 |
| ALB | per LCU | ~$25 |
| ECR storage | 10 GB | ~$1 |
| NAT Gateways (3×) | | ~$100 |
| **Total** | | **~$509/month** |

> **Savings tip:** Use Spot instances for app node group (add `capacityType: SPOT`) to cut EC2 cost by ~70%.
