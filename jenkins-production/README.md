# Jenkins Production on AWS EKS

> **Project 5** | Production-grade Jenkins on Kubernetes
> Stack: Jenkins · JCasC · Kubernetes agents · Kaniko · Trivy · Cosign · Shared Library · IRSA · EFS · ArgoCD integration

---
# > Enterprise CI Automation 

## What This Project Demonstrates

| Skill | Production Pattern |
|---|---|
| Jenkins on Kubernetes | StatefulSet + EFS — survives pod restarts |
| Zero manual configuration | JCasC — entire Jenkins configured from YAML in Git |
| Scalable agents | Ephemeral Kubernetes pods — zero idle cost |
| No static AWS keys | IRSA — short-lived STS tokens only |
| Secure image builds | Kaniko — no Docker socket, no privileged mode |
| Supply chain security | Trivy scan + Cosign signing in every pipeline |
| DRY pipelines | Shared Library — 50 services, one set of pipeline functions |
| GitOps integration | Pipelines update Git, ArgoCD deploys — never kubectl |
| Audit trail | Every action logged — who triggered, who approved, when |
| Reproducible | Pinned plugin versions baked into Docker image |
| Disaster recovery | EFS + S3 backup — recovery in 60-90 seconds |

---

## Prerequisites

```bash
# Required tools
terraform >= 1.6
kubectl   >= 1.28
helm      >= 3.13
aws       >= 2.15
docker    >= 24.0
jq        >= 1.6

# Required: EKS cluster from Project 1
# Required: ArgoCD hub from Project 2
# Required: EFS CSI driver on cluster
aws eks update-kubeconfig --region us-east-1 --name myapp-prod

# Verify EFS CSI driver is installed
kubectl get daemonset -n kube-system | grep efs
# Expected: efs-csi-node

# Install EFS CSI driver if missing
aws eks create-addon \
  --cluster-name myapp-prod \
  --addon-name aws-efs-csi-driver \
  --region us-east-1
```

---

## Step 1 — Provision Infrastructure (Terraform)

```bash
cd terraform/environments/prod

# Review what will be created
terraform init
terraform plan

# Creates:
#   - EFS file system + mount targets (multi-AZ)
#   - EFS access point (jenkins UID/GID)
#   - S3 bucket (artifacts + backup)
#   - IAM role: jenkins-controller-irsa (S3 + Secrets Manager)
#   - IAM role: jenkins-agent-irsa (ECR + S3 + Secrets Manager)

terraform apply

# Save outputs
CONTROLLER_ROLE_ARN=$(terraform output -raw jenkins_controller_role_arn)
AGENT_ROLE_ARN=$(terraform output -raw jenkins_agent_role_arn)
EFS_ID=$(terraform output -raw efs_file_system_id)
BUCKET=$(terraform output -raw artifacts_bucket_name)

echo "Controller role: ${CONTROLLER_ROLE_ARN}"
echo "Agent role:      ${AGENT_ROLE_ARN}"
echo "EFS ID:          ${EFS_ID}"
echo "S3 Bucket:       ${BUCKET}"
```

---

## Step 2 — Pre-populate AWS Secrets Manager

```bash
# These secrets are required BEFORE Jenkins starts.
# Jenkins reads them via IRSA — never stored in Jenkins.

aws secretsmanager create-secret \
  --name jenkins/admin-password \
  --secret-string "$(openssl rand -base64 32)" \
  --region us-east-1

# GitHub OAuth App: create at https://github.com/organizations/company/settings/applications/new
# Callback URL: https://jenkins.company.com/securityRealm/finishLogin
aws secretsmanager create-secret \
  --name jenkins/github-client-id \
  --secret-string "YOUR_GITHUB_OAUTH_CLIENT_ID" \
  --region us-east-1

aws secretsmanager create-secret \
  --name jenkins/github-client-secret \
  --secret-string "YOUR_GITHUB_OAUTH_CLIENT_SECRET" \
  --region us-east-1

# GitHub App (for higher rate limits): https://github.com/organizations/company/settings/apps
aws secretsmanager create-secret \
  --name jenkins/github-app-id \
  --secret-string "YOUR_GITHUB_APP_ID" \
  --region us-east-1

aws secretsmanager create-secret \
  --name jenkins/github-app-private-key \
  --secret-string "$(cat github-app-private-key.pem)" \
  --region us-east-1

# Slack: https://api.slack.com/apps → Bot Token
aws secretsmanager create-secret \
  --name jenkins/slack-bot-token \
  --secret-string "xoxb-YOUR-SLACK-BOT-TOKEN" \
  --region us-east-1

# ArgoCD: create a service account token in ArgoCD with app-sync role
aws secretsmanager create-secret \
  --name jenkins/argocd-token \
  --secret-string "YOUR_ARGOCD_TOKEN" \
  --region us-east-1

# Cosign: generate a new keypair
cosign generate-key-pair
aws secretsmanager create-secret \
  --name jenkins/cosign-private-key \
  --secret-string "$(cat cosign.key)" \
  --region us-east-1
aws secretsmanager create-secret \
  --name jenkins/cosign-password \
  --secret-string "YOUR_COSIGN_PASSWORD" \
  --region us-east-1

# Store public key for Kyverno policy verification (Project 4)
kubectl create configmap cosign-public-key \
  --from-file=cosign.pub \
  --namespace kyverno
```

