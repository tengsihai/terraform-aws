# 风险清单

评估口径：**等级 = 影响 × 可能性**，等级为「高」的条目必须在 apply 前由评审明确确认。
「状态」列：`已缓解` = 控制已落地；`已接受` = 有意承担，需要业务方签字；`待处理` = 需要跟进的缺口。

## 总览

| ID | 风险 | 等级 | 状态 |
| --- | --- | --- | --- |
| R-01 | 自动化误执行 `apply` / `destroy` | 高 | 已缓解 |
| R-02 | 离线 plan 被误当作已校验计划 | 高 | 已缓解 |
| R-03 | `aws_account_id` 仍为占位符 | 高 | 已缓解 |
| R-04 | 私网子网无 IPv4 出网 | 中 | 已接受 |
| R-05 | 未启用 Interface 端点导致 SSM/ECR 不可用 | 中 | 已接受 |
| R-06 | S3 日志桶无跨区域复制 | 中 | 已接受 |
| R-07 | dev/staging 日志保留不足 1 年 | 中 | 已接受 |
| R-08 | 远端 state 桶需手工创建与加固 | 高 | 待处理 |
| R-09 | KMS 密钥策略授予账户 root 全权 | 中 | 已接受 |
| R-10 | 无网络 ACL、无集中式流量检查 | 中 | 待处理 |
| R-11 | 私网 IPv6 默认不分配地址 | 低 | 已接受 |
| R-12 | 桶名依赖占位账户 ID，可能与现有桶冲突 | 中 | 已缓解 |
| R-13 | 无跨账户 / Transit Gateway 连接能力 | 中 | 待处理 |
| R-14 | Checkov severity 元数据离线缺失 | 中 | 已缓解 |
| R-15 | 无集成测试（Terratest 等） | 中 | 待处理 |
| R-16 | flow logs 60 秒聚合增加成本 | 低 | 已接受 |
| R-17 | 无 drift detection | 中 | 待处理 |
| R-18 | 未做 VPC / EIP 配额预检 | 低 | 待处理 |
| R-19 | provider 版本为区间约束，依赖 lock 文件 | 低 | 已缓解 |
| R-20 | 未强制资源标签合规 | 低 | 待处理 |
| R-21 | CI apply 角色权限偏宽 | 高 | 待处理 |
| R-22 | plan 工件的可信度依赖 GitHub | 中 | 已缓解 |
| R-23 | 第三方 Action 供应链风险 | 中 | 已缓解 |
| R-24 | fork PR 无 plan 覆盖 | 低 | 已接受 |
| R-25 | drift 检测只覆盖 Terraform 管理的资源 | 低 | 已接受 |
| R-26 | 合并即部署，缺少独立审批 | 中 | 已接受 |

---

## 高等级

### R-01 非受控地执行 `apply` / `destroy`

- **场景**：变更绕过人工把关直接落到真实账户。
- **影响**：生产网络被创建/修改/删除。VPC 删除会连带删除其下所有资源。
- **人工把关点**：**合并 PR**。main 上的 ruleset `protect-main` 禁止直接 push，
  要求 4 项 status checks 全绿；合并这个动作就是审批。
- **缓解**：
  - 本地：`scripts/lib.sh` 的 `refuse_mutation()` 硬拒绝，`Makefile` 的 `apply`/`destroy`
    目标只打印说明并 `exit 1`；
  - CI：唯一的执行入口 `apply.yml` 由「main 上的 plan 完成」自动触发，且只接受
    `push` 事件（一次合并）产生的 plan；执行对象是不可变的 plan 工件，不重新 plan；
  - `apply.yml` 在 apply 前校验 plan run 来源、分支、提交、SHA-256、时效与账户 ID；
  - 并发组 `cancel-in-progress: false`，不会把执行中的 apply 取消掉；
  - `staging` / `prod` 接入前必须把 required reviewers 加回 Environment，
    在合并之上再加一道显式审批。
- **剩余风险**：拥有写权限的人仍能合并一个含恶意变更的 PR。
  合并是唯一把关点，团队仓库务必把 required approvals 提到 ≥1。
- **状态**：已缓解（单人仓库）；团队场景需双人评审。

### R-26 合并即部署，缺少独立审批

