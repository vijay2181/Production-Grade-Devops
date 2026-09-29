# 🧪 Jenkins High Availability (HA) & Disaster Recovery Testing Guide

This guide provides step-by-step procedures to validate the 4 pillars of Jenkins HA: **Active Controller Auto-Healing**, **Dynamic Kubernetes Agents**, **JCasC Reconciliation**, and **Disaster Recovery Backup/Restore**.

---

## 🚀 1. Deploy the Complete HA Setup

```bash
cd cka/practical/jenkins-high-availability
chmod +x scripts/*.sh backup-dr/*.sh

# Deploy the entire stack to your Kubernetes cluster
./scripts/deploy-and-test.sh
```

---

## 🔬 2. Verification Scenarios

### Scenario A: Test Dynamic Kubernetes Agent Execution
1. Port-forward the Jenkins UI:
   ```bash
   kubectl port-forward svc/jenkins-ha 8080:8080 -n jenkins-ha
   ```
2. Log in at `http://localhost:8080` (`admin` / `AdminSecurePass123!`).
3. Create a new Pipeline Job using the provided [`pipelines/Jenkinsfile`](pipelines/Jenkinsfile:1).
4. Run the build and observe in terminal:
   ```bash
   kubectl get pods -n jenkins-ha -w
   ```
   *Notice the dynamic agent pod spawn (`jenkins-agent-...`), execute the pipeline in parallel, and automatically terminate upon completion.*

---

### Scenario B: Chaos Test — Controller Node Crash / Pod Kill (RTO Measurement)
Simulate an abrupt controller failure and measure the Recovery Time Objective (RTO):

```bash
./scripts/simulate-node-failure.sh
```
**Expected Result:**
- Kubernetes detects the termination.
- StatefulSet volume lock is cleanly handed over.
- New Controller pod re-mounts `$JENKINS_HOME` and resumes operation in **< 45 seconds** with **zero data loss**.

---

### Scenario C: Disaster Recovery (DR) Full Backup and Restore Test

1. **Trigger an On-Demand Backup:**
   ```bash
   kubectl create job --from=cronjob/jenkins-ha-thinbackup test-backup -n jenkins-ha
   kubectl wait --for=condition=Complete job/test-backup -n jenkins-ha
   ```

2. **Verify Backup Archive:**
   ```bash
   kubectl exec -it jenkins-ha-controller-0 -n jenkins-ha -- ls -la /var/jenkins_home/backups/
   ```

3. **Simulate Catastrophic Data Loss & 1-Click Restore:**
   ```bash
   # Restore from the latest archive using the automated DR tool
   ./backup-dr/restore-script.sh /var/jenkins_home/backups/<timestamp>/jenkins_core_config.tar.gz
   ```
