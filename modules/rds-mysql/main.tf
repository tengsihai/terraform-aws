###############################################################################
# MySQL on RDS
#
# 设计要点：
#   * 单 AZ（multi_az = false），实例类默认 db.t4g.micro
#   * 只放在私网子网，publicly_accessible = false
#   * 主用户密码不经过 Terraform：manage_master_user_password = true
#     让 RDS 在 Secrets Manager 里生成、托管并自动轮转密码
#   * 入站只允许显式列出的安全组（跳板机），没有其他来源
#   * 实例没有任何出站规则：RDS 的数据面不需要主动外连
###############################################################################

locals {
  tags = merge(var.tags, {
    "terraform-module" = "modules/rds-mysql"
    "Environment"      = var.environment
  })
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-rds"
  description = "Private subnets for the ${var.name} MySQL instance."
  subnet_ids  = var.subnet_ids

  tags = merge(local.tags, { Name = "${var.name}-rds" })
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-rds-"
  description = "MySQL ingress from explicitly allowed security groups only. No egress."
  vpc_id      = var.vpc_id

  # 不声明任何 ingress / egress 块：Terraform 会移除 AWS 默认的“全部放行”
  # 出站规则，剩下只有下面用独立资源声明的入站规则。
  tags = merge(local.tags, { Name = "${var.name}-rds" })
}

# 每条允许的安全组单独一条规则，plan 里能逐条看到从哪里能连进来。
# 用 count 而不是 for_each：安全组 ID 是 apply 后才知道的值，
# for_each 的 key 必须在 plan 期确定，count 只需要长度已知。
resource "aws_vpc_security_group_ingress_rule" "mysql" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "MySQL from an explicitly allowed security group (the bastion)."
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
  referenced_security_group_id = var.allowed_security_group_ids[count.index]

  tags = local.tags
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_157: 需求明确要求单 AZ；Multi-AZ 是可用性/成本决策，由调用方在需求变化时再开启。
  #checkov:skip=CKV_AWS_118: 增强监控需要额外的 IAM 角色和 CloudWatch Logs 摄取成本；本实例已开启 Performance Insights、error 与 slowquery 日志。
  #checkov:skip=CKV_AWS_354: Performance Insights 默认使用 AWS 托管的 aws/rds 密钥；调用方传入 kms_key_arn 时才会改用专用 CMK。
  identifier = "${var.name}-mysql"

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.db_name
  port     = var.port
  username = var.master_username

  # 允许应用程序用 IAM 角色临时凭证登录，不产生额外费用；实际授权仍由 IAM 策略决定。
  iam_database_authentication_enabled = true

  # 密码由 RDS 在 Secrets Manager 中生成并轮转，Terraform state 里没有明文。
  manage_master_user_password = true

  # 需求：单 AZ，且不对公网暴露。
  multi_az            = false
  publicly_accessible = false

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  backup_retention_period    = var.backup_retention_period
  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.name}-mysql-final"

  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  # Performance Insights 默认关闭：db.t4g.micro 不支持，开启会让 AWS 返回
  # InvalidParameterCombination（"Performance Insights not supported for this
  # configuration"）。实例类升级到支持 PI 的型号后再通过变量打开。
  #checkov:skip=CKV_AWS_129: db.t4g.micro 不支持 Performance Insights；需要 PI 时先换更大的实例类。
  #checkov:skip=CKV_AWS_354: PI 未启用；启用后应指定 performance_insights_kms_key_id。
  #checkov:skip=CKV_AWS_353: 同 CKV_AWS_129 —— db.t4g.micro 不支持 Performance Insights。
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null

  apply_immediately = var.apply_immediately

  tags = merge(local.tags, { Name = "${var.name}-mysql" })
}
