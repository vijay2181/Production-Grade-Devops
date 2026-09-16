#!/usr/bin/env bash
# =============================================================
# scripts/install.sh — Bootstrap Jenkins on EKS
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - Terraform applied (EFS, IAM roles created)
#   - AWS Secrets Manager secrets pre-populated
#   - EFS CSI driver installed on the cluster
#
# Usage:
#   CLUSTER_CONTEXT=myapp-prod \
#   EFS_ID=fs-abc123 \
#   CONTROLLER_ROLE_ARN=arn:aws:iam::123456789012:role/jenkins-controller-irsa \
#   AGENT_ROLE_ARN=arn:aws:iam::123456789012:role/jenkins-agent-irsa \
#   ./scripts/install.sh
# =============================================================
set -euo pipefail

CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-myapp-prod}"
EFS_ID="${EFS_ID:-}"
CONTROLLER_ROLE_ARN="${CONTROLLER_ROLE_ARN:-}"
AGENT_ROLE_ARN="${AGENT_ROLE_ARN:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
JENKINS_IMAGE="${JENKINS_IMAGE:-123456789012.dkr.ecr.us-east-1.amazonaws.com/jenkins-controller:2.440.3}"
JENKINS_URL="${JENKINS_URL:-https://jenkins.company.com}"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# ── Validate inputs ───────────────────────────────────────────
[[ -z "${EFS_ID}" ]]              && die "EFS_ID required (from terraform output efs_file_system_id)"
[[ -z "${CONTROLLER_ROLE_ARN}" ]] && die "CONTROLLER_ROLE_ARN required"
[[ -z "${AGENT_ROLE_ARN}" ]]      && die "AGENT_ROLE_ARN required"

log "=== Installing Jenkins on ${CLUSTER_CONTEXT} ==="
kubectl config use-context "${CLUSTER_CONTEXT}"

# ── Step 1: EFS StorageClass ──────────────────────────────────
log "[1/9] Creating EFS StorageClass..."
sed "s/fs-REPLACE_WITH_EFS_ID/${EFS_ID}/" \
  kubernetes/controller/storage-pdb.yaml | kubectl apply -f -
log "  ✅ StorageClass created (efs-sc)"

# ── Step 2: Namespace + PSA labels ───────────────────────────
log "[2/9] Creating jenkins namespace..."
kubectl apply -f kubernetes/namespace.yaml
log "  ✅ Namespace created with PSA labels"

# ── Step 3: Populate Secrets Manager secrets ─────────────────
log "[3/9] Checking required Secrets Manager secrets..."
REQUIRED_SECRETS=(
  "jenkins/admin-password"
  "jenkins/github-app-id"
  "jenkins/github-app-private-key"
  "jenkins/github-client-id"
  "jenkins/github-client-secret"
  "jenkins/slack-bot-token"
  "jenkins/argocd-token"
  "jenkins/cosign-private-key"
  "jenkins/cosign-password"
  "jenkins/sonarqube-token"
)

MISSING=0
for SECRET in "${REQUIRED_SECRETS[@]}"; do
  if ! aws secretsmanager describe-secret \
       --secret-id "${SECRET}" \
       --region "${AWS_REGION}" \
       --query 'ARN' \
       --output text &>/dev/null; then
    echo "  ❌ Missing: ${SECRET}"
    MISSING=$((MISSING + 1))
  else
    echo "  ✅ Found: ${SECRET}"
  fi
done

if [[ ${MISSING} -gt 0 ]]; then
  die "${MISSING} required secrets are missing from Secrets Manager. Create them first."
fi

# ── Step 4: Create Kubernetes Secret from Secrets Manager ─────
log "[4/9] Injecting secrets into cluster..."
# Pull all values from Secrets Manager and create a Kubernetes Secret
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id jenkins/admin-password \
  --region "${AWS_REGION}" \
  --query SecretString --output text)

GITHUB_CLIENT_ID=$(aws secretsmanager get-secret-value \
  --secret-id jenkins/github-client-id \
  --region "${AWS_REGION}" \
  --query SecretString --output text)

