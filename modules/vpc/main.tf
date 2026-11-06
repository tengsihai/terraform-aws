###############################################################################
# VPC
#
# 设计约定（详见 docs/ARCHITECTURE.md）：
#   * 三个可用区，每个 AZ 一对公网 / 私网子网
#   * 双栈：IPv4 + AWS 自动分配的 /56 IPv6
#   * 不创建 NAT 网关，私网路由表里也没有 IPv4 默认路由。
#     私网工作负载通过 VPC 终端节点访问 AWS API（默认是 S3 网关端点）。
#     启用 IPv6 时，出网走 egress-only internet gateway（只出不进）。
#   * 任何安全组都不接受 0.0.0.0/0 或 ::/0 入站
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

# 私网子网的 IPv6 出网通道。相当于 NAT 网关的 IPv6 版本，免费，
# 且外部无法主动发起入站连接。
resource "aws_egress_only_internet_gateway" "this" {
  count = var.ipv6_enabled ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-eigw" })
}
