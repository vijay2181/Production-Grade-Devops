# Jenkins Production — Testing Guide

> How to verify every component works correctly — and how to intentionally break things to confirm your defences hold.

---

## Prerequisites

```bash
# Tools required
kubectl    >= 1.28
helm       >= 3.13
terraform  >= 1.6
aws        >= 2.15
jq         >= 1.6
curl
```

---

## Phase 1 — Infrastructure Verification

### 1.1 EFS is mounted and writable

```bash
# Verify EFS PVC is Bound
kubectl get pvc -n jenkins
# Expected: jenkins-home-jenkins-0   Bound   efs-sc

# Exec into Jenkins pod and verify EFS mount
kubectl exec -it jenkins-0 -n jenkins -- df -h /var/jenkins_home
# Expected: filesystem starts with 127.0.0.1: (EFS NFS mount)

# Verify jenkins user owns the directory
kubectl exec -it jenkins-0 -n jenkins -- ls -la /var/jenkins_home
# Expected: drwxr-xr-x jenkins jenkins ...

# Write test
kubectl exec -it jenkins-0 -n jenkins -- touch /var/jenkins_home/test-write
kubectl exec -it jenkins-0 -n jenkins -- rm /var/jenkins_home/test-write
echo "✅ EFS writable"
```

### 1.2 IRSA is working (no static AWS keys)

```bash
# Exec into an agent pod (trigger a dummy build first, then exec quickly)
# OR: create a test pod with the agent ServiceAccount
kubectl run irsa-test \
  --image=amazon/aws-cli:latest \
  --serviceaccount=jenkins-agent \
  --namespace=jenkins \
  --restart=Never \
  --command -- sleep 300

# Verify AWS identity — should show the IRSA role, NOT a user key
kubectl exec -it irsa-test -n jenkins -- \
  aws sts get-caller-identity --region us-east-1

# Expected output:
# {
#   "UserId": "AROA...:jenkins-agent",
#   "Account": "123456789012",
#   "Arn": "arn:aws:iam::123456789012:assumed-role/jenkins-agent-irsa/jenkins-agent"
# }

# Verify no static keys are present
kubectl exec -it irsa-test -n jenkins -- env | grep -E 'AWS_ACCESS_KEY|AWS_SECRET'
# Expected: AWS_WEB_IDENTITY_TOKEN_FILE is set, but NO AWS_ACCESS_KEY_ID

kubectl delete pod irsa-test -n jenkins
echo "✅ IRSA working — no static keys"
```

### 1.3 Secrets Manager accessible from controller

```bash
kubectl exec -it jenkins-0 -n jenkins -- \
  aws secretsmanager get-secret-value \
    --secret-id jenkins/admin-password \
    --region us-east-1 \
    --query SecretString \
    --output text
# Expected: returns the password value (mask in screen recording)
echo "✅ Secrets Manager accessible from controller"
```

---

## Phase 2 — JCasC Verification

### 2.1 Verify JCasC loaded correctly

```bash
# Check JCasC status via Jenkins API
curl -sf -u admin:$(kubectl get secret jenkins-secrets -n jenkins -o jsonpath='{.data.admin-password}' | base64 -d) \
  https://jenkins.company.com/configuration-as-code/viewExport \
  | head -50
# Expected: returns YAML matching your jcasc/jenkins.yaml

# Check in UI: Manage Jenkins → Configuration as Code → View Configuration
# Should show all your configured settings with no "null" or "missing" values
echo "✅ JCasC loaded"
```

### 2.2 Verify GitHub OAuth

```bash
# Open in browser (private window)
# https://jenkins.company.com/securityRealm/commenceLogin
# Should redirect to GitHub OAuth
# Should come back as your GitHub user
# Should have only the permissions matching your GitHub team membership
echo "✅ GitHub OAuth working"
```

### 2.3 Verify Shared Library is registered

```bash
# Navigate to: Manage Jenkins → Configure System → Global Pipeline Libraries
# Should show: company-pipeline-lib → pointing to GitHub repo
# OR via API:
curl -sf -u admin:PASSWORD \
  https://jenkins.company.com/manage/api/json?depth=2 \
  | jq '.globalLibraries.libraries[].name'
# Expected: "company-pipeline-lib"
echo "✅ Shared Library registered"
```

---

## Phase 3 — Agent Pod Verification

### 3.1 Verify Kubernetes cloud is configured

```bash
# Navigate to: Manage Jenkins → Clouds → kubernetes
# Should show: Connected to Kubernetes cluster
# Available executor count: 0 (no builds running, pods are ephemeral)

# Trigger a test build and watch pods appear
kubectl get pods -n jenkins -w &

# Trigger the seed job or any pipeline
# Expected: new pod appears → runs → terminates
echo "✅ Kubernetes cloud working"
```