GITHUB_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id jenkins/github-client-secret \
  --region "${AWS_REGION}" \
  --query SecretString --output text)

SLACK_WEBHOOK=$(aws secretsmanager get-secret-value \
  --secret-id jenkins/slack-bot-token \
  --region "${AWS_REGION}" \
  --query SecretString --output text)

kubectl create secret generic jenkins-secrets \
  --namespace jenkins \
  --from-literal=admin-password="${ADMIN_PASSWORD}" \
  --from-literal=github-client-id="${GITHUB_CLIENT_ID}" \
  --from-literal=github-client-secret="${GITHUB_CLIENT_SECRET}" \
  --from-literal=slack-webhook-url="${SLACK_WEBHOOK}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "  ✅ Kubernetes secret created (jenkins-secrets)"

# ── Step 5: Build custom Jenkins image ───────────────────────
log "[5/9] Building Jenkins controller image with pinned plugins..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin \
    "$(echo ${JENKINS_IMAGE} | cut -d'/' -f1)"

docker build \
  --no-cache \
  -t "${JENKINS_IMAGE}" \
  -f docker/Dockerfile \
  .

docker push "${JENKINS_IMAGE}"
log "  ✅ Jenkins image pushed: ${JENKINS_IMAGE}"

# ── Step 6: Apply JCasC ConfigMap ────────────────────────────
log "[6/9] Creating JCasC ConfigMap..."
kubectl create configmap jenkins-casc-config \
  --namespace jenkins \
  --from-file=jenkins.yaml=jcasc/jenkins.yaml \
  --from-file=credentials.yaml=jcasc/credentials.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
log "  ✅ JCasC ConfigMap created"

# ── Step 7: Patch IRSA annotations ───────────────────────────
log "[7/9] Patching IRSA role ARNs..."
sed -i "s|arn:aws:iam::123456789012:role/jenkins-controller-irsa|${CONTROLLER_ROLE_ARN}|g" \
  kubernetes/controller/statefulset.yaml

sed -i "s|arn:aws:iam::123456789012:role/jenkins-agent-irsa|${AGENT_ROLE_ARN}|g" \
  kubernetes/agents/serviceaccount.yaml
log "  ✅ IRSA ARNs patched"

# ── Step 8: Apply all manifests ───────────────────────────────
log "[8/9] Applying Kubernetes manifests..."

# ServiceAccounts
kubectl apply -f kubernetes/agents/serviceaccount.yaml

# Controller manifests (order matters)
kubectl apply -f kubernetes/controller/storage-pdb.yaml
kubectl apply -f kubernetes/controller/networkpolicy.yaml
kubectl apply -f kubernetes/controller/service.yaml
kubectl apply -f kubernetes/controller/statefulset.yaml
kubectl apply -f kubernetes/controller/ingress.yaml

log "  ✅ Manifests applied"

# ── Step 9: Wait for Jenkins to be ready ─────────────────────
log "[9/9] Waiting for Jenkins to be ready..."
kubectl rollout status statefulset/jenkins \
  --namespace jenkins \
  --timeout=10m

# Wait for readiness probe to pass
kubectl wait pod/jenkins-0 \
  --namespace jenkins \
  --for=condition=Ready \
  --timeout=10m

log "  ✅ Jenkins is ready!"
log ""
log "=== Jenkins Installation Complete ==="
log ""
log "  URL: ${JENKINS_URL}"
log "  Login: GitHub SSO (${JENKINS_URL}/securityRealm/commenceLogin)"
log ""
log "Next steps:"
log "  1. Open ${JENKINS_URL} and verify JCasC loaded:"
log "     Manage Jenkins → Configuration as Code → View Configuration"
log "  2. Create the seed job:"
log "     ./scripts/seed-jobs.sh"
log "  3. Run the seed job to create all pipelines"
log "  4. Verify a test build:"
log "     kubectl logs jenkins-0 -n jenkins -f"