- **场景**：`apply.yml` 由合并自动触发，`dev` 环境不再有 required reviewers。
- **影响**：一次合并立即改变真实基础设施；plan 与 apply 之间没有人再看过一眼。
- **缓解**：
  - PR 上有 plan 摘要粘性评论，评审时能看到「会创建/修改/删除什么」；
  - PR 必须过 4 项检查才允许合并；
  - destructive 变更在摘要里有醒目告警（`> [!WARNING]`）；
  - `TF_ENVIRONMENTS` 只列已确认要自动部署的环境。
- **决策**：单人仓库接受；接入 staging/prod 时必须恢复 required reviewers（R-01）。
- **状态**：已接受。

### R-02 离线 plan 被误当作已校验计划

- **场景**：本机没有 AWS 凭据时 `make plan` 自动进入离线模式，provider 跳过所有凭据校验和
  API 调用，plan 里所有资源都是「新增」，没有 refresh，也没有账户级校验。
- **影响**：离线 plan 只能证明配置图自洽，无法发现：已存在的资源冲突、配额不足、
  AMI/服务不可用、账户级限制、与真实 state 的漂移。
- **缓解**：
  - 脚本在进入离线模式时打印醒目的 `WARN`；
  - provider 的 `offline_mode` 变量默认 `false`，且带明确注释说明它只能用于 CI 语法检查；
  - 审批流程要求审批人在**有凭据**的环境重跑 `./scripts/plan.sh <env>`。
- **状态**：已缓解。

### R-03 `aws_account_id` 仍为占位符

- **场景**：`env.tfvars` 里的 `123456789012` 未替换，被用于 KMS 策略、S3 桶策略、
  IAM 信任策略的 ARN。
- **影响**：策略指向不存在的账户，资源创建后无人可访问；flow log 投递被拒。
- **缓解**：
  - `plan.sh` 在线模式会比对 `aws sts get-caller-identity` 与实际账户，不一致直接中止；
  - 每次 apply 前必须走该脚本。
- **状态**：已缓解，但需在首次真实部署前替换。

### R-08 远端 state 桶需手工创建与加固

- **场景**：`backend.tf` 只声明了空的 `backend "s3" {}`，真实桶、KMS key、版本控制和
  Block Public Access 需要预先存在。
- **影响**：桶未加固 → state 泄漏（含资源 ID、部分敏感属性）；桶无版本控制 → state 损坏无法回滚。
- **缓解（部署前必须完成）**：
  - 开启版本控制；
  - 默认 SSE-KMS 加密；
  - Block Public Access 四项全开；
  - 桶策略拒绝非 TLS；
  - 启用 S3 原生锁（`use_lockfile = true`）或 DynamoDB 锁表；
  - 只允许 Terraform 执行角色读写。
- **状态**：待处理。

---

## 中等级

### R-04 私网子网无 IPv4 出网

- **场景**：设计上私网路由表没有 `0.0.0.0/0`，也没有 NAT。
- **影响**：私网实例无法访问公网 IPv4：不能装系统包、不能调第三方 API、不能访问公网 SaaS。
- **缓解**：S3 走网关端点；其他 AWS 服务通过 `interface_endpoint_services` 开 Interface 端点；
  需要公网出口的业务应放到公网子网（配合 ALB/NLB）或通过 Transit Gateway 集中出口。
- **决策**：需求明确要求禁止 NAT，接受该限制。
- **状态**：已接受。

### R-05 未启用 Interface 端点导致 SSM/ECR 不可用

- **场景**：`interface_endpoint_services` 默认为空。
- **影响**：私网实例无法用 Session Manager 登录，无法从 ECR 拉镜像——大多数容器化工作负载会直接起不来。
- **缓解**：按需打开 `["ssm","ssmmessages","ec2messages","ecr.api","ecr.dkr","logs"]`；
  成本 = 端点数量 × AZ 数 × 小时单价 + 数据处理费。上线前需成本确认。
- **状态**：已接受，需在业务接入时评估。

### R-06 S3 日志桶无跨区域复制

- **场景**：Checkov `CKV_AWS_144` 被内联豁免。
- **影响**：单区域灾难（区域级故障或误删）会导致审计日志丢失。
- **缓解**：CRR 的目标桶、目标区域和 KMS 授权属于组织级 DR 决策，应由 DR 账户统一配置；
  本模块只保证源桶可被复制（版本控制 + KMS CMK 已就绪）。
