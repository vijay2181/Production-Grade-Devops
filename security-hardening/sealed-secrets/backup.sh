#!/usr/bin/env bash
# =============================================================
# sealed-secrets/backup.sh — Back up the Sealed Secrets controller
#                            encryption key to AWS Secrets Manager
#
# Why this matters:
#   If the Sealed Secrets controller key is lost, ALL SealedSecret
#   objects in the cluster become permanently unrecoverable. You
#   cannot re-seal from the original Secrets because the private key
#   that decrypts them is gone.
#
# What this script does:
#   1. Exports the controller key Secret from kube-system
#   2. Uploads it to AWS Secrets Manager (with versioning)
#   3. Verifies the backup is readable
#   4. Alerts to Slack if backup is stale (> 24h) or fails
#
# Schedule (recommended):
#   Run as a Kubernetes CronJob or from CI nightly.
#   See the CronJob manifest at the bottom of this file.
#
# Usage:
#   ./sealed-secrets/backup.sh [--dry-run] [--cluster prod]
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - AWS CLI configured with IAM role/profile that has:
#       secretsmanager:CreateSecret
#       secretsmanager:PutSecretValue
#       secretsmanager:DescribeSecret
#       secretsmanager:GetSecretValue  (for verify step)
#   - jq, openssl
# =============================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
CLUSTER="${CLUSTER:-myapp-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-123456789012}"
SECRET_NAME="sealed-secrets/${CLUSTER}/controller-key"
NAMESPACE="kube-system"
LABEL_SELECTOR="sealedsecrets.bitnami.com/sealed-secrets-key"
DRY_RUN="${1:-}"

# Slack webhook — set as env var, never hardcode
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ALERT_CHANNEL="#security-alerts"

# ── Helpers ───────────────────────────────────────────────────
log()   { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2; }

slack_alert() {
  local message="$1"
  local color="${2:-danger}"  # good | warning | danger
  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    log "SLACK_WEBHOOK not set — skipping Slack notification"
    return
  fi
  curl -s -X POST "${SLACK_WEBHOOK}" \
    -H "Content-Type: application/json" \
    -d "{
      \"attachments\": [{
        \"color\": \"${color}\",
        \"title\": \"Sealed Secrets Key Backup — ${CLUSTER}\",
        \"text\": \"${message}\",
        \"footer\": \"backup.sh | $(date -u +%Y-%m-%dT%H:%M:%SZ)\"
      }]
    }" || true
}

die() {
  error "$1"
  slack_alert "🔴 Sealed Secrets backup FAILED on \`${CLUSTER}\`: $1"
  exit 1
}

# ── Pre-flight checks ─────────────────────────────────────────
log "=== Sealed Secrets key backup starting (cluster=${CLUSTER}) ==="

command -v kubectl  >/dev/null 2>&1 || die "kubectl not found"
command -v aws      >/dev/null 2>&1 || die "aws CLI not found"
command -v jq       >/dev/null 2>&1 || die "jq not found"
command -v openssl  >/dev/null 2>&1 || die "openssl not found"

# Verify cluster connectivity
kubectl cluster-info --context="${CLUSTER}" >/dev/null 2>&1 \
  || die "Cannot connect to cluster context '${CLUSTER}'"

# ── Step 1: Export controller key ─────────────────────────────
log "Step 1: Exporting Sealed Secrets controller key from cluster..."

KEY_JSON=$(kubectl get secret \
  -n "${NAMESPACE}" \
  -l "${LABEL_SELECTOR}" \
  -o json 2>/dev/null) \
  || die "Failed to get Sealed Secrets key from kube-system"

KEY_COUNT=$(echo "${KEY_JSON}" | jq '.items | length')
if [[ "${KEY_COUNT}" -eq 0 ]]; then
  die "No Sealed Secrets controller key found (label: ${LABEL_SELECTOR})"
fi

log "  Found ${KEY_COUNT} key(s) — all will be backed up (active + rotated)"

# Redact for logging — show key names only, never values
KEY_NAMES=$(echo "${KEY_JSON}" | jq -r '.items[].metadata.name')
log "  Key names: ${KEY_NAMES}"

# Extract certificate fingerprint for verification (public key only — safe to log)
CERT=$(echo "${KEY_JSON}" | jq -r '.items[0].data["tls.crt"]' | base64 -d)
FINGERPRINT=$(echo "${CERT}" | openssl x509 -fingerprint -noout -sha256 2>/dev/null | cut -d= -f2)
log "  Certificate fingerprint (sha256): ${FINGERPRINT}"

# Compute checksum of the full key material
CHECKSUM=$(echo "${KEY_JSON}" | sha256sum | awk '{print $1}')
log "  Key material checksum (sha256): ${CHECKSUM}"

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  log "DRY RUN — would upload to Secrets Manager as: ${SECRET_NAME}"
  log "DRY RUN — checksum: ${CHECKSUM}"
  log "=== Dry run complete — no changes made ==="
  exit 0
fi

# ── Step 2: Upload to AWS Secrets Manager ─────────────────────
log "Step 2: Uploading to AWS Secrets Manager (${AWS_REGION})..."

# Attach metadata as tags for auditability
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SECRET_PAYLOAD=$(echo "${KEY_JSON}" | jq -c \
  --arg cluster "${CLUSTER}" \
  --arg ts "${TIMESTAMP}" \
  --arg checksum "${CHECKSUM}" \
  --arg fingerprint "${FINGERPRINT}" \
  '{
    key_material: .,
    metadata: {
      cluster: $cluster,
      backed_up_at: $ts,
      checksum_sha256: $checksum,
      certificate_fingerprint: $fingerprint,
      key_count: (.items | length)
    }
  }')

