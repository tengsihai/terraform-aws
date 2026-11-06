# Module: `bastion`

SSM-only bastion for reaching RDS in private subnets, implemented as a pure Auto
Scaling group: **min 0 / max 1 / desired 0**. It costs nothing while idle; scale
it to 1 when a database session is needed and back to 0 afterwards.

The instance lives in a **public subnet** with an auto-assigned public IPv4 (no
Elastic IP), so the SSM agent reaches the public SSM endpoints through the
Internet Gateway. No Interface VPC endpoints are required. There is no SSH, no
key pair and no inbound rule.

## What it creates

| Resource | Notes |
| --- | --- |
| `aws_security_group` | **no ingress**, all egress allowed |
| `aws_vpc_security_group_egress_rule` | `-1` / `0.0.0.0/0` (required by design) |
| `aws_iam_role` + instance profile | only `AmazonSSMManagedInstanceCore` |
| `aws_launch_template` | AL2023 arm64, `t4g.micro`, IMDSv2, encrypted gp3 root volume with `delete_on_termination = true`, public IPv4 via `network_interfaces` |
| `aws_autoscaling_group` | min 0, max 1, desired 0; `desired_capacity` is ignored by Terraform so manual scaling sticks |

## Usage

```hcl
module "bastion" {
  source = "../../modules/bastion"

  name        = "platform-dev"
  environment = "dev"
  aws_region  = "ap-northeast-1"
  account_id  = "123456789012"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnet_ids

  ami_id        = var.bastion_ami_id
  instance_type = "t4g.micro"

  tags = local.common_tags
}
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | — | resource name prefix |
| `environment` | `string` | — | `dev` / `staging` / `prod` |
| `aws_region` | `string` | — | region for ARNs and CLI commands |
| `account_id` | `string` | — | 12-digit account ID for the instance ARN |
| `vpc_id` | `string` | — | VPC for the security group |
| `subnet_ids` | `list(string)` | — | public subnets for the ASG |
| `ami_id` | `string` | — | AL2023 arm64 AMI |
| `instance_type` | `string` | `t4g.micro` | |
| `root_volume_size` | `number` | `8` | gp3, encrypted, deleted with the instance |
| `min_size` | `number` | `0` | |
| `max_size` | `number` | `1` | |
| `desired_capacity` | `number` | `0` | ignored after creation so manual scaling is not reverted |
| `bastion_tag_key` | `string` | `Bastion` | tag used by the developer IAM policy |
| `tags` | `map(string)` | `{}` | |

## Outputs

`asg_name`, `asg_arn`, `security_group_id`, `launch_template_id`,
`instance_role_arn`, `bastion_tag_key`, `bastion_tag_value`,
`developer_policy_json`, `scale_up_command`, `scale_down_command`,
`instance_id_command`, `ssm_ready_command`.

## Operating the bastion

```bash
# 1. start one instance (compute + EBS billing starts here)
aws autoscaling set-desired-capacity \
  --region ap-northeast-1 \
  --auto-scaling-group-name platform-dev-bastion \
  --desired-capacity 1

# 2. wait until the SSM agent is online (usually 1-2 minutes)
aws ssm describe-instance-information --region ap-northeast-1 \
  --filters Key=PingStatus,Values=Online \
  --query 'InstanceInformationList[].{InstanceId:InstanceId,ComputerName:ComputerName,PingStatus:PingStatus}' \
  --output table

# 3. get the instance ID
aws autoscaling describe-auto-scaling-groups --region ap-northeast-1 \
  --auto-scaling-group-names platform-dev-bastion \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text

# 4. forward a local port straight to the RDS endpoint
aws ssm start-session --region ap-northeast-1 --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["13306"]}'
# then point DBeaver / Navicat at 127.0.0.1:13306

# 5. back to zero cost
aws autoscaling set-desired-capacity \
  --region ap-northeast-1 \
  --auto-scaling-group-name platform-dev-bastion \
  --desired-capacity 0
```

## Developer IAM policy

`developer_policy_json` contains the least-privilege policy to hand to
developers:

- `ssm:StartSession` on instance ARNs **only when** the instance carries
  `Bastion = <bastion_tag_value>`;
- `ssm:StartSession` on the
  `AWS-StartPortForwardingSessionToRemoteHost` document only;
- both statements require `aws:MultiFactorAuthPresent = true`.

There is no IAM action called `ssm:StartPortForwardingSessionToRemoteHost`:
port forwarding is authorized through `ssm:StartSession`, and the document ARN
restriction is what limits the caller to remote-host port forwarding.

The policy also needs a read permission to *find* the instance
(`ssm:DescribeInstanceInformation`, optionally `autoscaling:Describe*` if the
caller runs the commands above). That is intentionally not included, because
the requirement limits the policy to session start; grant it separately if
developers should run discovery themselves.

## Notes

- Public IPv4 addresses are billed per hour whether they are Elastic or
  auto-assigned; this module uses auto-assignment and never creates an EIP.
- No Interface VPC endpoints are needed: SSM traffic leaves through the IGW.
- EBS is billed only while an instance exists; the root volume is encrypted and
  deleted on termination.