- **状态**：已接受，需 DR 方案跟进。

### R-07 dev/staging 日志保留不足 1 年

- **场景**：Checkov `CKV_AWS_338` 被内联豁免。
- **影响**：dev 30 天、staging 90 天，低于部分合规基线的一年要求。
- **缓解**：prod 固定 365 天；dev/staging 保留期是成本决策。若审计范围覆盖非生产环境，需上调。
- **状态**：已接受。

### R-09 KMS 密钥策略授予账户 root 全权

- **场景**：两个 CMK 的策略都包含标准的 `kms:*` → `arn:aws:iam::<account>:root` 语句。
- **影响**：账户内任何拥有 IAM 权限的主体都可能被授予密钥使用权。
- **缓解**：这是 AWS 官方推荐的密钥管理语句，作用范围被密钥策略本身限制；
  真正的边界是 IAM identity policy。若需更严格，可改为指定的角色 ARN，但会破坏
  IAM 集中管理的可维护性。
- **状态**：已接受。

### R-10 无网络 ACL、无集中式流量检查

- **场景**：只使用安全组（有状态），未配置自定义 NACL，也没有 Network Firewall / TGW 检查点。
- **影响**：东西向流量（子网之间、AZ 之间）没有额外拦截层，出网流量也没有域名级过滤。
- **缓解**：私网本就无 IPv4 出网，公网子网应只放 ALB/NAT（本设计无 NAT）。
  需要深度检查时，应通过 Network Firewall 或集中式检查 VPC 实现。
- **状态**：待处理（取决于合规要求）。

### R-12 桶名依赖占位账户 ID

- **场景**：`<project>-<env>-logs-<account_id>-<region>`，账户 ID 为占位符时名字会与同区域
  其他人的桶冲突，或者与既有桶重名。
- **影响**：apply 时 `BucketAlreadyExists` 失败（不会造成数据损坏）。
- **缓解**：替换真实账户 ID 后自然唯一；复用已有桶时应改用 `data` 而非新建。
- **状态**：已缓解。

### R-13 无跨账户 / Transit Gateway 连接能力

- **场景**：模块不创建 TGW 挂载、VPC peering 或 RAM 共享。
- **影响**：多账户或混合云场景需要额外的连接层，当前需手工实现。
- **状态**：待处理。

### R-14 Checkov severity 元数据离线缺失

- **场景**：未接入 Prisma Cloud 时，Checkov 的 `severity` 字段为 `null`，
  `--hard-fail-on HIGH` 实际不会拦截任何东西。
- **影响**：看起来「高危门禁通过」，实际是假绿。
- **缓解**：`scripts/checkov_gate.py` 使用显式的 `HIGH_RISK_CHECKS` 白名单，
  并对报告里出现 CRITICAL/HIGH 的情况叠加拦截（接入平台后自动生效）。
- **状态**：已缓解。

### R-15 无集成测试

- **场景**：只有 `validate` 和 `plan`，没有 Terratest 或 `terraform test` 的
  真实创建/销毁验证。
- **影响**：路由、端点、IPv6 这类只能在真实环境验证的行为，缺陷要到 apply 后才暴露。
- **缓解**：建议在独立沙箱账户补 `terraform test`（`*.tftest.hcl`）验证 plan 断言。
- **状态**：待处理。

### R-17 无 drift detection

- **场景**：控制台手工改动不会被自动发现。
- **影响**：下一个人 apply 时可能产生意外 diff 甚至替换。
- **缓解**：建议对 prod 每日跑一次带凭据的 `terraform plan -detailed-exitcode`，
  以只读方式把 drift 报警出来（不 apply）。
- **状态**：待处理。

---

## 低等级

| ID | 风险 | 说明 |
| --- | --- | --- |
| R-11 | 私网 IPv6 默认不分配地址 | 子网有 /64 但不自动分配，需按 ENI 显式开启；避免隐式暴露 |
| R-16 | flow logs 60 秒聚合成本 | 600 秒更便宜但排查变慢；仅在成本敏感时下调 |
| R-18 | 未做配额预检 | 每账户每区域 VPC/EIP/端点配额可能不足，需在 apply 前确认 |
| R-19 | provider 版本为区间约束 | `>= 6.0.0, < 7.0.0`，实际版本由 `.terraform.lock.hcl` 锁定；lock 文件必须入库 |
| R-20 | 未强制标签合规 | 通过 provider `default_tags` 注入基础标签，但未用 SCP/Config 强制 |

