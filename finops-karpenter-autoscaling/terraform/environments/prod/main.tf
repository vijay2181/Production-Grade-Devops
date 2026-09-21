# =============================================================
# terraform/environments/prod/main.tf — FinOps & Karpenter Stack
# Provisions:
#   1. Karpenter Controller IRSA Role & Policy
#   2. Karpenter Node IAM Role, Instance Profile, & Custom SQS Interruption Queue
#   3. AWS EventBridge Rules for Spot Interruption, Rebalance, & EC2 State Change
#   4. OpenCost / Prometheus Cost Exporter IAM integration
# =============================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.26"
    }
  }
  backend "s3" {
    bucket         = "myapp-terraform-state"
    key            = "finops-karpenter/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "finops-karpenter-autoscaling"
      Environment = "prod"
      ManagedBy   = "terraform"
      "karpenter.sh/discovery" = var.cluster_name
    }
  }
}

# ── Data Sources ──────────────────────────────────────────────
data "aws_eks_cluster" "main" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_vpc" "main" {
  tags = { Name = "${var.cluster_name}-vpc" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { "karpenter.sh/discovery" = var.cluster_name }
}

# ── 1. SQS Interruption & Rebalance Queue ──────────────────────
# Buffers 2-minute Spot interruption & EC2 health events for Karpenter
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.cluster_name}-karpenter-interruption"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeToSQS"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# ── 2. EventBridge Rules for Spot Interruption ─────────────────
# Rule 1: EC2 Spot Instance Interruption Warning
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "Captures AWS EC2 Spot Instance Interruption Warnings"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# Rule 2: EC2 Instance Rebalance Recommendation (proactive consolidation)
resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${var.cluster_name}-rebalance-recommendation"
  description = "Captures EC2 Instance Rebalance Recommendations for proactive migration"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "rebalance_recommendation" {
  rule      = aws_cloudwatch_event_rule.rebalance_recommendation.name
  target_id = "KarpenterRebalanceQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# Rule 3: EC2 Instance State-change Notification (Terminated/Stopping)
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-instance-state-change"
  description = "Captures EC2 instance termination events to clean up Karpenter node records"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "KarpenterInstanceStateQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── 3. IAM Role for Karpenter Controller (IRSA) ───────────────
data "aws_iam_policy_document" "karpenter_controller_trust" {
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
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "karpenter_controller_policy" {
  statement {
    sid    = "AllowKarpenterEC2Actions"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowPassingInstanceRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  statement {
    sid    = "AllowPricingRead"
    effect = "Allow"
    actions = [
      "pricing:GetProducts"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage"
    ]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }

  statement {
    sid    = "AllowScopedEKSClusterAccess"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster"
    ]
    resources = [data.aws_eks_cluster.main.arn]
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_trust.json
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "karpenter-controller-policy"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller_policy.json
}

# ── 4. IAM Role & Instance Profile for Karpenter Worker Nodes ─
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach AWS managed policies required for EKS worker nodes
resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name
}

# ── 5. OpenCost IAM IRSA Role (AWS Pricing API Access) ─────────
data "aws_iam_policy_document" "opencost_trust" {
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
      values   = ["system:serviceaccount:opencost:opencost"]
    }
  }
}

data "aws_iam_policy_document" "opencost_policy" {
  statement {
    sid    = "AllowPricingAndCostExplorer"
    effect = "Allow"
    actions = [
      "pricing:GetProducts",
      "pricing:DescribeServices",
      "ce:GetCostAndUsage",
      "ce:GetDimensionValues"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "opencost" {
  name               = "${var.cluster_name}-opencost-irsa"
  assume_role_policy = data.aws_iam_policy_document.opencost_trust.json
}

resource "aws_iam_role_policy" "opencost" {
  name   = "opencost-policy"
  role   = aws_iam_role.opencost.id
  policy = data.aws_iam_policy_document.opencost_policy.json
}

# ── Outputs ───────────────────────────────────────────────────
output "karpenter_controller_role_arn" {
  description = "IAM Role ARN for Karpenter Controller IRSA"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_name" {
  description = "IAM Role name passed to EC2NodeClass"
  value       = aws_iam_role.karpenter_node.name
}

output "karpenter_interruption_queue_name" {
  description = "SQS Queue name for Spot Interruption and Rebalance events"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "opencost_role_arn" {
  description = "IAM Role ARN for OpenCost pricing integration"
  value       = aws_iam_role.opencost.arn
}
