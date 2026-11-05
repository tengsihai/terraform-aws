# terraform-aws — 三可用区 VPC 网络基础设施

标准 Terraform 模块仓库：可复用的 `vpc` / `logging-s3` 模块 + `dev` / `staging` / `prod` 三个环境根目录。

设计约束（硬性）：

- **3 个可用区**，每 AZ 一对公网/私网子网
- **IPv4 + IPv6 双栈**
- **S3 网关终端节点**
- **不创建 NAT 网关**，私网路由表没有 `0.0.0.0/0` 路由
- **任何安全组都不允许 `0.0.0.0/0` 或 `::/0` 入站**（变量校验层强制拒绝）
- **S3 日志桶开启服务端加密**（SSE-KMS + 轮转 CMK）

> 本地脚本不提供 apply 入口。唯一的执行路径是 GitHub Actions 的 `apply.yml`：
> 人工触发 → GitHub Environment 审批 → 执行已评审的 plan 文件。详见 [docs/CI-CD.md](docs/CI-CD.md)。

---

## 目录结构

```
.
├── .checkov.yaml                  # Checkov 配置（无全局豁免，豁免全部内联在代码里）
├── .tflint.hcl                    # tflint 规则与 AWS 插件
├── .github/
│   ├── workflows/
│   │   ├── pr-checks.yml          # fmt · validate · tflint · shellcheck/actionlint · checkov
│   │   ├── plan.yml               # 只读 plan → 工件 + PR 粘性评论
│   │   ├── apply.yml              # 人工审批后应用已评审的 plan（不重新 plan）
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
│   └── logging-s3/                # 加密日志桶模块
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
| 预期 plan | 42 add | 43 add | 43 add |

## 快速开始

```bash
make validate        # terraform fmt -check + 三个环境 validate
make scan            # checkov 全量扫描 + 高危门禁
make plan            # 三个环境 plan（无凭据时自动离线）
make check           # validate + scan

make apply           # 故意报错退出，见下方审批流程
```

离线模式（本机没有 AWS 凭据时）说明：

```bash
./scripts/plan.sh --offline prod
```

离线 plan 把 provider 的凭据校验全部跳过，状态存放在本地，所有资源都显示为「新增」。
它验证的是**配置图是否自洽**，不代表真实账户里会发生什么。详见 [docs/RISKS.md](docs/RISKS.md) R-02。

## 审批与执行（apply）

执行只有一条路径，且必须有人的批准：

1. 合并到 `main` 后，`plan.yml` 生成权威 plan 工件（`.tfplan` + 摘要 + 校验清单）。
2. 审批人从仓库设置里配置的 GitHub Environment（`prod` 要求 ≥2 名 reviewer）批准。
3. 触发方式：

   ```bash
   gh workflow run apply.yml \
     -f environment=prod \
     -f plan_run_id=<plan run 的 databaseId> \
     -f confirmation=prod
   ```

4. 审批通过后，CI 会重新校验：plan run 必须成功、来自 `plan.yml`、跑在 `main` 上、
   提交必须仍是 `main` 的 HEAD、工件 SHA-256 一致、plan 未超过 24 小时、`applyable=true`、
   账户 ID 与 `env.tfvars` 一致。
5. 最后执行 `terraform apply <已评审的 tfplan>` —— **不重新 plan**。

完整的门禁清单、OIDC 配置和排障见 [docs/CI-CD.md](docs/CI-CD.md)。

本地脚本（`Makefile`、`scripts/*.sh`）依旧没有 apply 入口：`make apply` 会直接报错退出。

## CI 门禁

| 阶段 | 失败条件 |
| --- | --- |
| `terraform fmt -check` | 任何格式漂移 |
| `terraform validate` | 任一环境或 bootstrap 校验失败 |
| `tflint` | provider 用法、未使用声明、AWS 规则违规 |
| `shellcheck` / `actionlint` | 脚本或 workflow 的静态错误 |
| `checkov` | 命中 `scripts/checkov_gate.py` 中的高危规则，或报告 CRITICAL/HIGH |
| account ID 校验 | `env.tfvars` 的账户 ID 与所假设角色不一致 |

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
| 公网 IP | `map_public_ip_on_launch = false`，按需绑 EIP |

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 拓扑、地址规划、IPv6、无 NAT 取舍
- [docs/CI-CD.md](docs/CI-CD.md) — 流水线、OIDC、审批门禁、排障
- [docs/RISKS.md](docs/RISKS.md) — 风险清单与缓解措施
- [docs/PLAN-CHECKLIST.md](docs/PLAN-CHECKLIST.md) — plan 预期校验点与危险信号
- [bootstrap/README.md](bootstrap/README.md) — OIDC provider 与 IAM 角色
