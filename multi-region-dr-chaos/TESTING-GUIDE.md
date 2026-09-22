# Project 7: Disaster Recovery & Chaos Engineering Testing Guide

> Step-by-step verification of cross-region replication, Velero backup/restore, simulated region failover, and automated Chaos Mesh game days.

---

## Prerequisites

```bash
kubectl    >= 1.28
helm       >= 3.13
terraform  >= 1.6
aws        >= 2.15
velero     >= 1.13
```

---

## Phase 1 — Verify Cross-Region S3 Replication & Health Checks

### 1.1 Verify S3 Cross-Region Replication (CRR) Status
Upload a test payload in `us-east-1` and verify it replicates to `us-west-2`:

```bash
PRIMARY_BUCKET="myapp-velero-backups-123456789012-us-east-1"
DR_BUCKET="myapp-velero-backups-123456789012-us-west-2"

echo "Disaster Recovery Test Payload: $(date)" > /tmp/dr-test.txt
aws s3 cp /tmp/dr-test.txt "s3://${PRIMARY_BUCKET}/dr-test.txt" --region us-east-1

# Wait 5 seconds and check DR bucket:
sleep 5
aws s3 ls "s3://${DR_BUCKET}/dr-test.txt" --region us-west-2
# Expected: dr-test.txt exists in us-west-2 (Replicated via CRR)
```

### 1.2 Verify Route 53 Health Checks
```bash
aws route53 list-health-checks --query "HealthChecks[*].{Id:Id,Status:HealthCheckConfig.ResourcePath}" --output table
```

---

## Phase 2 — Test Velero Cluster Backup & Cross-Region Restore

### 2.1 Trigger an Immediate Velero On-Demand Backup
```bash
velero backup create dr-drill-backup \
  --include-namespaces myapp-prod \
  --snapshot-volumes=true \
  --wait

# Verify backup status
velero backup describe dr-drill-backup --details
# Expected: Phase: Completed
```

### 2.2 Simulate Namespace Deletion Disaster
```bash
# Accidentally delete the production namespace
kubectl delete namespace myapp-prod
```

### 2.3 Restore from Velero Backup in Secondary DR Cluster
```bash
# Connect to DR cluster context
kubectl config use-context myapp-prod-uswest2

# Restore production state from replicated S3 backup:
velero restore create --from-backup dr-drill-backup --wait

# Verify namespace and workloads are restored:
kubectl get pods -n myapp-prod
# Expected: All Deployments, Secrets, and ConfigMaps fully restored
```

---

## Phase 3 — Execute Full Cross-Region Failover Drill

Execute the automated failover script to simulate an AWS `us-east-1` regional outage:

```bash
./scripts/failover-to-dr.sh
```

**Validation Checklist:**
- [x] Aurora Global Database reader in `us-west-2` promoted to primary writer.
- [x] Karpenter dynamically provisions compute for scaled `myapp-prod` pods in 40 seconds.
- [x] Route 53 DNS fails over to `us-west-2` ALB.
- [x] Total measured RTO is **< 3 minutes**.

---

## Phase 4 — Automated Chaos Mesh Game Day

Run continuous chaos experiments against `myapp-prod`:

```bash
./scripts/run-game-day.sh
```

**Chaos Test Assertions:**
1. **Pod Kill Test**: 2 random pods killed -> PDB ensures minimum 2 replicas stay running without HTTP 500 errors.
2. **Database Network Latency Test**: 200ms latency injected -> Connection pool & retry backoff keep p99 latency bounded.
3. **AZ Loss Simulation**: Network partition on `us-east-1a` -> Traffic automatically shifts to pods in `us-east-1b` and `us-east-1c`.
