# 风险清单

评估口径：**等级 = 影响 × 可能性**，等级为「高」的条目必须在 apply 前由评审明确确认。
「状态」列：`已缓解` = 控制已落地；`已接受` = 有意承担，需要业务方签字；`待处理` = 需要跟进的缺口。

## 总览

| ID | 风险 | 等级 | 状态 |
| --- | --- | --- | --- |
| R-01 | 自动化误执行 `apply` / `destroy` | 高 | 已缓解 |
| R-02 | 离线 plan 被误当作已校验计划 | 高 | 已缓解 |
| R-03 | `aws_account_id` 仍为占位符（仅 staging/prod） | 高 | 已缓解 |
| R-04 | 私网子网无 IPv4 出网 | 中 | 已接受 |
| R-05 | 未启用 Interface 端点导致 SSM/ECR 不可用 | 中 | 已接受 |
| R-06 | S3 日志桶无跨区域复制 | 中 | 已接受 |
| R-07 | dev/staging 日志保留不足 1 年 | 中 | 已接受 |
| R-08 | 远端 state 桶需手工创建与加固 | 高 | 已缓解（dev） |
| R-09 | KMS 密钥策略授予账户 root 全权 | 中 | 已接受 |
| R-10 | 无网络 ACL、无集中式流量检查 | 中 | 已接受（当前需求） |
| R-11 | 私网 IPv6 默认不分配地址 | 低 | 已接受 |
| R-12 | 桶名依赖占位账户 ID，可能与现有桶冲突 | 中 | 已缓解 |
| R-13 | 无跨账户 / Transit Gateway 连接能力 | 中 | 已接受（无跨账户需求） |
| R-14 | Checkov severity 元数据离线缺失 | 中 | 已缓解 |
| R-15 | 无集成测试（Terratest 等） | 中 | 已缓解（plan 级） |
| R-16 | flow logs 60 秒聚合增加成本 | 低 | 已接受 |
| R-17 | 无 drift detection | 中 | 已缓解 |
| R-18 | 未做 VPC / EIP 配额预检 | 低 | 已缓解 |
| R-19 | provider 版本为区间约束，依赖 lock 文件 | 低 | 已缓解 |
| R-20 | 未强制资源标签合规 | 低 | 已缓解 |
| R-21 | CI apply 角色权限偏宽 | 高 | 已缓解（权限边界） |
| R-22 | plan 工件的可信度依赖 GitHub | 中 | 已缓解 |
| R-23 | 第三方 Action 供应链风险 | 中 | 已缓解 |
| R-24 | fork PR 无 plan 覆盖 | 低 | 已接受 |
| R-25 | drift 检测只覆盖 Terraform 管理的资源 | 低 | 已接受 |
| R-26 | 合并即部署，缺少独立审批 | 中 | 已接受 |
| R-27 | 跳板机由 ASG 按需拉起 | 中 | 已缓解 |
| R-28 | 开发人员 IAM 策略需要单独分发 | 中 | 已接受（策略已输出） |
| R-29 | RDS 单 AZ，无跨 AZ 故障切换 | 中 | 已接受 |
| R-30 | 跳板机出站全部允许 | 低 | 已接受 |
| R-31 | CloudFront 未启用 WAF | 中 | 已接受 |
| R-32 | CloudFront 标准访问日志未启用 | 中 | 已接受（源站有 S3 日志） |
| R-33 | CloudFront 单源站，无 origin failover | 低 | 已接受 |
| R-34 | 静态站点未使用自定义域名 / ACM 证书 | 低 | 已接受 |
| R-35 | CloudFront 未启用地理限制 | 低 | 已接受（公开静态内容） |

---

## 高等级

### R-01 非受控地执行 `apply` / `destroy`

- **场景**：变更绕过人工把关直接落到真实账户。
- **影响**：生产网络被创建/修改/删除。VPC 删除会连带删除其下所有资源。
- **人工把关点**：**合并 PR**。环境分支上的 ruleset 禁止直接 push，
  要求全部 status checks 全绿；合并这个动作就是审批。
