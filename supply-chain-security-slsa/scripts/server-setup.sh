#!/usr/bin/env bash
# ==============================================================================
# server-setup.sh
# One-shot installation script for Linux test server (Ubuntu/Debian)
# Installs: Docker, Syft, Grype, Cosign, Kyverno CLI, Kind, Kubectl, Python3
# ==============================================================================

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m"

echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  Installing DevSecOps & Supply Chain Security Tooling           ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"

# 1. Base tools & Python
echo -e "\n${YELLOW}[1/7] Installing base dependencies & Python tools...${NC}"
sudo apt-get update && sudo apt-get install -y curl jq python3 python3-pip python3-venv git

# 2. Docker
echo -e "\n${YELLOW}[2/7] Installing Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
fi
echo -e "${GREEN}Docker: $(docker --version)${NC}"

# 3. Anchore Syft (SBOM)
echo -e "\n${YELLOW}[3/7] Installing Syft (SBOM Generation)...${NC}"
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin
echo -e "${GREEN}Syft: $(syft --version)${NC}"

# 4. Anchore Grype (Vulnerability Scanner)
echo -e "\n${YELLOW}[4/7] Installing Grype (Vulnerability Scanner)...${NC}"
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sudo sh -s -- -b /usr/local/bin
echo -e "${GREEN}Grype: $(grype version)${NC}"

# 5. Sigstore Cosign
echo -e "\n${YELLOW}[5/7] Installing Sigstore Cosign (Signing & Attestations)...${NC}"
COSIGN_VERSION="v2.2.4"
curl -LO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
sudo install cosign-linux-amd64 /usr/local/bin/cosign && rm cosign-linux-amd64
echo -e "${GREEN}Cosign: $(cosign version --json | jq -r .GitVersion)${NC}"

# 6. Kyverno CLI
echo -e "\n${YELLOW}[6/7] Installing Kyverno CLI...${NC}"
KYVERNO_VERSION="v1.12.0"
curl -LO "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/kyverno-cli_${KYVERNO_VERSION}_linux_x86_64.tar.gz"
tar -xzf "kyverno-cli_${KYVERNO_VERSION}_linux_x86_64.tar.gz" kyverno
sudo install kyverno /usr/local/bin/ && rm kyverno "kyverno-cli_${KYVERNO_VERSION}_linux_x86_64.tar.gz"
echo -e "${GREEN}Kyverno CLI: $(kyverno version)${NC}"

# 7. Kind & Kubectl
echo -e "\n${YELLOW}[7/7] Installing Kind & Kubectl...${NC}"
if ! command -v kind &> /dev/null; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64 && chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
fi
if ! command -v kubectl &> /dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install kubectl /usr/local/bin/ && rm kubectl
fi
echo -e "${GREEN}Kind: $(kind --version)${NC}"
echo -e "${GREEN}Kubectl: $(kubectl version --client -o yaml | grep gitVersion)${NC}"

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  All tools installed successfully!                             ${NC}"
echo -e "${BOLD}${GREEN}  You can now run: ./scripts/e2e-cluster-test.sh                ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
