# 架构说明

## 1. 总览

每个环境是一个独立的 Terraform 根目录，做四件事：调用 `logging-s3` 模块建加密日志桶，
调用 `vpc` 模块建网络，调用 `bastion` 模块在**公有子网**放一个 SSM 跳板 ASG，
调用 `rds-mysql` 模块在私网子网放一台 MySQL。业务负载不在本仓库范围内，
但通过模块输出去消费网络。

```
                         Internet
                            │
                   ┌────────┴────────┐
                   │   Internet GW   │
                   └────────┬────────┘
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   ┌────┴────┐         ┌────┴────┐         ┌────┴────┐   AZ-a / AZ-c / AZ-d
   │ public  │         │ public  │         │ public  │   map_public_ip_on_launch = false
   │  /20    │         │  /20    │         │  /20    │   └ 跳板机 ASG（0~1 台，t4g.micro）
   └────┬────┘         └────┬────┘         └────┬────┘      SSM 流量经 IGW 直连公网端点
        │  public RT: 0.0.0.0/0 → IGW, ::/0 → IGW
        │                   │                   │
        │   ┌───────────────┴───────────────┐   │
        │   │      S3 Gateway Endpoint      │   │   ← 挂在公网 + 3 张私网路由表
        │   └───────────────────────────────┘   │
        │                   │                   │
   ┌────┴────┐         ┌────┴────┐         ┌────┴────┐
   │ private │         │ private │         │ private │   每 AZ 一张独立私网路由表
   │  /20    │         │  /20    │         │  /20    │   ❌ 没有 0.0.0.0/0
   └────┬────┘         └────┬────┘         └────┬────┘      ::/0 → Egress-only IGW
        │                   │                   │         └ RDS MySQL（单 AZ）
        └───────── 无 NAT 网关 / 无 IPv4 出网 ───┘
```

## 2. 地址规划

所有环境使用 `10.X.0.0/16`，第三段由环境固定（dev=10、staging=20、prod=30）。

| 层级 | AZ-a | AZ-c | AZ-d | 大小 |
| --- | --- | --- | --- | --- |
| public | `10.X.0.0/20` | `10.X.16.0/20` | `10.X.32.0/20` | 各 4094 可用 |
| private | `10.X.128.0/20` | `10.X.144.0/20` | `10.X.160.0/20` | 各 4094 可用 |

公网与私网段刻意留出 `10.X.64.0/18` 的空档，后续要加第三层（如隔离区）不需要重新划段。

### IPv6

- VPC 申请 AWS 生成的 **/56**（`assign_generated_ipv6_cidr_block = true`）
- 每个子网用 `cidrsubnet(vpc_ipv6, 8, netnum)` 切出一个 **/64**，`netnum` 显式配置：
  - 公网 `[0,1,2]`，私网 `[8,9,10]`，中间留空便于扩展
- 公网子网 `::/0 → IGW`；私网子网 `::/0 → Egress-only IGW`（只出不进，免费）
- `assign_ipv6_address_on_creation` 默认 `false`：地址按 ENI 显式分配，避免隐式暴露

## 3. 为什么没有 NAT 网关

这是需求侧的硬约束，也带来真实的代价，必须理解清楚再使用：

**得到什么**

- 私网子网彻底没有到公网 IPv4 的路径，出网泄漏面为零
- 没有每 AZ 的 NAT 固定费用和按 GB 处理费
- 没有 NAT 实例 / 网关本身需要打补丁、监控、限流的运维面

**付出什么**

- 私网实例**无法访问任何公网 IPv4 地址**：不能直接 `yum/apt`、不能访问外网 API、
  不能访问公网 SaaS
- 访问 AWS 服务必须走 VPC 终端节点：
  - **S3**：已通过网关端点覆盖（免费）
  - **其他服务**（SSM、ECR、CloudWatch Logs、STS、KMS…）：需要 Interface 端点，
    每个 AZ 每小时计费 + 数据处理费
- 如果需要访问第三方公网 API，只能：
  1. 打开对应的 Interface 端点（仅限 AWS 服务）
  2. 通过 Transit Gateway 把流量送到集中式 egress VPC（不在本仓库范围）
  3. 在公网子网放代理，但这会把公网暴露面加回来

`interface_endpoint_services` 变量为此预留：默认空，按需填 `["ssm","ssmmessages","ec2messages"]` 之类。
不启用时，私网实例无法使用 SSM Session Manager，也无法拉取 ECR 镜像。

