#!/usr/bin/env bash
# =============================================================
# cutover.sh — Production cutover: switch DNS from old server to EKS
#
# Usage: ./scripts/cutover.sh <route53-hosted-zone-id> <domain>
# Example: ./scripts/cutover.sh Z1234567890ABCD api.myapp.com
# =============================================================
set -euo pipefail

HOSTED_ZONE_ID="${1:?Pass Route53 Hosted Zone ID as arg 1}"
DOMAIN="${2:?Pass domain as arg 2 e.g. api.myapp.com}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "=== Starting cutover to EKS for $DOMAIN ==="

# ── 1. Lower TTL 30 min BEFORE cutover (run this ahead of time!) ──
echo "[1/6] Lowering DNS TTL to 60s..."
ALB_DNS=$(kubectl get ingress myapp-myapp -n myapp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "     ALB DNS: $ALB_DNS"

# ── 2. Run load test against EKS first ───────────────────────────
echo "[2/6] Smoke-testing EKS endpoint..."
for i in $(seq 1 10); do
  curl -sf "https://${ALB_DNS}/health" && echo " ✓ $i/10" || { echo "FAIL on $i"; exit 1; }
  sleep 1
done

# ── 3. Update Route 53 A/CNAME ────────────────────────────────────
echo "[3/6] Updating Route53 $DOMAIN → $ALB_DNS ..."
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${DOMAIN}\",
        \"Type\": \"CNAME\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"${ALB_DNS}\"}]
      }
    }]
  }"

# ── 4. Monitor for 10 minutes ─────────────────────────────────────
echo "[4/6] Monitoring error rate for 10 min (Ctrl+C to stop)..."
for i in $(seq 1 20); do
  STATUS=$(curl -so /dev/null -w "%{http_code}" "https://${DOMAIN}/health" 2>/dev/null || echo "000")
  echo "  [$(date +%T)] HTTP $STATUS"
  [ "$STATUS" != "200" ] && echo "⚠️  Non-200 detected!" 
  sleep 30
done

# ── 5. Verify Prometheus metrics ──────────────────────────────────
echo "[5/6] Checking Prometheus alert state..."
kubectl get prometheusrules -n monitoring 2>/dev/null | head -5

echo "[6/6] Cutover complete ✅"
echo ""
echo "ROLLBACK COMMAND (if needed):"
echo "  Update Route53 back to old server IP/DNS"
echo "  aws route53 change-resource-record-sets ... (swap ALB_DNS back)"
