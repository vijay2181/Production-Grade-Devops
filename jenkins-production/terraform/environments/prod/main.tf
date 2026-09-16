# =============================================================
# terraform/environments/prod/main.tf
# Jenkins production infrastructure:
#   - EFS (Jenkins home — multi-AZ, survives pod restarts)
#   - IAM roles (IRSA for controller + agents)
#   - S3 (artifact storage + backup)
#   - Security Groups
# =============================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
  backend "s3" {
    bucket         = "myapp-terraform-state"
    key            = "jenkins/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "jenkins-production"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────
data "aws_eks_cluster" "main" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "main" {
  tags = { Name = "${var.cluster_name}-vpc" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}

# ── EFS — Jenkins home directory ──────────────────────────────
# Why EFS over EBS:
#   EBS is AZ-bound — if Jenkins Pod moves to another AZ, EBS can't follow.
#   EFS is multi-AZ — available in all AZs, Pod restarts anywhere and reattaches.
resource "aws_efs_file_system" "jenkins_home" {
  creation_token   = "jenkins-home-prod"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = { Name = "jenkins-home-prod" }
}

# EFS mount targets — one per private subnet (multi-AZ)
resource "aws_efs_mount_target" "jenkins_home" {
  for_each = toset(data.aws_subnets.private.ids)

  file_system_id  = aws_efs_file_system.jenkins_home.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs_jenkins.id]
}

# EFS access point — locks Jenkins to its own directory with fixed UID/GID
resource "aws_efs_access_point" "jenkins_home" {
  file_system_id = aws_efs_file_system.jenkins_home.id

  posix_user {
    uid = 1000  # jenkins user UID inside the container
    gid = 1000
  }

  root_directory {
    path = "/jenkins"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }

  tags = { Name = "jenkins-home-access-point" }
}

# Security Group — EFS only accepts traffic from EKS nodes
resource "aws_security_group" "efs_jenkins" {
  name        = "jenkins-efs-sg"
  description = "Allow NFS from EKS nodes to Jenkins EFS"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "NFS from EKS nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [data.aws_eks_cluster.main.resources[0].security_group_ids[0]]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "jenkins-efs-sg" }
}

# ── S3 — Artifacts + Backup ───────────────────────────────────
resource "aws_s3_bucket" "jenkins_artifacts" {
  bucket        = "myapp-jenkins-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = { Name = "jenkins-artifacts" }
}

resource "aws_s3_bucket_versioning" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter { prefix = "artifacts/" }
    expiration { days = 90 }
  }

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter { prefix = "backups/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

resource "aws_s3_bucket_public_access_block" "jenkins_artifacts" {
  bucket                  = aws_s3_bucket.jenkins_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── IRSA — Jenkins Controller ─────────────────────────────────
# Controller needs minimal AWS access:
# - Secrets Manager read (to bootstrap credentials)
# - S3 read/write (backup + artifact upload)
data "aws_iam_policy_document" "jenkins_controller_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:jenkins:jenkins-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_controller" {
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/*"
    ]
  }

  statement {
    sid    = "S3BackupAndArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.jenkins_artifacts.arn,
      "${aws_s3_bucket.jenkins_artifacts.arn}/*"
    ]
  }
}

resource "aws_iam_role" "jenkins_controller" {
  name               = "jenkins-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.jenkins_controller_trust.json
}

resource "aws_iam_role_policy" "jenkins_controller" {
  name   = "jenkins-controller-policy"
  role   = aws_iam_role.jenkins_controller.id
  policy = data.aws_iam_policy_document.jenkins_controller.json
}

# ── IRSA — Jenkins Agents ─────────────────────────────────────
# Agents need more AWS access (they do the actual CI work):
# - ECR push/pull (build and push images)
# - S3 read/write (artifact upload)
# - EKS describe (deploy validation)
# - Secrets Manager read (runtime secrets)
# DENY cross-account actions (defense in depth)
data "aws_iam_policy_document" "jenkins_agent_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:jenkins:jenkins-agent"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "jenkins_agent" {
  # ECR — push and pull images
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"]  # GetAuthorizationToken doesn't support resource scoping
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:ListImages"
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/myapp*"
    ]
  }

  # S3 artifact upload
  statement {
    sid    = "S3Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.jenkins_artifacts.arn,
      "${aws_s3_bucket.jenkins_artifacts.arn}/artifacts/*"
    ]
  }

  # Secrets Manager — runtime secrets only (scoped to jenkins/ prefix)
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/*"
    ]
  }

  # EKS describe (for deployment validation steps)
  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters"
    ]
    resources = ["*"]
  }

  # DENY: prevent agents from accessing other AWS accounts
  statement {
    sid    = "DenyOtherAccounts"
    effect = "Deny"
    actions = ["sts:AssumeRole"]
    not_resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"
    ]
  }
}

resource "aws_iam_role" "jenkins_agent" {
  name               = "jenkins-agent-irsa"
  assume_role_policy = data.aws_iam_policy_document.jenkins_agent_trust.json
}

resource "aws_iam_role_policy" "jenkins_agent" {
  name   = "jenkins-agent-policy"
  role   = aws_iam_role.jenkins_agent.id
  policy = data.aws_iam_policy_document.jenkins_agent.json
}

# ── Outputs ───────────────────────────────────────────────────
output "efs_file_system_id" {
  description = "EFS filesystem ID — put in helm values"
  value       = aws_efs_file_system.jenkins_home.id
}

output "efs_access_point_id" {
  description = "EFS access point ID — put in helm values"
  value       = aws_efs_access_point.jenkins_home.id
}

output "jenkins_controller_role_arn" {
  description = "IRSA role for Jenkins controller ServiceAccount"
  value       = aws_iam_role.jenkins_controller.arn
}

output "jenkins_agent_role_arn" {
  description = "IRSA role for Jenkins agent ServiceAccount"
  value       = aws_iam_role.jenkins_agent.arn
}

output "artifacts_bucket_name" {
  description = "S3 bucket for build artifacts and backups"
  value       = aws_s3_bucket.jenkins_artifacts.bucket
}
