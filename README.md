# terraform-aws — 三可用区 VPC 网络基础设施

标准 Terraform 模块仓库：可复用的 `vpc` / `logging-s3` / `rds-mysql` / `bastion` /
`cloudfront-s3` 模块 + `dev` / `staging` / `prod` 三个环境根目录。

设计约束（硬性）：

- **3 个可用区**，每 AZ 一对公网/私网子网
- **IPv4 + IPv6 双栈**
- **S3 网关终端节点**
- **不创建 NAT 网关**，私网路由表没有 `0.0.0.0/0` 路由
- **任何安全组都不允许 `0.0.0.0/0` 或 `::/0` 入站**（变量校验层强制拒绝）
- **S3 日志桶开启服务端加密**（SSE-KMS + 轮转 CMK）
- **RDS 只在私网子网、单 AZ、公网不可达**，主用户密码由 Secrets Manager 托管和轮转
- **跳板机是纯 ASG（desired=0）**，放在公有子网，经 IGW 直连 SSM 公网端点；
  仅通过 SSM 端口转发访问，无 SSH、无密钥对、无 EIP、无入站规则

> 本地脚本不提供 apply 入口。唯一的执行路径是 GitHub Actions 的 `apply.yml`：
> 人工触发 → GitHub Environment 审批 → 执行已评审的 plan 文件。详见 [docs/CI-CD.md](docs/CI-CD.md)。

---

## 分支模型

**分支即环境**，合并到哪个分支就部署哪个环境：

| 分支 | 作用 |
| --- | --- |
| 功能分支（`feat/*`、`fix/*`…） | 开发用，PR 的目标是环境分支 |
| `dev` / `staging` / `prod` | 环境分支，**合并进去就触发该环境的 plan → apply** |
| `main` | 发布后归档，不参与部署（只在发布时接收 `prod` 的合并） |

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
│   │   ├── pr-checks.yml          # fmt · validate · tflint · shellcheck/actionlint · checkov
│   │   ├── plan.yml               # 只读 plan → 工件 + PR 粘性评论
│   │   ├── apply.yml              # 合并到环境分支即部署：应用该分支上已评审的 plan
│   │   └── drift-detection.yml    # 定时只读 plan，发现漂移开 issue
│   ├── actions/terraform-init/    # OIDC 换角色 + S3 backend init
│   ├── scripts/render-plan-summary.py
│   └── dependabot.yml
├── bootstrap/                     # 一次性：GitHub OIDC provider + plan/apply IAM 角色
├── Makefile
├── modules/
│   ├── vpc/                       # 网络模块
│   │   ├── main.tf                #   VPC / IGW / Egress-only IGW
│   │   ├── locals.tf
│   │   ├── subnets.tf             #   6 个子网，IPv6 /64 切分
│   │   ├── routing.tf             #   公网/私网路由表（私网无 NAT 路由）
│   │   ├── endpoints.tf           #   S3 网关端点 + 可选 Interface 端点
│   │   ├── security-groups.tf     #   default SG 清空 + 附加 SG
│   │   ├── flow-logs.tf           #   CloudWatch / S3 flow logs
│   │   ├── variables.tf / outputs.tf / versions.tf
│   │   └── README.md
│   ├── logging-s3/                # 加密日志桶模块
│   ├── cloudfront-s3/             # 私有 S3 源站 + CloudFront（OAC）静态站点
│   │   ├── main.tf                #   KMS / 桶 / 桶策略 / OAC / 缓存与响应头策略 / 分发
│   │   ├── variables.tf / outputs.tf / versions.tf
│   │   ├── tests/cloudfront_s3.tftest.hcl
│   │   └── README.md
│   ├── rds-mysql/                 # 单 AZ MySQL + Secrets Manager 密码
│   │   ├── main.tf                #   子网组 / 安全组 / mysql 入站规则 / db_instance
│   │   ├── variables.tf / outputs.tf / versions.tf
│   │   └── README.md
│   └── bastion/                   # 公有子网 SSM 跳板机（纯 ASG，desired=0）
│       ├── main.tf                #   SG / IAM / Launch Template / ASG / 开发人员策略
│       ├── variables.tf / outputs.tf / versions.tf
│       └── README.md
├── environments/
│   ├── dev/                       # 10.10.0.0/16
│   ├── staging/                   # 10.20.0.0/16
│   └── prod/                      # 10.30.0.0/16
│       ├── versions.tf  backend.tf  providers.tf
│       ├── variables.tf  main.tf    outputs.tf
│       ├── env.tfvars             # 环境差异值
│       └── backend.hcl.example    # 远端 state 模板
├── scripts/
│   ├── lib.sh                     # 公共函数 + apply 拦截
│   ├── validate.sh                # fmt -check + validate（3 环境 + bootstrap）
│   ├── plan.sh                    # 本地 plan（自动 offline / online）
│   ├── scan.sh                    # checkov + 高危门禁
│   └── checkov_gate.py            # 显式高危规则清单
└── docs/
    ├── ARCHITECTURE.md            # 架构说明
    ├── CI-CD.md                   # 流水线、审批、OIDC 配置
    ├── RISKS.md                   # 风险清单
    └── PLAN-CHECKLIST.md          # plan 预期校验点
