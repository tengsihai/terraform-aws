###############################################################################
# VPC endpoints
#
# Because the private tier has no NAT gateway, every AWS service a private
# workload talks to must be reachable through an endpoint.
#   * S3            -> Gateway endpoint (free), attached to public + private
#                      route tables.
#   * anything else -> opt-in Interface endpoints via var.interface_endpoint_services
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

    # Scope of the ENDPOINT policy. It is not the authorization boundary:
    # IAM identity policies and S3 bucket policies still decide who may read
    # or write which object. Restricting it to a single bucket here would
    # silently break every other workload in the account.
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
