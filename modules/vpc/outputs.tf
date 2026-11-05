output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Primary IPv4 CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_ipv6_cidr_block" {
  description = "AWS-generated IPv6 CIDR of the VPC, or null when IPv6 is disabled."
  value       = aws_vpc.this.ipv6_cidr_block
}

output "availability_zones" {
  description = "Availability zones the subnets are spread across."
  value       = var.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by AZ."
  value       = [for key in local.public_subnet_keys : aws_subnet.public[key].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered by AZ."
  value       = [for key in sort(keys(local.private_subnets)) : aws_subnet.private[key].id]
}

output "public_subnet_cidrs" {
  description = "IPv4 CIDRs of the public subnets."
  value       = [for key in local.public_subnet_keys : aws_subnet.public[key].cidr_block]
}

output "private_subnet_cidrs" {
  description = "IPv4 CIDRs of the private subnets."
  value       = [for key in sort(keys(local.private_subnets)) : aws_subnet.private[key].cidr_block]
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables."
  value       = local.private_route_table_ids
}

output "nat_gateway_ids" {
  description = "Always empty. This module intentionally never creates a NAT gateway."
  value       = []
}

output "default_security_group_id" {
  description = "ID of the VPC default security group, which this module strips of all rules."
  value       = aws_default_security_group.this.id
}

output "interface_endpoint_security_group_id" {
  description = "Security group attached to interface endpoints, or null when none are enabled."
  value       = try(aws_security_group.interface_endpoints[0].id, null)
}

output "additional_security_group_ids" {
  description = "Map of additional security group name to security group ID."
  value       = { for name, sg in aws_security_group.additional : name => sg.id }
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or null when disabled."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "interface_endpoint_ids" {
  description = "Map of service name to interface endpoint ID."
  value       = { for service, endpoint in aws_vpc_endpoint.interface : service => endpoint.id }
}

output "flow_log_id" {
  description = "ID of the CloudWatch flow log, or null when flow logs are disabled."
  value       = try(aws_flow_log.cloudwatch[0].id, null)
}

output "flow_log_s3_id" {
  description = "ID of the S3 flow log, or null when the S3 destination is not configured."
  value       = try(aws_flow_log.s3[0].id, null)
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs, or null when disabled."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}
