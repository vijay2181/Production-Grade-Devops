#!/usr/bin/env bash
# =============================================================
# seal.sh — Encrypt a Kubernetes Secret into a SealedSecret
#
# Usage:
#   ./seal.sh <namespace> <secret-name> <key=value> [key=value...]
#
# Example:
#   ./seal.sh myapp db-credentials DB_USER=myuser DB_PASSWORD=s3cr3t
#
# The output is a SealedSecret YAML safe to commit to Git.
# Only the cluster's Sealed Secrets controller can decrypt it.
# =============================================================
set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <secret-name> <key=value>...}"
SECRET_NAME="${2:?Usage: $0 <namespace> <secret-name> <key=value>...}"
shift 2

# Check kubeseal is installed
command -v kubeseal &>/dev/null || {
  echo "kubeseal not installed. Install with: brew install kubeseal"
  exit 1
}

# Check kubectl context
echo "Current context: $(kubectl config current-context)"
echo "Namespace: ${NAMESPACE}"
echo "Secret name: ${SECRET_NAME}"
echo ""

# Build --from-literal args
LITERAL_ARGS=""
for KV in "$@"; do
  LITERAL_ARGS="${LITERAL_ARGS} --from-literal=${KV}"
done

# Step 1: Create a temporary plain Secret (not applied to cluster)
echo "[1/3] Creating temporary plain Secret..."
TMP_SECRET=$(kubectl create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  ${LITERAL_ARGS} \
  --dry-run=client \
  --output=yaml)

# Step 2: Encrypt with kubeseal using cluster's public key
echo "[2/3] Encrypting with kubeseal..."
SEALED_SECRET=$(echo "${TMP_SECRET}" | \
  kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --format=yaml)

# Step 3: Write to file
OUTPUT_FILE="sealed-secrets/${NAMESPACE}-${SECRET_NAME}.yaml"
echo "${SEALED_SECRET}" > "${OUTPUT_FILE}"

echo "[3/3] SealedSecret written to: ${OUTPUT_FILE}"
echo ""
echo "=== SAFE TO COMMIT TO GIT ==="
echo "kubectl apply -f ${OUTPUT_FILE}"
echo ""
echo "Contents:"
echo "${SEALED_SECRET}"
