# Module: `logging-s3`

Encrypted, versioned, private S3 bucket for log retention. Optionally accepts
VPC flow logs delivered by the `vpc` module.

## What it creates

| Resource | Purpose |
| --- | --- |
| `aws_kms_key` + `aws_kms_alias` | rotating CMK, 30-day deletion window |
| `aws_s3_bucket` | the log archive |
| `aws_s3_bucket_server_side_encryption_configuration` | SSE-KMS with bucket key |
| `aws_s3_bucket_versioning` | enabled |
| `aws_s3_bucket_public_access_block` | all four flags `true` |
| `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` |
| `aws_s3_bucket_policy` | denies every non-TLS request |
| `aws_s3_bucket_logging` | server access logging to `access-logs/` |
| `aws_s3_bucket_lifecycle_configuration` | expiry + noncurrent version expiry + multipart cleanup |

## Usage

```hcl
module "logging" {
  source = "../../modules/logging-s3"

  name                       = "platform-dev"
  environment                = "dev"
  bucket_name                = "platform-dev-logs-123456789012-ap-northeast-1"
  account_id                 = "123456789012"
  log_retention_days         = 90
  enable_vpc_flow_log_delivery = false
}
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | resource name prefix |
| `environment` | `string` | — | `dev` / `staging` / `prod` |
| `bucket_name` | `string` | — | globally unique bucket name |
| `account_id` | `string` | — | 12-digit account ID |
| `kms_deletion_window_in_days` | `number` | `30` | 7–30 |
| `log_retention_days` | `number` | `365` | object expiry |
| `noncurrent_version_retention_days` | `number` | `90` | |
| `enable_vpc_flow_log_delivery` | `bool` | `false` | grants `delivery.logs.amazonaws.com` |
| `force_destroy` | `bool` | `false` | keep `false` outside sandboxes |
| `tags` | `map(string)` | `{}` | |

## Outputs

`bucket_id`, `bucket_arn`, `bucket_domain_name`, `kms_key_arn`, `kms_key_id`.

## Notes

- The bucket logs to itself. This is intentional: the access trail must not
  depend on a second bucket that might be misconfigured or deleted.
- `force_destroy` is `false` by default, so `terraform destroy` on a bucket that
  still contains objects fails loudly instead of silently deleting audit data.
