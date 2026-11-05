###############################################################################
# Security groups
#
# Contract: no inbound rule in this module may use 0.0.0.0/0 or ::/0.
# That is enforced twice:
#   1. variable validation on var.additional_security_groups
#   2. every rule this module writes is scoped to the VPC CIDR ranges
###############################################################################

# The VPC default security group is adopted and stripped of every rule. Leaving
# it untouched would leave an allow-all egress rule (and, before AWS changed the
# default, an allow-all ingress rule) on every ENI that omits a security group.
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
