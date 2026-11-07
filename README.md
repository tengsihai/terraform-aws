# terraform-aws — 三可用区 VPC、静态站点与 Lambda 执行角色

标准 Terraform 模块仓库：可复用的 `vpc` / `logging-s3` / `cloudfront-s3` /
`rds-mysql` / `bastion` 模块 + `dev` / `staging` / `prod` 三个环境根目录。

设计约束（硬性）：

- **3 个可用区**，每 AZ 一对公网/私网子网
- **IPv4 + IPv6 双栈**
- **S3 网关终端节点**；私网路由表没有 `0.0.0.0/0` 路由，**不创建 NAT 网关**
- **任何安全组都不允许 `0.0.0.0/0` 或 `::/0` 入站**（`additional_security_groups`
  变量校验层强制拒绝）
- **两种 S3 桶都是私有的**：日志桶和站点桶都开启 Block Public Access、
  `BucketOwnerEnforced`、版本控制和 SSE-KMS（客户托管、自动轮转的 CMK）
- **站点通过 CloudFront OAC 读取**，不启用 S3 静态网站托管，桶策略用
  `aws:SourceArn` 锁定到本环境的分发
- **RDS 只在私网子网、单 AZ、公网不可达**，主用户密码由 Secrets Manager 托管和轮转
- **跳板机是纯 ASG（desired=0）**，放在公有子网，经 IGW 直连 SSM 公网端点；
  仅通过 SSM 端口转发访问，无 SSH、无密钥对、无 EIP、无入站规则
- **外部流水线一个工程一个部署角色**，不共用本仓库的基础设施写角色

> 本仓库的本地脚本不提供 apply/destroy 入口。日常变更的执行路径是 GitHub Actions
> 的 `apply.yml`：评审 plan 工件 → 合并 PR → 审批 → 应用该 plan。
> `bootstrap/` 是例外：它由管理员用一次性凭据手动 apply。详见
> [docs/CI-CD.md](docs/CI-CD.md)。

---

## 分支模型

**分支即环境**，合并到哪个分支就部署哪个环境：

| 分支 | 作用 |
| --- | --- |
| 功能分支（`feat/*`、`fix/*`…） | 开发用，PR 的目标是环境分支 |
| `dev` / `staging` / `prod` | 环境分支，**合并进去就触发该环境的 plan → apply** |
| `main` | 发布后归档，不参与部署 |

```
feat/xxx ──PR──► dev ──PR──► staging ──PR──► prod ──PR──► main（归档）
                 │           │              │
                 └ 部署 dev   └ 部署 staging  └ 部署 prod
```

每个环境分支都受 ruleset 保护：必须走 PR、必须过全部 required status checks、
不允许直接 push。仓库变量 `TF_ENVIRONMENTS` 决定哪些环境允许自动部署（默认 `["dev"]`）。

## 目录结构

```
.
├── .checkov.yaml                  # Checkov 配置（无全局豁免，豁免全部内联在代码里）
├── .tflint.hcl                    # tflint 规则与 AWS 插件
├── .github/
│   ├── workflows/
│   │   ├── pr-checks.yml          # fmt · validate · tflint · shellcheck/actionlint · checkov · module test
│   │   ├── plan.yml               # 只读 plan → 工件 + PR 粘性评论
│   │   ├── apply.yml              # 合并到环境分支即部署：应用该分支上已评审的 plan
│   │   └── drift-detection.yml    # 定时只读 plan，发现漂移开 issue
│   ├── actions/terraform-init/    # OIDC 换角色 + S3 backend init
│   ├── scripts/render-plan-summary.py
│   └── dependabot.yml
├── bootstrap/                     # 一次性：OIDC + plan/apply + 每个工程一个部署角色
├── Makefile
├── modules/
│   ├── vpc/                       # 三 AZ 网络、双栈、S3 端点、flow logs
│   ├── logging-s3/                # 加密日志桶
│   ├── cloudfront-s3/             # 私有 S3 源站 + CloudFront（OAC）静态站点
│   ├── rds-mysql/                 # 单 AZ MySQL + Secrets Manager 密码
│   └── bastion/                   # 公有子网 SSM 跳板机（纯 ASG，desired=0）
├── environments/
│   ├── dev/                       # 10.10.0.0/16
│   ├── staging/                   # 10.20.0.0/16
│   └── prod/                      # 10.30.0.0/16
│       ├── versions.tf  backend.tf  providers.tf
│       ├── variables.tf  main.tf    outputs.tf
│       ├── env.tfvars             # 环境差异值
│       └── backend.hcl.example    # 远端 state 模板
├── scripts/                       # validate / plan / scan / check-tags / check-quotas
└── docs/
    ├── ARCHITECTURE.md
    ├── CI-CD.md
    ├── RISKS.md
    └── PLAN-CHECKLIST.md
```