---

## Step 3 — Build Jenkins Controller Image

```bash
# Build custom image with pinned plugins (never use jenkins:lts in prod)
ECR_REGISTRY="123456789012.dkr.ecr.us-east-1.amazonaws.com"
IMAGE="${ECR_REGISTRY}/jenkins-controller:2.440.3"

# Login to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Create ECR repository if it doesn't exist
aws ecr create-repository \
  --repository-name jenkins-controller \
  --region us-east-1 2>/dev/null || true

# Build (this downloads all plugins — takes ~5 minutes first time)
docker build \
  --no-cache \
  -t "${IMAGE}" \
  -f docker/Dockerfile \
  .

# Push
docker push "${IMAGE}"
echo "✅ Jenkins image: ${IMAGE}"
```

---

## Step 4 — Install Jenkins

```bash
# Run the install script (handles everything: namespace, secrets, manifests)
CLUSTER_CONTEXT=myapp-prod \
EFS_ID="${EFS_ID}" \
CONTROLLER_ROLE_ARN="${CONTROLLER_ROLE_ARN}" \
AGENT_ROLE_ARN="${AGENT_ROLE_ARN}" \
JENKINS_IMAGE="${IMAGE}" \
JENKINS_URL="https://jenkins.company.com" \
  ./scripts/install.sh
```

---

## Step 5 — Verify Installation

```bash
# Pods running
kubectl get pods -n jenkins
# Expected: jenkins-0   3/3   Running

# JCasC loaded (check logs)
kubectl logs jenkins-0 -n jenkins | grep -E 'JCasC|configuration-as-code'
# Expected: "Configuration loaded from ..."

# Jenkins accessible
curl -sf https://jenkins.company.com/login | grep -i jenkins
# Expected: HTML containing "Jenkins"

# Run the full verification suite
# See TESTING-GUIDE.md for all checks
```

---

## Step 6 — Create Seed Job (One-Time Manual Step)

```bash
# This is the ONLY manual step in Jenkins UI.
# After this, everything is code.

# In Jenkins UI:
# 1. New Item → Freestyle Project → Name: "seed-job"
# 2. Source Code Management → Git: https://github.com/company/jenkins-production.git
#    Credentials: github-app-credentials
# 3. Build Steps → Process Job DSLs → DSL Script: seed/seed.groovy
# 4. Save → Build Now

# The seed job creates ALL other pipelines automatically.
echo "After seed job runs, all pipelines are created from code"
```

---

## Step 7 — Configure Multibranch Pipelines

```bash
# After seed job completes:
# Navigate to Jenkins → services/myapp
# Click "Scan Multibranch Pipeline Now"
# Expected: discovers main, develop, and all feature branches
# Each branch with a Jenkinsfile gets a pipeline automatically

# Trigger a test build on main
curl -X POST -u admin:"${ADMIN_PASSWORD}" \
  "https://jenkins.company.com/job/services/job/myapp/job/main/build"

# Watch in Blue Ocean (best pipeline view)
# https://jenkins.company.com/blue
```

---

## Project Links

