#!/usr/bin/env bash
# =============================================================
# bootstrap.sh — One-time EKS cluster setup after terraform apply
# Run ONCE per cluster lifecycle.
# Usage: ./scripts/bootstrap.sh <cluster-name> <aws-region>
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-myapp-prod}"
AWS_REGION="${2:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Bootstrapping cluster: $CLUSTER_NAME in $AWS_REGION ==="

# ── 1. Update kubeconfig ──────────────────────────────────────────
echo "[1/9] Updating kubeconfig..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"

# ── 2. Verify cluster ─────────────────────────────────────────────
echo "[2/9] Verifying cluster access..."
kubectl cluster-info
kubectl get nodes -o wide

# ── 3. Install AWS Load Balancer Controller ───────────────────────
echo "[3/9] Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Download and apply IAM policy
curl -o /tmp/iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/iam_policy.json 2>/dev/null || echo "Policy already exists."

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait

# ── 4. Install Cluster Autoscaler ─────────────────────────────────
echo "[4/9] Installing Cluster Autoscaler..."
helm upgrade --install cluster-autoscaler \
  autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$AWS_REGION" \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set rbac.serviceAccount.create=false \
  --wait

# ── 5. Install Metrics Server (required for HPA) ─────────────────
echo "[5/9] Installing Metrics Server..."
helm upgrade --install metrics-server \
  metrics-server/metrics-server \
  --namespace kube-system \
  --set args="{--kubelet-insecure-tls}" \
  --wait

# ── 6. Install External Secrets Operator ─────────────────────────
echo "[6/9] Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --wait

# Create ClusterSecretStore pointing to AWS Secrets Manager
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF

# ── 7. Install EBS CSI StorageClass ──────────────────────────────
echo "[7/9] Creating gp3 StorageClass..."
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
EOF

# ── 8. Create application namespace + RBAC ────────────────────────
echo "[8/9] Creating namespaces..."
kubectl apply -f kubernetes/base/namespace.yaml

# ── 9. Install monitoring stack ───────────────────────────────────
echo "[9/9] Installing monitoring stack..."
bash monitoring/install.sh

echo ""
echo "=== Bootstrap complete! ==="
echo "Next: run ./scripts/inject-secrets.sh then deploy with Helm."
