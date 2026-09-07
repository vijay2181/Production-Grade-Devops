variable "aws_region"  { default = "us-east-1" }
variable "environment" { default = "prod" }
variable "cluster_name" { default = "myapp-prod" }

# ── VPC ───────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false          # HA: one per AZ
  one_nat_gateway_per_az = true
  enable_dns_hostnames = true

  # Required tags for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── EKS ───────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.29"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    system = {
      name           = "system"
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels         = { role = "system" }
    }

    app = {
      name           = "app"
      instance_types = ["t3.large"]
      min_size       = 3
      max_size       = 20
      desired_size   = 3
      labels         = { role = "app" }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  cluster_addons = {
    vpc-cni            = { most_recent = true }
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }
}

# ── RDS (PostgreSQL) ──────────────────────────────────────────────
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "myapp-postgres"
  engine     = "postgres"
  engine_version = "16"
  instance_class  = "db.t3.medium"
  allocated_storage = 50
  max_allocated_storage = 500  # auto-scaling storage

  db_name  = "myapp"
  username = "myuser"
  port     = "5432"

  multi_az               = true   # HA
  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 7
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "myapp-postgres-final"

  performance_insights_enabled = true
  monitoring_interval          = 60
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
}

# ── ElastiCache (Redis) ───────────────────────────────────────────
resource "aws_elasticache_subnet_group" "redis" {
  name       = "myapp-redis-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "myapp-redis"
  description                = "MyApp Redis cluster"
  engine                     = "redis"
  engine_version             = "7.0"
  node_type                  = "cache.t3.micro"
  num_cache_clusters         = 2     # primary + replica
  automatic_failover_enabled = true
  multi_az_enabled           = true
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
}

# ── ECR repositories ──────────────────────────────────────────────
resource "aws_ecr_repository" "api" {
  name                 = "myapp/api"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── Security Groups ───────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name   = "myapp-rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_security_group" "redis" {
  name   = "myapp-redis-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}
