locals {
  tags = merge(var.tags, {
    "terraform-module" = "modules/vpc"
    # Capitalised to merge with the Environment tag the environment root supplies
    # through var.tags / provider default_tags. AWS tag keys are case-insensitive
    # in several services (IAM rejects a map holding both "Environment" and
    # "environment"), so the module must not introduce a second spelling.
    "Environment" = var.environment
  })

  public_subnet_keys  = [for i in range(length(var.public_subnet_cidrs)) : "public-${i}"]
  private_subnet_keys = [for i in range(length(var.private_subnet_cidrs)) : "private-${i}"]

  public_subnets = {
    for i, cidr in var.public_subnet_cidrs : local.public_subnet_keys[i] => {
      az          = var.azs[i]
      cidr_block  = cidr
      ipv6_netnum = var.public_subnet_ipv6_netnums[i]
    }
  }

  private_subnets = {
    for i, cidr in var.private_subnet_cidrs : local.private_subnet_keys[i] => {
      az          = var.azs[i]
      cidr_block  = cidr
      ipv6_netnum = var.private_subnet_ipv6_netnums[i]
    }
  }

  private_route_table_ids = [
    for key in sort(keys(local.private_subnets)) : aws_route_table.private[key].id
  ]

  create_interface_endpoints = length(var.interface_endpoint_services) > 0

  create_flow_logs        = var.flow_logs_enabled
  create_flow_log_kms_key = var.flow_logs_enabled && var.flow_logs_kms_key_arn == null
  flow_logs_kms_key_arn   = var.flow_logs_kms_key_arn != null ? var.flow_logs_kms_key_arn : try(aws_kms_key.flow_logs[0].arn, null)

  # Must stay plan-time known: `count` cannot depend on the bucket ARN, which is
  # only known after the logging module has been applied.
  enable_s3_flow_log = var.flow_logs_enabled && var.flow_logs_s3_enabled
}
