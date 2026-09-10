# ── IRSA: IAM Role for Service Account ────────────────────────────
# Creates an IAM role that the myapp-api ServiceAccount assumes.
# The pod gets temporary AWS credentials via projected token — no static keys.
# Token rotates automatically every 1 hour.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "cluster_name"   { default = "myapp-prod" }
variable "aws_region"     { default = "us-east-1" }
variable "aws_account_id" {}
variable "namespace"      { default = "myapp" }
variable "service_account_name" { default = "myapp-api" }

# ── Get OIDC provider from EKS cluster ────────────────────────────
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "cluster" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# ── Trust policy: only THIS service account can assume this role ──
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      # Only the specific service account in the specific namespace
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ── IAM Role ──────────────────────────────────────────────────────
resource "aws_iam_role" "myapp_api" {
  name               = "myapp-api-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Project     = "myapp"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# ── Permissions policy: MINIMUM required for the app ──────────────
# Only what the app actually needs — nothing more
data "aws_iam_policy_document" "myapp_permissions" {
  # Allow reading from Secrets Manager (for DB credentials via ESO)
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:myapp/prod/*"
    ]
  }

  # Allow Tempo + Loki S3 access (for Project 3 observability)
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::myapp-tempo-traces/*",
      "arn:aws:s3:::myapp-loki-logs/*"
    ]
  }

  # Allow S3 list (needed for bucket operations)
  statement {
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::myapp-tempo-traces",
      "arn:aws:s3:::myapp-loki-logs"
    ]
  }

  # DENY: Prevent accessing other namespaces' secrets
  statement {
    effect  = "Deny"
    actions = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    condition {
      test     = "StringNotLike"
      variable = "aws:ResourceTag/Project"
      values   = ["myapp"]
    }
  }
}

resource "aws_iam_policy" "myapp_api" {
  name   = "myapp-api-irsa-policy"
  policy = data.aws_iam_policy_document.myapp_permissions.json
}

resource "aws_iam_role_policy_attachment" "myapp_api" {
  role       = aws_iam_role.myapp_api.name
  policy_arn = aws_iam_policy.myapp_api.arn
}

# ── Output: ARN to use in ServiceAccount annotation ───────────────
output "irsa_role_arn" {
  value       = aws_iam_role.myapp_api.arn
  description = "Use this ARN in the ServiceAccount eks.amazonaws.com/role-arn annotation"
}
