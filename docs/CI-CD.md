# CI/CD 配置说明

本仓库的流水线把「校验」「计划」「执行」拆成三个独立阶段，执行阶段必须由人审批。

```
PR 提交
  │
  ├─ pr-checks.yml       fmt · validate · tflint · shellcheck/actionlint · checkov
  │                      （无 AWS 凭据，fork PR 也跑）
  │
  └─ plan.yml            只读角色 → terraform plan → 计划摘要粘到 PR
                         （fork PR 跳过，因为拿不到 OIDC token）

合并到 main
  │
  └─ plan.yml            main 上的权威计划 → 上传 terraform-plan-<env> 工件
                         （含 .tfplan / plan.txt / plan.json / manifest.txt）

人工审批
  │
  └─ apply.yml           workflow_dispatch + GitHub Environment required reviewers
                         → 校验工件 → 应用「那一份」plan 文件（不重新 plan）

定时
  └─ drift-detection.yml  只读 plan，发现漂移开 issue，绝不 apply
```

## 1. 工作流职责

| 文件 | 触发 | 权限 | 作用 |
| --- | --- | --- | --- |
| `pr-checks.yml` | `pull_request`、push main | `contents: read` | 无凭据的快速校验 |
| `plan.yml` | `pull_request`、push main、手动 | `contents: read`、`id-token: write`、`pull-requests: write` | 生成可审批的 plan 工件 |
| `apply.yml` | 仅手动 | `contents: read`、`id-token: write`、`actions: read` | 应用已审批的 plan |
| `drift-detection.yml` | 工作日定时、手动 | `contents: read`、`id-token: write`、`issues: write` | 发现漂移并开 issue |

共用组件：

- `.github/actions/terraform-init/action.yml` — 装 Terraform、OIDC 换角色、带 S3 backend 参数 `init`
- `.github/scripts/render-plan-summary.py` — 把 `terraform show -json` 渲染成 Markdown 摘要

## 2. 一次性配置

### 2.1 创建 OIDC provider 与 IAM 角色

用管理员凭据执行一次 `bootstrap/`：

