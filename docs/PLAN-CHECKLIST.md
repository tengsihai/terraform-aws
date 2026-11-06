# Plan 预期校验点

每次生成 plan 后，对照本文逐项核对。**任何一项不符合都不能进入 apply 审批。**

报告位置：`reports/<env>/plan-<timestamp>.tfplan`（二进制，用于 apply）与
`plan-<timestamp>.txt`（可读，用于评审）。

## 1. 预期汇总

| 环境 | `Plan:` 行 | 说明 |
| --- | --- | --- |
| dev | `Plan: 53 to add, 0 to change, 0 to destroy.` | 不含 S3 flow log |
| staging | `Plan: 54 to add, 0 to change, 0 to destroy.` | 含 `aws_flow_log.s3` |
| prod | `Plan: 54 to add, 0 to change, 0 to destroy.` | 含 `aws_flow_log.s3` |

其中新增的 11 个资源来自 `bastion`（7）和 `rds`（4）。不创建 SSM Interface 端点。

首次部署（state 为空）三个环境都必须是 **0 to change / 0 to destroy**。
出现任何 `destroy` 或 `must be replaced`，立即停止评审。

## 2. 资源清单核对

### logging 模块（10 个）

| 资源 | 关键属性 |
| --- | --- |
| `aws_kms_key.logs` | `enable_key_rotation = true`，`deletion_window_in_days = 7/30/30` |
| `aws_kms_alias.logs` | `alias/<name>-logs` |
| `aws_s3_bucket.logs` | `force_destroy = false` |
| `aws_s3_bucket_versioning.logs` | `status = "Enabled"` |
| `aws_s3_bucket_server_side_encryption_configuration.logs` | `sse_algorithm = "aws:kms"`，`bucket_key_enabled = true` |
| `aws_s3_bucket_public_access_block.logs` | 四项全部 `true` |
| `aws_s3_bucket_ownership_controls.logs` | `BucketOwnerEnforced` |
| `aws_s3_bucket_logging.logs` | `target_prefix = "access-logs/"` |
| `aws_s3_bucket_lifecycle_configuration.logs` | 有 `expiration`、`noncurrent_version_expiration`、`abort_incomplete_multipart_upload` |
| `aws_s3_bucket_policy.logs` | 含 `DenyInsecureTransport` |

### vpc 模块（32 个）

| 资源 | 数量 | 核对点 |
| --- | --- | --- |
| `aws_vpc.this` | 1 | `assign_generated_ipv6_cidr_block = true` |
| `aws_internet_gateway.this` | 1 | |
| `aws_egress_only_internet_gateway.this[0]` | 1 | IPv6 私网出口 |
| `aws_subnet.public` | 3 | `map_public_ip_on_launch = false`，各带 IPv6 /64 |
| `aws_subnet.private` | 3 | `map_public_ip_on_launch = false`，各带 IPv6 /64 |
| `aws_route_table.public` | 1 | |
| `aws_route_table.private` | 3 | 每 AZ 一张 |
| `aws_route.public_ipv4_default` | 1 | → IGW |
| `aws_route.public_ipv6_default[0]` | 1 | `::/0` → IGW |
| `aws_route.private_ipv6_default` | 3 | `::/0` → EIGW |
| `aws_route_table_association.public` | 3 | |
| `aws_route_table_association.private` | 3 | |
| `aws_default_security_group.this` | 1 | **无任何 ingress/egress** |
| `aws_vpc_endpoint.s3[0]` | 1 | Gateway，挂 4 张路由表 |
| `aws_kms_key.flow_logs[0]` | 1 | `enable_key_rotation = true` |
| `aws_kms_alias.flow_logs[0]` | 1 | |
| `aws_cloudwatch_log_group.flow_logs[0]` | 1 | `retention_in_days` 符合环境表 |
| `aws_iam_role.flow_logs[0]` | 1 | 信任 `vpc-flow-logs.amazonaws.com` |
| `aws_iam_role_policy.flow_logs[0]` | 1 | |
| `aws_flow_log.cloudwatch[0]` | 1 | `traffic_type = "ALL"`，`max_aggregation_interval = 60` |
| `aws_flow_log.s3[0]` | staging/prod 各 1 | `log_destination_type = "s3"` |

