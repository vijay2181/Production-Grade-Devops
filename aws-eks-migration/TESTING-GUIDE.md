# Testing Guide — Docker Compose → EKS Migration

> **Rule:** Never switch DNS to EKS without passing every gate below.
> 90 minutes of testing = protection from a multi-hour production outage.

---

## What Breaks If You Skip Each Test

| Skipped Test | What Happens in Production |
|---|---|
| Image build test | All pods → `CrashLoopBackOff`, users see 502 |
| Secrets test | App boots, first DB query → 500 error for every user |
| Load test before cutover | ALB health checks fail under real traffic, instant 503 for all users |
| RDS data migration test | Users log in, their data is missing |
| Rollback test | Production is broken at 2am, you can't remember the right command |

---

## Test Phases Overview

```
Phase 1  ─ Local validation (docker-compose)        ~25 min
Phase 2  ─ Image validation                         ~15 min
Phase 3  ─ Cluster + pod health                     ~20 min
Phase 4  ─ Connectivity (DB + Redis)                ~10 min
Phase 5  ─ Ingress + TLS                            ~10 min
Phase 6  ─ Load test (k6)                           ~20 min
Phase 7  ─ Data migration verification               ~5 min
Phase 8  ─ Rollback drill (practice BEFORE cutover) ~10 min
Phase 9  ─ Cutover monitoring                       ~10 min
──────────────────────────────────────────────────────────
Total                                               ~125 min
```

---

## Phase 1 — Local Validation (docker-compose)

Validate the app works on your machine before touching any AWS infra.

```bash
cd docker-compose

# Start the full stack
docker-compose up -d

# Wait for health checks to pass
docker-compose ps
# All services should show: healthy

# Test API health
curl -s http://localhost/health
# Expected: {"status":"ok","ts":"..."}

# Test readiness (DB + Redis)
curl -s http://localhost/ready
# Expected: {"status":"ready"}

# Test business logic
curl -s -X POST http://localhost/api/items \
  -H "Content-Type: application/json" \
  -d '{"name":"test-item","value":"test-value"}'
# Expected: {"id":1,"name":"test-item","value":"test-value","created_at":"..."}

curl -s http://localhost/api/items
# Expected: {"source":"db","data":[...]}  (first call — from DB)

curl -s http://localhost/api/items
# Expected: {"source":"cache","data":[...]}  (second call — from Redis cache)

# Check metrics endpoint
curl -s http://localhost/metrics | grep http_requests_total
# Expected: http_requests_total{...} <number>

# Tear down
docker-compose down -v

echo "✅ Phase 1 PASSED"
```

**Gate:** All responses match expected output. Do not proceed if any fail.

---

## Phase 2 — Image Validation

Validate the production Docker image before pushing to ECR.

```bash
# Build the image
docker build -t myapp/api:test app/

# Run with env vars (simulate EKS environment)
docker run -d \
  --name api-test \
  -p 3000:3000 \
  -e NODE_ENV=production \
  -e PORT=3000 \
  -e DB_HOST=host.docker.internal \
  -e DB_PORT=5432 \
  -e DB_NAME=myapp \
  -e DB_USER=myuser \
  -e DB_PASSWORD=mysecretpassword \
  -e REDIS_HOST=host.docker.internal \
  -e REDIS_PORT=6379 \
  myapp/api:test

sleep 5

# Test health endpoint (no DB needed)
curl -s http://localhost:3000/health
# Expected: {"status":"ok","ts":"..."}

# Verify container runs as non-root
docker exec api-test whoami
# Expected: appuser  (NOT root)

# Verify read-only root filesystem (nothing writable except /tmp)
docker exec api-test touch /test-write 2>&1
# Expected: touch: /test-write: Read-only file system

docker exec api-test touch /tmp/test-write
# Expected: success (tmp is an emptyDir volume)

# Verify no secrets in image layers
docker history myapp/api:test --no-trunc | grep -i password
# Expected: no output

# Scan for CVEs
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  myapp/api:test
# Expected: exit 0 (no HIGH/CRITICAL CVEs)

# Cleanup
docker rm -f api-test

echo "✅ Phase 2 PASSED"
```

**Gate:** Non-root, read-only FS, no CVEs. Do not push to ECR if any fail.

---

## Phase 3 — Cluster and Pod Health

Validate the EKS cluster and all pods are in the correct state.

