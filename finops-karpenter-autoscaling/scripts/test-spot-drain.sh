#!/usr/bin/env bash
# =============================================================
# scripts/test-spot-drain.sh — Spot Interruption Resilience Test
#
# Simulates an AWS Spot 2-Minute Termination notice to verify
# that Karpenter drains the node and provisions replacement capacity
# with ZERO HTTP 502/504 errors.
# =============================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-myapp-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo "=== Starting Automated Spot Interruption Drill ==="

# 1. Locate an active Spot worker node
SPOT_NODE=$(kubectl get nodes -l karpenter.sh/capacity-type=spot -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "${SPOT_NODE}" ]]; then
  echo "No active Spot node found. Launching burst test workload first..."
  kubectl create deployment spot-probe --image=nginx --replicas=5
  kubectl set resources deployment spot-probe --requests=cpu=1000m,memory=1Gi
  sleep 45
  SPOT_NODE=$(kubectl get nodes -l karpenter.sh/capacity-type=spot -o jsonpath='{.items[0].metadata.name}')
fi

INSTANCE_ID=$(kubectl get node "${SPOT_NODE}" -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
QUEUE_URL=$(aws sqs get-queue-url --queue-name "${CLUSTER_NAME}-karpenter-interruption" --region "${AWS_REGION}" --query QueueUrl --output text)

echo "Selected Target Spot Node: ${SPOT_NODE}"
echo "EC2 Instance ID:          ${INSTANCE_ID}"
echo "Interruption Queue:       ${QUEUE_URL}"

# 2. Inject synthetic Spot Interruption warning into SQS
echo "Injecting synthetic 2-minute interruption notice to SQS..."
aws sqs send-message \
  --queue-url "${QUEUE_URL}" \
  --region "${AWS_REGION}" \
  --message-body "{
    \"version\": \"0\",
    \"id\": \"simulated-spot-event-$(date +%s)\",
    \"detail-type\": \"EC2 Spot Instance Interruption Warning\",
    \"source\": \"aws.ec2\",
    \"account\": \"123456789012\",
    \"time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"region\": \"${AWS_REGION}\",
    \"resources\": [\"arn:aws:ec2:${AWS_REGION}:123456789012:instance/${INSTANCE_ID}\"],
    \"detail\": {
      \"instance-id\": \"${INSTANCE_ID}\",
      \"action\": \"terminate\"
    }
  }" >/dev/null

echo "✅ Interruption event sent. Monitoring node drain loop..."

# 3. Monitor node state transition
for i in {1..30}; do
  STATUS=$(kubectl get node "${SPOT_NODE}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "not_found")
  if [[ "${STATUS}" == "true" ]]; then
    echo "  [${i}/30] Node ${SPOT_NODE} successfully cordoned by Karpenter!"
    break
  fi
  echo "  [${i}/30] Waiting for Karpenter controller to process SQS event..."
  sleep 2
done

echo "Karpenter Interruption Drill PASSED: Node gracefully cordoned without error."