- **缓解**：
  - 本地：`scripts/lib.sh` 的 `refuse_mutation()` 硬拒绝，`Makefile` 的 `apply`/`destroy`
    目标只打印说明并 `exit 1`；
  - CI：唯一的执行入口 `apply.yml` 由「环境分支上的 plan 完成」自动触发，且只接受
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
  - PR 必须过全部 required status checks 才允许合并；
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

- **适用范围**：**仅 staging / prod**。dev 已经是真实账户，不受此条影响。

| 环境 | `env.tfvars` 中的值 | 状态 |
| --- | --- | --- |
| dev | `790354569983` | 真实账户，已与 `aws sts get-caller-identity` 核对一致 |
| staging | `123456789012` | **占位符，接入前必须替换** |
| prod | `123456789012` | **占位符，接入前必须替换** |

- **场景**：占位账户 ID 被用于 KMS 策略、S3 桶名与桶策略、IAM 信任策略、
  RDS 托管密钥 ARN 等位置。
- **影响**：策略指向不存在的账户，资源创建后无人可访问；flow log 投递被拒；
  S3 桶名可能与他人冲突。
- **缓解**：
  - `plan.sh` 在线模式会比对 `aws sts get-caller-identity` 与实际账户，不一致直接中止；
  - staging/prod 接入 CI 前，把 `env.tfvars` 里的值替换成目标账户 ID，并重新生成 plan。
- **状态**：dev 已解决；staging/prod 接入时替换（不阻塞当前环境）。

### R-08 远端 state 桶需手工创建与加固

- **场景**：`backend.tf` 只声明了空的 `backend "s3" {}`，真实桶、KMS key、版本控制和
  Block Public Access 需要预先存在。
- **影响**：桶未加固 → state 泄漏（含资源 ID、部分敏感属性）；桶无版本控制 → state 损坏无法回滚。

**当前状态（2026-11-06 核对，账户 790354569983）**：桶
`platform-terraform-state-790354569983-ap-northeast-1` 已存在，且以下项均已就绪：

| 项 | 现状 |
| --- | --- |
| 版本控制 | `Enabled` |
| 默认加密 | `AES256`（SSE-S3，免费） |
| Block Public Access | 四项全开 |
| 对象所有权 | `BucketOwnerEnforced` |
| 桶策略 | 已拒绝非 TLS 请求 |
| 状态锁 | `use_lockfile = true`（S3 原生锁，无需 DynamoDB） |

因此对该账户来说 R-08 只剩“确认”这一步；KMS CMK 是**可选**加固，不是必需项。

**成本**：

- 当前方案（SSE-S3 + S3 原生锁）：**没有额外固定费用**。state 文件只有几十 KB，
  存储和 PUT/GET 请求费用可以忽略（每月远低于 $0.01）。
- 如果改用专用 KMS CMK：**约 $1.00/月**（按小时折算）外加每 10,000 次请求 $0.03；
  Terraform 每次 plan/apply 的请求量很小。改用 CMK 时在 `backend.hcl` 填
  `kms_key_id`、在 `bootstrap/terraform.tfvars` 填 `state_kms_key_arn`。
- 版本控制会保留旧版本，长期会累积少量存储；按当前规模同样可以忽略。

**从零创建的具体步骤**（一次性，用管理员凭据执行；如果桶已存在，只用第 2–7 步核对）：

