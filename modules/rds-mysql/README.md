# Module: `rds-mysql`

Single-AZ MySQL instance on RDS, placed in private subnets, with the master
password generated and rotated by RDS in AWS Secrets Manager.

## What it creates

| Resource | Notes |
| --- | --- |
| `aws_db_subnet_group` | private subnets only |
| `aws_security_group` | no ingress and **no egress** by default |
| `aws_vpc_security_group_ingress_rule` | one TCP/3306 rule per allowed security group |
| `aws_db_instance` | MySQL, single AZ, `publicly_accessible = false`, encrypted storage |

## Usage

```hcl
module "rds" {
  source = "../../modules/rds-mysql"

  name        = "platform-dev"
  environment = "dev"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnet_ids

  allowed_security_group_ids = [module.bastion.security_group_id]

  deletion_protection = false
  skip_final_snapshot = true

  tags = local.common_tags
}
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | resource name prefix |
| `environment` | `string` | — | `dev` / `staging` / `prod` |
| `vpc_id` | `string` | — | VPC for the security group |
| `subnet_ids` | `list(string)` | — | at least two private subnets in different AZs |
| `allowed_security_group_ids` | `list(string)` | `[]` | groups allowed to reach MySQL |
| `engine_version` | `string` | `8.4` | major.minor lets RDS pick the latest minor |
| `instance_class` | `string` | `db.t4g.micro` | |
| `allocated_storage` | `number` | `20` | GiB, minimum 20 |
| `max_allocated_storage` | `number` | `100` | storage autoscaling ceiling |
| `db_name` | `string` | `appdb` | initial database |
| `master_username` | `string` | `admin` | password comes from Secrets Manager |
| `port` | `number` | `3306` | |
| `backup_retention_period` | `number` | `7` | 1–35 days |
| `deletion_protection` | `bool` | `false` | |
| `skip_final_snapshot` | `bool` | `true` | |
| `apply_immediately` | `bool` | `false` | |
| `kms_key_arn` | `string` | `null` | storage CMK; `null` uses the AWS-managed `aws/rds` key |
| `performance_insights_enabled` | `bool` | `false` | off: unsupported on `db.t4g.micro` |
| `performance_insights_retention_period` | `number` | `7` | 7 or 731 |
| `tags` | `map(string)` | `{}` | |

## Outputs

`instance_id`, `instance_arn`, `endpoint`, `address`, `port`, `database_name`,
`security_group_id`, `master_user_secret_arn`.

The password itself is never an output and never stored in Terraform state.

## Notes

- `manage_master_user_password = true` makes RDS create and rotate the master
  password in Secrets Manager. Callers retrieve it with
  `aws secretsmanager get-secret-value --secret-id <master_user_secret_arn>`.
- The instance security group has no egress rules: the RDS data plane never
  initiates outbound connections.
- `multi_az` is fixed to `false` because the design requires single-AZ
  (`CKV_AWS_157` is suppressed inline). Change the module if that requirement
  changes.
- Performance Insights is **off by default**: `db.t4g.micro` does not support it
  and AWS rejects the combination with `InvalidParameterCombination`. Switch to
  a larger instance class first, then set `performance_insights_enabled = true`
  (retention 7 = free tier, 731 = paid).
- `error` and `slowquery` logs are exported to CloudWatch.
