###############################################################################
# dev
#
# PLACEHOLDER: aws_account_id is NOT a real account. Replace it before running
# anything against a live account. scripts/plan.sh refuses to produce a plan
# when it can talk to AWS and this value does not match the caller identity.
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

# Interface endpoints cost money per AZ-hour; dev starts with the free S3
# gateway endpoint only. Add e.g. ["ssm", "ssmmessages", "ec2messages"] when you
# need sessionless access to private instances.
interface_endpoint_services = []

flow_logs_retention_in_days = 30
log_retention_days          = 90
enable_s3_flow_logs         = false

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
