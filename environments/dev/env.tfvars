###############################################################################
# dev
#
# aws_account_id below is the real account this environment deploys into
# (verified against aws sts get-caller-identity on 2026-11-06).
# staging/prod still carry the 123456789012 placeholder and must be updated
# before they are connected to a live account.
###############################################################################

aws_region     = "ap-northeast-1"
aws_account_id = "790354569983"

vpc_cidr = "10.10.0.0/16"

azs = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
private_subnet_cidrs = ["10.10.128.0/20", "10.10.144.0/20", "10.10.160.0/20"]

ipv6_enabled                = true
public_subnet_ipv6_netnums  = [0, 1, 2]
private_subnet_ipv6_netnums = [8, 9, 10]

map_public_ip_on_launch = false

# 跳板机在公有子网，SSM Agent 的 443 出站经 IGW 直连公网 SSM 端点，
# 因此不创建 ssm / ec2messages / ssmmessages Interface 端点（省掉按 AZ-hour 的费用）。
#
# 私网的 Lambda 没有公网出口，读 RDS 主用户密码必须走 Secrets Manager 的
# Interface 端点。接口型端点按 AZ-hour 计费，先只在 dev 开一档打通链路。
interface_endpoint_services = ["secretsmanager"]

flow_logs_retention_in_days = 30
log_retention_days          = 90
enable_s3_flow_logs         = false

# 前端是 SPA：S3 的 403/404 回退到 index.html（HTTP 200），深链接交给前端路由。
site_spa_mode = true

# --- Guardrail example (rejected by variable validation) --------------------
# Uncommenting this makes `terraform plan` fail with an explicit error; that is
# the intended behaviour, not a bug.
#
# additional_security_groups = {
#   bastion = {
#     description = "SSH from anywhere"
#     ingress = [{
#       description = "SSH"
#       from_port   = 22
#       to_port     = 22
#       protocol    = "tcp"
#       cidr_blocks = ["0.0.0.0/0"]
#     }]
#   }
# }

# --- RDS (MySQL) + 跳板机 ----------------------------------------------------
# Amazon Linux 2023 arm64 的 AMI。查询方式（区域与服务端保持一致）：
#   aws ssm get-parameter --region ap-northeast-1 \
#     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
#     --query Parameter.Value --output text
# AMI 会随上游更新；重建跳板机前请重新查询并更新这里。
bastion_ami_id        = "ami-0726b213222e0072c"
bastion_instance_type = "t4g.micro"

# 纯 SSM 方案：私网子网 + 三个 Interface 端点，无入站规则、无 SSH、无密钥对、无 EIP。
# ASG 默认 0 实例：需要时手工 set-desired-capacity 1，用完改回 0。

db_engine_version  = "8.4"
db_instance_class  = "db.t4g.micro"
db_name            = "appdb"
db_master_username = "admin"

# dev 是可丢弃环境：允许删除实例，不保留最终快照。
db_deletion_protection = false
db_skip_final_snapshot = true
