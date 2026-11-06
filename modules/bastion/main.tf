###############################################################################
# SSM Bastion（纯 ASG 方案）
#
# 设计约束：
#   * 实例放在公网子网，自动分配公网 IPv4（不绑 EIP）
#   * SSM Agent 的 443 出站流量经 IGW 直连 SSM 公网端点，不需要 Interface 端点
#   * 不开放任何入站规则，也不使用 SSH / 密钥对；唯一访问路径是 SSM
#   * ASG min=0 / max=1 / desired=0：平时不产生任何计算和 EBS 费用，
#     需要时手动把 desired capacity 改成 1，用完改回 0
#   * 根 EBS 卷 DeleteOnTermination = true，实例回收后不留存储账单
#   * 实例角色只挂 AmazonSSMManagedInstanceCore，没有其他权限
###############################################################################

data "aws_partition" "current" {}

locals {
  tags = merge(var.tags, {
    "terraform-module" = "modules/bastion"
    "Environment"      = var.environment
  })

  bastion_tag_value = "${var.name}-bastion"

  # 实例和卷上的标签。Bastion 标签同时是开发人员 IAM 策略的条件（ssm:resourceTag）。
  instance_tags = merge(var.tags, {
    Name                  = "${var.name}-bastion"
    Environment           = var.environment
    terraform-module      = "modules/bastion"
    (var.bastion_tag_key) = local.bastion_tag_value
  })
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-bastion-"
  description = "SSM bastion: no ingress. All egress allowed; SSM traffic reaches the public endpoints through the IGW."

  vpc_id = var.vpc_id
  tags   = merge(local.tags, { Name = "${var.name}-bastion" })
}

# 需求明确要求出站全部允许；入站保持零规则。
#checkov:skip=CKV_AWS_382: 需求要求跳板机出站不设限。实例没有任何入站规则，唯一访问路径是 SSM，公网暴露面为零。
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "All egress. Required by design; there are no ingress rules."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = local.tags
}

resource "aws_iam_role" "this" {
  name_prefix = "${var.name}-bastion-"
  description = "SSM bastion instance role. Only AmazonSSMManagedInstanceCore is attached."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.name}-bastion" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-bastion-"
  role        = aws_iam_role.this.name

  tags = merge(local.tags, { Name = "${var.name}-bastion" })
}

resource "aws_launch_template" "this" {
  #checkov:skip=CKV_AWS_88: 跳板机按要求放在公有子网，需要一个公网 IPv4 才能经 IGW 访问 SSM 公网端点；实例零入站规则，唯一访问路径是 SSM。
  name_prefix   = "${var.name}-bastion-"
  description   = "SSM bastion. No key pair, no SSH. Public IPv4 is used only to reach the SSM public endpoints through the IGW."
  image_id      = var.ami_id
  instance_type = var.instance_type
  ebs_optimized = true

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  # ASG 负责选择子网。实例放在公网子网，通过自动分配的公网 IPv4 经 IGW
  # 访问 SSM 公网端点；不绑定 EIP，也没有任何入站规则。
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.this.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  tags = merge(local.tags, { Name = "${var.name}-bastion" })
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-bastion"
  vpc_zone_identifier = var.subnet_ids

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  health_check_type = "EC2"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(local.instance_tags, { Name = "${var.name}-bastion" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # desired_capacity 是给人手动操作的：Terraform 不把它拉回变量值。
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

###############################################################################
# 开发人员 IAM 策略片段（不创建资源，仅作为 output 提供）
#
# 只允许对带有 Bastion=<tag value> 标签的实例发起 SSM 会话，
# 并且只允许使用 AWS-StartPortForwardingSessionToRemoteHost 文档做端口转发。
# 所有语句都要求调用方已通过 MFA。
#
# 说明：SSM 没有名为 ssm:StartPortForwardingSessionToRemoteHost 的 IAM action，
# 端口转发统一使用 ssm:StartSession 授权，再通过文档 ARN 限定只能用这一个文档。
###############################################################################

locals {
  developer_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartSessionOnTaggedBastionOnly"
        Effect   = "Allow"
        Action   = ["ssm:StartSession"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${var.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/${var.bastion_tag_key}" = local.bastion_tag_value
          }
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
        }
      },
      {
        Sid    = "PortForwardingDocumentOnly"
        Effect = "Allow"
        Action = ["ssm:StartSession"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-StartPortForwardingSessionToRemoteHost",
        ]
        Condition = {
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
        }
      },
    ]
  }
}
