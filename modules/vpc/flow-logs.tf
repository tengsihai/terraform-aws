###############################################################################
# VPC 流量日志
#
# 主要目标端：CloudWatch Logs，用专门的轮转 CMK 加密，
# 60 秒粒度（安全排查需要这个精度）。
# 可选第二目标端：加密的 S3 日志桶，用于超出 CloudWatch Logs
# 保留窗口的长期留存。
###############################################################################

resource "aws_kms_key" "flow_logs" {
  count = local.create_flow_log_kms_key ? 1 : 0

  description             = "CMK encrypting ${var.name} VPC flow logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.flow_logs_kms[0].json

  tags = merge(local.tags, { Name = "${var.name}-flow-logs" })
}

resource "aws_kms_alias" "flow_logs" {
  count = local.create_flow_log_kms_key ? 1 : 0

  name          = "alias/${var.name}-flow-logs"
  target_key_id = aws_kms_key.flow_logs[0].key_id
}

data "aws_iam_policy_document" "flow_logs_kms" {
  #checkov:skip=CKV_AWS_111:AWS KMS key policies must grant kms-star on resource-star to the account root principal. The scope of a key policy is the key itself so a narrower Resource is not expressible.
  #checkov:skip=CKV_AWS_109:See CKV_AWS_111. The kms-star grant is the AWS documented account administration statement and is bounded by the key policy scope.
  #checkov:skip=CKV_AWS_356:See CKV_AWS_111. Resource-star is mandatory in a KMS key policy and key administrators are limited by key policy not by ARN.

  count = local.create_flow_log_kms_key ? 1 : 0

  statement {
    sid    = "AllowAccountRootToAdministerKey"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsToUseKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]

    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${var.account_id}:log-group:/aws/vpc/${var.name}/*"]
    }
  }
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338:dev and staging deliberately keep shorter retention as a cost decision while prod pins 365 days. See docs/RISKS.md R-07.

  count = local.create_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_in_days
  kms_key_id        = local.flow_logs_kms_key_arn

  tags = merge(local.tags, { Name = "${var.name}-flow-logs" })
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  count = local.create_flow_logs ? 1 : 0

  statement {
    sid     = "VpcFlowLogsAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_permissions" {
  count = local.create_flow_logs ? 1 : 0

  statement {
    sid    = "WriteFlowLogsToCloudWatch"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = local.create_flow_logs ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role[0].json
  description        = "Allows VPC Flow Logs to write into CloudWatch Logs"

  tags = merge(local.tags, { Name = "${var.name}-vpc-flow-logs" })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.create_flow_logs ? 1 : 0

  name   = "${var.name}-vpc-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_permissions[0].json
}

resource "aws_flow_log" "cloudwatch" {
  count = local.create_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = var.flow_logs_traffic_type
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  max_aggregation_interval = var.flow_logs_max_aggregation_interval

  tags = merge(local.tags, { Name = "${var.name}-flow-logs" })
}

resource "aws_flow_log" "s3" {
  count = local.enable_s3_flow_log ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = var.flow_logs_traffic_type
  log_destination_type = "s3"
  log_destination      = var.flow_logs_s3_bucket_arn

  # 包含安全排查需要的字段。`${version}` 必须放在最前面。
  log_format = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${vpc-id} $${subnet-id} $${instance-id} $${tcp-flags} $${type} $${pkt-srcaddr} $${pkt-dstaddr}"

  max_aggregation_interval = var.flow_logs_max_aggregation_interval

  tags = merge(local.tags, { Name = "${var.name}-flow-logs-s3" })
}
