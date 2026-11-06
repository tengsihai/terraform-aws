###############################################################################
# VPC 终端节点
#
# 私网层没有 NAT 网关，所以私网工作负载要访问的每个 AWS 服务，
# 都必须能通过终端节点到达。
#   * S3       -> Gateway 端点（免费），挂在公网 + 三张私网路由表上。
#   * 其他服务 -> 通过 var.interface_endpoint_services 按需开启 Interface 端点
###############################################################################

data "aws_partition" "current" {}

data "aws_iam_policy_document" "s3_endpoint" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  statement {
    sid    = "AllowS3DataPlaneFromVpc"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]

    # 这是「端点策略」的作用范围，它不是授权边界：
    # 谁可以读写哪个对象，仍然由 IAM 身份策略和 S3 桶策略决定。
    # 如果在这里收窄到单个桶，会让账户里其他工作负载的 S3 访问静默失败。
    resources = ["arn:${data.aws_partition.current.partition}:s3:::*"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat([aws_route_table.public.id], local.private_route_table_ids)

  policy = var.s3_endpoint_policy_json != null ? var.s3_endpoint_policy_json : data.aws_iam_policy_document.s3_endpoint[0].json

  tags = merge(local.tags, { Name = "${var.name}-s3-gateway" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoint_services

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type = "Interface"

  private_dns_enabled = var.interface_endpoint_private_dns_enabled

  subnet_ids         = [for key in sort(keys(local.private_subnets)) : aws_subnet.private[key].id]
  security_group_ids = [aws_security_group.interface_endpoints[0].id]

  tags = merge(local.tags, {
    Name = "${var.name}-vpce-${replace(each.value, ".", "-")}"
  })
}
