#!/usr/bin/env bash
# ==============================================================================
# restore-script.sh
# 1-Click Disaster Recovery Restore for Jenkins HA
# ==============================================================================

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"

echo -e "${BOLD}${YELLOW}================================================================${NC}"
echo -e "${BOLD}${YELLOW}   🔄 Jenkins HA Disaster Recovery Restoration Script           ${NC}"
echo -e "${BOLD}${YELLOW}================================================================${NC}"

BACKUP_ARCHIVE="${1:-}"

if [ -z "${BACKUP_ARCHIVE}" ]; then
    echo -e "${RED}Error: Please specify the backup archive path.${NC}"
    echo "Usage: ./restore-script.sh <path-to-jenkins_core_config.tar.gz>"
    exit 1
fi

if [ ! -f "${BACKUP_ARCHIVE}" ]; then
    echo -e "${RED}Error: Backup file '${BACKUP_ARCHIVE}' not found!${NC}"
    exit 1
fi

echo -e "\n${YELLOW}[1/3] Scaling down Jenkins HA Controller...${NC}"
kubectl scale statefulset jenkins-ha-controller --replicas=0 -n jenkins-ha
kubectl wait --for=delete pod/jenkins-ha-controller-0 -n jenkins-ha --timeout=60s || true

echo -e "\n${YELLOW}[2/3] Restoring configurations to Persistent Volume...${NC}"
# Spin up temporary restore pod to extract files safely into PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jenkins-ha-restore-worker
  namespace: jenkins-ha
spec:
  restartPolicy: Never
  containers:
    - name: restore-worker
      image: alpine:3.19
      command: ["sleep", "3600"]
      volumeMounts:
        - name: jenkins-home
          mountPath: /var/jenkins_home
  volumes:
    - name: jenkins-home
      persistentVolumeClaim:
        claimName: jenkins-ha-home-pvc
EOF

echo "Waiting for restore worker pod..."
kubectl wait --for=condition=Ready pod/jenkins-ha-restore-worker -n jenkins-ha --timeout=60s

echo "Copying backup archive to volume..."
kubectl cp "${BACKUP_ARCHIVE}" jenkins-ha/jenkins-ha-restore-worker:/var/jenkins_home/restore_temp.tar.gz

echo "Extracting backup..."
kubectl exec -it jenkins-ha-restore-worker -n jenkins-ha -- /bin/sh -c \
  "tar -xzf /var/jenkins_home/restore_temp.tar.gz -C /var/jenkins_home && rm -f /var/jenkins_home/restore_temp.tar.gz && chown -R 1000:1000 /var/jenkins_home"

kubectl delete pod jenkins-ha-restore-worker -n jenkins-ha --grace-period=0 --force

echo -e "\n${YELLOW}[3/3] Scaling Jenkins HA Controller back up...${NC}"
kubectl scale statefulset jenkins-ha-controller --replicas=1 -n jenkins-ha
kubectl wait --for=condition=Ready pod/jenkins-ha-controller-0 -n jenkins-ha --timeout=180s

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  ✅ Disaster Recovery Restore Completed Successfully!          ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