```bash
# Verify cluster access
kubectl cluster-info
# Expected: Kubernetes control plane is running at https://...

# All nodes Ready
kubectl get nodes -o wide
# Expected: All nodes STATUS=Ready

# All system pods Running
kubectl get pods -n kube-system
# Expected: No pods in Pending, CrashLoopBackOff, or Error state

# All application pods Running
kubectl get pods -n myapp -o wide
# Expected: All pods STATUS=Running, READY=1/1

# Check pod details for any warnings
kubectl describe pods -n myapp | grep -A5 "Warning\|Error\|OOMKilled"
# Expected: no output

# Verify pod is running as non-root
POD=$(kubectl get pod -l app.kubernetes.io/name=myapp -n myapp \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -n myapp -- id
# Expected: uid=1001(appuser) gid=1001(appgroup)

# Verify all replicas are available
kubectl get deployment myapp-myapp -n myapp
# Expected: READY matches DESIRED (e.g. 3/3 or 5/5)

# HPA is active and not at max
kubectl get hpa myapp-myapp -n myapp
# Expected: MINPODS=3, MAXPODS=20, REPLICAS shows current (not at max)

# PDB is satisfied
kubectl get pdb myapp-myapp-pdb -n myapp
# Expected: ALLOWED DISRUPTIONS >= 1

# Recent events (should be clean)
kubectl get events -n myapp --sort-by='.lastTimestamp' | tail -20
# Expected: no Warning or Error events

echo "✅ Phase 3 PASSED"
```

**Gate:** All pods Running, no warnings, non-root confirmed.

---

## Phase 4 — Connectivity (DB + Redis)

Validate the app can actually reach the database and cache.

```bash
POD=$(kubectl get pod -l app.kubernetes.io/name=myapp -n myapp \
  -o jsonpath='{.items[0].metadata.name}')

# Test readiness endpoint (calls DB + Redis internally)
kubectl exec $POD -n myapp -- \
  wget -qO- http://localhost:3000/ready
# Expected: {"status":"ready"}

# Test direct DB connectivity from pod
kubectl exec $POD -n myapp -- \
  sh -c 'nc -zv $DB_HOST $DB_PORT'
# Expected: Connection to <RDS-endpoint> 5432 port [tcp/postgresql] succeeded!

# Test direct Redis connectivity from pod
kubectl exec $POD -n myapp -- \
  sh -c 'nc -zv $REDIS_HOST $REDIS_PORT'
# Expected: Connection to <ElastiCache-endpoint> 6379 port [tcp/redis] succeeded!

# Test secret values are injected correctly (should NOT print plaintext — just checks existence)
kubectl exec $POD -n myapp -- \
  sh -c 'echo DB_USER is set: $([ -n "$DB_USER" ] && echo YES || echo NO)'
# Expected: DB_USER is set: YES

kubectl exec $POD -n myapp -- \
  sh -c 'echo DB_PASSWORD is set: $([ -n "$DB_PASSWORD" ] && echo YES || echo NO)'
# Expected: DB_PASSWORD is set: YES

# Verify NetworkPolicy is working — redis should NOT be reachable from default namespace
kubectl run netpol-test --image=busybox --rm -it --restart=Never \
  --namespace=default -- \
  sh -c 'nc -zv redis.myapp.svc.cluster.local 6379' 2>&1
# Expected: connection refused or timed out (NetworkPolicy blocks this)

echo "✅ Phase 4 PASSED"
```

**Gate:** DB and Redis reachable from pods, NetworkPolicy blocking cross-namespace traffic.

---

## Phase 5 — Ingress and TLS

Validate the ALB, HTTPS, and routing.