```

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
| KMS 待删除窗口 | 7 天 | 30 天 | 30 天 |
| RDS 实例类 | db.t4g.micro（单 AZ） | 同左 | 同左 |
| RDS 删除保护 | 否 | 是 | 是 |
| RDS 最终快照 | 跳过 | 保留 | 保留 |
| 跳板机实例类 | t4g.micro | 同左 | 同左 |
| 跳板机容量 | ASG min 0 / max 1 / desired 0 | 同左 | 同左 |
| 跳板机登录方式 | 公有子网 + IGW 直连 SSM 公网端点（无 SSH、无密钥对、无 EIP） | 同左 | 同左 |
| SSM Interface 端点 | 不创建 | 不创建 | 不创建 |
| Secrets Manager Interface 端点 | 创建 | 不创建 | 不创建 |
| 静态站点桶 | `<prefix>-site-<account>-<region>` | 同左 | 同左 |
| CloudFront 价格等级 | PriceClass_200 | 同左 | 同左 |
| SPA 回退（403/404 → index.html） | 是 | 是 | 是 |
| 预期 plan | 77 add | 76 add | 76 add |

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

- 源站桶**没有**公有读策略，也不启用 S3 静态网站托管；所有读取都经过
  CloudFront OAC，桶策略用 `aws:SourceArn` 锁定到本环境的分发。
- 使用 CloudFront 默认的 `*.cloudfront.net` 证书，因此模块不需要
  `us-east-1` 的 ACM/WAF provider；自定义域名与 WAF 见 R-31 / R-34。
- `site_spa_mode = true` 时，S3 的 403/404 会回退到 `index.html`（HTTP 200），
  适合前端路由。

发布内容（需对桶有 `s3:PutObject` 权限）：

```bash
# 输出名见 terraform output
aws s3 sync ./dist "s3://$(terraform -chdir=environments/dev output -raw site_bucket_name)" --delete
aws cloudfront create-invalidation \
  --distribution-id "$(terraform -chdir=environments/dev output -raw cloudfront_distribution_id)" \
  --paths "/*"
```

相关输出：`site_bucket_name`、`cloudfront_distribution_id`、
`cloudfront_domain_name`、`cloudfront_hosted_zone_id`。

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
- **跳板机**：纯 ASG 方案。`min=0 / max=1 / desired=0`，空闲时没有实例，
  不产生计算和 EBS 费用。启动模板为 AL2023 arm64 + `t4g.micro`，
  根卷加密且 `delete_on_termination = true`。
- **公有子网 + 自动分配公网 IPv4（不绑 EIP）**：SSM Agent 的 443 出站经 IGW
  直连 SSM 公网端点，因此**不创建** ssm / ec2messages / ssmmessages Interface 端点。
- **没有 SSH、密钥对**：安全组零入站规则，唯一访问路径是 SSM Session Manager。
- 实例角色只挂 `AmazonSSMManagedInstanceCore`，没有 Secrets Manager 权限；
  数据库密码请用自己的 IAM 权限读取。

### 操作跳板机

```bash
# 1. 拉起 1 台（开始计费）
aws autoscaling set-desired-capacity --region ap-northeast-1 \
  --auto-scaling-group-name platform-dev-bastion --desired-capacity 1

# 2. 等待 SSM Agent 上线（通常 1-2 分钟）
aws ssm describe-instance-information --region ap-northeast-1 \
  --filters Key=PingStatus,Values=Online \
  --query 'InstanceInformationList[].{InstanceId:InstanceId,ComputerName:ComputerName,PingStatus:PingStatus}' \
  --output table

# 3. 取实例 ID
aws autoscaling describe-auto-scaling-groups --region ap-northeast-1 \
  --auto-scaling-group-names platform-dev-bastion \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text

# 4. 本地 13306 → RDS:3306；DBeaver/Navicat 连 127.0.0.1:13306
aws ssm start-session --region ap-northeast-1 --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["13306"]}'