```bash
export REGION=ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="platform-terraform-state-${ACCOUNT_ID}-${REGION}"

# 1.（可选，会产生约 $1/月的 CMK 费用）专用 KMS CMK + 自动轮转
KEY_ID=$(aws kms create-key --region "$REGION" \
  --description "Terraform remote state" \
  --query KeyMetadata.KeyId --output text)
aws kms enable-key-rotation --region "$REGION" --key-id "$KEY_ID"
aws kms create-alias --region "$REGION" \
  --alias-name alias/terraform-state --target-key-id "$KEY_ID"

# 2. 桶（ap-northeast-1 必须带 LocationConstraint）
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# 3. 版本控制（state 回滚的前提）
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# 4. 默认 SSE-KMS 加密（bucket key 降低 KMS 调用成本）
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "alias/terraform-state"
      },
      "BucketKeyEnabled": true
    }]
  }'

# 5. Block Public Access 四项全开
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 6. 关闭 ACL，统一桶所有者
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# 7. 拒绝非 TLS 请求
cat > /tmp/state-bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::${BUCKET}",
      "arn:aws:s3:::${BUCKET}/*"
    ],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/state-bucket-policy.json
rm -f /tmp/state-bucket-policy.json
```

完成后再接线：

1. `environments/<env>/backend.hcl` 填入 `bucket`、`key`、`region`、`encrypt = true`，
   保留 `use_lockfile = true`（S3 原生锁，无需 DynamoDB）；只有使用 CMK 时才加
   `kms_key_id = alias/terraform-state`，SSE-S3 时不要填；
2. `bootstrap/terraform.tfvars` 填同一个 `state_bucket_name`；使用 CMK 时再填
   `state_kms_key_arn`；
3. `terraform init -backend-config=backend.hcl` 验证能读到 state。

只允许 Terraform 执行角色读写这一点由 bootstrap 的 `state_access` 策略保证；
桶策略层面再按角色 ARN 收窄属于可选的第二层加固。

- **状态**：dev 账户已满足（SSE-S3）；staging/prod 接入时按上面步骤创建各自的桶。

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

- **场景**：`interface_endpoint_services` 默认为空（目前只有 dev 开了 `secretsmanager`，ssm/ecr 仍未开）。
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
- **现有控制**：安全组零公网入站、私网无 IPv4 出网、VPC flow logs 记录全部流量。
- **决策**：集中式流量检查需要 Network Firewall 或 TGW 检查 VPC，属于跨账户/合规级项目，
  会引入固定成本和运维面；当前需求不包含，作为已知缺口接受。合规要求出现时单独立项。
- **状态**：已接受（当前需求）。

### R-12 桶名依赖占位账户 ID

- **场景**：`<project>-<env>-logs-<account_id>-<region>`，账户 ID 为占位符时名字会与同区域
  其他人的桶冲突，或者与既有桶重名。
- **影响**：apply 时 `BucketAlreadyExists` 失败（不会造成数据损坏）。
- **缓解**：替换真实账户 ID 后自然唯一；复用已有桶时应改用 `data` 而非新建。
- **状态**：已缓解。

### R-13 无跨账户 / Transit Gateway 连接能力

- **场景**：模块不创建 TGW 挂载、VPC peering 或 RAM 共享。
- **影响**：多账户或混合云场景需要额外的连接层，当前需手工实现。
- **决策**：当前是单账户、单 VPC 设计，没有跨账户或本地数据中心互联需求；
  需要时通过 TGW 或 peering 单独设计，不影响现有地址规划。
- **状态**：已接受（无跨账户需求）。

### R-14 Checkov severity 元数据离线缺失

- **场景**：未接入 Prisma Cloud 时，Checkov 的 `severity` 字段为 `null`，
  `--hard-fail-on HIGH` 实际不会拦截任何东西。
- **影响**：看起来「高危门禁通过」，实际是假绿。
- **缓解**：`scripts/checkov_gate.py` 使用显式的 `HIGH_RISK_CHECKS` 白名单，
  并对报告里出现 CRITICAL/HIGH 的情况叠加拦截（接入平台后自动生效）。
- **状态**：已缓解。

### R-15 无集成测试

