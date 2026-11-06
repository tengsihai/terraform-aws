# bootstrap 的 state 和各环境的 state 放在同一个桶里，
# 这样本地目录被误删也不会让 IAM 角色变成孤儿资源。
#
# terraform init -reconfigure -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
