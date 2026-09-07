#!/usr/bin/env bash
# =============================================================
# inject-secrets.sh — Push secrets to AWS Secrets Manager
# and create ExternalSecret CRDs that sync to k8s Secrets.
#
# Usage: ./scripts/inject-secrets.sh
# Prerequisites: AWS CLI configured, kubectl context set.
# =============================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="myapp"

echo "=== Injecting secrets for namespace: $NAMESPACE ==="

# ── 1. Prompt for secret values ──────────────────────────────────
read -rsp "Enter DB_USER: "    DB_USER;    echo
read -rsp "Enter DB_PASSWORD: " DB_PASSWORD; echo

# ── 2. Put secrets into AWS Secrets Manager ───────────────────────
echo "[1/3] Storing in AWS Secrets Manager..."
aws secretsmanager create-secret \
  --name "myapp/prod/db-credentials" \
  --description "MyApp production DB credentials" \
  --secret-string "{\"DB_USER\":\"$DB_USER\",\"DB_PASSWORD\":\"$DB_PASSWORD\"}" \
  --region "$AWS_REGION" 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id "myapp/prod/db-credentials" \
  --secret-string "{\"DB_USER\":\"$DB_USER\",\"DB_PASSWORD\":\"$DB_PASSWORD\"}" \
  --region "$AWS_REGION"

echo "[2/3] Secrets stored in Secrets Manager."

# ── 3. Create ExternalSecret CRD ─────────────────────────────────
echo "[3/3] Creating ExternalSecret in namespace $NAMESPACE..."
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: ${NAMESPACE}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
  data:
    - secretKey: DB_USER
      remoteRef:
        key: myapp/prod/db-credentials
        property: DB_USER
    - secretKey: DB_PASSWORD
      remoteRef:
        key: myapp/prod/db-credentials
        property: DB_PASSWORD
EOF

echo ""
echo "=== Secrets injected successfully ==="
echo "Verify: kubectl get secret db-credentials -n $NAMESPACE"