```bash
cd bootstrap
terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

产出：

```hcl
plan_role_arn   = "arn:aws:iam::<account>:role/terraform-plan"
apply_role_arns = {
  dev     = "arn:aws:iam::<account>:role/terraform-apply-dev"
  staging = "arn:aws:iam::<account>:role/terraform-apply-staging"
  prod    = "arn:aws:iam::<account>:role/terraform-apply-prod"
}
```

详见 [bootstrap/README.md](../bootstrap/README.md)。

### 2.2 GitHub Environments

在 **Settings → Environments** 创建四个环境：

| 环境 | Required reviewers | Deployment branches | 用途 |
| --- | --- | --- | --- |
| `terraform-plan` | 无 | **不限**（PR 也要跑 plan） | plan 与 drift 使用的只读角色 |
| `dev` | 可选 | `main` | dev apply |
| `staging` | **必须** | `main` | staging apply |
| `prod` | **必须**（≥2 人） | `main` | prod apply |

> `terraform-plan` 不要限制部署分支。如果把它限制为 `main`，来自功能分支的 PR 就拿不到
> 该环境的变量，`plan.yml` 会直接失败。

`required reviewers` 就是「人工审批」本身：`apply.yml` 的 job 声明了 `environment: <env>`，
在审批通过前不会执行任何步骤。**这一步无法用代码完成，必须在仓库设置里手工勾选。**

### 2.3 Variables

仓库级（Settings → Secrets and variables → Actions → Variables）：

| 名称 | 示例 | 说明 |
| --- | --- | --- |
| `AWS_REGION` | `ap-northeast-1` | state 桶与资源所在区域 |
| `TF_STATE_BUCKET` | `platform-terraform-state-790354569983-ap-northeast-1` | 远端 state 桶 |
| `TF_STATE_KMS_KEY_ARN` | `arn:aws:kms:...` | 可选，state 加密密钥 |
| `TF_ENVIRONMENTS` | `["dev"]` | 参与 plan / drift / apply 的环境，JSON 数组。默认 `["dev"]`；未接入的环境不要写进来 |

> `TF_ENVIRONMENTS` 是开关：只写了 `["dev"]` 时，staging / prod 不会被 plan，
> apply 也会拒绝它们。等 staging 的 state 桶和角色就绪后，改成
> `["dev","staging"]` 即可，不需要动代码。

环境级（每个 Environment 单独设置，覆盖仓库级）：

| 环境 | `AWS_ROLE_ARN` |
| --- | --- |
| `terraform-plan` | `arn:aws:iam::<account>:role/terraform-plan` |
| `dev` | `arn:aws:iam::<account>:role/terraform-apply-dev` |
| `staging` | `arn:aws:iam::<account>:role/terraform-apply-staging` |
| `prod` | `arn:aws:iam::<account>:role/terraform-apply-prod` |

> 只接入 dev 时，`bootstrap` 用 `environments = ["dev"]`，只需创建 `terraform-plan`
> 和 `dev` 两个 GitHub Environment。`TF_ENVIRONMENTS` 保持 `["dev"]`。

**不需要任何长期 AWS 密钥。** 全链路使用 OIDC 短期凭证。

### 2.4 分支保护

对 `main` 启用 required status checks（Settings → Branches）：

- `fmt + validate`
- `tflint`
- `shellcheck + actionlint`
- `checkov`

同时建议：

- Require pull request reviews（≥1）
- Require branches to be up to date before merging
- 禁止直接 push 到 `main`

### 2.5 Actions 全局设置

Settings → Actions → General：

- **Workflow permissions**：`Read repository contents and packages permissions`（默认最小权限）
- **Fork pull request workflows**：要求维护者批准后才运行
- 不允许 fork 访问 secrets（默认行为，不要打开）

## 3. 日常流程

### 提交 PR

```bash
git push origin feature/xxx
```

`pr-checks.yml` 与 `plan.yml` 自动运行。plan 摘要以**粘性评论**形式出现在 PR 上，
每个环境一条，重复推送会更新同一条评论而不是刷屏。

### 合并后准备 apply

```bash
# 找到当前 main 上成功的 plan run
gh run list --workflow=plan.yml --branch=main --limit 10 \
  --json databaseId,headSha,conclusion,createdAt

# 确认它对应 main 的 HEAD
git rev-parse origin/main
```

plan 摘要里的 commit 必须等于当前 `main` 的 HEAD。

### 发起 apply

```bash
gh workflow run apply.yml \
  -f environment=prod \
  -f plan_run_id=<上面的 databaseId> \
  -f confirmation=prod