## 模块

| 模块 | 作用 | 关键资源 |
| --- | --- | --- |
| `vpc` | 三 AZ 双栈网络 | VPC、IGW、Egress-only IGW、6 子网、路由表、S3 Gateway 端点、可选 Interface 端点、default SG 清空、附加安全组、CloudWatch/S3 flow logs |
| `logging-s3` | 加密日志桶 | 轮转 CMK、版本控制、Block Public Access、桶策略 Deny 非 TLS、自记录访问日志、生命周期 |
| `cloudfront-s3` | 静态站点 | 私有源站桶、SSE-KMS、OAC、缓存/源站请求/响应头策略、CloudFront 分发、SPA 回退 |
| `rds-mysql` | 单 AZ MySQL | DB subnet group、零 egress 安全组、按安全组授权的 3306 入站、`manage_master_user_password = true` |
| `bastion` | SSM 跳板机 | 零入站安全组、全出站、实例角色（仅 `AmazonSSMManagedInstanceCore`）、Launch Template、ASG min 0 / max 1 / desired 0 |

## 环境差异

| 项 | dev | staging | prod |
| --- | --- | --- | --- |
| VPC CIDR | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| AZ | ap-northeast-1a / 1c / 1d | 同左 | 同左 |
| 公网子网 | `10.X.0.0/20`, `.16.0/20`, `.32.0/20` | 同左 | 同左 |
| 私网子网 | `10.X.128.0/20`, `.144.0/20`, `.160.0/20` | 同左 | 同左 |
| IPv6 | 启用（AWS 分配 /56） | 启用 | 启用 |
| VPC flow logs 保留 | 30 天 | 90 天 | 365 天 |
| S3 日志桶保留 | 90 天 | 180 天 | 365 天 |
| flow logs 投递到 S3 | 否 | 是 | 是 |
| KMS 待删除窗口（日志桶 / 站点桶） | 7 天 | 30 天 | 30 天 |
| RDS 实例类 | db.t4g.micro（单 AZ） | 同左 | 同左 |
| RDS 删除保护 | 否 | 是 | 是 |
| RDS 最终快照 | 跳过 | 保留 | 保留 |
| 跳板机实例类 | t4g.micro | 同左 | 同左 |
| 跳板机容量 | ASG min 0 / max 1 / desired 0 | 同左 | 同左 |
| SSM Interface 端点 | 不创建 | 不创建 | 不创建 |
| Secrets Manager Interface 端点 | 创建 | 不创建 | 不创建 |
| SPA 回退（403/404 → index.html） | 是 | 是 | 是 |
| 预期 plan（空 state） | 77 add | 76 add | 76 add |

`staging` / `prod` 的 `env.tfvars` 里 `aws_account_id` 仍是占位符，接入真实账户前必须替换。

## 静态站点（CloudFront + S3）

```
浏览器 ── HTTPS (TLS 1.2+) ──► CloudFront（OAC + 安全响应头）
                                   │  SigV4，只允许本分发
                                   ▼
                             私有 S3 桶（SSE-KMS，Block Public Access 全开）
                                   │  S3 服务端访问日志
                                   ▼
                             加密日志桶 access-logs/
```

- 源站桶没有公有读策略，也没有 `aws_s3_bucket_website_configuration`；所有读取都走
  CloudFront OAC，桶策略和 KMS 策略都用 `aws:SourceArn` 锁定到本环境的分发
- 查看器强制 `redirect-to-https`，最低 `TLSv1.2_2021`
- 边缘统一注入 HSTS、`X-Frame-Options: DENY`、nosniff、referrer policy
- `site_spa_mode = true`：S3 的 403/404 回退到 `index.html`，响应码 200，
  `ErrorCachingMinTTL = 0`
