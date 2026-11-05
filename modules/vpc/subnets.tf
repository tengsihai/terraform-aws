###############################################################################
# Subnets
#
# IPv6: the VPC receives a /56; each subnet carves a /64 out of it with
# cidrsubnet(..., 8, netnum).
###############################################################################

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value.cidr_block

  availability_zone = each.value.az
  ipv6_cidr_block   = var.ipv6_enabled ? cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, each.value.ipv6_netnum) : null

  # Secure default: public subnets do not hand out public IPv4 addresses
  # implicitly. Workloads that truly need one attach an EIP explicitly.
  map_public_ip_on_launch         = var.map_public_ip_on_launch
  assign_ipv6_address_on_creation = var.ipv6_enabled ? var.assign_ipv6_address_on_creation : false

  tags = merge(local.tags, {
    Name = "${var.name}-public-${each.value.az}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value.cidr_block

  availability_zone = each.value.az
  ipv6_cidr_block   = var.ipv6_enabled ? cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, each.value.ipv6_netnum) : null

  map_public_ip_on_launch = false

  # Private IPv6 is available but opt-in per ENI: there is no stateful
  # firewall in front of these subnets, so assignment is explicit.
  assign_ipv6_address_on_creation = false

  tags = merge(local.tags, {
    Name = "${var.name}-private-${each.value.az}"
    Tier = "private"
  })
}
