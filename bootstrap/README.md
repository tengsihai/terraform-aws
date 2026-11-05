# bootstrap — GitHub OIDC 与 Terraform 角色

一次性引导配置。用**管理员凭据**手工执行，不参与日常流水线。

## 为什么需要它

GitHub Actions 需要访问 AWS 才能 plan / apply。这里不使用长期密钥，而是：

1. AWS 信任 GitHub 的 OIDC 提供方 `token.actions.githubusercontent.com`；
2. 工作流运行时拿到一个短期 token；
3. 用 token 换取某个 IAM 角色的临时凭证；
4. 信任策略用 `sub` 声明限定「哪个仓库的哪个环境」才能换取。

fork 出来的 PR 拿不到 OIDC token，所以外部贡献者无法借此访问账户。

## 创建的东西

| 资源 | 信任条件 | 权限 |
| --- | --- | --- |
| `aws_iam_openid_connect_provider.github` | — | 仅作为信任锚点 |
| `aws_iam_role.plan` | `repo:<owner>/<repo>:environment:terraform-plan`（见下方 sub 格式说明） | 只读 + state 读写 |
| `aws_iam_role.apply["dev"]` | `repo:<owner>/<repo>:environment:dev` | 网络/存储/KMS/日志/IAM 变更 |
| `aws_iam_role.apply["staging"]` | `repo:<owner>/<repo>:environment:staging` | 同上（`environments` 含 staging 时才创建） |
| `aws_iam_role.apply["prod"]` | `repo:<owner>/<repo>:environment:prod` | 同上（`environments` 含 prod 时才创建） |

### sub claim 有两种格式

GitHub 把 OIDC 的 `sub` 改成了带数字 ID 的格式。同一个 workflow 现在可能发出：

```
repo:tengsihai/terraform-aws:environment:dev                     # 旧格式
repo:tengsihai@40748495/terraform-aws@1445773765:environment:dev # 新格式（带 owner/repo ID）
```

所以信任策略对两种都放行：login 和仓库名是精确匹配，数字 ID 用 `*`。login 不能包含
`@`，所以这个通配符不会放宽信任范围——攻击者无法注册一个 login 使 pattern 变宽。

排查方法：加一个临时 workflow，`permissions: id-token: write` 后解码
`ACTIONS_ID_TOKEN_REQUEST_URL` 返回的 JWT，看 `sub` 字段的实际值。

`environments` 默认是 `["dev"]`：只创建 dev 的 apply 角色。每个 apply 角色只对自己环境的
GitHub Environment 生效，即使有人拿到了 staging 的审批，也换不到 prod 的角色。

将来接入 staging/prod：把 `environments` 改成 `["dev","staging","prod"]` 重新 apply，
再把新角色的 ARN 填进对应的 GitHub Environment variables。

## 使用

```bash
cd bootstrap

cat > terraform.tfvars <<'EOF'
github_owner     = "acme"
github_repo      = "terraform-aws"
state_bucket_name = "platform-terraform-state-123456789012-ap-northeast-1"
# state_kms_key_arn = "arn:aws:kms:ap-northeast-1:123456789012:key/..."
EOF

terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

把输出的 `plan_role_arn` 和 `apply_role_arns` 填进 GitHub 的 Environment variables，
见 [docs/CI-CD.md](../docs/CI-CD.md) 第 2.3 节。

## 前置条件

- 目标账户已存在，且 `state_bucket_name` 指向的桶已创建（开启版本控制、加密、
  Block Public Access、S3 原生锁）。
- 执行者具备创建 IAM 角色与 OIDC provider 的权限。
- 如果账户里已经有 `token.actions.githubusercontent.com` 的 provider，
  设置 `create_oidc_provider = false` 并传入 `oidc_provider_arn`。

## 关于权限范围

apply 角色目前能管理本仓库涉及的资源类型，资源范围是账户级。这在 Terraform 里是
常见取舍：`Create*` 动作作用的对象在执行前还不存在，无法预先写成 ARN 白名单。

收紧路径（按优先级）：

1. 用 **permission boundary** 给角色加一条硬上限；
2. 用 **SCP** 限制可操作的区域和服务；
3. 用 IAM Access Analyzer 基于 CloudTrail 生成更精确的策略；
4. 把 apply 角色限制到专用的工作负载账户。

对应风险见 [docs/RISKS.md](../docs/RISKS.md) R-21。

## 销毁

`bootstrap` 只管角色和 provider，不碰 state 桶和业务资源。删除前请确认没有
workflow 仍在引用这些角色：

```bash
terraform destroy -target=aws_iam_role_policy.plan -target=aws_iam_role.plan
```
