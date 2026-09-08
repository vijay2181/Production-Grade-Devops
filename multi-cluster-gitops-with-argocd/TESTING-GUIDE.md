# Testing Guide — Multi-Cluster GitOps with ArgoCD

> Never promote a canary or cut traffic without passing every gate below.

---

## Test Phases Overview

```
Phase 1  ─ ArgoCD health check                  ~10 min
Phase 2  ─ Cluster registration                 ~10 min
Phase 3  ─ ApplicationSet sync                  ~15 min
Phase 4  ─ GitOps loop (push → auto-deploy)     ~20 min
Phase 5  ─ Canary rollout + analysis            ~30 min
Phase 6  ─ Canary abort (rollback test)         ~10 min
Phase 7  ─ Blue/Green promotion                 ~15 min
Phase 8  ─ Drift detection + self-heal          ~10 min
Phase 9  ─ Notifications                        ~10 min
Phase 10 ─ Sync window enforcement              ~5  min
──────────────────────────────────────────────────────────
Total                                           ~135 min
```

---

## Phase 1 — ArgoCD Health Check

```bash
# All ArgoCD pods Running
kubectl get pods -n argocd
# Expected: argocd-server, argocd-repo-server, argocd-application-controller,
#           argocd-dex-server, argocd-redis — all Running 1/1

# ArgoCD Image Updater running
kubectl get pods -n argocd | grep image-updater
# Expected: argocd-image-updater-xxxx   1/1   Running

# Argo Rollouts controller running
kubectl get pods -n argo-rollouts
# Expected: argo-rollouts-xxxx   1/1   Running

# CLI works
argocd version --client
# Expected: argocd: v2.10.x

echo "✅ Phase 1 PASSED"
```

---

## Phase 2 — Cluster Registration

```bash
# All spoke clusters registered
argocd cluster list
# Expected:
#   SERVER                                    NAME             STATUS
#   https://kubernetes.default.svc            in-cluster       Successful
#   https://dev-cluster.example.com           myapp-dev        Successful
#   https://staging-cluster.example.com       myapp-staging    Successful
#   https://prod-cluster.example.com          myapp-prod       Successful
# STATUS must be "Successful" — not "Unknown" or "Failed"

# Verify ArgoCD can reach prod cluster
argocd cluster get myapp-prod
# Expected: Connection Status: Successful, Server Version: 1.29.x

echo "✅ Phase 2 PASSED"
```

---

## Phase 3 — ApplicationSet Sync

```bash
# ApplicationSet was created
kubectl get applicationset -n argocd
# Expected: myapp   1m

# Three Applications were generated
kubectl get applications -n argocd
# Expected:
#   NAME             CLUSTER         NAMESPACE       SYNC STATUS   HEALTH STATUS
#   myapp-dev        myapp-dev       myapp-dev       Synced        Healthy
#   myapp-staging    myapp-staging   myapp-staging   Synced        Healthy
#   myapp-prod       myapp-prod      myapp-prod      Synced        Healthy

# All pods running on each cluster
kubectl get pods -n myapp-dev     --context=myapp-dev
kubectl get pods -n myapp-staging --context=myapp-staging
kubectl get pods -n myapp-prod    --context=myapp-prod
# Expected: all Running

# Verify dev has 1 replica, staging 2, prod 5
kubectl get deployment api -n myapp-dev     --context=myapp-dev
kubectl get deployment api -n myapp-staging --context=myapp-staging
kubectl get deployment api -n myapp-prod    --context=myapp-prod

echo "✅ Phase 3 PASSED"
```

---

## Phase 4 — GitOps Loop (Push → Auto-Deploy)

This is the most important test. Proves the full GitOps loop works.