# Check whether the secret already exists
SECRET_EXISTS=$(aws secretsmanager describe-secret \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query 'ARN' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "${SECRET_EXISTS}" == "NOT_FOUND" ]]; then
  log "  Creating new secret: ${SECRET_NAME}"
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --description "Sealed Secrets controller encryption key for cluster ${CLUSTER}" \
    --secret-string "${SECRET_PAYLOAD}" \
    --region "${AWS_REGION}" \
    --tags \
      Key=cluster,Value="${CLUSTER}" \
      Key=managed-by,Value=sealed-secrets-backup \
      Key=environment,Value=production \
    >/dev/null
else
  log "  Updating existing secret: ${SECRET_NAME}"
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${SECRET_PAYLOAD}" \
    --region "${AWS_REGION}" \
    --version-stages AWSCURRENT \
    >/dev/null
fi

log "  ✅ Uploaded to AWS Secrets Manager: ${SECRET_NAME}"

# ── Step 3: Verify backup is readable ─────────────────────────
log "Step 3: Verifying backup is readable from Secrets Manager..."

VERIFY_CHECKSUM=$(aws secretsmanager get-secret-value \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query 'SecretString' \
  --output text 2>/dev/null \
  | jq -r '.key_material' \
  | sha256sum | awk '{print $1}')

if [[ "${VERIFY_CHECKSUM}" != "${CHECKSUM}" ]]; then
  die "Backup verification FAILED — checksum mismatch (expected: ${CHECKSUM}, got: ${VERIFY_CHECKSUM})"
fi

log "  ✅ Backup verified — checksum matches"

# ── Step 4: Check backup freshness (for alerting CronJob use) ─
log "Step 4: Checking backup freshness..."

LAST_BACKED_UP=$(aws secretsmanager describe-secret \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query 'LastChangedDate' \
  --output text 2>/dev/null || echo "unknown")

log "  Last backup: ${LAST_BACKED_UP}"

# Alert if running as a freshness check (--check-stale flag)
if [[ "${DRY_RUN}" == "--check-stale" ]]; then
  LAST_EPOCH=$(date -d "${LAST_BACKED_UP}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_BACKED_UP%.*}" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE_HOURS=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))
  log "  Backup age: ${AGE_HOURS}h"

  if [[ ${AGE_HOURS} -gt 24 ]]; then
    slack_alert "⚠️ Sealed Secrets backup on \`${CLUSTER}\` is ${AGE_HOURS}h old (threshold: 24h). Run backup immediately." "warning"
    error "Backup is stale (${AGE_HOURS}h > 24h threshold)"
    exit 2
  fi
  log "  ✅ Backup is fresh (${AGE_HOURS}h old)"
fi

# ── Done ──────────────────────────────────────────────────────
log ""
log "=== Sealed Secrets key backup complete ==="
log ""
log "  Secret ARN : arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:${SECRET_NAME}"
log "  Checksum   : ${CHECKSUM}"
log "  Fingerprint: ${FINGERPRINT}"
log "  Backed up  : ${TIMESTAMP}"
log ""
log "To restore in a disaster recovery scenario:"
log "  1. Install the Sealed Secrets controller (same version)"
log "  2. aws secretsmanager get-secret-value --secret-id ${SECRET_NAME} --query SecretString --output text | jq -r '.key_material' > restored-key.json"
log "  3. kubectl apply -f restored-key.json"
log "  4. kubectl rollout restart deployment/sealed-secrets-controller -n kube-system"
log "  5. Verify: kubectl get sealedsecret -A (should all show Ready)"

slack_alert "✅ Sealed Secrets key backup succeeded on \`${CLUSTER}\` — ${KEY_COUNT} key(s) stored. Fingerprint: ${FINGERPRINT}" "good"

# =============================================================
# Kubernetes CronJob — run this backup nightly at 02:00 UTC
#
# Apply with: kubectl apply -f sealed-secrets/backup-cronjob.yaml
# =============================================================
cat <<'CRONJOB_EOF'
---
# To deploy this CronJob, save as sealed-secrets/backup-cronjob.yaml
# and substitute the actual values for CLUSTER, AWS_REGION, etc.
#
# apiVersion: batch/v1
# kind: CronJob
# metadata:
#   name: sealed-secrets-backup
#   namespace: kube-system
#   labels:
#     app: sealed-secrets-backup
# spec:
#   schedule: "0 2 * * *"           # daily at 02:00 UTC
#   concurrencyPolicy: Forbid
#   successfulJobsHistoryLimit: 3
#   failedJobsHistoryLimit: 3
#   jobTemplate:
#     spec:
#       template:
#         spec:
#           serviceAccountName: sealed-secrets-backup
#           restartPolicy: OnFailure
#           containers:
#             - name: backup
#               image: amazon/aws-cli:latest
#               command: ["/bin/bash", "/scripts/backup.sh"]
#               env:
#                 - name: CLUSTER
#                   value: "myapp-prod"
#                 - name: AWS_REGION
#                   value: "us-east-1"
#                 - name: SLACK_WEBHOOK
#                   valueFrom:
#                     secretKeyRef:
#                       name: slack-webhook
#                       key: url
#               volumeMounts:
#                 - name: backup-script
#                   mountPath: /scripts
#           volumes:
#             - name: backup-script
#               configMap:
#                 name: sealed-secrets-backup-script
#                 defaultMode: 0755
CRONJOB_EOF
