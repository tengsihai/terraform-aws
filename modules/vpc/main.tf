###############################################################################
# VPC
#
# Design contract (see docs/ARCHITECTURE.md):
#   * three availability zones, one public and one private subnet per AZ
#   * dual stack: IPv4 + AWS-generated /56 IPv6
#   * NO NAT gateway and NO IPv4 default route in the private route tables.
#     Private workloads reach AWS APIs through VPC endpoints (S3 gateway by
#     default). IPv6 egress, when enabled, uses an egress-only internet gateway.
#   * no security group accepts 0.0.0.0/0 or ::/0 ingress
###############################################################################

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  instance_tenancy                 = "default"
  enable_dns_support               = var.enable_dns_support
  enable_dns_hostnames             = var.enable_dns_hostnames
  assign_generated_ipv6_cidr_block = var.ipv6_enabled

  tags = merge(local.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-igw" })
}

# IPv6-only outbound path for private subnets. This is the IPv6 counterpart of a
# NAT gateway and is free of charge; inbound connections cannot be initiated.
resource "aws_egress_only_internet_gateway" "this" {
  count = var.ipv6_enabled ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-eigw" })
}