- 使用 CloudFront 默认 `*.cloudfront.net` 证书，不引入 `us-east-1` 的 ACM/WAF provider。
  WAF、CloudFront 标准日志、自定义域名分别见 [docs/RISKS.md](docs/RISKS.md) 的
  R-31 / R-32 / R-34

发布内容（需要有站点桶写权限的流水线；本仓库的 `react-aws-deploy-<env>` 就是这个角色）：

```bash
aws s3 sync ./dist "s3://$(terraform -chdir=environments/dev output -raw site_bucket_name)" --delete
aws cloudfront create-invalidation \
  --distribution-id "$(terraform -chdir=environments/dev output -raw cloudfront_distribution_id)" \
  --paths "/*"
```

相关输出：`site_bucket_name`、`site_bucket_arn`、`site_kms_key_arn`、
`cloudfront_distribution_id`、`cloudfront_distribution_arn`、
`cloudfront_domain_name`、`cloudfront_hosted_zone_id`。

## Lambda 执行角色与外部流水线

环境根目录创建并管理一个 Lambda execution role，供外部流水线部署的函数共用：

- 名称：`<project>-<env>-lambda-execution`
- 信任：`lambda.amazonaws.com`
- 托管策略：`AWSLambdaBasicExecutionRole`、`AWSLambdaVPCAccessExecutionRole`、
  `AWSXRayDaemonWriteAccess`
- 内联策略：只允许 `secretsmanager:GetSecretValue`，资源为 RDS 托管的主用户密钥
- 输出：`lambda_execution_role_arn`

`bootstrap/` 为每个工程创建独立部署角色，互不共用权限：

| 角色 | 信任的仓库 | 权限 |
| --- | --- | --- |
| `terraform-plan` | `terraform-aws` | 只读 + state 读写 |
| `terraform-apply-<env>` | `terraform-aws` | 基础设施写权限，挂权限边界 |
| `react-aws-deploy-<env>` | `react-aws` | 站点桶 List/Get/Put/Delete、CloudFront invalidation、站点 CMK 的 GenerateDataKey/Decrypt |
| `lambda-aws-deploy-<env>` | `lambda-aws` | SAM/CloudFormation、Lambda、API Gateway、产物桶；`iam:PassRole` 仅限执行角色 ARN |
| `rds-migrate-<env>` | `mysql-aws` | 读 RDS 托管主用户密钥、SSM 端口转发到跳板机、临时调整跳板机 ASG 容量 |

外部流水线的约定：

- `react-aws` 用 `react-aws-deploy-<env>` 上传静态资源并失效缓存
- `lambda-aws` 用 `lambda-aws-deploy-<env>` 执行 `sam deploy`；模板的 `Role` 必须是
  `lambda_execution_role_arn` 的完整 ARN，函数的 `VpcConfig` 用
  `lambda_security_group_id` 和私网子网
- `mysql-aws` 用 `rds-migrate-<env>` 执行 Flyway 迁移；角色由 `bootstrap/` 创建，
  不再在业务仓库里维护 IAM 脚本
- 任何流水线都不应使用 `terraform-apply-<env>`，该角色只信任本仓库

## 数据库与跳板机

```
本地 DBeaver/Navicat ── SSM 端口转发 ──► 跳板机 ASG（t4g.micro，公有子网，0~1 台）
                                              │   443 出站经 IGW 直连 SSM 公网端点
                                              │ TCP/3306
                                              ▼
                                          RDS MySQL 8.4 (db.t4g.micro, 单 AZ, 私网子网)
```

- **RDS**：`manage_master_user_password = true`，Terraform 不接触明文密码。
  Security Group 有两条 3306 入站规则（跳板机、Lambda），没有出站规则；
  `publicly_accessible = false`、单 AZ。
- **跳板机**：纯 ASG，`min=0 / max=1 / desired=0`，空闲时无实例、无计算和 EBS 费用。
  启动模板为 AL2023 arm64 + `t4g.micro`，根卷加密且 `delete_on_termination = true`。
- **公有子网 + 自动分配公网 IPv4（不绑 EIP）**：SSM Agent 的 443 出站经 IGW
  直连 SSM 公网端点，因此不创建 ssm / ec2messages / ssmmessages Interface 端点。
- **没有 SSH、密钥对**：安全组零入站规则，唯一访问路径是 SSM Session Manager。

操作跳板机：