## 4. VPC 终端节点

| 端点 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| S3 | Gateway | 启用 | 挂在公网表 + 3 张私网表；免费 |
| 其他 | Interface | 关闭 | 由 `interface_endpoint_services` 控制 |

三个环境的 `interface_endpoint_services` 都保持为空：跳板机放在公有子网，
SSM Agent 的 443 出站经 IGW 直连 SSM 公网端点，不需要 Interface 端点。
需要私网访问 SSM/ECR 时再按需打开。

S3 网关端点策略只授予数据面动作（`Get/Put/List/Delete`），资源范围是全分区 S3。
这不是授权边界——真正的鉴权由 IAM identity policy 和桶策略决定；端点策略若按单桶收窄，
会让账户里其他工作负载的 S3 访问静默失败，所以这里刻意保持数据面级别。

Interface 端点共用一张安全组：入站只允许 VPC 的 IPv4/IPv6 网段访问 443，出站只回 VPC 网段。

## 5. 安全组模型

1. **default SG 被接管并清空**（`aws_default_security_group` 不带任何规则）。
   任何忘记指定 SG 的 ENI 都不会继承隐式放行规则。
2. **禁止公网入站**由两层保证：
   - 变量校验：`additional_security_groups` 的任一条 ingress 只要包含 `0.0.0.0/0`
     或 `::/0`，`terraform plan` 直接失败并给出明确错误
   - 模块自身写的规则：接口端点 SG 只允许 `var.vpc_cidr` 和 VPC 的 IPv6 段
3. 所有规则必须带 `description`（Checkov CKV_AWS_23）。
4. 出站默认收窄到 VPC 网段。唯一的例外是跳板机安全组的 443 出站
   （公网子网、无 NAT，SSM 和 `dnf` 必须走 IGW），见第 8 节。
5. `map_public_ip_on_launch = false`；只有跳板机在启动模板里显式启用公网 IPv4
   （公有子网，经 IGW 访问 SSM 公网端点），不绑 EIP。

## 6. 日志与审计

| 日志 | 位置 | 加密 | 保留 |
| --- | --- | --- | --- |
| VPC flow logs | CloudWatch `/aws/vpc/<name>/flow-logs` | 专用 CMK（自动轮转） | dev 30 / staging 90 / prod 365 天 |
| VPC flow logs（第二份） | S3 日志桶 `AWSLogs/<account>/` | SSE-KMS | 跟随桶生命周期 |
| S3 访问日志 | 同桶 `access-logs/` | SSE-KMS | 跟随桶生命周期 |
| S3 Object Lock | 未启用 | — | — |

flow log 使用自定义字段格式（含 `tcp-flags`、`pkt-srcaddr`、`pkt-dstaddr`），
聚合间隔 60 秒——安全排查需要近实时，600 秒会明显拖慢定位。

S3 日志桶的访问日志**写到桶自身**。这是刻意选择：审计线索不能依赖另一个可能被误删或误配的桶。

## 7. 模块边界

```
environments/<env>
   ├── module.logging  (modules/logging-s3)  → bucket_arn
   ├── module.vpc      (modules/vpc)         → vpc_id, subnet_ids, ...
   ├── module.bastion  (modules/bastion)     → asg_name, security_group_id, developer_policy_json
   └── module.rds      (modules/rds-mysql)   → endpoint, master_user_secret_arn
```

- `logging-s3` 完全不知道 VPC 的存在，只暴露 `bucket_arn`。
- `vpc` 通过 `flow_logs_s3_bucket_arn` + `flow_logs_s3_enabled` 接收投递目标。
  两个参数必须分开：`count` 只能依赖 plan 期已知值，而桶 ARN 要等到 apply 后才确定。
- 环境层用 `depends_on = [module.logging]` 保证桶策略和 KMS 授权先于 flow log 创建，
  否则 AWS 会在校验 flow log 目标时拒绝。
- `rds` 接收 `bastion` 的安全组 ID 作为唯一入站来源；`bastion` 不反向依赖 `rds`。
- 跳板机不再挂 Secrets Manager 读取权限：实例角色只有 SSM 托管策略。

## 8. 数据库与跳板机

需求约束：RDS 单 AZ、`db.t4g.micro`、私网子网、密码用 Secrets Manager；
跳板机为纯 ASG 方案，公有子网，只做 SSM 端口转发，不做 SSH。

