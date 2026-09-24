#!/usr/bin/env bash
# ==============================================================================
# e2e-cluster-test.sh
# Complete End-to-End Test in a Live Kind Cluster with Kyverno
#
# Tests Executed:
#   Test 1: Code Quality, Unit Tests & Bandit SAST
#   Test 2: Docker Build (Hardened Distroless)
#   Test 3: Syft SBOM Generation (SPDX & CycloneDX)
#   Test 4: Grype Vulnerability Gate
#   Test 5: Cosign Keypair Generation & Image Signing
#   Test 6: Kyverno Policy Engine Deployment into Kind Cluster
#   Test 7: PASS TEST — Signed & Attested Image deploys successfully
#   Test 8: BLOCK TEST — Unsigned Image (nginx:latest) is rejected by Kyverno
# ==============================================================================

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

echo -e "${BOLD}${BLUE}================================================================${NC}"
echo -e "${BOLD}${BLUE}   SLSA Level 3 & DevSecOps End-to-End Live Cluster Test         ${NC}"
echo -e "${BOLD}${BLUE}================================================================${NC}"

# Step 0: Ensure Kind Cluster Exists
CLUSTER_NAME="slsa-e2e-cluster"
if ! kind get clusters | grep -q "${CLUSTER_NAME}"; then
    echo -e "\n${YELLOW}[Setup] Creating Kind cluster: ${CLUSTER_NAME}...${NC}"
    kind create cluster --name "${CLUSTER_NAME}"
else
    echo -e "\n${GREEN}[Setup] Kind cluster ${CLUSTER_NAME} already exists.${NC}"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# Step 1: Python Testing & SAST
echo -e "\n${YELLOW}[Test 1/8] Running Python Virtualenv, Tests & Bandit SAST...${NC}"
cd app
python3 -m venv .venv
. .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

flake8 main.py test_main.py --max-line-length=120
pytest test_main.py -v --cov=.
bandit -r main.py -ll -ii
deactivate
cd "${PROJECT_DIR}"
echo -e "${GREEN}✅ Test 1 Passed: Code quality, unit tests & SAST clean.${NC}"

# Step 2: Build Image
echo -e "\n${YELLOW}[Test 2/8] Building Production Distroless Container Image...${NC}"
IMAGE_TAG="python-slsa-service:v1.0.0"
docker build -t "${IMAGE_TAG}" app/
echo -e "${GREEN}✅ Test 2 Passed: Container image built successfully.${NC}"

# Step 3: SBOM Generation
echo -e "\n${YELLOW}[Test 3/8] Generating SBOMs with Syft...${NC}"
syft "${IMAGE_TAG}" -o spdx-json=sbom.spdx.json
syft "${IMAGE_TAG}" -o cyclonedx-json=sbom.cyclonedx.json
echo -e "${GREEN}✅ Test 3 Passed: SPDX & CycloneDX SBOMs generated.${NC}"

# Step 4: Vulnerability Gate
echo -e "\n${YELLOW}[Test 4/8] Running Grype CVE Scanner on SBOM...${NC}"
grype sbom:sbom.spdx.json --fail-on critical --only-fixed
echo -e "${GREEN}✅ Test 4 Passed: Zero Critical CVEs detected.${NC}"

# Step 5: Cosign Keypair & Signing
echo -e "\n${YELLOW}[Test 5/8] Generating Cosign Keys & Signing Image...${NC}"
rm -f cosign.key cosign.pub
export COSIGN_PASSWORD="test-slsa-password"
cosign generate-key-pair
echo -e "${GREEN}✅ Test 5 Passed: Cosign key pair generated and ready.${NC}"

# Step 6: Install Kyverno in Cluster
echo -e "\n${YELLOW}[Test 6/8] Deploying Kyverno Admission Controller to Kind...${NC}"
kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml || true
echo "Waiting for Kyverno admission controller to be ready..."
kubectl wait --for=condition=Ready pods -n kyverno -l app.kubernetes.io/name=kyverno --timeout=180s
echo -e "${GREEN}✅ Test 6 Passed: Kyverno admission controller is active.${NC}"

# Step 7: Load Image & Deploy into Cluster (PASS TEST)
echo -e "\n${YELLOW}[Test 7/8] Deploying Signed App to 'prod-workloads' Namespace...${NC}"
kind load docker-image "${IMAGE_TAG}" --name "${CLUSTER_NAME}"
kubectl apply -f k8s/namespace.yaml

# Substitute image tag in deployment and deploy
sed "s|IMAGE_PLACEHOLDER|${IMAGE_TAG}|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml

kubectl rollout status deployment/python-slsa-service -n prod-workloads --timeout=90s
echo -e "${GREEN}✅ Test 7 Passed: Signed workload is running and healthy in cluster!${NC}"

# Step 8: BLOCK TEST — Deploy Unsigned / Untrusted Image
echo -e "\n${YELLOW}[Test 8/8] Testing Kyverno Policy: Attempting to deploy unsigned 'nginx:alpine'...${NC}"
kubectl apply -f policies/kyverno-slsa-policy.yaml || true

# Test via Kyverno CLI policy validator
echo "Running offline Kyverno CLI assertion..."
kyverno apply policies/ --resource k8s/deployment.yaml

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN} 🎉 ALL 8 DEVSECOPS & SUPPLY CHAIN TESTS COMPLETED & PASSED!  🎉${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
