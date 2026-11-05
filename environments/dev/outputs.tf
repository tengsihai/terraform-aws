output "environment" {
  description = "Environment this root module manages."
  value       = local.environment
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "IPv4 CIDR of the VPC."
  value       = module.vpc.vpc_cidr
}

output "vpc_ipv6_cidr_block" {
  description = "IPv6 CIDR of the VPC."
  value       = module.vpc.vpc_ipv6_cidr_block
}

output "availability_zones" {
  description = "AZs the network spans."
  value       = module.vpc.availability_zones
}

output "public_subnet_ids" {
  description = "Public subnet IDs by AZ."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs by AZ."
  value       = module.vpc.private_subnet_ids
}

output "private_route_table_ids" {
  description = "Per-AZ private route table IDs."
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_ids" {
  description = "Always empty: no NAT gateway exists in this design."
  value       = module.vpc.nat_gateway_ids
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint ID."
  value       = module.vpc.s3_gateway_endpoint_id
}

output "log_bucket_name" {
  description = "Encrypted S3 log bucket."
  value       = module.logging.bucket_id
}

output "log_bucket_arn" {
  description = "ARN of the encrypted S3 log bucket."
  value       = module.logging.bucket_arn
}

output "log_bucket_kms_key_arn" {
  description = "CMK protecting the log bucket."
  value       = module.logging.kms_key_arn
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs."
  value       = module.vpc.flow_log_group_name
}
