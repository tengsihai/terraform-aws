# CI/CD 配置说明

本仓库的流水线把「校验」「计划」「执行」拆成三个独立阶段。**人工把关点是「合并 PR」**：
合并 = 审批，合并后自动部署。

```
PR 提交
  │
  ├─ pr-checks.yml       fmt · validate · tflint · shellcheck/actionlint · checkov
  │                      （无 AWS 凭据，fork PR 也跑）
  │
  └─ plan.yml            只读角色 → terraform plan → 计划摘要粘到 PR
                         （fork PR 跳过，因为拿不到 OIDC token）

人工合并（这就是审批）
  │
  ├─ plan.yml            main 上的权威计划 → 上传 terraform-plan-<env> 工件
  │                      （含 .tfplan / plan.txt / plan.json / manifest.txt）
  │
  └─ apply.yml           由 plan 完成自动触发，仅接受 main 上 push 产生的 plan
                         → 校验工件 → 应用「那一份」plan 文件（不重新 plan）

定时
  └─ drift-detection.yml  只读 plan，发现漂移开 issue，绝不 apply
```

## 1. 工作流职责

| 文件 | 触发 | 权限 | 作用 |
| --- | --- | --- | --- |
| `pr-checks.yml` | `pull_request`、push main | `contents: read` | 无凭据的快速校验 |
| `plan.yml` | `pull_request`、push main、手动 | `contents: read`、`id-token: write`、`pull-requests: write` | 生成可审批的 plan 工件 |
| `apply.yml` | plan 完成（自动） | `contents: read`、`id-token: write`、`actions: read` | 应用 main 上那份 plan |
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
| `dev` | **无**（合并即审批） | `main` | dev apply |
| `staging` | **必须**（接入前先加回来） | `main` | staging apply |
| `prod` | **必须**（≥2 人，接入前先加回来） | `main` | prod apply |

> `terraform-plan` 不要限制部署分支。如果把它限制为 `main`，来自功能分支的 PR 就拿不到
> 该环境的变量，`plan.yml` 会直接失败。

**合并就是审批。** 自动部署路径上 `dev` 不设 required reviewers——把关发生在 PR 阶段：
必须走 PR、必须过 4 项 required status checks、由人点合并。
`staging` / `prod` 在接入 `TF_ENVIRONMENTS` 之前必须把 required reviewers 加回来，
否则合并一次就把生产改了。

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

### 2.4 分支保护（自动部署的安全前提）

`main` 上已创建 ruleset `protect-main`（enforcement: active）：

| 规则 | 值 |
| --- | --- |
| Require a pull request before merging | 必须走 PR，**不允许直接 push** |
| Required approvals | 0（单人仓库；有第二个人时建议提到 1） |
| Require status checks | `fmt + validate`、`tflint`、`shellcheck + actionlint`、`checkov` |
| Require branches to be up to date | 开 |
| Block force pushes / deletion | 开 |

> 自动部署的安全性完全建立在这条 ruleset 上：绕过 PR 直接 push 就绕过了全部把关。
> 单人仓库把 approvals 设为 0 是为了让自己的 PR 也能合；团队仓库务必改成 ≥1。

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

### 合并 = 部署

4 项检查全绿后，直接合并。合并后自动发生：

1. `plan.yml` 在 main 上出权威 plan 并上传工件；
2. `apply.yml` 由该 plan 完成自动触发，校验后 apply。

**没有额外的审批点击。** 如果想在上生产前多一道人工确认，把 `prod` 环境的
required reviewers 加回来即可——`apply.yml` 的 job 绑定了 `environment`，会自动等待审批。

手动重放一条历史 plan（逃生通道）：

```bash
gh run rerun <失败的 apply run id>     # 重跑同一条 apply，不重新 plan
```

`apply.yml` 在执行前会做一遍机器校验（见下一节），任何一项不满足都会中止。

## 4. apply 阶段的安全校验

`apply.yml` 在真正执行前，逐项验证：

| 校验 | 失败后果 |
| --- | --- |
| plan run 的 `conclusion` 必须是 `success` | 拒绝执行 |
| plan run 的 `event` 必须是 `push`（即一次合并） | 拒绝执行（PR/手动 plan 不能用来 apply） |
| plan run 的 `head_branch` 必须是 `main` | 拒绝执行 |
| plan run 必须由 `.github/workflows/plan.yml` 产生 | 拒绝执行 |
| plan run 的 `head_sha` 必须等于当前 `main` HEAD | 拒绝执行，新合并会由自己的 run 接管 |
| 工件 `manifest.txt` 中的 `environment` 与目标一致 | 拒绝执行 |
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

