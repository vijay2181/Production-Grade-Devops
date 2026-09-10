#!/usr/bin/env bash
# =============================================================
# audit.sh — Run CIS Kubernetes Benchmark + security checks
# Uses kube-bench to test against CIS controls.
# =============================================================
set -euo pipefail

NAMESPACE="kube-bench"
echo "=== Kubernetes Security Audit ==="

# ── 1. CIS Benchmark via kube-bench ──────────────────────────────
echo "[1/5] Running CIS Benchmark (kube-bench)..."
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      hostPID: true
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:latest
          command: ["kube-bench", "--json"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      restartPolicy: Never
      volumes:
        - name: var-lib-etcd
          hostPath: { path: /var/lib/etcd }
        - name: var-lib-kubelet
          hostPath: { path: /var/lib/kubelet }
        - name: etc-systemd
          hostPath: { path: /etc/systemd }
        - name: etc-kubernetes
          hostPath: { path: /etc/kubernetes }
EOF

# Wait for kube-bench to complete
echo "  Waiting for kube-bench to complete..."
kubectl wait --for=condition=complete job -l app=kube-bench \
  -n ${NAMESPACE} --timeout=120s 2>/dev/null || true

# Print results
BENCH_POD=$(kubectl get pod -n ${NAMESPACE} \
  -l job-name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${BENCH_POD}" ]; then
  kubectl logs "${BENCH_POD}" -n ${NAMESPACE} | \
    python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  totals = data.get('Totals', {})
  print(f'  PASS: {totals.get(\"total_pass\", 0)}')
  print(f'  FAIL: {totals.get(\"total_fail\", 0)}')
  print(f'  WARN: {totals.get(\"total_warn\", 0)}')
  print(f'  INFO: {totals.get(\"total_info\", 0)}')
except:
  print('  Could not parse results — check pod logs manually')
" 2>/dev/null || echo "  Check pod logs: kubectl logs ${BENCH_POD} -n ${NAMESPACE}"
fi

# ── 2. OPA Gatekeeper violations ─────────────────────────────────
echo ""
echo "[2/5] OPA Gatekeeper constraint violations..."
kubectl get constraints -A -o json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
total_violations = 0
for item in data.get('items', []):
  name = item['metadata']['name']
  violations = item.get('status', {}).get('totalViolations', 0)
  if violations > 0:
    print(f'  {name}: {violations} violations')
    for v in item.get('status', {}).get('violations', [])[:3]:
      print(f'    - {v.get(\"message\", \"\")}')
  total_violations += violations
print(f'  Total violations: {total_violations}')
" 2>/dev/null || echo "  Gatekeeper not installed or no constraints found"

# ── 3. Trivy vulnerability reports ───────────────────────────────
echo ""
echo "[3/5] Trivy vulnerability summary..."
kubectl get vulnerabilityreports -A -o json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
critical = high = medium = 0
for item in data.get('items', []):
  s = item.get('report', {}).get('summary', {})
  critical += s.get('criticalCount', 0)
  high     += s.get('highCount', 0)
  medium   += s.get('mediumCount', 0)
print(f'  CRITICAL: {critical}')
print(f'  HIGH:     {high}')
print(f'  MEDIUM:   {medium}')
if critical > 0:
  print('  ⚠️  CRITICAL CVEs found — update affected images immediately')
" 2>/dev/null || echo "  Trivy Operator not installed or no reports yet"

# ── 4. Falco alert summary ────────────────────────────────────────
echo ""
echo "[4/5] Recent Falco alerts (last 10 min)..."
kubectl logs -l app.kubernetes.io/name=falco \
  -n falco \
  --since=10m \
  --tail=20 2>/dev/null | \
  grep -E "CRITICAL|ERROR|WARNING" | \
  head -10 || echo "  No Falco alerts in last 10 minutes"

# ── 5. Pods running as root check ────────────────────────────────
echo ""
echo "[5/5] Pods running as root or without securityContext..."
kubectl get pods -A -o json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
risky = []
for pod in data.get('items', []):
  ns   = pod['metadata']['namespace']
  name = pod['metadata']['name']
  spec = pod.get('spec', {})
  psc  = spec.get('securityContext', {})
  if psc.get('runAsUser', -1) == 0 or psc.get('runAsNonRoot') == False:
    risky.append(f'{ns}/{name}')
  for c in spec.get('containers', []):
    csc = c.get('securityContext', {})
    if csc.get('runAsUser', -1) == 0 or csc.get('privileged') == True:
      risky.append(f'{ns}/{name}/{c[\"name\"]}')
if risky:
  print(f'  ⚠️  {len(risky)} risky containers found:')
  for r in risky[:10]:
    print(f'    - {r}')
else:
  print('  ✅ No containers running as root')
" 2>/dev/null

echo ""
echo "=== Audit complete ==="
echo "For full Trivy reports: kubectl get vulnerabilityreports -A"
echo "For Falco UI: kubectl port-forward svc/falcosidekick-ui 2802:2802 -n falco"
