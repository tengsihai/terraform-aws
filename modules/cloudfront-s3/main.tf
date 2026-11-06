###############################################################################
# 私有 S3 源站 + CloudFront 静态站点
#
# 设计约束：
#   * 桶永远不公开：Block Public Access 四项全开 + BucketOwnerEnforced
#   * CloudFront 只能通过 Origin Access Control（SigV4）读取对象，
#     桶策略用 aws:SourceArn 把它锁定到本模块创建的这一张分发
#   * 桶内容用客户托管、自动轮转的 KMS CMK 加密
#   * 版本控制开启；非当前版本和未完成的分片上传都会被清理
#   * 服务端访问日志写到调用方提供的加密日志桶
#   * 查看器只能走 HTTPS，最低 TLS 1.2；统一注入安全响应头
#   * 不创建自定义域名证书：使用 CloudFront 默认证书，
#     因此 ACM / WAF 所需的 us-east-1 provider 不会进入本模块
###############################################################################

data "aws_partition" "current" {}

locals {
  tags = merge(var.tags, {
    "terraform-module" = "modules/cloudfront-s3"
    # 参见 modules/vpc/locals.tf：AWS 的 tag key 大小写不敏感，
    # 再加一个小写 "environment" 会让 IAM 拒绝整个请求。
    "Environment" = var.environment
  })

  origin_id = "s3-${var.bucket_name}"
}

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

  statement {
    sid    = "AllowCloudFrontToDecrypt"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # CloudFront 只读对象，只需要 Decrypt，不需要 GenerateDataKey。
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_kms_key" "site" {
  description             = "CMK protecting the ${var.bucket_name} static site bucket"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key.json

  tags = merge(local.tags, { Name = "${var.name}-site" })
}

resource "aws_kms_alias" "site" {
  name          = "alias/${var.name}-site"
  target_key_id = aws_kms_key.site.key_id
}

###############################################################################
# 源站桶
###############################################################################

resource "aws_s3_bucket" "site" {
  #checkov:skip=CKV2_AWS_62:This bucket only serves static objects through CloudFront. No consumer reacts to object events, so notifications would add surface without benefit.
  #checkov:skip=CKV_AWS_144:Cross-region replication is an organisation level DR decision. Destination bucket region and KMS grant are owned by the DR account. Tracked in docs/RISKS.md.

  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.site.arn
    }

    bucket_key_enabled = true
  }
}

# 站点内容由发布流程覆盖写入，当前版本不做过期；
# 只清理被替换掉的旧版本和失败的分片上传。
resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    id     = "expire-noncurrent-site-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.site]
}

# 访问日志写到已有的加密日志桶。它的桶策略（logging-s3 模块）已经
# 允许 logging.s3.amazonaws.com 写入 access-logs/ 前缀，
# 所以这里的 target_prefix 必须落在该前缀下面。
resource "aws_s3_bucket_logging" "site" {
  bucket = aws_s3_bucket.site.id

  target_bucket = var.log_bucket_id
  target_prefix = "access-logs/${var.bucket_name}/"
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
      aws_s3_bucket.site.arn,
      "${aws_s3_bucket.site.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # 只允许本模块创建的那一张 CloudFront 分发读取对象。
  # aws:SourceArn 是 OAC 场景下限制混淆代理的关键条件。
  statement {
    sid     = "AllowCloudFrontOAC"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.site.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.bucket.json

  # 策略不能在公共访问被阻断之前生效，
  # 否则一个宽松的策略会有短暂的生效窗口。
  depends_on = [aws_s3_bucket_public_access_block.site]
}

###############################################################################
# CloudFront
###############################################################################

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name}-site-oac"
  description                       = "SigV4 OAC for the ${var.bucket_name} static site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "site" {
  name        = "${var.name}-site-cache"
  comment     = "Static site cache policy: compress, cache for one hour, no cookies or query strings in the key."
  default_ttl = 3600
  max_ttl     = 86400
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# 静态源站不需要向 S3 转发任何查看器信息。
resource "aws_cloudfront_origin_request_policy" "site" {
  name    = "${var.name}-site-origin-request"
  comment = "Forward nothing to the S3 origin; OAC signs the request itself."

  cookies_config {
    cookie_behavior = "none"
  }

  headers_config {
    header_behavior = "none"
  }

  query_strings_config {
    query_string_behavior = "none"
  }
}

# 安全响应头统一在边缘注入，源站桶里不需要额外配置。
# CSP 不在这里设置：它和站点实际加载的资源强相关，
# 由应用侧按自身情况声明，避免一个通用策略把站点打挂。
resource "aws_cloudfront_response_headers_policy" "site" {
  name    = "${var.name}-site-security-headers"
  comment = "HSTS, clickjacking, MIME sniffing and referrer hardening for the static site."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      # preload 需要显式声明才会被浏览器接受；默认的 *.cloudfront.net
      # 主机名本来就在预加载列表之外，这个标记不会改变站点可达性。
      preload  = true
      override = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  #checkov:skip=CKV_AWS_68:AWS WAF for CloudFront must be created in us-east-1, which this module intentionally does not wire up. The site serves immutable static objects only; WAF is tracked as R-31 in docs/RISKS.md.
  #checkov:skip=CKV_AWS_86:CloudFront standard logging is ACL based and cannot write to a BucketOwnerEnforced bucket. Access to the origin is still logged by S3 server access logging; tracked as R-32 in docs/RISKS.md.
  #checkov:skip=CKV_AWS_310:A single-region S3 origin with versioning is the designed recovery model for static content. Origin failover would require a second bucket in another region; tracked as R-33 in docs/RISKS.md.
  #checkov:skip=CKV_AWS_174:This check rejects every distribution that uses the CloudFront default certificate, even with minimum_protocol_version = TLSv1.2_2021. A custom certificate requires an ACM cert in us-east-1 and a domain this repository does not own. Tracked as R-34 in docs/RISKS.md.
  #checkov:skip=CKV_AWS_374:Geo restriction is a business decision for public static content. The site is intentionally reachable worldwide; tracked as R-35 in docs/RISKS.md.
  #checkov:skip=CKV2_AWS_42:See CKV_AWS_174. The default *.cloudfront.net certificate is deliberate; custom domains and ACM are tracked as R-34 in docs/RISKS.md.
  #checkov:skip=CKV2_AWS_47:No WAFv2 web ACL is attached, so the Log4j AMR rule cannot apply. See CKV_AWS_68 and R-31 in docs/RISKS.md.

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name} static site"
  default_root_object = var.default_root_object
  price_class         = var.price_class
  http_version        = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = local.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = local.origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = aws_cloudfront_cache_policy.site.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.site.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
    compress                   = true
  }

  # SPA 深链接在 S3 上找不到对象时会返回 403/404；
  # 交给 index.html，由前端路由接管。
  dynamic "custom_error_response" {
    for_each = var.spa_mode ? [403, 404] : []

    content {
      error_code         = custom_error_response.value
      response_code      = 200
      response_page_path = "/${var.default_root_object}"
      # 不缓存错误响应：SPA 回退后立刻按 index.html 的缓存策略处理。
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = merge(local.tags, { Name = "${var.name}-site" })
}