```bash
# 1. 拉起 1 台（开始计费）
aws autoscaling set-desired-capacity --region ap-northeast-1 \
  --auto-scaling-group-name platform-dev-bastion --desired-capacity 1

# 2. 等待 SSM Agent 上线
aws ssm describe-instance-information --region ap-northeast-1 \
  --filters Key=PingStatus,Values=Online \
  --query 'InstanceInformationList[].{InstanceId:InstanceId,ComputerName:ComputerName,PingStatus:PingStatus}' \
  --output table

# 3. 取实例 ID
aws autoscaling describe-auto-scaling-groups --region ap-northeast-1 \
  --auto-scaling-group-names platform-dev-bastion \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text

# 4. 本地 13306 → RDS:3306
aws ssm start-session --region ap-northeast-1 --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["13306"]}'

# 5. 用完缩回 0
aws autoscaling set-desired-capacity --region ap-northeast-1 \
  --auto-scaling-group-name platform-dev-bastion --desired-capacity 0
```

`terraform output` 会直接给出以上命令：`bastion_asg_name`、
`bastion_security_group_id`、`bastion_scale_up_command`、
`bastion_scale_down_command`、`bastion_instance_id_command`、
`bastion_ssm_ready_command`、`bastion_port_forward_command`、
`bastion_developer_policy_json`。

`bastion_developer_policy_json` 是最小权限策略：只允许 `ssm:StartSession`，
通过 `ssm:resourceTag/Bastion` 限定到本环境的实例，通过文档 ARN 限定只能用
`AWS-StartPortForwardingSessionToRemoteHost`，并要求 MFA。

## 快速开始

```bash
make validate        # terraform fmt -check + 三个环境 validate
make test            # 模块测试（terraform test + mock provider，不连 AWS）
make scan            # checkov 全量扫描 + 高危门禁
make plan            # 三个环境 plan（无凭据时自动离线）
make check-tags      # 离线 plan 后检查每个资源的基础标签
make quotas          # 只读的 VPC/IGW/EIP/RDS 配额预检（需要 AWS 凭据）
make verify          # validate + 模块测试 + 标签 + 离线 plan + checkov

make apply           # 故意报错退出：本地不提供 apply 入口
```

离线模式（本机没有 AWS 凭据时）：

```bash
./scripts/plan.sh --offline prod
```

离线 plan 把 provider 的凭据校验全部跳过，验证的是**配置图是否自洽**，
不代表真实账户里会发生什么。详见 [docs/RISKS.md](docs/RISKS.md) R-02。

## 审批与执行（apply）

**合并 PR 就是审批。** 变更只有一条路径：

1. 提交 PR 到目标环境分支 → 全部 required status checks 必须全绿。
2. 由人合并。
3. 合并后自动：`plan.yml` 在该环境分支上出权威 plan 工件 → `apply.yml` 被该 plan
   完成自动触发。
4. apply 前机器校验：plan run 成功、来自 `plan.yml`、是该环境分支 push 产生的、
   提交仍是 HEAD、工件 SHA-256 一致、plan 未超过 24 小时、`applyable=true`、
   账户 ID 与 `env.tfvars` 一致。
5. 执行 `terraform apply <评审过的 tfplan>` —— **不重新 plan**。

`bootstrap/` 不在这条链路里，必须由管理员手动 apply。角色与 OIDC 配置见
[bootstrap/README.md](bootstrap/README.md)。

## CI 门禁

| 阶段 | 失败条件 |
| --- | --- |
| `terraform fmt -check` | 任何格式漂移 |
| `terraform validate` | 任一环境或 bootstrap 校验失败 |
| `terraform test` | `bastion` / `rds-mysql` / `cloudfront-s3` 模块测试断言失败 |
| 标签合规 | 任一可打标签资源缺少 `Project` / `Environment` / `ManagedBy` / `Repository` |
| `tflint` | provider 用法、未使用声明、AWS 规则违规 |
| `shellcheck` / `actionlint` | 脚本或 workflow 的静态错误 |
| `checkov` | 命中 `scripts/checkov_gate.py` 中的高危规则，或报告 CRITICAL/HIGH |
| account ID 校验 | `env.tfvars` 的账户 ID 与所假设角色不一致 |

每个豁免都以 `#checkov:skip=<check-id>:<理由>` 内联在被豁免的资源上，仓库里没有全局 skip 列表。

