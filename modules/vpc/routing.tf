###############################################################################
# 路由表
#
# 公网：一张共享路由表，0.0.0.0/0 和 ::/0 指向 internet gateway。
# 私网：每个 AZ 一张路由表，::/0 指向 egress-only internet gateway。
#       这里刻意没有 0.0.0.0/0 路由：本 VPC 不建 NAT 网关，
#       私网的 IPv4 流量无法离开 VPC。访问 AWS API 走 VPC 终端节点。
###############################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_ipv4_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "public_ipv6_default" {
  count = var.ipv6_enabled ? 1 : 0

  route_table_id              = aws_route_table.public.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-private-${each.value.az}"
  })
}

resource "aws_route" "private_ipv6_default" {
  for_each = var.ipv6_enabled ? local.private_subnets : {}

  route_table_id              = aws_route_table.private[each.key].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