- **场景**：真实创建/销毁（Terratest）仍未覆盖；但配置层面的 plan 断言已经补齐。
- **已实施**：
  - `modules/bastion/tests/bastion.tftest.hcl`：ASG 0/1/0、实例类型、无密钥对、
    根卷加密 + DeleteOnTermination、IMDSv2、公网 IPv4、开发人员策略的标签/MFA/文档限制；
  - `modules/rds-mysql/tests/rds_mysql.tftest.hcl`：MySQL、单 AZ、不对公网、
    存储加密、Secrets Manager 托管密码、仅安全组来源的 3306 入站；
  - 使用 `mock_provider`，不访问 AWS；`make test` 本地运行，
    `pr-checks.yml` 的 `module-tests` job 在 CI 运行。
- **剩余风险**：mock 测试验证的是配置图，不是真实 AWS 行为（路由、端点、IPv6 仍需实机验证）。
  真实创建/销毁测试应在独立沙箱账户用 Terratest 或 `terraform test` + 真实 provider 完成。
- **状态**：已缓解（plan 级集成测试已落地）；真实 apply/destroy 测试待沙箱账户。

### R-17 无 drift detection

- **场景**：控制台手工改动不会被自动发现。
- **影响**：下一个人 apply 时可能产生意外 diff 甚至替换。
- **已实施**：`.github/workflows/drift-detection.yml` 在工作日 01:00 UTC 运行，
  用只读的 `terraform-plan` 角色执行 `terraform plan -detailed-exitcode`，
  发现漂移时自动开/更新带 `drift` 标签的 GitHub issue，并上传 plan 报告；
  流程只读，不会 apply。
- **剩余风险**：只覆盖 Terraform 管理的资源（见 R-25）。
- **状态**：已缓解。

### R-27 跳板机由 ASG 按需拉起（公有子网）

- **场景**：`bastion` 模块在公有子网创建 0~1 台的 ASG，实例自动分配公网 IPv4
  （不绑 EIP），SSM Agent 的 443 出站经 IGW 直连 SSM 公网端点；不部署
  ssm / ec2messages / ssmmessages Interface 端点。
- **影响**：实例有公网地址，理论上可被扫描；实际风险在于谁能调用
  `ssm:StartSession`。拿到会话的人可以建立到 RDS 的端口转发。
- **缓解**：
  - 安全组**没有任何入站规则**，没有 SSH、密钥对和 22 端口；
  - IMDSv2 强制（`http_tokens = "required"`），根卷加密；
  - ASG 默认 0 实例，不需要时不存在可连接的目标；
  - 模块输出 `developer_policy_json`：只允许 `ssm:StartSession`，
    通过 `ssm:resourceTag/Bastion` 限定到本环境的实例，通过文档 ARN 限定
    只能用 `AWS-StartPortForwardingSessionToRemoteHost`，并要求 MFA；
  - CloudTrail 记录每一次 StartSession。
- **状态**：已缓解。开发人员策略需要实际挂到 IAM 用户/组上（见 R-28）。

### R-28 开发人员 IAM 策略需要单独分发

- **场景**：模块只**输出**最小权限策略，不创建 IAM 用户、组或角色。
- **影响**：如果开发人员继续使用更宽的现成权限（例如 `ssm:*` 或 `AdministratorAccess`），
  上面所有标签和文档限制都不会生效。
- **分发步骤**（策略已由 `terraform output bastion_developer_policy_json` 提供）：

  ```bash
  # 1. 导出策略 JSON
  terraform -chdir=environments/dev output -raw bastion_developer_policy_json \
    > /tmp/bastion-developer-dev.json

  # 2. 建成客户托管策略（每个环境一份，标签值不同）
  POLICY_ARN=$(aws iam create-policy \
    --policy-name bastion-developer-dev \
    --policy-document file:///tmp/bastion-developer-dev.json \
    --query Policy.Arn --output text)

  # 3a. 挂到 IAM 用户
  aws iam attach-user-policy --user-name <developer> --policy-arn "$POLICY_ARN"

  # 3b. 或挂到 IAM 组
  aws iam attach-group-policy --group-name db-developers --policy-arn "$POLICY_ARN"
  ```

  使用 IAM Identity Center 时，把同一份 JSON 作为 permission set 的内联策略，
  不要另外授予 `ssm:*`。
