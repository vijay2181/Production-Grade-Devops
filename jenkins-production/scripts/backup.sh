#!/usr/bin/env bash
# =============================================================
# scripts/backup.sh — Backup Jenkins home to S3
#
# Backs up: job configs, plugin configs, credentials (encrypted),
#           build history, JCasC configs, audit logs.
# Excludes: workspaces (ephemeral), large log files, tmp files.
#
# Schedule: nightly at 02:00 UTC (via CronJob — see seed.groovy)
# Usage: ./scripts/backup.sh [--dry-run]
# =============================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET="${ARTIFACTS_BUCKET:-myapp-jenkins-artifacts-123456789012}"
DRY_RUN="${1:-}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
DATE=$(date -u +%Y%m%d)
JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_home}"
BACKUP_PREFIX="backups/${DATE}"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

log "=== Jenkins backup starting (${TIMESTAMP}) ==="

# Verify Jenkins is not running a build that could cause inconsistency
# (Best effort — Jenkins doesn't have a built-in quiesce for this)
ACTIVE_BUILDS=$(curl -sf "http://localhost:8080/computer/api/json" \
  --header "Authorization: Bearer $(cat /run/secrets/jenkins-token 2>/dev/null || echo '')" \
  2>/dev/null | jq '.computer[].executors[]?.currentExecutable | select(. != null)' | wc -l || echo 0)

if [[ ${ACTIVE_BUILDS} -gt 0 ]]; then
  log "  ⚠️  ${ACTIVE_BUILDS} builds currently running — backup may be slightly inconsistent"
fi

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  log "DRY RUN — would sync to: s3://${BUCKET}/${BACKUP_PREFIX}/"
  aws s3 sync "${JENKINS_HOME}" "s3://${BUCKET}/${BACKUP_PREFIX}/" \
    --region "${AWS_REGION}" \
    --exclude "workspace/*" \
    --exclude "caches/*" \
    --exclude "*.tmp" \
    --exclude "*.log" \
    --exclude ".git/*" \
    --dryrun
  log "=== Dry run complete ==="
  exit 0
fi

# ── Sync to S3 ────────────────────────────────────────────────
log "Syncing ${JENKINS_HOME} to s3://${BUCKET}/${BACKUP_PREFIX}/..."
aws s3 sync "${JENKINS_HOME}" "s3://${BUCKET}/${BACKUP_PREFIX}/" \
  --region "${AWS_REGION}" \
  --exclude "workspace/*" \
  --exclude "caches/*" \
  --exclude "*.tmp" \
  --exclude "logs/*.log" \
  --exclude ".git/*" \
  --delete \
  --sse aws:kms

# ── Record backup metadata ────────────────────────────────────
BACKUP_SIZE=$(aws s3 ls "s3://${BUCKET}/${BACKUP_PREFIX}/" \
  --region "${AWS_REGION}" \
  --recursive \
  --human-readable \
  --summarize 2>/dev/null \
  | grep "Total Size" | awk '{print $3, $4}' || echo "unknown")

OBJECT_COUNT=$(aws s3 ls "s3://${BUCKET}/${BACKUP_PREFIX}/" \
  --region "${AWS_REGION}" \
  --recursive \
  --summarize 2>/dev/null \
  | grep "Total Objects" | awk '{print $3}' || echo "unknown")

aws s3 cp - "s3://${BUCKET}/${BACKUP_PREFIX}/backup-metadata.json" \
  --region "${AWS_REGION}" \
  --content-type "application/json" \
  <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "date": "${DATE}",
  "jenkins_home": "${JENKINS_HOME}",
  "size": "${BACKUP_SIZE}",
  "object_count": "${OBJECT_COUNT}",
  "active_builds_at_backup": ${ACTIVE_BUILDS}
}
EOF

log "  ✅ Backup complete"
log "     Location: s3://${BUCKET}/${BACKUP_PREFIX}/"
log "     Size: ${BACKUP_SIZE} | Objects: ${OBJECT_COUNT}"

# ── Verify backup ─────────────────────────────────────────────
log "Verifying backup..."
# Check that critical files are present
CRITICAL_PATHS=(
  "config.xml"
  "jobs"
  "casc_configs"
)

ALL_PRESENT=true
for PATH_CHECK in "${CRITICAL_PATHS[@]}"; do
  if aws s3 ls "s3://${BUCKET}/${BACKUP_PREFIX}/${PATH_CHECK}" \
       --region "${AWS_REGION}" &>/dev/null; then
    echo "  ✅ ${PATH_CHECK}"
  else
    echo "  ❌ MISSING: ${PATH_CHECK}"
    ALL_PRESENT=false
  fi
done

if [[ "${ALL_PRESENT}" != "true" ]]; then
  die "Backup verification failed — critical files missing"
fi

log "  ✅ Backup verified"

# ── Rotate old backups (keep last 30 days) ────────────────────
log "Rotating backups older than 30 days..."
CUTOFF=$(date -u -d '30 days ago' +%Y%m%d 2>/dev/null || \
         date -u -v-30d +%Y%m%d 2>/dev/null || echo "00000000")

aws s3 ls "s3://${BUCKET}/backups/" --region "${AWS_REGION}" | \
  awk '{print $2}' | \
  grep -E '^[0-9]{8}/$' | \
  sed 's|/||' | \
  while read -r BACKUP_DATE; do
    if [[ "${BACKUP_DATE}" < "${CUTOFF}" ]]; then
      log "  Removing old backup: ${BACKUP_DATE}"
      aws s3 rm "s3://${BUCKET}/backups/${BACKUP_DATE}/" \
        --region "${AWS_REGION}" \
        --recursive
    fi
  done

log ""
log "=== Backup complete: ${TIMESTAMP} ==="
log ""
log "To restore:"
log "  1. kubectl exec -it jenkins-0 -n jenkins -- bash"
log "  2. aws s3 sync s3://${BUCKET}/${BACKUP_PREFIX}/ /var/jenkins_home/"
log "  3. kubectl rollout restart statefulset/jenkins -n jenkins"
