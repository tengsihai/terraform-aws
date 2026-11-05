# Module: `vpc`

Three-AZ, dual-stack (IPv4 + IPv6) VPC with public and private tiers, an S3
gateway endpoint, encrypted VPC flow logs, and **no NAT gateway**.

## What it creates

| Resource | Count | Notes |
| --- | --- | --- |
| `aws_vpc` | 1 | dual stack, DNS support + hostnames |
| `aws_internet_gateway` | 1 | public tier egress |
| `aws_egress_only_internet_gateway` | 0/1 | IPv6-only egress for the private tier |
| `aws_subnet` | 6 | 3 public + 3 private, one pair per AZ |
| `aws_route_table` | 4 | 1 public + 1 private per AZ |
| `aws_vpc_endpoint` (Gateway) | 0/1 | S3, attached to public + private route tables |
| `aws_vpc_endpoint` (Interface) | 0..n | opt-in via `interface_endpoint_services` |
| `aws_security_group` | 0..n | interface-endpoint SG + `additional_security_groups` |
| `aws_default_security_group` | 1 | stripped of every rule |
| `aws_flow_log` | 1..2 | CloudWatch always, S3 optional |
| `aws_cloudwatch_log_group` + KMS + IAM role | 0/1 | encrypted, 60 s aggregation |

**No NAT gateway and no `0.0.0.0/0` route in the private route tables.** This is
a hard design constraint, not an omission — see
[`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md).

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name        = "platform-dev"
  environment = "dev"
  aws_region  = "ap-northeast-1"
  account_id  = "123456789012"

  vpc_cidr             = "10.10.0.0/16"
  azs                  = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
  public_subnet_cidrs  = ["10.10.0.0/20", "10.10.16.0/20", "10.10.32.0/20"]
  private_subnet_cidrs = ["10.10.128.0/20", "10.10.144.0/20", "10.10.160.0/20"]
}
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | resource name prefix |
| `environment` | `string` | — | `dev` / `staging` / `prod` |
| `aws_region` | `string` | — | region, used for the S3 endpoint service name |
| `account_id` | `string` | — | 12-digit account ID for KMS policies |
| `vpc_cidr` | `string` | — | IPv4 CIDR, `/20` or larger |
| `azs` | `list(string)` | — | exactly three distinct AZs |
| `public_subnet_cidrs` | `list(string)` | — | exactly three CIDRs |
| `private_subnet_cidrs` | `list(string)` | — | exactly three CIDRs |
| `ipv6_enabled` | `bool` | `true` | request an AWS-generated `/56` |
| `public_subnet_ipv6_netnums` | `list(number)` | `[0,1,2]` | `/64` net numbers |
| `private_subnet_ipv6_netnums` | `list(number)` | `[8,9,10]` | `/64` net numbers |
| `map_public_ip_on_launch` | `bool` | `false` | opt-in public IPv4 |
| `assign_ipv6_address_on_creation` | `bool` | `false` | public subnets only |
| `enable_s3_gateway_endpoint` | `bool` | `true` | required without NAT |
| `s3_endpoint_policy_json` | `string` | `null` | endpoint policy override |
| `interface_endpoint_services` | `set(string)` | `[]` | e.g. `["ssm","ecr.api"]` |
| `flow_logs_enabled` | `bool` | `true` | |
| `flow_logs_traffic_type` | `string` | `ALL` | |
| `flow_logs_max_aggregation_interval` | `number` | `60` | 60 or 600 |
| `flow_logs_retention_in_days` | `number` | `365` | |
| `flow_logs_kms_key_arn` | `string` | `null` | reuse an existing CMK |
| `flow_logs_s3_bucket_arn` | `string` | `null` | second destination |
| `flow_logs_s3_enabled` | `bool` | `false` | must be set alongside the ARN; `count` cannot depend on a value that is unknown at plan time |
| `additional_security_groups` | `map(object)` | `{}` | ingress from `0.0.0.0/0` / `::/0` is rejected |
| `tags` | `map(string)` | `{}` | |

## Outputs

`vpc_id`, `vpc_cidr`, `vpc_ipv6_cidr_block`, `availability_zones`,
`public_subnet_ids`, `private_subnet_ids`, `public_subnet_cidrs`,
`private_subnet_cidrs`, `public_route_table_id`, `private_route_table_ids`,
`nat_gateway_ids` (always `[]`), `default_security_group_id`,
`interface_endpoint_security_group_id`, `additional_security_group_ids`,
`s3_gateway_endpoint_id`, `interface_endpoint_ids`, `flow_log_id`,
`flow_log_s3_id`, `flow_log_group_name`.

## Guardrails enforced by the module

1. `additional_security_groups` validation rejects `0.0.0.0/0` and `::/0` in any
   ingress rule — `terraform plan` fails before anything is created.
2. Every security group rule must have a description (`CKV_AWS_23`).
3. `map_public_ip_on_launch` defaults to `false` (`CKV_AWS_130`).
4. The default security group is adopted and emptied (`CKV2_AWS_12`).
5. Flow logs are on by default (`CKV2_AWS_11`).