## 5. 人工把关在哪里

本地脚本（`Makefile`、`scripts/*.sh`）仍然完全不提供 apply 入口。
唯一的执行路径是 `apply.yml`，它由「合并到 main」触发，把关点是：

- **必须走 PR**：main 上的 ruleset 禁止直接 push；
- **必须过 4 项 required status checks**：fmt/validate、tflint、shellcheck/actionlint、checkov；
- **必须由人点合并**：合并这个动作就是审批；
- 执行对象是该次合并产生的不可变 plan 工件，不是现场重新计算的计划；
- `staging` / `prod` 接入时把 required reviewers 加回 `apply.yml` 绑定的 Environment，
  即可在自动触发之上再加一道显式审批。

也就是说：**自动化从不「决定」变更，只负责在人工合并后执行那个已经定稿的计划。**

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
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | 信任策略的 `sub` 与 GitHub 实际发出的不一致。**GitHub 已把 sub 改成带数字 ID 的格式**：`repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<name>`，旧格式 `repo:<owner>/<repo>:environment:<name>` 也可能仍出现。`bootstrap` 两种都收（login 与仓库名钉死、数字 ID 用通配符，不会放宽信任范围）。排查时直接解码 workflow 拿到的 OIDC token 看 `sub` 字段 |
| `not authorized to perform: s3:DeleteObject ... .tflock` | S3 原生锁（`use_lockfile`）释放失败，`state_access` 缺锁文件删除权限，或锁文件残留。手动删 `<key>.tflock` 等价于 `terraform force-unlock` |
| plan 在 fork PR 上被跳过 | 预期行为：fork 拿不到 OIDC token。静态检查仍在 `pr-checks.yml` 中执行 |
| `env.tfvars aws_account_id is ... but the assumed role belongs to ...` | 把 `environments/<env>/env.tfvars` 里的占位符 `123456789012` 换成真实账户 ID |
| apply 报 `main moved since this plan was produced` | plan 之后有人合并了新提交。这是正常竞争：新合并会由它自己的 plan→apply 链路接管 |
| apply 报 `plan is XXh old` | 超过 24 小时。重新 plan |
| apply 报 `Saved plan is stale` | plan 之后 state 被改动过（例如有人手工 apply）。重新 plan |
| drift issue 每天重复开 | 正常情况只会更新同一个 issue；标题为 `[drift] <env>` |
| `checkov` 失败 | 看 `reports/checkov-*/checkov-cli.txt`；修复问题，或在受影响资源上写 `#checkov:skip=<id>:<理由>` |

## 7.1 操作红线

| 红线 | 原因 |
| --- | --- |
| **不要对运行中的 apply 执行 `gh run rerun`** | rerun 会**取消正在执行的 apply** 并重新开始，留下部分创建的资源。`terraform apply` 被打断是这套体系里最危险的操作之一 |
| 不要在 apply 运行时动 `TF_ENVIRONMENTS` | 同上，改变 environment 保护规则会取消等待中的 deployment |
| 出现 `Saved plan is stale` 不要 force-unlock | 这说明 state 已经前进。正确做法：重新出 plan，apply 会把已建资源识别为已存在，增量补齐剩余部分 |

**部分 apply 的恢复流程**（本次事故验证过）：

1. `Saved plan is stale` 出现，说明 state 与 plan 不一致，但**已创建的资源仍然合法存在**；
2. 确认没有残留锁：`aws s3api head-object --bucket <bucket> --key <key>.tflock`；
3. 重跑 `plan.yml`（合并产生的 plan run 直接 `gh run rerun <plan run id>`，或推一个新提交）；
4. 新 plan 会把已建资源视为 no-op，只补齐剩余部分；
5. apply 自动触发，恢复到完整状态。

如果部分 apply 是因为 IAM 权限不足，先补 `bootstrap` 的策略再走第 3 步。

## 8. 已知限制

- **required reviewers 无法用代码配置**，必须在 GitHub UI 手工设置。
- **plan 工件的可信度依赖 GitHub Actions 本身**。有 write 权限的人可以伪造工件；
  因此审批人必须核对摘要，而不是只看「校验通过」。
- **bootstrap 的角色权限较宽**（见 `docs/RISKS.md` R-21），应配合 SCP / permission boundary 收窄。
- **fork PR 没有 plan**，只看静态检查。
- **没有 Terraform Cloud / Atlantis**，状态锁依赖 S3 的 `use_lockfile`。
