locals {
  # Pinned per environment directory: env.tfvars cannot change it by accident.
  environment = "dev"

  name_prefix = "${var.project}-${local.environment}"

  common_tags = {
    Project     = var.project
    Environment = local.environment
    ManagedBy   = "terraform"
    Repository  = "terraform-aws"
  }

  # S3 bucket names are globally unique; account id + region make this
  # reproducible without a random suffix.
  log_bucket_name = "${local.name_prefix}-logs-${var.aws_account_id}-${var.aws_region}"
}

module "logging" {
  source = "../../modules/logging-s3"

  name        = local.name_prefix
  environment = local.environment
  bucket_name = local.log_bucket_name
  account_id  = var.aws_account_id

  # dev gets the shortest legally allowed KMS waiting period.
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

  # The S3 flow-log destination requires the bucket policy (and its KMS grant)
  # to exist before AWS validates the flow log configuration.
  depends_on = [module.logging]
}