```bash
# Step 1: Make a visible change to dev overlay
echo "  # test change $(date)" >> apps/myapp/overlays/dev/patch.yaml
git add .
git commit -m "test: gitops loop validation"
git push origin develop

# Step 2: Watch ArgoCD detect the change (within 3 min)
kubectl get applications myapp-dev -n argocd -w
# Expected: SYNC STATUS changes OutOfSync → Synced

# Step 3: Verify the change was applied
kubectl get pods -n myapp-dev --context=myapp-dev -w
# Expected: pods restart with new revision

# Step 4: Verify Image Updater wrote back to Git
# Push a new image to ECR with a semver tag:
# docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0
# Wait 2-5 min, then:
git pull
cat apps/myapp/overlays/dev/kustomization.yaml | grep newTag
# Expected: newTag: v1.1.0  ← Image Updater committed this

echo "✅ Phase 4 PASSED — GitOps loop confirmed"
```

---

## Phase 5 — Canary Rollout + Analysis

```bash
# Switch to prod context
kubectl config use-context myapp-prod

# Trigger a new rollout (update image tag)
kubectl argo rollouts set image myapp-api \
  api=123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0 \
  -n myapp-prod

# Watch the rollout progress step by step
kubectl argo rollouts get rollout myapp-api -n myapp-prod --watch

# Expected progression:
#   Progressing - 10% canary weight
#   Progressing - AnalysisRun running (api-success-rate)
#   Progressing - 50% canary weight
#   Progressing - AnalysisRun running (api-success-rate)
#   Healthy     - 100% (fully promoted)

# During the 10% phase, verify traffic split on ALB:
# In AWS Console → EC2 → Target Groups
# Two target groups should show: stable (90% weight), canary (10% weight)

# Check AnalysisRun results
kubectl get analysisrun -n myapp-prod
kubectl describe analysisrun -n myapp-prod | grep -A5 "Status\|Measurements"
# Expected: Phase: Successful, all metric measurements passed

echo "✅ Phase 5 PASSED — Canary promoted successfully"
```

---

## Phase 6 — Canary Abort (Rollback Test)

```bash
kubectl config use-context myapp-prod

# Trigger a rollout with a bad image (simulate broken deploy)
kubectl argo rollouts set image myapp-api \
  api=123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:bad-image \
  -n myapp-prod

# Wait for rollout to start (10% canary)
kubectl argo rollouts get rollout myapp-api -n myapp-prod

# Manually abort (simulating engineer intervention or failed analysis)
./scripts/promote-canary.sh abort

# Verify rollback to stable
kubectl argo rollouts get rollout myapp-api -n myapp-prod
# Expected: Phase: Degraded → Healthy (rolled back to previous stable)

# Verify stable pods are running the OLD image
kubectl get pods -n myapp-prod -o jsonpath='{.items[*].spec.containers[0].image}'
# Expected: v1.1.0 (stable), NOT bad-image

echo "✅ Phase 6 PASSED — Abort and rollback confirmed"
```

---

## Phase 7 — Blue/Green Promotion

```bash
kubectl config use-context myapp-staging

# Trigger a blue/green rollout
kubectl argo rollouts set image myapp-api-bluegreen \
  api=123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.1.0 \
  -n myapp-staging

# Watch green (preview) pods come up
kubectl argo rollouts get rollout myapp-api-bluegreen -n myapp-staging --watch
# Expected: green pods Running, blue pods still receiving traffic

# Hit preview service directly (test green before promoting)
PREVIEW_SVC=$(kubectl get svc myapp-api-preview -n myapp-staging \
  -o jsonpath='{.spec.clusterIP}')
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n myapp-staging -- curl -sf http://${PREVIEW_SVC}/health
# Expected: {"status":"ok"}

# Promote green → becomes active (blue/green swap)
./scripts/promote-canary.sh promote  # (works for both canary and blue/green)

# Verify active service now routes to new version
kubectl argo rollouts get rollout myapp-api-bluegreen -n myapp-staging
# Expected: Healthy, active = v1.1.0, old blue pods scaling down

echo "✅ Phase 7 PASSED — Blue/Green promotion confirmed"
```