---

## CI/CD 相关

### R-21 CI apply 角色权限偏宽

- **场景**：`bootstrap/` 创建的 apply 角色能管理本仓库涉及的全部资源类型，资源范围是账户级。
- **影响**：如果 apply 工作流被滥用（恶意 plan + 有审批权的人放行），影响面是整个账户的
  网络/存储/KMS/日志资源，而不限于本项目。
- **原因**：Terraform 的 `Create*` 动作作用的对象在执行前不存在，无法预先写成 ARN 白名单。
  硬要收窄会导致首次创建失败。
- **缓解（按优先级）**：
  1. 给角色加 **permission boundary**，设一条不可越过的硬上限；
  2. 用 **SCP** 限制可操作区域、服务与资源标签；
  3. 用 IAM Access Analyzer 基于 CloudTrail 生成更精确的策略；
  4. 把 CI 放在专用的工作负载账户，通过跨账户角色访问目标账户。
- **检测**：`CKV_AWS_108/109/111/356` 对该策略已内联豁免并写明理由；
  豁免一旦扩散到其他资源，Code Review 必须拒绝。
- **状态**：待处理。

### R-22 plan 工件的可信度依赖 GitHub

- **场景**：`apply.yml` 应用的是从 GitHub Actions 工件库下载的 plan 文件。
- **影响**：对仓库有 write 权限的人理论上可以构造一个 run 并伪造工件。
- **缓解**：
  - 校验 run 必须由 `plan.yml` 产生、在 `main` 上、`conclusion=success`；
  - 校验 `head_sha` 仍等于 `main` 的 HEAD；
  - 校验 manifest 中的环境、提交与 plan 文件 SHA-256；
  - 限制 `PLAN_MAX_AGE_HOURS`（默认 24h）；
  - 最关键的补偿控制是**审批人必须阅读摘要**，不能只看「检查通过」。
- **状态**：已缓解。

### R-23 第三方 Action 供应链风险

- **场景**：工作流引用了 `actions/*`、`hashicorp/setup-terraform`、
  `aws-actions/configure-aws-credentials` 等第三方 Action。
- **影响**：上游被投毒会影响流水线，进而影响 AWS 凭证。
- **缓解**：
  - 只使用 GitHub 官方或厂商官方 Action，没有引入来源不明的 Action；
  - `actions/checkout` 设置 `persist-credentials: false`，避免 token 留在 git 配置里；
  - 工作流顶层 `permissions` 为最小权限，按 job 单独提权；
  - `dependabot.yml` 每周跟进版本；
  - **建议进一步把 Action 固定到 commit SHA**（当前使用 major tag）。
- **状态**：已缓解，SHA 固定待办。

### R-24 fork PR 没有 plan 覆盖

- **场景**：`plan.yml` 对 fork PR 直接跳过，因为 fork 拿不到 OIDC token。
- **影响**：外部贡献者提交的改动没有针对真实账户的 plan 结果，只有静态检查。
- **缓解**：合并前由维护者在内部 PR 或本地重跑 plan；`pr-checks.yml` 的
  fmt/validate/tflint/checkov 仍会执行。
- **状态**：已接受。

### R-25 drift 检测只覆盖 Terraform 管理的资源

- **场景**：`drift-detection.yml` 靠 `terraform plan` 发现差异。
- **影响**：在 Terraform 之外创建的「影子资源」不会出现在任何 plan 里；
  被手工删除但从未纳入 state 的资源也不会被发现。
- **缓解**：配合 AWS Config / Security Hub 的资源配置检查覆盖非 IaC 资源。
- **状态**：已接受。

---

## 每次 apply 前必须确认

1. R-03：`env.tfvars` 的 `aws_account_id` 是真实账户。
2. R-08：state 桶已开启版本控制、加密、Block Public Access、锁。
3. R-04/R-05：业务确实不需要 IPv4 出网，或已启用所需 Interface 端点。
4. R-21：apply 角色的权限边界已确认（至少已评估是否加 permission boundary）。
5. `docs/PLAN-CHECKLIST.md` 的全部校验点通过。
