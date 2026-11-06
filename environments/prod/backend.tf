###############################################################################
# 远端 state
#
# 这里不提交任何真实取值。初始化方式：
#
#   terraform init -backend-config=backend.hcl
#
# 把 backend.hcl.example 复制成 backend.hcl（已被 git 忽略）。
# 没有 AWS 账户时只做语法检查，可用 `terraform init -backend=false`。
###############################################################################

terraform {
  backend "s3" {}
}