## 安全控制一览

| 控制 | 实现 |
| --- | --- |
| 禁止公网入站 | `additional_security_groups` 变量校验拒绝 `0.0.0.0/0`、`::/0` |
| default SG 无规则 | `aws_default_security_group` 接管并清空 |
| 禁止 NAT | 私网路由表不创建 `0.0.0.0/0` 路由，模块无 `aws_nat_gateway` |
| S3 私有访问 | S3 网关端点挂到公网 + 私网路由表 |
| 日志桶加密 | SSE-KMS（CMK 自动轮转）+ bucket key |
| 站点桶加密 | SSE-KMS（CMK 自动轮转）+ bucket key；CloudFront 仅在 `aws:SourceArn` 匹配时分发可 Decrypt |
| S3 桶防公开 | 两种桶都开启 Block Public Access 四项 + `BucketOwnerEnforced` |
| S3 桶审计 | 日志桶自记录访问日志；站点桶的访问日志写入日志桶 |
| 传输加密 | S3 桶策略 Deny `aws:SecureTransport=false`；CloudFront 强制 HTTPS |
| 网络审计 | VPC flow logs，`ALL`，60s 聚合，KMS 加密 |
| 公网 IP | `map_public_ip_on_launch = false`；只有跳板机在启动模板里显式启用公网 IPv4，无 EIP |
| 数据库不暴露 | RDS 在私网子网，`publicly_accessible = false`，入站只来自跳板机与 Lambda 安全组 |
| Lambda 出站收窄 | Lambda 安全组零入站，只有 3306 / 443 两条出站，目标都是本环境 `vpc_cidr` |
| 数据库凭据 | Secrets Manager 托管主用户密码（自动轮转），Terraform state 无明文 |
| 数据库登录面 | 跳板机零入站规则；端口转发全部走 SSM Session Manager |
| Lambda 执行角色 | 只有 CloudWatch Logs、X-Ray、VPC ENI 和读取 RDS 主用户密钥的权限 |
| 流水线隔离 | 一个工程一个部署角色，`terraform-apply-<env>` 只信任本仓库 |
| 实例角色最小权限 | 跳板机只挂 `AmazonSSMManagedInstanceCore` |

## 销毁与恢复

本仓库没有自动 destroy 入口。销毁同样使用评审过的 destroy plan：

```bash
# 1. 先删除外部流水线创建的、仍持有 VPC ENI 的 Lambda stack
aws cloudformation delete-stack --stack-name <lambda-aws-stack>
aws cloudformation wait stack-delete-complete --stack-name <lambda-aws-stack>

# 2. 版本控制桶必须先清空（current + noncurrent + delete markers）
#    否则 aws_s3_bucket 的 force_destroy = false 会让 destroy 失败

# 3. 生成并应用 destroy plan（管理员凭据）
terraform -chdir=environments/dev plan -destroy -var-file=env.tfvars -out=/tmp/dev-destroy.tfplan
terraform -chdir=environments/dev apply /tmp/dev-destroy.tfplan
```

销毁 `environments/dev` 会删除 VPC、RDS、站点/日志桶、CloudFront、Interface 端点和
KMS 密钥（密钥进入 `PendingDeletion`，7/30 天后彻底删除）。`bootstrap/` 的 OIDC、
部署角色、权限边界和 Terraform state 桶不受影响，恢复时只需要重新 apply
`environments/<env>`，再重新部署外部流水线的 stack。

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 拓扑、地址规划、IPv6、无 NAT 取舍
- [docs/CI-CD.md](docs/CI-CD.md) — 流水线、OIDC、审批门禁、排障
- [docs/RISKS.md](docs/RISKS.md) — 风险清单与缓解措施
- [docs/PLAN-CHECKLIST.md](docs/PLAN-CHECKLIST.md) — plan 预期校验点与危险信号
- [modules/cloudfront-s3/README.md](modules/cloudfront-s3/README.md) — 私有 S3 源站、OAC 与发布方式
- [modules/rds-mysql/README.md](modules/rds-mysql/README.md) — 单 AZ MySQL 与 Secrets Manager 密码
- [modules/bastion/README.md](modules/bastion/README.md) — 跳板机的访问方式与安全组
- [bootstrap/README.md](bootstrap/README.md) — OIDC provider、plan/apply 角色与每工程部署角色
