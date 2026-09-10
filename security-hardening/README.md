# Kubernetes Security Hardening — End-to-End Execution Guide

> **Project 4** | Builds on Projects 1, 2, 3
> Stack: Falco · OPA Gatekeeper · Kyverno · Trivy Operator · Sealed Secrets · Pod Security · RBAC · IRSA

---

## Prerequisites

```bash
brew install kubeseal kube-bench kubectl helm
kubectl config use-context myapp-prod
```

---

## Step 1 — Apply Pod Security Admission Labels

```bash
# Apply namespace security profiles FIRST
# (built-in Kubernetes — no install needed)
kubectl apply -f pod-security/namespace-labels.yaml

# Verify labels applied
kubectl get namespace myapp-prod -o jsonpath='{.metadata.labels}' | python3 -m json.tool
# Expected: pod-security.kubernetes.io/enforce: restricted

# Test: try to deploy a root container — should be BLOCKED
kubectl run test-root --image=nginx --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' \
  -n myapp-prod
# Expected: Error from server (Forbidden): pods "test-root" is forbidden:
#           violates PodSecurity "restricted:latest"
```

---

## Step 2 — Install OPA Gatekeeper

```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update

helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --set replicas=2 \
  --wait

# Apply ConstraintTemplates (policy definitions)
kubectl apply -f gatekeeper/templates/constraint-templates.yaml

# Wait for CRDs
sleep 15

# Apply Constraints (policy instances)
kubectl apply -f gatekeeper/constraints/constraints.yaml

# Test 1: Deploy image with :latest tag — should FAIL
kubectl run test-latest --image=nginx:latest -n myapp --restart=Never
# Expected: Error: Container 'test-latest' uses :latest tag

# Test 2: Deploy without resource limits — should FAIL
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-no-limits
  namespace: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
        - name: test
          image: nginx:1.25
          # No resources set → should be blocked
EOF
# Expected: Error: Container 'test' must have CPU limits set

# View all violations
kubectl get constraints -A
kubectl describe constraint deny-latest-images
```

---

## Step 3 — Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set replicaCount=2 \
  --wait

kubectl apply -f kyverno/policies/policies.yaml

# Test mutation: deploy without securityContext — Kyverno should AUTO-ADD it
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-kyverno-mutate
  namespace: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-kyverno
  template:
    metadata:
      labels:
        app: test-kyverno
    spec:
      containers:
        - name: api
          image: 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.0.0
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          livenessProbe:
            httpGet: { path: /health, port: 3000 }
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet: { path: /ready, port: 3000 }
            initialDelaySeconds: 5
            periodSeconds: 10
EOF

# Verify Kyverno auto-added securityContext
kubectl get pod -l app=test-kyverno -n myapp -o jsonpath=\
  '{.items[0].spec.containers[0].securityContext}' | python3 -m json.tool
# Expected:
# {
#   "allowPrivilegeEscalation": false,
#   "readOnlyRootFilesystem": true,
#   "capabilities": {"drop": ["ALL"]}
# }

# Clean up test
kubectl delete deployment test-kyverno-mutate -n myapp
```

---

## Step 4 — Install Sealed Secrets

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm upgrade --install sealed-secrets \
  sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --values sealed-secrets/install.yaml \
  --wait

# !! CRITICAL: Backup the controller key !!
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > BACKUP-sealed-secrets-master-key.yaml
# Store this outside Git (AWS S3, 1Password, etc.)

# Create a real sealed secret for db-credentials
chmod +x sealed-secrets/seal.sh
./sealed-secrets/seal.sh myapp db-credentials \
  DB_USER=myuser \
  DB_PASSWORD=mysecretpassword

# Apply the sealed secret
kubectl apply -f sealed-secrets/myapp-db-credentials.yaml

# Verify it was decrypted into a plain Secret
kubectl get secret db-credentials -n myapp
kubectl get secret db-credentials -n myapp \
  -o jsonpath='{.data.DB_USER}' | base64 -d
# Expected: myuser
```

---

## Step 5 — Install Falco

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --values falco/install.yaml \
  --wait \
  --timeout 10m

# Apply custom rules
kubectl create configmap falco-custom-rules \
  --from-file=custom-rules.yaml=falco/rules/custom-rules.yaml \
  -n falco --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart daemonset/falco -n falco
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=falco \
  -n falco --timeout=120s

