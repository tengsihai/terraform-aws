locals {
  tags = merge(var.tags, {
    "terraform-module" = "modules/vpc"
    # 这里用大写的 Environment，是为了和环境根目录通过 var.tags / provider
    # default_tags 注入的 Environment 合并。多个 AWS 服务的 tag key 是大小写
    # 不敏感的（IAM 会直接拒绝同时含 "Environment" 和 "environment" 的 map），
    # 所以模块不能引入第二种拼写。
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

  # 必须在 plan 阶段就是已知值：count 不能依赖桶 ARN，
  # 那个值要等 logging 模块 apply 之后才知道。
  enable_s3_flow_log = var.flow_logs_enabled && var.flow_logs_s3_enabled
}
