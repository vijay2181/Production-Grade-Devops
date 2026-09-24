# 🧪 Complete End-to-End Testing & Verification Guide

This guide details how to run the full DevSecOps & SLSA Level 3 test suite on your server.

---

## 📁 Test Scripts Created

| Script | Purpose |
| :--- | :--- |
| [`scripts/server-setup.sh`](scripts/server-setup.sh:1) | **One-shot installer** for Ubuntu/Debian: Installs Docker, Syft, Grype, Cosign, Kyverno CLI, Kind, Kubectl, Python3 venv. |
| [`scripts/e2e-cluster-test.sh`](scripts/e2e-cluster-test.sh:1) | **Complete automated 8-stage test runner** that executes code analysis, container build, SBOM, CVE scanning, signing, and live Kubernetes admission testing. |
| [`scripts/test-pipeline.sh`](scripts/test-pipeline.sh:1) | **Offline/local dry-run** verification script. |
| [`Jenkinsfile`](../Jenkinsfile:1) | **Production CI/CD Pipeline** for Jenkins. |

---

## 🚀 Execution Steps on Your Test Server

### Step 1: Install Tools (One-time)
```bash
cd cka/practical/supply-chain-security-slsa
chmod +x scripts/*.sh

# Run the automated installer
./scripts/server-setup.sh
```

### Step 2: Run Full Automated E2E Cluster Test
```bash
./scripts/e2e-cluster-test.sh
```

---

## 🔍 What the Test Runner (`e2e-cluster-test.sh`) Validates:

```
[Test 1/8] 🧪 Python Quality: Flake8 linting, Pytest unit tests, Bandit SAST security analysis
[Test 2/8] 📦 Container: Builds multi-stage distroless Python 3.11 container (non-root UID 65532)
[Test 3/8] 📋 SBOM Generation: Exports SPDX and CycloneDX SBOMs via Anchore Syft
[Test 4/8] 🛡️ CVE Gate: Scans SBOM with Anchore Grype (blocks on critical vulnerabilities)
[Test 5/8] 🔏 Cryptographic Signing: Generates Sigstore Cosign keypair and signs image
[Test 6/8] ☸️ Admission Controller: Spawns Kind cluster and installs Kyverno
[Test 7/8] ✅ PASS TEST: Deploys signed Python service to 'prod-workloads' namespace
[Test 8/8] ⛔ BLOCK TEST: Tests Kyverno policy gating against unsigned workloads
```

---

## 📊 Manual Verification Commands

Once the tests pass, you can query your cluster directly:

```bash
# 1. Verify Pods running with restricted security context
kubectl get pods -n prod-workloads -o wide

# 2. Check Service endpoint response
kubectl run test-curl --rm -it --image=curlimages/curl -n prod-workloads -- curl http://python-slsa-service/

# 3. View the generated SBOMs
cat sbom.spdx.json | jq .name
cat sbom.cyclonedx.json | jq .metadata
```
