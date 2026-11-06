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

output "lambda_security_group_id" {
  description = "Security group attached to the Lambda functions."
  value       = module.vpc.additional_security_group_ids["lambda"]
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

output "site_bucket_name" {
  description = "Private S3 bucket holding the static site content."
  value       = module.site.bucket_id
}

output "site_bucket_arn" {
  description = "ARN of the private static site bucket."
  value       = module.site.bucket_arn
}

output "site_kms_key_arn" {
  description = "CMK protecting the static site bucket."
  value       = module.site.kms_key_arn
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID, used for cache invalidations."
  value       = module.site.distribution_id
}

output "cloudfront_distribution_arn" {
  description = "ARN of the CloudFront distribution."
  value       = module.site.distribution_arn
}

output "cloudfront_domain_name" {
  description = "Public CloudFront hostname of the static site."
  value       = module.site.distribution_domain_name
}

output "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID, for alias records against the distribution."
  value       = module.site.distribution_hosted_zone_id
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs."
  value       = module.vpc.flow_log_group_name
}

output "rds_instance_endpoint" {
  description = "Host:port endpoint of the MySQL instance."
  value       = module.rds.endpoint
}

output "rds_instance_address" {
  description = "Hostname of the MySQL instance."
  value       = module.rds.address
}

output "rds_database_name" {
  description = "Initial database created inside the MySQL instance."
  value       = module.rds.database_name
}

output "rds_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master user credentials. Retrieve the value with aws secretsmanager get-secret-value."
  value       = module.rds.master_user_secret_arn
}

output "rds_security_group_id" {
  description = "Security group controlling access to the MySQL instance."
  value       = module.rds.security_group_id
}

output "bastion_asg_name" {
  description = "Name of the SSM bastion Auto Scaling group (min 0, max 1, desired 0)."
  value       = module.bastion.asg_name
}

output "bastion_security_group_id" {
  description = "Bastion security group ID: no ingress rules, all egress allowed."
  value       = module.bastion.security_group_id
}

output "bastion_instance_role_arn" {
  description = "Bastion instance role. Only AmazonSSMManagedInstanceCore is attached."
  value       = module.bastion.instance_role_arn
}

output "bastion_scale_up_command" {
  description = "Starts one bastion instance (creates compute and EBS cost until scaled back to 0)."
  value       = module.bastion.scale_up_command
}

output "bastion_scale_down_command" {
  description = "Terminates the bastion instance and returns to zero compute/EBS cost."
  value       = module.bastion.scale_down_command
}

output "bastion_instance_id_command" {
  description = "Prints the running bastion instance ID."
  value       = module.bastion.instance_id_command
}

output "bastion_ssm_ready_command" {
  description = "Lists SSM-managed instances and their ping status."
  value       = module.bastion.ssm_ready_command
}

output "bastion_port_forward_command" {
  description = "SSM port forwarding straight to the RDS endpoint. Replace <BASTION_INSTANCE_ID> with the value from bastion_instance_id_command, then point DBeaver/Navicat at 127.0.0.1:<local port>."
  value       = "aws ssm start-session --region ${var.aws_region} --target <BASTION_INSTANCE_ID> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{\"host\":[\"${module.rds.address}\"],\"portNumber\":[\"${module.rds.port}\"],\"localPortNumber\":[\"${var.db_local_port}\"]}'"
}

output "bastion_developer_policy_json" {
  description = "Least-privilege IAM policy for developers: ssm:StartSession only, restricted by bastion tag and the port-forwarding document, MFA required."
  value       = module.bastion.developer_policy_json
}