# TEST: Trigger a Falco alert (shell in container)
API_POD=$(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec ${API_POD} -n myapp -- sh -c "echo test"
# Expected: Falco alert fires within 2 seconds
# Check: kubectl logs -l app.kubernetes.io/name=falco -n falco --tail=5
# Expected: CRITICAL Shell spawned in myapp container

# View Falcosidekick UI
kubectl port-forward svc/falco-falcosidekick-ui 2802:2802 -n falco
# Open: http://localhost:2802
```

---

## Step 6 — Install Trivy Operator

```bash
helm repo add trivy-operator https://aquasecurity.github.io/helm-charts
helm upgrade --install trivy-operator \
  trivy-operator/trivy-operator \
  --namespace trivy-system \
  --create-namespace \
  --set trivy.ignoreUnfixed=true \
  --set operator.vulnerabilityScannerEnabled=true \
  --set operator.configAuditScannerEnabled=true \
  --set operator.secretScannerEnabled=true \
  --wait

# Wait for scans to complete (~5 min)
echo "Waiting for Trivy to scan running images..."
sleep 300

# View vulnerability reports
kubectl get vulnerabilityreports -n myapp
kubectl describe vulnerabilityreport \
  $(kubectl get vulnerabilityreport -n myapp -o name | head -1) -n myapp

# View config audit reports (misconfig detection)
kubectl get configauditreports -n myapp

# Check for exposed secrets in running images
kubectl get exposedsecretreports -A
```

---

## Step 7 — Apply RBAC + NetworkPolicies

```bash
# RBAC
kubectl apply -f rbac/rbac.yaml

# Verify developer can't delete prod namespace
kubectl auth can-i delete namespace --as=system:serviceaccount:myapp:myapp-api
# Expected: no

# NetworkPolicies (zero-trust)
kubectl apply -f network-policies/zero-trust.yaml

# Test connectivity is still working after NetworkPolicy
API_POD=$(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}')

# API → RDS: should work
kubectl exec ${API_POD} -n myapp -- nc -zv ${DB_HOST} 5432
# Expected: Connection succeeded

# API → Kubernetes API: should be BLOCKED
kubectl exec ${API_POD} -n myapp -- \
  wget -qO- --timeout=3 https://kubernetes.default.svc 2>&1
# Expected: Connection refused or timed out
```

---

## Step 8 — IRSA Setup

```bash
cd irsa
terraform init
terraform apply -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)"

# Get the role ARN
ROLE_ARN=$(terraform output -raw irsa_role_arn)

# Annotate the ServiceAccount
kubectl annotate serviceaccount myapp-api \
  -n myapp \
  eks.amazonaws.com/role-arn="${ROLE_ARN}" \
  --overwrite

# Restart pods to pick up the new ServiceAccount
kubectl rollout restart deployment/api -n myapp

# Verify: pod has AWS_WEB_IDENTITY_TOKEN_FILE env var
kubectl exec -it $(kubectl get pod -l app=api -n myapp \
  -o jsonpath='{.items[0].metadata.name}') -n myapp -- env | grep AWS
# Expected:
#   AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
#   AWS_ROLE_ARN=arn:aws:iam::123456789:role/myapp-api-irsa-role
# NOT expected: AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY
```

---

## Step 9 — Run Full Security Audit

```bash
chmod +x scripts/audit.sh
./scripts/audit.sh

# Expected output:
#   CIS Benchmark: PASS: 85+, FAIL: 15-, WARN: 10-
#   OPA violations: 0 (if all apps comply)
#   Trivy: 0 CRITICAL CVEs (if images are up to date)
#   Falco alerts: none in last 10 min
#   Root containers: 0
```

---

## Day-2 Operations

```bash
# Rotate a sealed secret (e.g. password changed)
./sealed-secrets/seal.sh myapp db-credentials DB_USER=myuser DB_PASSWORD=newpassword
kubectl apply -f sealed-secrets/myapp-db-credentials.yaml
kubectl rollout restart deployment/api -n myapp

# Check what Gatekeeper would block (dry-run)
kubectl apply --dry-run=server -f your-deployment.yaml

# See all Kyverno policy reports
kubectl get policyreport -A
kubectl describe policyreport -n myapp

# View recent Falco alerts in Grafana
# Loki query: {source="falco"} | json | priority=~"CRITICAL|ERROR"

# Scan a specific image with Trivy (ad-hoc)
trivy image 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/api:v1.0.0

# Update Falco rules
vim falco/rules/custom-rules.yaml
kubectl create configmap falco-custom-rules \
  --from-file=custom-rules.yaml=falco/rules/custom-rules.yaml \
  -n falco --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart daemonset/falco -n falco
```
