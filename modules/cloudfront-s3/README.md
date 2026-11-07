# Module: `cloudfront-s3`

Private S3 bucket plus a CloudFront distribution that serves it through an
Origin Access Control (OAC). Use it for static sites, SPAs and single-page
documentation.

## What it creates

| Resource | Purpose |
| --- | --- |
| `aws_kms_key` + `aws_kms_alias` | rotating CMK; CloudFront may decrypt only this distribution's requests |
| `aws_s3_bucket` | private origin bucket |
| `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` |
| `aws_s3_bucket_public_access_block` | all four flags `true` |
| `aws_s3_bucket_versioning` | enabled |
| `aws_s3_bucket_server_side_encryption_configuration` | SSE-KMS with bucket key |
| `aws_s3_bucket_lifecycle_configuration` | noncurrent version expiry + multipart cleanup |
| `aws_s3_bucket_logging` | server access logs into the caller's encrypted log bucket |
| `aws_s3_bucket_policy` | denies non-TLS, allows `s3:GetObject` only from this distribution |
| `aws_cloudfront_origin_access_control` | SigV4 OAC, `signing_behavior = always` |
| `aws_cloudfront_cache_policy` | compression, 1 h default TTL, no viewer data in the key |
| `aws_cloudfront_origin_request_policy` | forwards nothing to S3 |
| `aws_cloudfront_response_headers_policy` | HSTS, `X-Frame-Options: DENY`, nosniff, referrer policy |
| `aws_cloudfront_distribution` | HTTPS-only, TLS 1.2+, IPv6, HTTP/2+HTTP/3 |

## Usage

```hcl
module "site" {
  source = "../../modules/cloudfront-s3"

  name          = "platform-dev"
  environment   = "dev"
  account_id    = "123456789012"
  bucket_name   = "platform-dev-site-123456789012-ap-northeast-1"
  log_bucket_id = module.logging.bucket_id

  spa_mode                    = true
  kms_deletion_window_in_days = 7

  tags = local.common_tags

  # 日志桶的桶策略必须先存在，S3 才能接受日志投递配置。
  depends_on = [module.logging]
}
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | resource name prefix |
| `environment` | `string` | — | `dev` / `staging` / `prod` |
| `account_id` | `string` | — | 12-digit account ID |
| `bucket_name` | `string` | — | globally unique origin bucket name |
| `log_bucket_id` | `string` | — | target for server access logs; must allow `logging.s3.amazonaws.com` |
| `kms_deletion_window_in_days` | `number` | `30` | 7–30 |
| `default_root_object` | `string` | `index.html` | root object |
| `spa_mode` | `bool` | `false` | map 403/404 to the root object with HTTP 200 |
| `price_class` | `string` | `PriceClass_200` | includes Asia, matching the ap-northeast-1 origin |
| `noncurrent_version_retention_days` | `number` | `30` | |
| `force_destroy` | `bool` | `false` | keep `false` outside sandboxes |
| `tags` | `map(string)` | `{}` | |

## Outputs

`bucket_id`, `bucket_arn`, `kms_key_arn`, `distribution_id`,
`distribution_arn`, `distribution_domain_name`, `distribution_hosted_zone_id`.

## Publishing content

The bucket is private and has no public policy. Publish through the AWS CLI
with an IAM principal that holds `s3:PutObject` on the bucket:

```bash
aws s3 sync ./dist "s3://$(terraform output -raw site_bucket_name)" --delete
aws cloudfront create-invalidation \
  --distribution-id "$(terraform output -raw cloudfront_distribution_id)" \
  --paths "/*"
```

## Notes and deliberate gaps

- **No WAF and no CloudFront standard logging.** A CloudFront-scoped WAFv2 web
  ACL must live in `us-east-1`; standard logging is ACL based and cannot write
  to a `BucketOwnerEnforced` bucket. Both are documented in `docs/RISKS.md`
  (R-31, R-32) instead of being silently skipped.
- **No custom domain.** Using the default `*.cloudfront.net` certificate keeps
  the module out of `us-east-1`. Add an ACM certificate in `us-east-1` and an
  `aliases` input before you need a vanity hostname.
- The bucket logs to the shared log bucket, not to itself, so the site bucket
  holds only serveable objects.
