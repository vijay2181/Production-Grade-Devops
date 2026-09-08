terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "myapp-terraform-state"
    key            = "hub/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "myapp-tf-locks"
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "myapp"
      Environment = "hub"
      ManagedBy   = "terraform"
      Role        = "argocd-hub"
    }
  }
}

# ── VPC ───────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "myapp-hub-vpc"
  cidr = "10.10.0.0/16"   # different CIDR per cluster to allow VPC peering

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24", "10.10.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true   # hub is internal-only, single NAT is fine
  enable_dns_hostnames   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                  = 1
    "kubernetes.io/cluster/myapp-hub"         = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"         = 1
    "kubernetes.io/cluster/myapp-hub"         = "shared"
  }
}

# ── EKS Hub Cluster (ArgoCD only — NO app workloads) ──────────────
module "eks_hub" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "myapp-hub"
  cluster_version = "1.29"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    hub = {
      name           = "hub"
      instance_types = ["t3.medium"]   # small — only runs ArgoCD
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels         = { role = "hub" }
    }
  }

  cluster_addons = {
    vpc-cni    = { most_recent = true }
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
  }
}

output "hub_cluster_name"     { value = module.eks_hub.cluster_name }
output "hub_cluster_endpoint" { value = module.eks_hub.cluster_endpoint }