- **复核**：用 IAM Access Analyzer 确认没有更宽的 `ssm:StartSession` 授权；
  定期检查 CloudTrail 的 StartSession 记录。
- **决策**：挂载到用户/组/SSO 属于组织 IAM 流程，不在 Terraform 里创建 IAM 用户或组；
  策略内容本身已经落地并可直接使用。
- **状态**：已接受（策略已输出，分发步骤已明确，挂载由组织执行）。

### R-29 RDS 单 AZ，无跨 AZ 故障切换

- **场景**：需求明确要求单 AZ，模块固定 `multi_az = false`。
- **影响**：AZ 故障时实例不可用，直到 AWS 恢复或从快照重建；RPO 取决于备份窗口。
- **缓解**：自动备份保留 7 天（`backup_retention_period` 可调）；staging/prod
  开启删除保护并保留最终快照；恢复时可以把快照建到其他 AZ。
- **决策**：需求要求单 AZ，接受可用性取舍。需要 HA 时改模块为 `multi_az = true`。
- **状态**：已接受。

### R-31 CloudFront 未启用 WAF

- **场景**：`cloudfront-s3` 模块只分发私有 S3 桶里的静态对象，没有挂 WAFv2 Web ACL。
- **影响**：边缘层没有托管的常见规则集和 Log4j/AMR 规则；恶意请求会直接落到
  CloudFront 缓存或源站。静态对象没有请求解析面，实际可利用性低，但缺少一层通用过滤。
- **原因**：CloudFront 作用域的 WAFv2 Web ACL 必须创建在 `us-east-1`，
  本模块刻意不引入第二个 provider；WAF 还有每月固定费用。
- **缓解**：源站桶私有，只允许本分发通过 OAC 读取；查看器只能走 TLS 1.2+；
  CloudFront 边缘缓存吸收大部分流量；源站访问由 S3 服务端访问日志记录。
- **状态**：已接受。需要 WAF 时在环境根目录加 `us-east-1` 别名 provider，
  由模块接收 web ACL ARN 并挂到 `web_acl_id`。

### R-32 CloudFront 标准访问日志未启用

- **场景**：`aws_cloudfront_distribution` 没有配置 `logging_config`。
- **影响**：边缘侧的查看器请求（客户端 IP、URI、状态码、缓存命中）不会写入日志；
  只有到达源站的请求会出现在 S3 服务端访问日志里。
- **原因**：CloudFront 标准日志是 ACL 模式，目标桶必须允许
  `log-delivery-write` 之类的 ACL 授权，与日志桶的 `BucketOwnerEnforced` 冲突；
  跨区域日志桶还需要额外配置。
- **缓解**：源站桶开启 S3 服务端访问日志并写入加密日志桶；CloudFront 指标
  （请求数、4xx/5xx、缓存命中率）仍可在 CloudWatch 查看。
- **状态**：已接受。需要边缘级审计时，改用 CloudFront 日志 v2 / 实时日志
  （Kinesis Data Streams），不要回退到 ACL 模式。

---

## 低等级

| ID | 风险 | 说明 |
| --- | --- | --- |
| R-11 | 私网 IPv6 默认不分配地址 | 子网有 /64 但不自动分配，需按 ENI 显式开启；避免隐式暴露 |
| R-16 | flow logs 60 秒聚合成本 | 600 秒更便宜但排查变慢；仅在成本敏感时下调 |
| R-18 | 未做配额预检 | 已提供 `make quotas`（`scripts/check-quotas.sh`，只读）：对比 VPC / IGW / EIP / RDS 配额与已用量 + 计划量，apply 前人工运行 |
| R-19 | provider 版本为区间约束 | `>= 6.0.0, < 7.0.0`，实际版本由 `.terraform.lock.hcl` 锁定；lock 文件必须入库 |
| R-20 | 未强制标签合规 | 已提供 `make check-tags`（`scripts/check-tags.py`）并接入 CI：基于离线 plan JSON，要求每个可打标签资源带 `Project` / `Environment` / `ManagedBy` / `Repository`；SCP/Config 级别的强制仍在组织层 |
| R-30 | 跳板机出站全部允许 | 需求要求；实例无入站规则，唯一访问路径是 SSM |
| R-33 | CloudFront 单源站，无 origin failover | 静态内容靠 S3 版本控制和同区域多 AZ 持久性恢复；跨区域源站属于 DR 决策，见 R-06 |
| R-34 | 静态站点未使用自定义域名 / ACM 证书 | 使用 CloudFront 默认 `*.cloudfront.net` 证书，因此不需要 `us-east-1` 的 ACM；需要品牌域名时再补 |
| R-35 | CloudFront 未启用地理限制 | 站点是公开静态内容，有意面向全球；`geo_restriction = none` 是显式选择 |

