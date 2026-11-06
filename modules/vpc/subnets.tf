###############################################################################
# 子网
#
# IPv6：VPC 拿到一个 /56，每个子网用 cidrsubnet(..., 8, netnum)
# 从中切出一个 /64。
###############################################################################

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value.cidr_block

  availability_zone = each.value.az
  ipv6_cidr_block   = var.ipv6_enabled ? cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, each.value.ipv6_netnum) : null

  # 安全默认值：公网子网不会隐式分配公网 IPv4 地址。
  # 确实需要的工作负载显式绑一个 EIP。
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

  # 私网子网有 IPv6 段，但按 ENI 逐个开启：这些子网前面没有状态防火墙，
  # 所以地址分配保持显式。
  assign_ipv6_address_on_creation = false

  tags = merge(local.tags, {
    Name = "${var.name}-private-${each.value.az}"
    Tier = "private"
  })
}
