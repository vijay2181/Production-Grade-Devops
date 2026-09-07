output "cluster_name"       { value = module.eks.cluster_name }
output "cluster_endpoint"   { value = module.eks.cluster_endpoint }
output "rds_endpoint"       { value = module.rds.db_instance_endpoint }
output "redis_endpoint"     { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "ecr_api_url"        { value = aws_ecr_repository.api.repository_url }