# 5. 用完缩回 0（实例和根卷一起删除，停止计费）
aws autoscaling set-desired-capacity --region ap-northeast-1 \
  --auto-scaling-group-name platform-dev-bastion --desired-capacity 0
```

`terraform output` 会直接给出以上命令：
`bastion_asg_name`、`bastion_security_group_id`、`bastion_scale_up_command`、
`bastion_scale_down_command`、`bastion_instance_id_command`、
`bastion_ssm_ready_command`、`bastion_port_forward_command`、
`bastion_developer_policy_json`。

### 开发人员 IAM 策略

`bastion_developer_policy_json` 输出一份最小权限策略：只允许
`ssm:StartSession`，通过 `ssm:resourceTag/Bastion` 限定到本环境的跳板机实例，
通过文档 ARN 限定只能用 `AWS-StartPortForwardingSessionToRemoteHost`，
并要求 MFA。注意 SSM 并没有名为
`ssm:StartPortForwardingSessionToRemoteHost` 的 IAM action —— 端口转发统一用
`ssm:StartSession` 授权，文档 ARN 才是限制点。

成本提示：跳板机空闲时为零成本；运行期间按 t4g.micro + 8 GiB gp3 + 公网 IPv4
计费（公网 IPv4 与是否绑定 EIP 无关）。跳板机不用任何 Interface 端点；
Interface 端点只有 dev 的 `secretsmanager` 一个（按 AZ-hour 计费）。


## 快速开始

```bash
make validate        # terraform fmt -check + 三个环境 validate
make test            # 模块测试（terraform test + mock provider，不连 AWS）
make scan            # checkov 全量扫描 + 高危门禁
make plan            # 三个环境 plan（无凭据时自动离线）
make check           # validate + scan
make check-tags      # 离线 plan 后检查每个资源的基础标签
make quotas          # 只读的 VPC/IGW/EIP/RDS 配额预检（需要 AWS 凭据）
make verify          # 一条命令：validate + 模块测试 + 标签 + 离线 plan + checkov

