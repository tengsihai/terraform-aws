###############################################################################
# prod
#
# PLACEHOLDER: aws_account_id is NOT a real account. Replace it before running
# anything against a live account.
###############################################################################

aws_region     = "ap-northeast-1"
aws_account_id = "123456789012"

vpc_cidr = "10.30.0.0/16"

azs = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

public_subnet_cidrs  = ["10.30.0.0/20", "10.30.16.0/20", "10.30.32.0/20"]
private_subnet_cidrs = ["10.30.128.0/20", "10.30.144.0/20", "10.30.160.0/20"]

ipv6_enabled                = true
public_subnet_ipv6_netnums  = [0, 1, 2]
private_subnet_ipv6_netnums = [8, 9, 10]

map_public_ip_on_launch = false

# 跳板机在公有子网，SSM Agent 的 443 出站经 IGW 直连公网 SSM 端点，
# 因此不创建 ssm / ec2messages / ssmmessages Interface 端点（省掉按 AZ-hour 的费用）。
interface_endpoint_services = []

flow_logs_retention_in_days = 365
log_retention_days          = 365
enable_s3_flow_logs         = true

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

# prod 保留最终快照，并阻止误删实例。
db_deletion_protection = true
db_skip_final_snapshot = false