| 项 | 选择 | 说明 |
| --- | --- | --- |
| RDS 引擎 | MySQL 8.4 | `engine_version` 写 major.minor，minor 由 RDS 选择 |
| 实例类 | `db.t4g.micro` | 单 AZ（`multi_az = false`） |
| 子网 | 三张私网子网组成的 DB subnet group | RDS 拒绝少于两个 AZ 的子网组 |
| 公网访问 | `publicly_accessible = false` | 私网路由表本来也没有 IPv4 出网 |
| 密码 | `manage_master_user_password = true` | RDS 在 Secrets Manager 生成并轮转，state 无明文 |
| 加密 | `storage_encrypted = true` | 默认 `aws/rds` 托管密钥；可传 `kms_key_arn` 用 CMK |
| 入站 | 仅跳板机安全组 → TCP/3306 | 没有其他来源，也没有出站规则 |
| 跳板机 | ASG + Launch Template，`t4g.micro`，AL2023 arm64 | 公有子网，自动分配公网 IPv4 |
| 跳板机容量 | min 0 / max 1 / desired 0 | 空闲时零计算、零 EBS 费用 |
| 跳板机入站 | 无任何规则 | 无 SSH、无密钥对、无 22 端口 |
| 跳板机出站 | 全部允许 | 按需求；SSM 的 443 经 IGW 直连公网端点 |
| 跳板机根卷 | gp3、加密、`delete_on_termination = true` | 实例回收即删除，不留存储账单 |
| SSM 访问 | 公网 SSM 端点（经 IGW） | 不创建 ssm / ec2messages / ssmmessages Interface 端点 |

跳板机安全组有一条 `0.0.0.0/0` **出站**规则，这是需求明确要求的“出站全部允许”，
不是遗漏；入站面是零规则，暴露面只剩“谁有权限 StartSession”。公网 IPv4 是
自动分配的，不使用 EIP。

### 通过 SSM 端口转发连 RDS

```bash
# 拉起一台
aws autoscaling set-desired-capacity --region ap-northeast-1 \
  --auto-scaling-group-name <asg> --desired-capacity 1

# 等 SSM Agent 上线
aws ssm describe-instance-information --region ap-northeast-1 \
  --filters Key=PingStatus,Values=Online

# 取实例 ID
aws autoscaling describe-auto-scaling-groups --region ap-northeast-1 \
  --auto-scaling-group-names <asg> \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text

# 本地端口直连 RDS
aws ssm start-session --region ap-northeast-1 --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["13306"]}'

# 缩回 0
aws autoscaling set-desired-capacity --region ap-northeast-1 \
  --auto-scaling-group-name <asg> --desired-capacity 0
```

`AWS-StartPortForwardingSessionToRemoteHost` 由跳板机上的 SSM Agent 直接连接
RDS 端点，本地 DBeaver/Navicat 指向 `127.0.0.1:13306` 即可。

ASG 的 `desired_capacity` 设置了 `lifecycle.ignore_changes`，因此手工
`set-desired-capacity` 之后不会被下一次 `terraform apply` 拉回 0。

### 开发人员权限

模块输出的 `developer_policy_json` 只授予：

- 对带 `Bastion = <环境>-bastion` 标签的实例调用 `ssm:StartSession`；
- 对 `AWS-StartPortForwardingSessionToRemoteHost` 文档调用 `ssm:StartSession`；
- 两条语句都要求 `aws:MultiFactorAuthPresent = true`。

SSM 没有 `ssm:StartPortForwardingSessionToRemoteHost` 这个 IAM action；
端口转发的授权动作是 `ssm:StartSession`，文档 ARN 才是收窄手段。

## 9. 变更流程

```
编辑代码/变量
   │
   ├─ make validate  → fmt + validate（不连 AWS）
   ├─ make test      → 模块 plan 断言（mock provider，不连 AWS）
   ├─ make scan      → checkov + 高危门禁
   ├─ make quotas    → 只读配额预检（需要凭据）
   └─ make plan      → 生成 reports/<env>/plan-<ts>.tfplan
                          │
                          ├─ make check-tags 检查资源标签
                          ├─ 人工对照 docs/PLAN-CHECKLIST.md 逐项核对
                          └─ 审批人手工 apply 该 plan 文件
```

`make verify` 把 validate、test、check-tags、离线 plan 和 checkov 串起来一次跑完。

自动化链路上不存在任何写操作入口。