make apply           # 故意报错退出，见下方审批流程
```

离线模式（本机没有 AWS 凭据时）说明：

```bash
./scripts/plan.sh --offline prod
```

离线 plan 把 provider 的凭据校验全部跳过，状态存放在本地，所有资源都显示为「新增」。
它验证的是**配置图是否自洽**，不代表真实账户里会发生什么。详见 [docs/RISKS.md](docs/RISKS.md) R-02。

## 审批与执行（apply）

**合并 PR 就是审批。** 变更只有一条路径：

1. 提交 PR 到目标环境分支 → 全部 required status checks 必须全绿（环境分支有 ruleset，
   不允许直接 push）。
2. 由人合并。
3. 合并后自动：`plan.yml` 在该环境分支上出权威 plan 工件 → `apply.yml` 被该 plan
   完成自动触发（`head_branch` 必须是 `dev`/`staging`/`prod`，且在 `TF_ENVIRONMENTS` 内）。
4. apply 前机器校验：plan run 必须成功、必须是该环境分支上 push 产生的、来自 `plan.yml`、
   提交仍是该分支的 HEAD、工件 SHA-256 一致、plan 未超过 24 小时、`applyable=true`、
   账户 ID 与 `env.tfvars` 一致。
5. 执行 `terraform apply <合并时评审的 tfplan>` —— **不重新 plan**。

`dev` 环境没有额外的审批点击。`staging` / `prod` 接入前必须把 required reviewers
加回各自的 GitHub Environment——`apply.yml` 的 job 绑定了 `environment`，会自动等待审批；
同时把该环境名加进仓库变量 `TF_ENVIRONMENTS`，否则合并不会触发部署。

失败重放：`gh run rerun <apply run id>`（应用同一份 plan，不重新 plan）。

完整的门禁清单、OIDC 配置和排障见 [docs/CI-CD.md](docs/CI-CD.md)。

本地脚本（`Makefile`、`scripts/*.sh`）依旧没有 apply 入口：`make apply` 会直接报错退出。

## CI 门禁

| 阶段 | 失败条件 |
| --- | --- |
| `terraform fmt -check` | 任何格式漂移 |
| `terraform validate` | 任一环境或 bootstrap 校验失败 |
| `terraform test` | `bastion` / `rds-mysql` / `cloudfront-s3` 模块测试断言失败（ASG 容量、无密钥对、单 AZ、桶不公开、仅 OAC 读取等） |
| 标签合规 | 任一可打标签资源缺少 `Project` / `Environment` / `ManagedBy` / `Repository` |
| `tflint` | provider 用法、未使用声明、AWS 规则违规 |
| `shellcheck` / `actionlint` | 脚本或 workflow 的静态错误 |
| `checkov` | 命中 `scripts/checkov_gate.py` 中的高危规则，或报告 CRITICAL/HIGH |
| account ID 校验 | `env.tfvars` 的账户 ID 与所假设角色不一致 |

`make quotas` 不在 CI 里：它需要 `service-quotas` 权限，且必须在真实账户上运行。
apply 前由人工执行，见 [docs/PLAN-CHECKLIST.md](docs/PLAN-CHECKLIST.md)。

Checkov 的 severity 元数据只在接入 Prisma Cloud 平台时才完整，离线运行时为 `null`。
因此门禁使用**显式高危清单**而不是 `--hard-fail-on HIGH`，避免「什么都没拦住」的假绿。

每个豁免都以 `#checkov:skip=<check-id>:<理由>` 内联在被豁免的资源上，评审时可见，仓库里没有全局 skip 列表。

## 安全控制一览

| 控制 | 实现 |
| --- | --- |
| 禁止公网入站 | `additional_security_groups` 变量校验拒绝 `0.0.0.0/0`、`::/0` |
| default SG 无规则 | `aws_default_security_group` 接管并清空 |
| 禁止 NAT | 私网路由表不创建 `0.0.0.0/0` 路由，模块无 `aws_nat_gateway` |
| S3 私有访问 | S3 网关端点挂到公网 + 私网路由表 |
| S3 桶加密 | SSE-KMS（CMK 自动轮转）+ bucket key |
| S3 桶防公开 | Block Public Access 四项全开 + `BucketOwnerEnforced` |
| S3 桶审计 | 桶自记录访问日志到 `access-logs/` |
| 传输加密 | 桶策略 Deny 所有 `aws:SecureTransport=false` |
| 网络审计 | VPC flow logs，`ALL`，60s 聚合，KMS 加密 |
| 公网 IP | `map_public_ip_on_launch = false`；只有跳板机在启动模板里显式启用公网 IPv4（无 EIP、无入站） |
| 数据库不暴露 | RDS 在私网子网，`publicly_accessible = false`，入站只来自跳板机与 Lambda 两张安全组 |
| Lambda 出站收窄 | Lambda 安全组零入站，只有 3306 / 443 两条出站，目标都是本环境 `vpc_cidr` |
| 数据库凭据 | Secrets Manager 托管主用户密码（自动轮转），Terraform state 无明文 |
| 数据库登录面 | 跳板机零入站规则；端口转发全部走 SSM Session Manager |
| 实例角色最小权限 | 只挂 `AmazonSSMManagedInstanceCore`，无其他权限 |
| 跳板机成本 | ASG desired=0；根卷 `delete_on_termination = true` |
| 静态站点源站 | 桶私有（四项 Block Public Access + `BucketOwnerEnforced`），只有本分发能通过 OAC 读取 |
| 静态站点加密 | SSE-KMS（CMK 自动轮转）；CloudFront 仅在 `aws:SourceArn` 匹配本分发时可 Decrypt |
| 静态站点传输 | 查看器强制跳转 HTTPS，最低 TLS 1.2；统一注入 HSTS / DENY / nosniff / referrer 响应头 |
| 静态站点审计 | 源站桶的 S3 服务端访问日志写入加密日志桶 |
| Lambda 执行角色 | 只有 CloudWatch Logs、X-Ray、VPC ENI 和读取 RDS 主用户密钥的权限；由本仓库创建，外部流水线只能 PassRole |

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 拓扑、地址规划、IPv6、无 NAT 取舍
- [docs/CI-CD.md](docs/CI-CD.md) — 流水线、OIDC、审批门禁、排障
- [docs/RISKS.md](docs/RISKS.md) — 风险清单与缓解措施
- [docs/PLAN-CHECKLIST.md](docs/PLAN-CHECKLIST.md) — plan 预期校验点与危险信号
- [modules/cloudfront-s3/README.md](modules/cloudfront-s3/README.md) — 私有 S3 源站、OAC 与发布方式
- [modules/rds-mysql/README.md](modules/rds-mysql/README.md) — 单 AZ MySQL 与 Secrets Manager 密码
- [modules/bastion/README.md](modules/bastion/README.md) — 跳板机的访问方式与安全组
- [bootstrap/README.md](bootstrap/README.md) — OIDC provider 与 IAM 角色