---

## CI/CD 相关

### R-21 CI apply 角色权限偏宽

- **场景**：`bootstrap/` 创建的 apply 角色能管理本仓库涉及的全部资源类型，资源范围是账户级。
- **影响**：如果 apply 工作流被滥用（恶意 plan + 有审批权的人放行），影响面是整个账户的
  网络/存储/KMS/日志/EC2/RDS 资源，而不限于本项目。
- **原因**：Terraform 的 `Create*` 动作作用的对象在执行前不存在，无法预先写成 ARN 白名单。
  硬要收窄会导致首次创建失败。
- **已实施（第一层）**：apply 角色挂载了**权限边界**
  `aws_iam_policy.apply_boundary`（[bootstrap/main.tf](../bootstrap/main.tf)）：
  - 只允许 `ec2` / `s3` / `kms` / `logs` / `rds` / `autoscaling` / `secretsmanager` /
    `sts` 和显式列出的 IAM 动作（没有 `iam:*`）；
  - 显式拒绝 `iam:CreateUser`、`iam:CreateAccessKey`、`iam:CreateLoginProfile`、
    `iam:AttachUserPolicy`、`iam:PutUserPolicy` 等凭据/提权动作；
  - 区域型 API 通过 `aws:RequestedRegion` 限定在 `var.aws_region`（默认 ap-northeast-1），
    全球型 API（IAM、STS）不受影响。
- **剩余风险与后续**：
  1. 边界内的服务仍是账户级资源范围，能创建 IAM 角色并以 EC2 实例配置文件的方式
     使用——恶意 plan 仍可能滥用。第二层应用 **SCP** 限制服务、区域和资源标签；
  2. 用 IAM Access Analyzer 基于 CloudTrail 生成更精确的策略；
  3. 长期方案是把 CI 放在专用的工作负载账户，通过跨账户角色访问目标账户。
- **检测**：`CKV_AWS_108/109/111/356/2_AWS_40` 对相关策略已内联豁免并写明理由；
  豁免一旦扩散到其他资源，Code Review 必须拒绝。
- **状态**：已缓解（权限边界已落地）；剩余收紧项（SCP、独立账户）属于组织层决策。

### R-22 plan 工件的可信度依赖 GitHub

- **场景**：`apply.yml` 应用的是从 GitHub Actions 工件库下载的 plan 文件。
- **影响**：对仓库有 write 权限的人理论上可以构造一个 run 并伪造工件。
- **缓解**：
  - 校验 run 必须由 `plan.yml` 产生、在环境分支上、`conclusion=success`；
  - 校验 `head_sha` 仍等于该环境分支的 HEAD；
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
4. R-21：apply 角色已挂权限边界，确认边界 ARN 与预期一致；SCP 是否到位另行评估。
5. R-27/R-28：跳板机的 SSM 访问权限、开发人员策略分发和 MFA 要求已确认。
6. R-29：已确认业务接受 RDS 单 AZ。
7. `make quotas`（R-18）显示配额充足；`make check-tags` 与 `make test` 全部通过。
8. `docs/PLAN-CHECKLIST.md` 的全部校验点通过。