`data` 源（`aws_iam_policy_document.*`、`aws_partition.current`）在 plan 中显示为
`will be read during apply`，属于正常现象，不计入资源数。

### bastion 模块（7 个）

| 资源 | 核对点 |
| --- | --- |
| `aws_security_group.this` | 描述含 "no ingress"；**不得有任何 ingress 规则** |
| `aws_vpc_security_group_egress_rule.all` | `ip_protocol = "-1"`、`cidr_ipv4 = "0.0.0.0/0"`（需求要求出站全部允许） |
| `aws_iam_role.this` | 信任 `ec2.amazonaws.com` |
| `aws_iam_role_policy_attachment.ssm` | 只挂 `AmazonSSMManagedInstanceCore` |
| `aws_iam_instance_profile.this` | |
| `aws_launch_template.this` | `instance_type = "t4g.micro"`、`image_id` = AL2023 arm64、`http_tokens = "required"`、根卷 `encrypted = true` 且 `delete_on_termination = true`、`network_interfaces.associate_public_ip_address = true`、**无 `key_name`** |
| `aws_autoscaling_group.this` | `min_size = 0`、`max_size = 1`、`desired_capacity = 0`、`vpc_zone_identifier` = 三张公网子网 |

plan 中**不应出现** `aws_instance`、`aws_eip`、`aws_key_pair`、`key_name`
或任何 `aws_vpc_security_group_ingress_rule`。（ASG 的实例是运行时创建的，
不属于 Terraform 资源。）

### rds 模块（4 个）

| 资源 | 核对点 |
| --- | --- |
| `aws_db_subnet_group.this` | 三张私网子网 |
| `aws_security_group.this` | 无 ingress / egress 规则 |
| `aws_vpc_security_group_ingress_rule.mysql[0]` | `referenced_security_group_id` = 跳板机安全组，端口 3306；不得出现 `cidr_ipv4` |
| `aws_db_instance.this` | `engine = "mysql"`、`instance_class = "db.t4g.micro"`、`multi_az = false`、`publicly_accessible = false`、`storage_encrypted = true`、`manage_master_user_password = true` |

## 3. 必须为空的检查

```bash
# 1. 不得出现 NAT 网关资源
#    注意：plan 末尾的 `+ nat_gateway_ids = []` 是模块 output，不是资源，属正常。
grep -c 'aws_nat_gateway\.' reports/<env>/plan-latest.txt        # 期望 0

# 2. 不得出现 0.0.0.0/0 或 ::/0 入站
grep -nE '0\.0\.0\.0/0|::/0' reports/<env>/plan-latest.txt
```

第 2 条预期**恰好命中 6 行**：5 行路由目的网段，加上跳板机唯一的一条公网出站规则。

| 出现次数 | 资源 | 含义 |
| --- | --- | --- |
| 3 | `aws_route.private_ipv6_default["private-0/1/2"]` | 私网 IPv6 `::/0` → Egress-only IGW（只出不进） |
| 1 | `aws_route.public_ipv6_default[0]` | 公网 IPv6 `::/0` → IGW |
| 1 | `aws_route.public_ipv4_default` | 公网 IPv4 `0.0.0.0/0` → IGW |
| 1 | `module.bastion.aws_vpc_security_group_egress_rule.all` | 跳板机出站全部允许（需求要求），**出站** |

用下面这条命令确认除这条出站规则外，没有任何命中落在安全组上：

```bash
grep -nE '0\.0\.0\.0/0|::/0' reports/<env>/plan-latest.txt \
  | grep -viE 'destination_(ipv6_)?cidr_block'
# 期望恰好 1 行：+ cidr_ipv4 = "0.0.0.0/0"
# 用 grep -B30 确认它属于 aws_vpc_security_group_egress_rule.all
```

安全组**入站**规则里不允许出现 `0.0.0.0/0` 或 `::/0`：

```bash
grep -nE 'cidr_ipv4\s*=\s*"0\.0\.0\.0/0"|cidr_ipv6\s*=\s*"::/0"' reports/<env>/plan-latest.txt
# 只允许 all 出站这一条出现在 aws_vpc_security_group_egress_rule.all 下
```

