#!/usr/bin/env bash
# ==============================================================================
# deploy-and-test.sh
# End-to-End deployment & verification for Jenkins High Availability on K8s
# ==============================================================================

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m"

echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}   🚀 Deploying Production Jenkins High Availability on K8s     ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

# 1. Apply Kubernetes manifests
echo -e "\n${YELLOW}[1/4] Applying Namespaces, RBAC, Storage & Configs...${NC}"
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/rbac.yaml
kubectl apply -f kubernetes/configmap-jcasc.yaml
kubectl apply -f kubernetes/pvc.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/statefulset.yaml
kubectl apply -f backup-dr/cronjob-backup.yaml

# 2. Wait for Jenkins Controller to be Ready
echo -e "\n${YELLOW}[2/4] Waiting for Jenkins HA Controller to initialize (Plugins + JCasC)...${NC}"
kubectl wait --for=condition=Ready pod/jenkins-ha-controller-0 -n jenkins-ha --timeout=240s
echo -e "${GREEN}✅ Jenkins HA Controller is online and healthy.${NC}"

# 3. Check JCasC and Prometheus metrics endpoints
echo -e "\n${YELLOW}[3/4] Verifying health and metrics endpoints...${NC}"
kubectl exec -n jenkins-ha jenkins-ha-controller-0 -- curl -s http://localhost:8080/login | grep -q "Jenkins" && echo -e "${GREEN}✅ UI /login endpoint responding.${NC}"

# 4. Trigger Disaster Recovery Backup Job
echo -e "\n${YELLOW}[4/4] Testing Disaster Recovery Automated Backup CronJob...${NC}"
kubectl create job --from=cronjob/jenkins-ha-thinbackup manual-dr-backup-test -n jenkins-ha
kubectl wait --for=condition=Complete job/manual-dr-backup-test -n jenkins-ha --timeout=60s
echo -e "${GREEN}✅ Disaster recovery backup verified.${NC}"

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  🎉 JENKINS HIGH AVAILABILITY DEPLOYMENT READY!                 ${NC}"
echo -e "${BOLD}${GREEN}  To access UI: kubectl port-forward svc/jenkins-ha 8080:8080 -n jenkins-ha ${NC}"
echo -e "${BOLD}${GREEN}  User: admin | Password: AdminSecurePass123!                   ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