```bash
# Get ALB DNS name
ALB_DNS=$(kubectl get ingress myapp-myapp -n myapp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"
# Expected: some-random-id.us-east-1.elb.amazonaws.com (NOT empty)

# HTTP → HTTPS redirect works
curl -sv http://${ALB_DNS}/health 2>&1 | grep "< HTTP\|Location"
# Expected: HTTP/1.1 301 or 302 + Location: https://...

# HTTPS health check
curl -sf https://${ALB_DNS}/health
# Expected: {"status":"ok","ts":"..."}

# HTTPS readiness
curl -sf https://${ALB_DNS}/ready
# Expected: {"status":"ready"}

# POST a record
curl -sf -X POST https://${ALB_DNS}/api/items \
  -H "Content-Type: application/json" \
  -d '{"name":"eks-test","value":"it-works"}'
# Expected: {"id":1,"name":"eks-test","value":"it-works","created_at":"..."}

# GET records back
curl -sf https://${ALB_DNS}/api/items
# Expected: {"source":"db","data":[{"id":1,...}]}

# Second GET — should hit Redis cache
curl -sf https://${ALB_DNS}/api/items
# Expected: {"source":"cache","data":[...]}

# TLS certificate is valid (not self-signed)
curl -sv https://${ALB_DNS}/health 2>&1 | grep "SSL certificate verify"
# Expected: SSL certificate verify ok

# Verify custom domain (if DNS is already pointed)
# curl -sf https://api.myapp.com/health

echo "✅ Phase 5 PASSED"
```

**Gate:** HTTPS works, redirect from HTTP, TLS valid, business endpoints return correct data.

---

## Phase 6 — Load Test (k6)

This is the most important test. Run this BEFORE switching DNS.
It answers: "Will EKS hold up under real traffic?"

```bash
# Install k6
brew install k6         # macOS
# apt install k6        # Ubuntu

ALB_DNS=$(kubectl get ingress myapp-myapp -n myapp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Run load test — ramp to 100 concurrent users
k6 run - <<EOF
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

let errorRate   = new Rate('errors');
let postLatency = new Trend('post_latency');

export let options = {
  stages: [
    { duration: '1m', target: 20  },   // warm up
    { duration: '3m', target: 100 },   // ramp to 100 users
    { duration: '2m', target: 100 },   // hold at 100
    { duration: '1m', target: 0   },   // ramp down
  ],
  thresholds: {
    http_req_failed:   ['rate<0.01'],   // error rate must be < 1%
    http_req_duration: ['p(95)<500'],   // p95 latency must be < 500ms
    errors:            ['rate<0.01'],
  },
};

export default function () {
  // GET /api/items
  let getRes = http.get('https://${ALB_DNS}/api/items');
  check(getRes, {
    'GET status 200': (r) => r.status === 200,
    'GET < 500ms':    (r) => r.timings.duration < 500,
  });
  errorRate.add(getRes.status !== 200);

  sleep(0.5);

  // POST /api/items
  let postRes = http.post(
    'https://${ALB_DNS}/api/items',
    JSON.stringify({ name: 'load-test', value: String(Date.now()) }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  check(postRes, {
    'POST status 201': (r) => r.status === 201,
    'POST < 1000ms':   (r) => r.timings.duration < 1000,
  });
  postLatency.add(postRes.timings.duration);

  sleep(0.5);
}
EOF

# While k6 runs, watch HPA in another terminal:
# kubectl get hpa myapp-myapp -n myapp -w

# And watch pods:
# kubectl get pods -n myapp -w
```

**Expected k6 output:**
```
✓ GET status 200
✓ GET < 500ms
✓ POST status 201
✓ POST < 1000ms

checks.........................: 99.8%
http_req_failed................: 0.00%   ✓ PASS
http_req_duration p(95)........: 234ms   ✓ PASS (< 500ms)
```

**Gate:** Error rate < 1%, p95 < 500ms. **Do NOT cut over DNS if this fails.**

---

## Phase 7 — Data Migration Verification

Before cutover, verify all data from the old server made it to RDS.

```bash
# On OLD docker-compose server — count rows per table
docker exec postgres psql -U myuser -d myapp \
  -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY tablename;"

# On RDS — count rows per table
kubectl run pg-check --image=postgres:16-alpine --rm -it --restart=Never \
  -n myapp \
  --env="PGPASSWORD=$DB_PASSWORD" \
  -- psql -h $DB_HOST -U $DB_USER -d myapp \
  -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY tablename;"

# Compare outputs manually — row counts must match exactly

# Also verify the most recent records
# Old server:
docker exec postgres psql -U myuser -d myapp \
  -c "SELECT id, created_at FROM items ORDER BY id DESC LIMIT 5;"

# RDS:
kubectl run pg-check2 --image=postgres:16-alpine --rm -it --restart=Never \
  -n myapp \
  --env="PGPASSWORD=$DB_PASSWORD" \
  -- psql -h $DB_HOST -U $DB_USER -d myapp \
  -c "SELECT id, created_at FROM items ORDER BY id DESC LIMIT 5;"

echo "✅ Phase 7 PASSED — if row counts match"
```

