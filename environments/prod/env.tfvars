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

# No Interface endpoints are enabled by default: they bill per AZ-hour and
# require an explicit cost decision. Enable SSM here when private-instance
# shell access is needed:
#   interface_endpoint_services = ["ssm", "ssmmessages", "ec2messages"]
interface_endpoint_services = []

flow_logs_retention_in_days = 365
log_retention_days          = 365
enable_s3_flow_logs         = true