### 3.2 Verify agent security context

```bash
# While a build is running, exec into the agent pod
AGENT_POD=$(kubectl get pods -n jenkins -l jenkins/agent=true -o name | head -1)
kubectl exec -it "${AGENT_POD}" -n jenkins -- id
# Expected: uid=1000(jenkins) gid=1000(jenkins) — NOT root

kubectl exec -it "${AGENT_POD}" -n jenkins -- cat /proc/1/status | grep -E 'CapEff|CapPrm'
# Expected: 0000000000000000 — no capabilities
echo "✅ Agent runs as non-root, no capabilities"
```

### 3.3 Verify Kaniko builds without Docker socket

```bash
# Check that no Docker socket is mounted in any agent container
AGENT_POD=$(kubectl get pods -n jenkins -l jenkins/agent=true -o name | head -1)
kubectl get pod "${AGENT_POD}" -n jenkins -o json \
  | jq '.spec.volumes[] | select(.name | contains("docker"))'
# Expected: empty — no docker socket volume

kubectl exec -it "${AGENT_POD}" -n jenkins -c kaniko -- \
  ls /var/run/docker.sock 2>&1
# Expected: ls: /var/run/docker.sock: No such file or directory
echo "✅ No Docker socket in agent pods"
```

---

## Phase 4 — Pipeline End-to-End Test

### 4.1 Run a full pipeline

```bash
# Trigger the myapp pipeline on the main branch
# Watch it execute in Blue Ocean or classic view

# Expected stages:
# ✅ Checkout
# ✅ Unit Tests (parallel)
# ✅ Lint (parallel)
# ✅ SAST (parallel)
# ✅ Build Image (Kaniko)
# ✅ Image Scan (Trivy)
# ✅ Sign Image (Cosign)
# ✅ Deploy → dev
# ✅ Integration Tests
# (approval gate for staging/prod)
```

### 4.2 Verify image was pushed to ECR

```bash
# After the Build Image stage completes
GIT_SHA=$(git rev-parse --short HEAD)
aws ecr describe-images \
  --repository-name myapp \
  --image-ids imageTag="${GIT_SHA}" \
  --region us-east-1 \
  | jq '.imageDetails[0] | {pushedAt, imageDigest, imageSizeInBytes}'
# Expected: image details with recent timestamp
echo "✅ Image in ECR"
```

### 4.3 Verify image is signed

```bash
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:${GIT_SHA}"
cosign verify --key cosign.pub "${IMAGE}"
# Expected: verification successful
echo "✅ Image is signed"
```

### 4.4 Verify GitOps repo was updated

```bash
# After Deploy → dev stage
git -C /tmp/gitops pull
grep "newTag" /tmp/gitops/apps/myapp/overlays/dev/kustomization.yaml
# Expected: newTag: <current-git-sha>
echo "✅ GitOps repo updated"
```

---

## Phase 5 — Security Testing (Red Team)

### 5.1 Test: Can an agent escape to the host?

```bash
# Exec into a running agent pod
AGENT_POD=$(kubectl get pods -n jenkins -l jenkins/agent=true -o name | head -1)

# Try to mount host filesystem
kubectl exec -it "${AGENT_POD}" -n jenkins -c build -- \
  mount /dev/sda1 /mnt/host 2>&1
# Expected: mount: permission denied (no CAP_SYS_ADMIN)

# Try to create a privileged container via Docker
kubectl exec -it "${AGENT_POD}" -n jenkins -c build -- \
  docker run --privileged ubuntu 2>&1
# Expected: docker: command not found (no Docker in build container)

echo "✅ Agent cannot escape to host"
```

### 5.2 Test: Can a Jenkinsfile access Secrets Manager directly?

```bash
# Create a Jenkinsfile that tries to enumerate secrets
cat > /tmp/evil-Jenkinsfile << 'EOF'
pipeline {
  agent { kubernetes { label 'nodejs' } }
  stages {
    stage('Exfiltrate') {
      steps {
        container('build') {
          sh '''
            # Try to list all Secrets Manager secrets
            aws secretsmanager list-secrets --region us-east-1
          '''
        }
      }
    }
  }
}
EOF

# Expected: Either fails (no list permission on IRSA role)
# or only shows secrets scoped to jenkins/* prefix
# Verify the IRSA policy has no ListSecrets permission
aws iam get-role-policy \
  --role-name jenkins-agent-irsa \
  --policy-name jenkins-agent-policy \
  | jq '.PolicyDocument.Statement[] | select(.Action | contains("secretsmanager:ListSecrets"))'
# Expected: empty — ListSecrets is not granted
echo "✅ Agents cannot enumerate Secrets Manager"
```