```

随后：

1. GitHub 会显示该 run **等待审批**（因为 `prod` 环境配置了 required reviewers）；
2. 审批人打开 run，核对摘要里的 plan 内容与 `docs/PLAN-CHECKLIST.md`；
3. 审批通过后，job 才会开始执行。

`apply.yml` 在审批后会再做一遍机器校验（见下一节），任何一项不满足都会中止。

## 4. apply 阶段的安全校验

`apply.yml` 在真正执行前，逐项验证：

| 校验 | 失败后果 |
| --- | --- |
| 触发分支必须是 `main` | 拒绝执行 |
| `confirmation` 必须等于 `environment` | job 直接跳过 |
| plan run 的 `conclusion` 必须是 `success` | 拒绝执行 |
| plan run 的 `event` ∈ {push, workflow_dispatch} | 拒绝执行（PR 上的 plan 不能用来 apply） |
| plan run 的 `head_branch` 必须是 `main` | 拒绝执行 |
| plan run 必须由 `.github/workflows/plan.yml` 产生 | 拒绝执行 |
| plan run 的 `head_sha` 必须等于当前 `main` HEAD | 拒绝执行，要求重新 plan |
| 工件 `manifest.txt` 中的 `environment` 与输入一致 | 拒绝执行 |
| 工件的 `commit_sha` 与 plan run 的 `head_sha` 一致 | 拒绝执行 |
| plan 文件的 SHA-256 与 manifest 记录一致 | 拒绝执行（防篡改） |
| plan 生成时间 ≤ `PLAN_MAX_AGE_HOURS`（默认 24h） | 拒绝执行 |
| `plan.json` 的 `applyable` 必须为 `true` | 拒绝执行 |
| `env.tfvars` 的 `aws_account_id` 与所假设角色所属账户一致 | 拒绝执行 |

最后一步是：

```bash
terraform apply "<下载的 tfplan>"
```

**不带 `-out`、不重新 plan**，所以评审人看到的内容就是实际执行的内容。

此外，Terraform 自身还有一层保护：如果远端 state 在 plan 之后发生了变化，
`terraform apply <saved-plan>` 会报 "Saved plan is stale" 并拒绝执行。

## 5. 与「禁止自动 apply」的关系

仓库的本地脚本（`Makefile`、`scripts/*.sh`）仍然完全不提供 apply 入口。
唯一的执行路径是 `apply.yml`，它满足：

- 只能由人手动触发（`workflow_dispatch`）；
- 必须经过 GitHub Environment 的 required reviewers 审批；
- 执行对象是已评审的不可变 plan 工件，不是现场重新计算的计划。

也就是说：**自动化从不「决定」变更，只负责在人工批准后执行一个已经定稿的计划。**

## 6. 各检查拦截什么

| 检查 | 拦截的问题 |
| --- | --- |
| `terraform fmt -check` | 格式漂移导致的无意义 diff |
| `terraform validate` | 语法、类型、变量约束错误 |
| `tflint` | provider 用法错误、未使用声明、AWS 规则 |
| `shellcheck` | 脚本引号、未定义变量、错误处理 |
| `actionlint` | workflow 语法、表达式、shellcheck 检查内联脚本 |
| `checkov` | 安全基线，高危规则见 `scripts/checkov_gate.py` |
| account ID 校验 | 占位符账户 ID 被带上真实环境 |
| 工件校验 | 篡改、误用其他提交或其他环境的 plan |

## 7. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| `No valid credential sources found` | 本地用的是 AWS CLI 的 `login` 登录（`aws configure list` 里 credential type 显示为 `login`），Terraform 的 SDK 读不到。`plan.sh` 会自动导出会话凭证；手工执行时先跑 `eval "$(aws configure export-credentials --format env)"` |
| `Backend configuration changed` | 本地目录此前初始化成了别的后端。加 `-reconfigure` 重跑 `terraform init`（`plan.sh` 已自动处理） |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | 信任策略的 `sub` 与运行时环境名不匹配。检查 job 的 `environment:` 是否与 `bootstrap` 中的 `variables.environments` / `plan_environment_name` 一致 |
| plan 在 fork PR 上被跳过 | 预期行为：fork 拿不到 OIDC token。静态检查仍在 `pr-checks.yml` 中执行 |
| `env.tfvars aws_account_id is ... but the assumed role belongs to ...` | 把 `environments/<env>/env.tfvars` 里的占位符 `123456789012` 换成真实账户 ID |
| apply 报 `main moved since this plan was produced` | plan 之后有人合并了新提交。重新跑 `plan.yml`，用新的 run ID |
| apply 报 `plan is XXh old` | 超过 24 小时。重新 plan |
| apply 报 `Saved plan is stale` | plan 之后 state 被改动过（例如有人手工 apply）。重新 plan |
| drift issue 每天重复开 | 正常情况只会更新同一个 issue；标题为 `[drift] <env>` |
| `checkov` 失败 | 看 `reports/checkov-*/checkov-cli.txt`；修复问题，或在受影响资源上写 `#checkov:skip=<id>:<理由>` |

## 8. 已知限制

- **required reviewers 无法用代码配置**，必须在 GitHub UI 手工设置。
- **plan 工件的可信度依赖 GitHub Actions 本身**。有 write 权限的人可以伪造工件；
  因此审批人必须核对摘要，而不是只看「校验通过」。
- **bootstrap 的角色权限较宽**（见 `docs/RISKS.md` R-21），应配合 SCP / permission boundary 收窄。
- **fork PR 没有 plan**，只看静态检查。
- **没有 Terraform Cloud / Atlantis**，状态锁依赖 S3 的 `use_lockfile`。
