###############################################################################
# 加密的 S3 日志归档桶
#
# 下面每一项控制都是有意的：
#   * SSE-KMS，使用客户托管且自动轮转的密钥
#   * 版本控制 + 非当前版本过期（防止覆盖和删除）
#   * Block Public Access 四项全开，加上 BucketOwnerEnforced 所有权
#   * 桶策略拒绝任何非 TLS 请求
#   * 桶自身开启服务端访问日志
#   * 生命周期过期，避免桶无限增长
###############################################################################

locals {
  tags = merge(var.tags, {
    "terraform-module" = "modules/logging-s3"
    # 参见 modules/vpc/locals.tf：AWS 的 tag key 是大小写不敏感的，
    # 再加一个小写 "environment" 会让 IAM 拒绝整个请求。
    "Environment" = var.environment
  })
}

data "aws_partition" "current" {}

###############################################################################
# KMS
###############################################################################

data "aws_iam_policy_document" "kms_key" {
  #checkov:skip=CKV_AWS_111:AWS KMS key policies must grant kms-star on resource-star to the account root principal. The scope of a key policy is the key itself so a narrower Resource is not expressible.
  #checkov:skip=CKV_AWS_109:See CKV_AWS_111. The kms-star grant is the AWS documented account administration statement and is bounded by the key policy scope.
  #checkov:skip=CKV_AWS_356:See CKV_AWS_111. Resource-star is mandatory in a KMS key policy and key administrators are limited by key policy not by ARN.

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

  dynamic "statement" {
    for_each = var.enable_vpc_flow_log_delivery ? [1] : []

    content {
      sid    = "AllowVpcFlowLogsDelivery"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey*",
      ]

      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [var.account_id]
      }
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "CMK protecting the ${var.name} log bucket"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key.json

  tags = merge(local.tags, { Name = "${var.name}-logs" })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

###############################################################################
# 桶
###############################################################################

resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV2_AWS_62:This bucket is a passive log archive with no consumer reacting to object events so notifications would add surface without benefit.
  #checkov:skip=CKV_AWS_144:Cross-region replication is an organisation level DR decision. Destination bucket region and KMS grant are owned by the DR account. Tracked as R-06 in docs/RISKS.md.

  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }

    bucket_key_enabled = true
  }
}

# 服务端访问日志写到桶自身：日志归档桶是这个账户里唯一一个
# 访问痕迹必须能独立存活下来的桶。
resource "aws_s3_bucket_logging" "logs" {
  bucket = aws_s3_bucket.logs.id

  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-log-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.logs]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid     = "AllowServerAccessLogging"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.logs.arn}/access-logs/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  dynamic "statement" {
    for_each = var.enable_vpc_flow_log_delivery ? [1] : []

    content {
      sid     = "AllowVpcFlowLogsDelivery"
      effect  = "Allow"
      actions = ["s3:PutObject"]

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${var.account_id}/*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [var.account_id]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.bucket.json

  # 策略不能在公共访问被阻断之前生效，
  # 否则一个宽松的策略会有短暂的生效窗口。
  depends_on = [aws_s3_bucket_public_access_block.logs]
}
