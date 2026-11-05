# Plan 预期校验点

每次生成 plan 后，对照本文逐项核对。**任何一项不符合都不能进入 apply 审批。**

报告位置：`reports/<env>/plan-<timestamp>.tfplan`（二进制，用于 apply）与
`plan-<timestamp>.txt`（可读，用于评审）。

## 1. 预期汇总

| 环境 | `Plan:` 行 | 说明 |
| --- | --- | --- |
| dev | `Plan: 42 to add, 0 to change, 0 to destroy.` | 不含 S3 flow log |
| staging | `Plan: 43 to add, 0 to change, 0 to destroy.` | 含 `aws_flow_log.s3` |
| prod | `Plan: 43 to add, 0 to change, 0 to destroy.` | 含 `aws_flow_log.s3` |

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

## 3. 必须为空的检查

```bash
# 1. 不得出现 NAT 网关资源
#    注意：plan 末尾的 `+ nat_gateway_ids = []` 是模块 output，不是资源，属正常。
grep -c 'aws_nat_gateway\.' reports/<env>/plan-latest.txt        # 期望 0

# 2. 不得出现 0.0.0.0/0 或 ::/0 入站
grep -nE '0\.0\.0\.0/0|::/0' reports/<env>/plan-latest.txt
```

第 2 条预期**恰好命中 5 行**，全部是路由目的网段：

| 出现次数 | 资源 | 含义 |
| --- | --- | --- |
| 3 | `aws_route.private_ipv6_default["private-0/1/2"]` | 私网 IPv6 `::/0` → Egress-only IGW（只出不进） |
| 1 | `aws_route.public_ipv6_default[0]` | 公网 IPv6 `::/0` → IGW |
| 1 | `aws_route.public_ipv4_default` | 公网 IPv4 `0.0.0.0/0` → IGW |

用下面这条命令确认没有任何命中落在安全组规则上（无输出即通过）：

```bash
grep -nE '0\.0\.0\.0/0|::/0' reports/<env>/plan-latest.txt \
  | grep -viE 'destination_(ipv6_)?cidr_block'      # 应无输出
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

`grep -cE '^  # '` 得到的是「资源 + data 源 + output」的总行数（dev 为 54），
不是资源数。资源数一律以 `Plan:` 行为准。

## 5. 危险信号（出现即停止）

| 信号 | 原因 |
| --- | --- |
| `aws_nat_gateway` | 违反禁止 NAT 的硬约束 |
| 安全组规则含 `0.0.0.0/0` 或 `::/0` | 违反禁止公网入站 |
| 任意 `will be destroyed` | 首次部署不应有删除 |
| `force_destroy = true` | 日志桶可能被静默清空 |
| `aws_kms_key` 的 `deletion_window_in_days` 缺失 | 密钥可能被立即删除 |
| `aws_s3_bucket_public_access_block` 任一项为 `false` | 桶可能公开 |
| 资源数显著偏离 42/43 | 代码或变量被意外修改 |
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

- [ ] `Plan:` 行与预期一致（42 / 43，0 change，0 destroy）
- [ ] 第 3 节的三条 grep 结果符合预期
- [ ] 第 5 节危险信号一条都没有出现
- [ ] `aws_account_id` 已替换为真实账户
- [ ] R-08（state 桶加固）已完成
- [ ] 已确认业务接受「私网无 IPv4 出网」（R-04）或已启用所需 Interface 端点（R-05）
- [ ] plan 文件哈希已记录：`shasum -a 256 reports/<env>/plan-<ts>.tfplan`
