###############################################################################
# 安全组
#
# 约定：本模块不会产生任何使用 0.0.0.0/0 或 ::/0 的入站规则。
# 这由两层保证：
#   1. var.additional_security_groups 上的变量校验
#   2. 模块自己写的每条规则都限定在 VPC 的 CIDR 范围内
###############################################################################

# 接管并清空 VPC 的默认安全组。放任不管的话，任何没有显式指定安全组的 ENI
# 都会挂上一条允许全部出站的规则（在 AWS 修改默认行为之前，还包含允许全部入站）。
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-default-deny-all" })
}

resource "aws_security_group" "interface_endpoints" {
  count = local.create_interface_endpoints ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "HTTPS from inside the VPC to interface endpoints. No internet ingress."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from the VPC IPv4 range"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.ipv6_enabled ? [aws_vpc.this.ipv6_cidr_block] : []

    content {
      description      = "HTTPS from the VPC IPv6 range"
      from_port        = 443
      to_port          = 443
      protocol         = "tcp"
      ipv6_cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "HTTPS back into the VPC only. This VPC has no NAT gateway and no internet egress."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.tags, { Name = "${var.name}-vpce" })
}

resource "aws_security_group" "additional" {
  #checkov:skip=CKV2_AWS_5:These groups are attached by the workload modules that consume the additional_security_group_ids output. The map is empty by default so no unattached group is created.

  for_each = var.additional_security_groups

  name_prefix = "${var.name}-${each.key}-"
  description = each.value.description
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = each.value.ingress

    content {
      description      = ingress.value.description
      from_port        = ingress.value.from_port
      to_port          = ingress.value.to_port
      protocol         = ingress.value.protocol
      cidr_blocks      = ingress.value.cidr_blocks
      ipv6_cidr_blocks = ingress.value.ipv6_cidr_blocks
    }
  }

  dynamic "egress" {
    for_each = each.value.egress

    content {
      description      = egress.value.description
      from_port        = egress.value.from_port
      to_port          = egress.value.to_port
      protocol         = egress.value.protocol
      cidr_blocks      = egress.value.cidr_blocks
      ipv6_cidr_blocks = egress.value.ipv6_cidr_blocks
    }
  }

  tags = merge(local.tags, { Name = "${var.name}-${each.key}" })
}
