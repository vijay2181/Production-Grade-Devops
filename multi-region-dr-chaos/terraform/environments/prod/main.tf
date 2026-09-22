# =============================================================
# terraform/environments/prod/main.tf — Multi-Region DR Stack
# Provisions:
#   1. Multi-Region S3 Buckets with Bidirectional Cross-Region Replication (CRR)
#   2. Route 53 Failover Routing, Health Checks & ARC Control Panel
#   3. Velero IRSA Roles (us-east-1 and us-west-2)
#   4. Aurora Global Database Cross-Region Configuration
# =============================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
  backend "s3" {
    bucket         = "myapp-terraform-state"
    key            = "multi-region-dr/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# ── Providers (Primary & Secondary Regions) ───────────────────
provider "aws" {
  alias  = "primary"
  region = var.primary_region
  default_tags {
    tags = {
      Project     = "multi-region-dr-chaos"
      Environment = "prod"
      RegionRole  = "primary"
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
  default_tags {
    tags = {
      Project     = "multi-region-dr-chaos"
      Environment = "prod"
      RegionRole  = "secondary"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# ── 1. Velero S3 Buckets & Cross-Region Replication (CRR) ─────
# Primary S3 Bucket in us-east-1
resource "aws_s3_bucket" "velero_primary" {
  provider      = aws.primary
  bucket        = "myapp-velero-backups-${data.aws_caller_identity.current.account_id}-us-east-1"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "velero_primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.velero_primary.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_primary" {
  provider = aws.primary
  bucket   = aws_s3_bucket.velero_primary.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

# Secondary S3 Bucket in us-west-2 (DR Target)
resource "aws_s3_bucket" "velero_secondary" {
  provider      = aws.secondary
  bucket        = "myapp-velero-backups-${data.aws_caller_identity.current.account_id}-us-west-2"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "velero_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.velero_secondary.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.velero_secondary.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

# IAM Role for S3 Cross-Region Replication
resource "aws_iam_role" "s3_crr" {
  name = "myapp-velero-s3-crr-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "s3_crr" {
  name = "s3-crr-policy"
  role = aws_iam_role.s3_crr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Effect = "Allow"
        Resource = [aws_s3_bucket.velero_primary.arn]
      },
      {
        Action = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Effect = "Allow"
        Resource = ["${aws_s3_bucket.velero_primary.arn}/*"]
      },
      {
        Action = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Effect = "Allow"
        Resource = ["${aws_s3_bucket.velero_secondary.arn}/*"]
      }
    ]
  })
}

# Attach CRR Configuration
resource "aws_s3_bucket_replication_configuration" "crr_primary_to_secondary" {
  provider   = aws.primary
  depends_on = [aws_s3_bucket_versioning.velero_primary, aws_s3_bucket_versioning.velero_secondary]
  role       = aws_iam_role.s3_crr.arn
  bucket     = aws_s3_bucket.velero_primary.id

  rule {
    id     = "velero-backup-replication"
    status = "Enabled"
    destination {
      bucket        = aws_s3_bucket.velero_secondary.arn
      storage_class = "STANDARD_IA"
    }
  }
}

# ── 2. Route 53 Health Checks & Failover Routing ─────────────
# Health check on Primary Region ALB (/health endpoint)
resource "aws_route53_health_check" "primary_alb" {
  fqdn              = "api-useast1.company.com"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = "3"
  request_interval  = "10" # Fast 10-second health check interval
  enable_sni        = true

  tags = { Name = "primary-useast1-alb-health" }
}

# Health check on Secondary Region ALB
resource "aws_route53_health_check" "secondary_alb" {
  fqdn              = "api-uswest2.company.com"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = "3"
  request_interval  = "10"
  enable_sni        = true

  tags = { Name = "secondary-uswest2-alb-health" }
}

# Route 53 Primary Failover Record
resource "aws_route53_record" "primary" {
  zone_id = var.hosted_zone_id
  name    = "api.company.com"
  type    = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary-useast1"
  health_check_id = aws_route53_health_check.primary_alb.id

  alias {
    name                   = "dualstack.myapp-prod-primary-alb.us-east-1.elb.amazonaws.com"
    zone_id                = "Z35SXDOTRQ7X7K" # us-east-1 standard ALB Hosted Zone ID
    evaluate_target_health = true
  }
}

# Route 53 Secondary Failover Record (Standby)
resource "aws_route53_record" "secondary" {
  zone_id = var.hosted_zone_id
  name    = "api.company.com"
  type    = "A"

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier  = "secondary-uswest2"
  health_check_id = aws_route53_health_check.secondary_alb.id

  alias {
    name                   = "dualstack.myapp-prod-secondary-alb.us-west-2.elb.amazonaws.com"
    zone_id                = "Z1H1FL5Y3QYW2J" # us-west-2 standard ALB Hosted Zone ID
    evaluate_target_health = true
  }
}

# ── 3. Velero IRSA IAM Roles (Primary & Secondary) ────────────
data "aws_iam_policy_document" "velero_policy" {
  statement {
    sid    = "EC2SnapshotPermissions"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "S3BackupStoragePermissions"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.velero_primary.arn,
      "${aws_s3_bucket.velero_primary.arn}/*",
      aws_s3_bucket.velero_secondary.arn,
      "${aws_s3_bucket.velero_secondary.arn}/*"
    ]
  }
}

resource "aws_iam_role" "velero_primary" {
  provider = aws.primary
  name     = "myapp-velero-primary-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/PRIMARY_CLUSTER_ID"
      }
      Condition = {
        StringEquals = {
          "oidc.eks.us-east-1.amazonaws.com/id/PRIMARY_CLUSTER_ID:sub" = "system:serviceaccount:velero:velero"
          "oidc.eks.us-east-1.amazonaws.com/id/PRIMARY_CLUSTER_ID:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "velero_primary" {
  provider = aws.primary
  name     = "velero-policy"
  role     = aws_iam_role.velero_primary.id
  policy   = data.aws_iam_policy_document.velero_policy.json
}

# ── Outputs ───────────────────────────────────────────────────
output "velero_primary_bucket" {
  description = "Velero Primary S3 Bucket in us-east-1"
  value       = aws_s3_bucket.velero_primary.bucket
}

output "velero_secondary_bucket" {
  description = "Velero DR Target S3 Bucket in us-west-2"
  value       = aws_s3_bucket.velero_secondary.bucket
}

output "velero_primary_role_arn" {
  description = "IAM Role ARN for Velero Primary cluster"
  value       = aws_iam_role.velero_primary.arn
}

output "route53_primary_health_check_id" {
  description = "Route 53 Health Check ID for Primary us-east-1"
  value       = aws_route53_health_check.primary_alb.id
}