**Gate:** Row counts match exactly between old server and RDS.

---

## Phase 8 — Rollback Drill

Practice the rollback **before** going live. You must be able to do this
from memory at 2am under pressure.

```bash
# Step 1: See current Helm release history
helm history myapp --namespace myapp
# Note the current REVISION number

# Step 2: Simulate a bad deploy (deploy a broken tag)
helm upgrade myapp helm/charts/myapp \
  --namespace myapp \
  --set image.tag="broken-tag-does-not-exist" \
  --wait --timeout 2m 2>&1 || echo "Deploy failed as expected"

# Step 3: Check pod state
kubectl get pods -n myapp
# Some pods should show ErrImagePull or ImagePullBackOff

# Step 4: Roll back immediately
helm rollback myapp --namespace myapp --wait
# Expected: Rollback was a success! Happy Helming!

# Step 5: Verify pods recovered
kubectl get pods -n myapp
# Expected: All pods Running again

# Step 6: Verify rollout history
kubectl rollout history deployment/myapp-myapp -n myapp

# Step 7: Kubectl-only rollback (alternative)
kubectl rollout undo deployment/myapp-myapp -n myapp
kubectl rollout status deployment/myapp-myapp -n myapp

echo "✅ Phase 8 PASSED — rollback works, you know the commands"
```

**Gate:** You can roll back within 2 minutes. If you struggled with any command, practice again.

---

## Phase 9 — Cutover Monitoring

After DNS switch, monitor for 10 minutes minimum.

```bash
DOMAIN="api.myapp.com"

echo "Monitoring $DOMAIN for 10 minutes after DNS cutover..."

for i in $(seq 1 20); do
  TIMESTAMP=$(date +%T)
  HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" \
    --max-time 5 "https://${DOMAIN}/health" 2>/dev/null || echo "000")
  LATENCY=$(curl -so /dev/null -w "%{time_total}" \
    --max-time 5 "https://${DOMAIN}/health" 2>/dev/null || echo "timeout")

  if [ "$HTTP_STATUS" = "200" ]; then
    echo "  [$TIMESTAMP] ✅ HTTP $HTTP_STATUS  latency: ${LATENCY}s"
  else
    echo "  [$TIMESTAMP] 🚨 HTTP $HTTP_STATUS  latency: ${LATENCY}s  ← INVESTIGATE"
  fi

  sleep 30
done

echo ""
echo "Also check in parallel:"
echo "  kubectl get pods -n myapp -w"
echo "  kubectl top pods -n myapp"
echo "  Grafana → MyApp API Dashboard → Error Rate panel"
```

**Gate:** All 20 checks return HTTP 200. If 3+ consecutive non-200s → run rollback immediately.

---

## Full Test Execution Checklist

```
[ ] Phase 1  — docker-compose works locally
[ ] Phase 2  — image is non-root, read-only FS, no CVEs
[ ] Phase 3  — all pods Running, no warnings, HPA active
[ ] Phase 4  — DB + Redis reachable, NetworkPolicy blocking cross-NS
[ ] Phase 5  — ALB HTTPS works, HTTP redirects, TLS valid
[ ] Phase 6  — k6 load test: error rate < 1%, p95 < 500ms  ← DO NOT SKIP
[ ] Phase 7  — RDS row counts match old server exactly      ← DO NOT SKIP
[ ] Phase 8  — rollback drill completed, commands memorised ← DO NOT SKIP
[ ] Phase 9  — post-cutover monitoring: 20 consecutive 200s
```

---

## Quick Reference — Key Commands During Incidents

```bash
# What is broken right now?
kubectl get pods -n myapp
kubectl get events -n myapp --sort-by='.lastTimestamp' | tail -20

# Why is a pod failing?
kubectl describe pod <pod-name> -n myapp
kubectl logs <pod-name> -n myapp --previous   # logs from crashed container

# Is it a code bug or infra bug?
kubectl logs -l app.kubernetes.io/name=myapp -n myapp --tail=50

# Roll back immediately
helm rollback myapp --namespace myapp --wait

# Scale up manually during a traffic spike
kubectl scale deployment myapp-myapp --replicas=10 -n myapp

# Check if HPA is the problem
kubectl describe hpa myapp-myapp -n myapp

# Is the ALB healthy?
kubectl describe ingress myapp-myapp -n myapp
```