| Previous project | How Jenkins uses it |
|---|---|
| [Project 1 — aws-eks-migration](../aws-eks-migration/) | Deploys to this cluster, uses ECR, RDS, ElastiCache |
| [Project 2 — argocd-multicluster](../argocd-multicluster/) | Pipelines trigger ArgoCD sync — never kubectl directly |
| [Project 3 — observability](../observability/) | Jenkins metrics scraped by Prometheus, Grafana dashboard |
| [Project 4 — kubernetes-security](../kubernetes-security/) | Agents comply with Kyverno/PSA, Falco monitors jenkins namespace |

---

## File Structure

```
jenkins-production/
├── ARCHITECTURE.md          ← Why Jenkins, production patterns, HA design
├── DIAGRAMS.md              ← 7 Mermaid diagrams (architecture, pipeline flow, etc.)
├── TESTING-GUIDE.md         ← Verification + red-team tests (8 phases)
├── README.md                ← This file
│
├── terraform/
│   └── environments/prod/
│       ├── main.tf          ← EFS, S3, IAM (IRSA) for controller + agents
│       ├── variables.tf
│       └── terraform.tfvars
│
├── docker/
│   └── Dockerfile           ← Custom Jenkins image with pinned plugins
│
├── plugins/
│   └── plugins.txt          ← All plugins pinned to exact versions
│
├── jcasc/
│   ├── jenkins.yaml         ← Full Jenkins config (auth, clouds, agents, libraries)
│   └── credentials.yaml     ← Credential providers (no secrets in file)
│
├── kubernetes/
│   ├── namespace.yaml                   ← PSA labels + namespace
│   ├── controller/
│   │   ├── statefulset.yaml             ← Jenkins controller + JVM tuning
│   │   ├── service.yaml                 ← ClusterIP + headless service
│   │   ├── ingress.yaml                 ← Internal ALB + TLS
│   │   ├── storage-pdb.yaml             ← EFS StorageClass + PodDisruptionBudget
│   │   └── networkpolicy.yaml           ← Zero-trust network rules
│   └── agents/
│       └── serviceaccount.yaml          ← IRSA SA + ClusterRole
│
├── pipelines/
│   ├── myapp/
│   │   └── Jenkinsfile                  ← Full production CI/CD pipeline (330 lines)
│   ├── seed/
│   │   └── seed.groovy                  ← Job DSL seed job (creates all other jobs)
│   └── shared-library/
│       └── vars/
│           ├── buildImage.groovy        ← Kaniko image build
│           ├── runTests.groovy          ← Test runner (Node.js, Java, Go)
│           ├── securityScan.groovy      ← Trivy scan with CRITICAL gate
│           ├── signImage.groovy         ← Cosign image signing
│           ├── deployToEKS.groovy       ← ArgoCD GitOps deployment
│           └── notifySlack.groovy       ← Structured Slack notifications
│
└── scripts/
    ├── install.sh           ← Full bootstrap (prereq check → manifests → wait)
    ├── backup.sh            ← Backup Jenkins home to S3
    └── upgrade.sh           ← Safe plugin upgrade workflow
```

---

## Key Design Decisions

### Why StatefulSet, not Deployment?
Stable pod name (`jenkins-0`) + PVC lifecycle binding. EFS remounts on any node. Deployment would create random pod names and lose PVC binding on restart.

### Why EFS, not EBS?
EBS is AZ-bound. If the node running Jenkins is in `us-east-1a` and it fails, EBS can't attach in `us-east-1b`. EFS is multi-AZ. Jenkins Pod can restart on any node and remount instantly.

### Why JCasC instead of UI configuration?
UI config is stored in `config.xml`. One accidental change = no Git history, no rollback, no review. JCasC means every Jenkins change is a Pull Request with reviewer approval and automatic history.

### Why Kaniko instead of Docker-in-Docker?
Docker-in-Docker requires `--privileged`. Privileged containers can escape to the host. Kaniko builds images inside a normal container with no host access.

### Why does the pipeline update Git instead of running kubectl?
GitOps contract: cluster state must always match Git. If Jenkins ran `kubectl apply` directly, ArgoCD would see drift and revert the change. Updating Git first means ArgoCD applies it, and the cluster state is always in sync with the repository.

### Why pin plugin versions?
Jenkins has 1800+ plugins. Auto-updates break pipelines. A plugin update on Friday afternoon is a production incident. Pinned versions = reproducible Jenkins. Upgrades are deliberate, tested on staging first.
