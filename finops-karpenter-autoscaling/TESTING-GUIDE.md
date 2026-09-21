# Project 6: FinOps & Karpenter Testing Guide

> Step-by-step verification, load testing, consolidation validation, and simulated Spot disruption tests.

---

## Prerequisites

```bash
kubectl    >= 1.28
helm       >= 3.13
terraform  >= 1.6
aws        >= 2.15
jq
```

---

## Phase 1 — Verify Karpenter v1.0+ & NodePools

### 1.1 Verify Karpenter Controller Health
```bash
# Check controller pods running in HA across separate AZs
kubectl get pods -n karpenter -o wide

# Verify Karpenter controller logs for discovery
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller --tail=50
# Expected: "Discovered subnets...", "Discovered security groups...", "Ready"
```

### 1.2 Verify NodePools and EC2NodeClass CRDs
```bash
kubectl get ec2nodeclasses.karpenter.k8s.aws
# Expected: default (Ready)

kubectl get nodepools.karpenter.sh
# Expected:
# NAME                NODECLASS   NODES   READY   AGE
# critical-ondemand   default     2       True    5m
# general-spot        default     4       True    5m
# ci-ephemeral        default     0       True    5m
```

---

## Phase 2 — Test Dynamic Node Provisioning & Bin-Packing

### 2.1 Trigger a Sudden High-CPU Scaling Burst
Create a burst deployment requiring 16 vCPUs to force Karpenter to launch Spot instances:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: compute-burst-test
  namespace: default
spec:
  replicas: 16
  selector:
    matchLabels:
      app: compute-burst
  template:
    metadata:
      labels:
        app: compute-burst
    spec:
      nodeSelector:
        nodepool: general-spot
      containers:
        - name: stress
          image: public.ecr.aws/docker/library/busybox:latest
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: "1000m"
              memory: "1Gi"
EOF
```

### 2.2 Watch Karpenter Launch Dynamic Nodes (under 45 seconds)
```bash
# Watch pending pods schedule
kubectl get pods -l app=compute-burst -w

# In another terminal, watch Karpenter provision nodes directly via EC2 Fleet:
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller -f | grep -E 'found provisionable pod|launched node'
```
*Expected: Karpenter computes the optimal combination (e.g. 1x `c7g.4xlarge` Spot or 2x `c7g.2xlarge` Spot) and launches instances within 35–45 seconds.*

---

## Phase 3 — Test Active Defragmentation & Consolidation

### 3.1 Scale Down the Burst Workload
```bash
# Scale down from 16 replicas to 2 replicas
kubectl scale deployment compute-burst-test --replicas=2
```

### 3.2 Watch Karpenter Consolidate and Terminate Unneeded Nodes
```bash
# Watch Karpenter evaluate consolidation
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller -f | grep -E 'consolidating|terminating node'

# Watch node count shrink automatically:
kubectl get nodes -l nodepool=general-spot -w
```
*Expected: Karpenter cordons, drains, and deletes empty/underutilized nodes within 30 seconds, returning compute bill to baseline.*

---

## Phase 4 — Test Spot Interruption 2-Minute Graceful Drain

### 4.1 Simulate AWS Spot Interruption via AWS CLI
Trigger a simulated Spot interruption event by pushing a synthetic EventBridge message directly to the SQS queue:

```bash
CLUSTER_NAME="myapp-prod"
QUEUE_URL=$(aws sqs get-queue-url --queue-name "${CLUSTER_NAME}-karpenter-interruption" --query QueueUrl --output text)
TEST_NODE=$(kubectl get nodes -l karpenter.sh/capacity-type=spot -o jsonpath='{.items[0].metadata.name}')
INSTANCE_ID=$(kubectl get node "${TEST_NODE}" -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)

echo "Simulating 2-minute Spot Interruption on instance: ${INSTANCE_ID} (${TEST_NODE})"

aws sqs send-message \
  --queue-url "${QUEUE_URL}" \
  --message-body "{
    \"version\": \"0\",
    \"id\": \"test-event-123\",
    \"detail-type\": \"EC2 Spot Instance Interruption Warning\",
    \"source\": \"aws.ec2\",
    \"account\": \"123456789012\",
    \"time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"region\": \"us-east-1\",
    \"resources\": [\"arn:aws:ec2:us-east-1:123456789012:instance/${INSTANCE_ID}\"],
    \"detail\": {
      \"instance-id\": \"${INSTANCE_ID}\",
      \"action\": \"terminate\"
    }
  }"
```

### 4.2 Verify Graceful Pod Rescheduling (Zero 502 Errors)
```bash
# Watch the target node get cordoned and drained
kubectl get node "${TEST_NODE}"
# Status: Ready,SchedulingDisabled

# Verify Karpenter immediately provisions a replacement node BEFORE draining completes:
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller | grep -E 'interruption|cordon|drain'
```

---

## Phase 5 — Test KEDA Scale-to-Zero & Event-Driven Scaling

### 5.1 Verify KEDA ScaledObjects
```bash
kubectl get scaledobjects -n myapp-prod
# Expected:
# NAME                         TARGETNAME                MIN   MAX   TRIGGERS   AUTHENTICATION
# order-processor-sqs-scaler   order-processor-worker    0     40    aws-sqs    keda-aws-credentials
# myapp-api-http-scaler        myapp                     3     50    prometheus
```

### 5.2 Test Scale to Zero
Verify worker deployment has 0 pods when SQS is empty:
```bash
kubectl get deployment order-processor-worker -n myapp-prod
# Expected: READY 0/0
```

### 5.3 Inject 2,000 SQS Messages and Watch Instant Scale Out
```bash
SQS_URL="https://sqs.us-east-1.amazonaws.com/123456789012/myapp-order-processing-queue"

# Send 500 test messages
for i in {1..500}; do
  aws sqs send-message --queue-url "${SQS_URL}" --message-body "{\"order_id\": ${i}}" >/dev/null &
done
wait

# Watch KEDA instantly scale pods from 0 to 25:
kubectl get pods -n myapp-prod -l app=order-processor -w
```

---

## Phase 6 — Verify OpenCost & FinOps Prometheus Metrics

### 6.1 Query OpenCost Cost Allocation Endpoint
```bash
kubectl port-forward -n opencost svc/opencost 9003:9003 &

# Query hourly cost broken down by Kubernetes namespace:
curl -s "http://localhost:9003/allocation/compute?window=1h&aggregate=namespace" | jq .
```

### 6.2 Verify Prometheus FinOps Rules
```bash
# Query active FinOps Prometheus metrics
curl -s "http://localhost:9090/api/v1/query?query=node_cpu_hourly_cost" | jq .
```