---

## Phase 8 — Drift Detection + Self-Heal

```bash
# Simulate someone manually changing a Deployment in prod (drift)
kubectl scale deployment api --replicas=10 \
  -n myapp-prod --context=myapp-prod

# ArgoCD detects drift within 3 min (selfHeal is enabled for dev/staging)
kubectl get application myapp-dev -n argocd -w
# Expected: SYNC STATUS briefly shows OutOfSync → then auto-reverts to Synced

# For prod (manual sync only) — ArgoCD shows OutOfSync but does NOT auto-revert
kubectl get application myapp-prod -n argocd
# Expected: SYNC STATUS = OutOfSync  (human must approve sync)

# Verify the replica count was reverted in dev (selfHeal)
kubectl get deployment api -n myapp-dev --context=myapp-dev
# Expected: DESIRED = 1 (reverted to Git state)

# Manually sync prod after review
argocd app sync myapp-prod
kubectl get application myapp-prod -n argocd
# Expected: Synced + Healthy

echo "✅ Phase 8 PASSED — Drift detection and self-heal confirmed"
```

---

## Phase 9 — Notifications

```bash
# Trigger a sync on dev (should send Slack message to #deployments)
argocd app sync myapp-dev

# Check notification controller logs
kubectl logs -l app.kubernetes.io/name=argocd-notifications-controller \
  -n argocd --tail=20
# Expected: Sending notification ... to slack:deployments

# Force a failure (point to non-existent Git branch)
# Then check for failure notification in Slack

echo "✅ Phase 9 PASSED — confirm Slack messages received"
```

---

## Phase 10 — Sync Window Enforcement

```bash
# Simulate a prod deploy OUTSIDE allowed window (weekends / after 5pm)
# Temporarily patch the sync window to simulate blocked deploy:

argocd app sync myapp-prod --dry-run
# If outside sync window:
# Expected: ComparisonError: ... blocked by sync window

# Verify inside window works:
# (run during Mon-Fri 9am-5pm)
argocd app sync myapp-prod
# Expected: Sync succeeded

echo "✅ Phase 10 PASSED — sync windows enforced"
```

---

## Full Checklist

```
[ ] Phase 1  — All ArgoCD pods Running, Image Updater + Rollouts running
[ ] Phase 2  — All 3 spoke clusters registered with STATUS=Successful
[ ] Phase 3  — ApplicationSet generated 3 Applications, all Synced + Healthy
[ ] Phase 4  — Push to Git → ArgoCD auto-deploys within 3 min        ← DO NOT SKIP
[ ] Phase 5  — Canary: 10% → analysis → 50% → analysis → 100%        ← DO NOT SKIP
[ ] Phase 6  — Canary abort → rollback to stable confirmed            ← DO NOT SKIP
[ ] Phase 7  — Blue/Green: preview healthy → promote → swap confirmed
[ ] Phase 8  — Manual kubectl change → ArgoCD reverts (self-heal)     ← DO NOT SKIP
[ ] Phase 9  — Slack notification received on deploy + fail
[ ] Phase 10 — Sync window blocks deploy outside allowed hours
```

---

## Key Commands Quick Reference

```bash
# See all apps across all clusters
argocd app list

# See sync + health status of one app
argocd app get myapp-prod

# Force a sync (prod)
argocd app sync myapp-prod

# Watch a rollout
kubectl argo rollouts get rollout myapp-api -n myapp-prod --watch

# Promote canary one step
kubectl argo rollouts promote myapp-api -n myapp-prod

# Abort canary (rollback)
kubectl argo rollouts abort myapp-api -n myapp-prod

# See analysis runs
kubectl get analysisrun -n myapp-prod

# See ArgoCD events
kubectl get events -n argocd --sort-by='.lastTimestamp' | tail -20

# Hard refresh (ignore cache)
argocd app get myapp-prod --hard-refresh
```