```bash
# 3. 不得出现 destroy / replace
grep -nE 'must be replaced|will be destroyed|forces replacement' reports/<env>/plan-latest.txt  # 应无输出
```

## 4. 逐项校验命令

```bash
ENV=prod
PLAN=reports/${ENV}/plan-latest.txt

# 子网数量：6（3 公网 + 3 私网）
grep -cE '^  # module\.vpc\.aws_subnet\.(public|private)' "$PLAN"

# 私网路由表：3（每 AZ 一张）
grep -cE '^  # module\.vpc\.aws_route_table\.private' "$PLAN"

# S3 网关端点
grep -A3 'aws_vpc_endpoint\.s3' "$PLAN"

# 默认安全组（不得出现 ingress / egress 条目）
grep -A10 'aws_default_security_group\.this' "$PLAN"

# 资源总数以 plan 末尾的 `Plan:` 行为准，不要用 grep 计数
grep -E '^Plan: ' "$PLAN"
```

`grep -cE '^  # '` 得到的是「资源 + data 源 + output」的总行数（dev 为 65，
staging/prod 为 66），不是资源数。资源数一律以 `Plan:` 行为准。

## 5. 危险信号（出现即停止）

| 信号 | 原因 |
| --- | --- |
| `aws_nat_gateway` | 违反禁止 NAT 的硬约束 |
| 安全组**入站**规则含 `0.0.0.0/0` 或 `::/0` | 违反禁止公网入站（跳板机出站全部允许是需求，唯一例外） |
| 任意 `will be destroyed` | 首次部署不应有删除 |
| `force_destroy = true` | 日志桶可能被静默清空 |
| `aws_kms_key` 的 `deletion_window_in_days` 缺失 | 密钥可能被立即删除 |
| `aws_s3_bucket_public_access_block` 任一项为 `false` | 桶可能公开 |
| `aws_db_instance` 的 `publicly_accessible = true` 或 `multi_az = true` | 违反单 AZ / 私网约束 |
| `aws_db_instance` 出现 `password` 或 `master_user_secret` 以外的凭据字段 | 密码不应经过 Terraform |
| `aws_instance`、`aws_key_pair`、`key_name`、`aws_eip` | 跳板机是纯 ASG + SSM，禁止单实例、密钥对、EIP |
| `aws_autoscaling_group` 的 `min_size` / `desired_capacity` 不为 0 | 空闲时会产生计算费用 |
| 资源数显著偏离 53/54 | 代码或变量被意外修改 |
| `aws_account_id` 仍为 `123456789012`（在线 mode） | 占位符，策略会指向错误账户 |

## 6. 负向验证（一次性检查，确认护栏真的生效）

变量校验是「禁止公网入站」的第一道防线，建议定期确认它没有被改坏：

1. 临时取消 `environments/dev/env.tfvars` 末尾 `additional_security_groups` 示例的注释。
2. 执行 `./scripts/plan.sh --offline dev`。
3. 预期结果：plan **失败**，报错包含
   `Ingress rules must not use 0.0.0.0/0 or ::/0`。
4. 恢复注释。

若第 3 步没有失败，说明变量校验被破坏，必须修复后才能继续。

## 7. 幂等性确认

apply 完成后，再次执行 `./scripts/plan.sh <env>`（在线模式），预期：

```
No changes. Your infrastructure matches the configuration.
```

出现非空 diff 说明存在 drift 或配置未收敛，需先查明原因。

## 8. 审批签字项

apply 前由评审人逐条确认：

- [ ] `./scripts/check-quotas.sh`（或 `make quotas`）显示 VPC / IGW / EIP / RDS 配额充足
- [ ] `make check-tags` 三个环境全部 PASS
- [ ] `make test` 的模块测试全部通过
- [ ] `Plan:` 行与预期一致（53 / 54，0 change，0 destroy）
- [ ] 第 3 节的三条 grep 结果符合预期
- [ ] 第 5 节危险信号一条都没有出现
- [ ] `aws_account_id` 已替换为真实账户
- [ ] R-08（state 桶加固）已完成
- [ ] 已确认业务接受「私网无 IPv4 出网」（R-04）或已启用所需 Interface 端点（R-05）
- [ ] plan 文件哈希已记录：`shasum -a 256 reports/<env>/plan-<ts>.tfplan`
