#!/usr/bin/env bash
# =============================================================
# install-security-stack.sh — Install all security tools in order
#
# Order matters:
#   1. Pod Security labels (built-in, no install)
#   2. OPA Gatekeeper (admission webhook — must be first)
#   3. Kyverno (admission webhook — after Gatekeeper)
#   4. Sealed Secrets controller
#   5. Falco + Falcosidekick
#   6. Trivy Operator
#   7. Apply RBAC
#   8. Apply NetworkPolicies
#   9. Apply IRSA via Terraform
#
# Usage: ./scripts/install-security-stack.sh [cluster-context]
# =============================================================
set -euo pipefail

CONTEXT="${1:-myapp-prod}"
kubectl config use-context "${CONTEXT}"

echo "=== Installing security stack on ${CONTEXT} ==="

# ── Add Helm repos ────────────────────────────────────────────────
helm repo add gatekeeper   https://open-policy-agent.github.io/gatekeeper/charts
helm repo add kyverno      https://kyverno.github.io/kyverno
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo add trivy-operator https://aquasecurity.github.io/helm-charts
helm repo update

# ── Step 1: Pod Security Admission labels ────────────────────────
echo "[1/9] Applying Pod Security Admission namespace labels..."
kubectl apply -f pod-security/namespace-labels.yaml
echo "  ✅ Pod Security labels applied"

# ── Step 2: OPA Gatekeeper ────────────────────────────────────────
echo "[2/9] Installing OPA Gatekeeper..."
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --set replicas=2 \
  --set controllerManager.resources.limits.memory=512Mi \
  --set audit.resources.limits.memory=512Mi \
  --wait \
  --timeout 10m

# Wait for Gatekeeper webhooks to be ready
kubectl wait --for=condition=Ready pods \
  -l app=gatekeeper \
  -n gatekeeper-system \
  --timeout=120s

# Apply ConstraintTemplates FIRST (policy definitions)
echo "  Applying ConstraintTemplates..."
kubectl apply -f gatekeeper/templates/constraint-templates.yaml

# Wait for each Gatekeeper CRD to be fully established
# (sleep is unreliable — use kubectl wait for deterministic readiness)
echo "  Waiting for Gatekeeper constraint CRDs to be established..."
for CRD in \
  denylatestimages.constraints.gatekeeper.sh \
  denyprivilegedcontainers.constraints.gatekeeper.sh \
  requireresourcelimits.constraints.gatekeeper.sh \
  allowedimageregistries.constraints.gatekeeper.sh \
  denyrootuser.constraints.gatekeeper.sh; do
  kubectl wait crd/"${CRD}" \
    --for=condition=Established \
    --timeout=60s
  echo "    ✓ CRD ${CRD} established"
done

# Apply Constraints SECOND (policy instances)
echo "  Applying Constraints..."
kubectl apply -f gatekeeper/constraints/constraints.yaml
echo "  ✅ OPA Gatekeeper installed"

# ── Step 3: Kyverno ───────────────────────────────────────────────
echo "[3/9] Installing Kyverno..."
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set replicaCount=2 \
  --set resources.limits.memory=512Mi \
  --wait \
  --timeout 10m

kubectl apply -f kyverno/policies/policies.yaml
echo "  ✅ Kyverno installed"

# ── Step 4: Sealed Secrets ────────────────────────────────────────
echo "[4/9] Installing Sealed Secrets controller..."
helm upgrade --install sealed-secrets \
  sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --values sealed-secrets/install.yaml \
  --wait

# Install kubeseal CLI
brew install kubeseal 2>/dev/null || true
echo "  ✅ Sealed Secrets installed"

# Deploy the automated backup CronJob
echo "  Deploying Sealed Secrets backup CronJob..."
kubectl create configmap sealed-secrets-backup-script \
  --from-file=backup.sh=sealed-secrets/backup.sh \
  -n kube-system \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f sealed-secrets/backup-cronjob.yaml
echo "  ✅ Backup CronJob deployed (runs nightly at 02:00 UTC)"
echo ""
echo "  ⚠️  IMPORTANT: Run initial backup immediately:"
echo "    CLUSTER=${CONTEXT} ./sealed-secrets/backup.sh"
echo ""
echo "  To verify backup:"
echo "    aws secretsmanager get-secret-value \\"
echo "      --secret-id sealed-secrets/${CONTEXT}/controller-key \\"
echo "      --region us-east-1 --query SecretString --output text | jq .metadata"

# ── Step 5: Falco ─────────────────────────────────────────────────
echo "[5/9] Installing Falco (eBPF mode)..."
helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --values falco/install.yaml \
  --wait \
  --timeout 10m

# Apply custom rules ConfigMap
kubectl create configmap falco-custom-rules \
  --from-file=custom-rules.yaml=falco/rules/custom-rules.yaml \
  -n falco \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart daemonset/falco -n falco
echo "  ✅ Falco installed"

# ── Step 6: Trivy Operator ────────────────────────────────────────
echo "[6/9] Installing Trivy Operator..."
helm upgrade --install trivy-operator \
  trivy-operator/trivy-operator \
  --namespace trivy-system \
  --create-namespace \
  --set trivy.ignoreUnfixed=true \
  --set operator.scanJobTimeout=5m \
  --set operator.vulnerabilityScannerEnabled=true \
  --set operator.configAuditScannerEnabled=true \
  --set operator.secretScannerEnabled=true \
  --wait

echo "  ✅ Trivy Operator installed"
echo "  Scans run automatically — results in ~5 min"
echo "  kubectl get vulnerabilityreports -A"

# ── Step 7: RBAC ──────────────────────────────────────────────────
echo "[7/9] Applying RBAC..."
kubectl apply -f rbac/rbac.yaml
echo "  ✅ RBAC applied"

# ── Step 8: NetworkPolicies ───────────────────────────────────────
echo "[8/9] Applying NetworkPolicies (zero-trust)..."
kubectl apply -f network-policies/zero-trust.yaml
echo "  ✅ NetworkPolicies applied"
echo "  ⚠️  Test app connectivity after this step!"

# ── Step 9: IRSA (Terraform) ─────────────────────────────────────
echo "[9/9] IRSA setup requires Terraform — run separately:"
echo "  cd irsa && terraform init && terraform apply"
echo "  Then annotate ServiceAccount with the output role ARN"

echo ""
echo "=== Security stack installed ==="
echo ""
echo "Verify:"
echo "  kubectl get pods -n gatekeeper-system"
echo "  kubectl get pods -n kyverno"
echo "  kubectl get pods -n falco"
echo "  kubectl get pods -n trivy-system"
echo ""
echo "Run security audit:"
echo "  ./scripts/audit.sh"