### 5.3 Test: Groovy sandbox prevents dangerous operations

```bash
# Try to run a Jenkinsfile with sandbox-blocked operations
# In Jenkins UI: create a pipeline with this script:
# pipeline {
#   agent any
#   stages {
#     stage('Test') {
#       steps {
#         script {
#           // This should be blocked by sandbox
#           Runtime.exec(['cat', '/etc/passwd'])
#         }
#       }
#     }
#   }
# }

# Expected: build fails with "Scripts not permitted to use method..."
echo "✅ Groovy sandbox is enforced"
```

### 5.4 Test: NetworkPolicy blocks agent-to-agent communication

```bash
# Start two build pods (trigger two builds simultaneously)
# Try to curl from agent pod 1 to agent pod 2
POD1=$(kubectl get pods -n jenkins -l jenkins/agent=true -o name | head -1)
POD2=$(kubectl get pods -n jenkins -l jenkins/agent=true -o name | tail -1)
POD2_IP=$(kubectl get "${POD2}" -n jenkins -o jsonpath='{.status.podIP}')

kubectl exec -it "${POD1}" -n jenkins -c build -- \
  curl -sf --max-time 3 "http://${POD2_IP}:8080" 2>&1
# Expected: curl: (28) Operation timed out (NetworkPolicy blocks it)
echo "✅ NetworkPolicy blocks agent-to-agent"
```

---

## Phase 6 — Backup and Recovery Test

### 6.1 Run backup and verify

```bash
# Run backup manually
kubectl exec -it jenkins-0 -n jenkins -- \
  /var/jenkins_home/scripts/backup.sh

# Verify in S3
DATE=$(date +%Y%m%d)
aws s3 ls "s3://myapp-jenkins-artifacts-123456789012/backups/${DATE}/" \
  --region us-east-1 \
  --human-readable \
  | tail -5
echo "✅ Backup in S3"
```

### 6.2 Recovery drill (quarterly)

```bash
# Step 1: Backup current state
./scripts/backup.sh

# Step 2: Simulate pod loss
kubectl delete pod jenkins-0 -n jenkins
# Expected: Kubernetes recreates it (StatefulSet)
kubectl wait pod/jenkins-0 -n jenkins --for=condition=Ready --timeout=5m
echo "Recovery from pod restart: ✅"

# Step 3: Verify job history is intact
curl -sf -u admin:PASSWORD \
  https://jenkins.company.com/job/services/job/myapp/api/json \
  | jq '.builds | length'
# Expected: same number as before pod deletion

echo "✅ Recovery drill passed"
```

---

## Phase 7 — Prometheus Metrics

```bash
# Verify Jenkins metrics endpoint
curl -sf https://jenkins.company.com/prometheus | head -30
# Expected: Prometheus text format with jenkins_* metrics

# Check key metrics
curl -sf https://jenkins.company.com/prometheus \
  | grep -E 'jenkins_builds_duration|jenkins_executor_count|jenkins_queue_size'
# Expected: all three metrics present with numeric values

# Check Grafana dashboard
# Navigate to: Grafana → Dashboards → Jenkins Production
# Should show: build success rate, duration, queue depth, executor count
echo "✅ Prometheus metrics working"
```

---

## Phase 8 — Chaos Engineering

### 8.1 Kill the controller mid-build

```bash
# Start a long-running build (add sleep 120 to a test pipeline)
# While it's running:
kubectl delete pod jenkins-0 -n jenkins

# Watch recovery:
kubectl get pods -n jenkins -w
# Expected: jenkins-0 Terminating → Pending → Running → Ready
# in approximately 60-90 seconds

# The running build WILL be lost (Jenkins doesn't checkpoint builds)
# This is expected — EFS preserves config but not in-flight build state
# Build history (completed builds) should be intact after recovery
echo "✅ Controller self-heals in ~90 seconds"
```

### 8.2 Scale Karpenter to zero (test agent scheduling)

```bash
# Trigger 10 builds simultaneously
for i in $(seq 1 10); do
  curl -X POST -u admin:PASSWORD \
    "https://jenkins.company.com/job/services/job/myapp/job/main/build"
done

# Watch Karpenter provision new nodes
kubectl get nodes -w &

# Watch agent pods pending then running
kubectl get pods -n jenkins -w

# Expected: Karpenter provisions Spot nodes, all 10 builds eventually run
echo "✅ Agent autoscaling works"
```
