locals {
  # 每个环境目录固定自己的值：env.tfvars 无法意外改动它。
  environment = "prod"

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

  # prod 用最长待删除窗口，误删密钥时有 30 天可恢复。
  kms_deletion_window_in_days = 30

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

  # Lambda 是纯客户端：没有任何入站规则。两条出站分别用于连 MySQL 和
  # Secrets Manager 的 Interface 端点，目标都限定在本环境的 VPC 网段内。
  # 用 merge 而不是直接覆盖，保留 tfvars 里按需追加的其他安全组。
  additional_security_groups = merge(var.additional_security_groups, {
    lambda = {
      description = "Egress-only group for the Lambda workload: MySQL and Secrets Manager. No ingress."
      ingress     = []
      egress = [
        {
          description = "MySQL to the RDS instance inside this VPC."
          from_port   = 3306
          to_port     = 3306
          protocol    = "tcp"
          cidr_blocks = [var.vpc_cidr]
        },
        {
          description = "HTTPS to the Secrets Manager interface endpoint inside this VPC."
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = [var.vpc_cidr]
        },
      ]
    }
  })

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

module "bastion" {
  source = "../../modules/bastion"

  name        = local.name_prefix
  environment = local.environment
  aws_region  = var.aws_region
  account_id  = var.aws_account_id

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnet_ids

  ami_id           = var.bastion_ami_id
  instance_type    = var.bastion_instance_type
  min_size         = var.bastion_min_size
  max_size         = var.bastion_max_size
  desired_capacity = var.bastion_desired_capacity

  # 公有子网，自动分配公网 IPv4，经 IGW 直连 SSM 公网端点；
  # 无入站规则、无 SSH、无密钥对、无 EIP。ASG 默认 desired_capacity = 0。
  tags = local.common_tags
}

module "rds" {
  source = "../../modules/rds-mysql"

  name        = local.name_prefix
  environment = local.environment
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnet_ids

  engine_version  = var.db_engine_version
  instance_class  = var.db_instance_class
  db_name         = var.db_name
  master_username = var.db_master_username

  # 入站只允许显式列出的两张安全组：跳板机（人工运维）和 Lambda（应用）。
  # 单 AZ、公网不可达由模块内部固定。
  allowed_security_group_ids = [
    module.bastion.security_group_id,
    module.vpc.additional_security_group_ids["lambda"],
  ]

  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = var.db_skip_final_snapshot

  tags = local.common_tags
}
