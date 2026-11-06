locals {
  # 每个环境目录固定自己的值：env.tfvars 无法意外改动它。
  environment = "dev"

  name_prefix = "${var.project}-${local.environment}"

  common_tags = {
    Project     = var.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Repository  = "terraform-aws"
  }

  # S3 桶名全局唯一；用账户 ID + 区域就能稳定复现，
  # 不需要加随机后缀。
  log_bucket_name = "${local.name_prefix}-logs-${var.aws_account_id}-${var.aws_region}"
}

module "logging" {
  source = "../../modules/logging-s3"

  name        = local.name_prefix
  environment = local.environment
  bucket_name = local.log_bucket_name
  account_id  = var.aws_account_id

  # dev 使用允许的最短 KMS 待删除窗口。
  kms_deletion_window_in_days = 7

  log_retention_days           = var.log_retention_days
  enable_vpc_flow_log_delivery = var.enable_s3_flow_logs
  force_destroy                = false

  tags = local.common_tags
}

module "vpc" {
  source = "../../modules/vpc"

  name        = local.name_prefix
  environment = local.environment
  aws_region  = var.aws_region
  account_id  = var.aws_account_id

  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  ipv6_enabled                = var.ipv6_enabled
  public_subnet_ipv6_netnums  = var.public_subnet_ipv6_netnums
  private_subnet_ipv6_netnums = var.private_subnet_ipv6_netnums
  map_public_ip_on_launch     = var.map_public_ip_on_launch
  interface_endpoint_services = var.interface_endpoint_services
  additional_security_groups  = var.additional_security_groups

  flow_logs_enabled           = true
  flow_logs_traffic_type      = "ALL"
  flow_logs_retention_in_days = var.flow_logs_retention_in_days
  flow_logs_s3_bucket_arn     = var.enable_s3_flow_logs ? module.logging.bucket_arn : null
  flow_logs_s3_enabled        = var.enable_s3_flow_logs

  tags = local.common_tags

  # S3 flow log 目标要求桶策略（以及对应的 KMS 授权）先存在，
  # 否则 AWS 在校验 flow log 配置时会拒绝。
  depends_on = [module.logging]
}
