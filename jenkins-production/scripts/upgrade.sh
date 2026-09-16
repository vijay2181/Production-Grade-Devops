#!/usr/bin/env bash
# =============================================================
# scripts/upgrade.sh — Safe Jenkins plugin upgrade workflow
#
# NEVER auto-update plugins in production.
# This script provides a safe, reviewed upgrade process:
#   1. Check what updates are available
#   2. Test on staging Jenkins first
#   3. Roll out to production only after staging passes
#
# Usage:
#   ./scripts/upgrade.sh --check            # List available updates
#   ./scripts/upgrade.sh --apply staging    # Update staging image + deploy
#   ./scripts/upgrade.sh --apply prod       # Update prod (after staging OK)
# =============================================================
set -euo pipefail

MODE="${1:---check}"
ENV="${2:-staging}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REGISTRY="${ECR_REGISTRY:-123456789012.dkr.ecr.us-east-1.amazonaws.com}"
IMAGE_BASE="${ECR_REGISTRY}/jenkins-controller"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

case "${MODE}" in

  --check)
    log "=== Checking for Jenkins plugin updates ==="
    log "Current plugins.txt:"
    cat plugins/plugins.txt | grep -v '^#' | grep -v '^$' | sort

    log ""
    log "To check for updates, visit:"
    log "  https://updates.jenkins.io/current/update-center.json"
    log ""
    log "Or use the Jenkins update center API:"
    curl -sf "https://updates.jenkins.io/current/update-center.json" \
      | tr -d ')]}' \
      | jq -r '.plugins | to_entries[] | "\(.key):\(.value.version)"' \
      | sort > /tmp/available-versions.txt

    log "Comparing installed vs available..."
    while IFS=: read -r PLUGIN VERSION; do
      AVAILABLE=$(grep "^${PLUGIN}:" /tmp/available-versions.txt | cut -d: -f2 || echo "unknown")
      if [[ "${VERSION}" != "${AVAILABLE}" && "${AVAILABLE}" != "unknown" ]]; then
        echo "  UPDATE: ${PLUGIN} | installed: ${VERSION} → available: ${AVAILABLE}"
      fi
    done < <(grep -v '^#' plugins/plugins.txt | grep -v '^$' | sed 's/:.*/&/')
    ;;

  --apply)
    log "=== Applying plugin updates to ${ENV} ==="

    # Build new Jenkins image
    NEW_TAG="$(date +%Y%m%d)-${ENV}"
    FULL_IMAGE="${IMAGE_BASE}:${NEW_TAG}"

    log "Building new Jenkins image: ${FULL_IMAGE}"
    aws ecr get-login-password --region "${AWS_REGION}" \
      | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

    docker build \
      --no-cache \
      -t "${FULL_IMAGE}" \
      -f docker/Dockerfile \
      .

    docker push "${FULL_IMAGE}"
    log "  ✅ Image pushed: ${FULL_IMAGE}"

    # Update StatefulSet image
    log "Updating Jenkins StatefulSet in ${ENV}..."
    kubectl set image statefulset/jenkins \
      jenkins="${FULL_IMAGE}" \
      --namespace jenkins \
      --context "myapp-${ENV}"

    # Wait for rollout
    kubectl rollout status statefulset/jenkins \
      --namespace jenkins \
      --context "myapp-${ENV}" \
      --timeout=10m

    log "  ✅ Jenkins updated to ${FULL_IMAGE} on ${ENV}"
    log ""
    log "  Verify:"
    log "    kubectl logs jenkins-0 -n jenkins --context myapp-${ENV} | grep 'Jenkins is fully up'"
    log "    Run a test pipeline before proceeding to production"
    ;;

  *)
    die "Unknown mode: ${MODE}. Use --check or --apply [staging|prod]"
    ;;

esac
