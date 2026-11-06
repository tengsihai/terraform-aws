provider "aws" {
  region = var.aws_region

  # 仅供离线 / CI 语法检查使用。
  #
  # offline_mode 为 true 时，provider 完全不调用 AWS：凭证是占位符，
  # 所有远端查询都被跳过。这样才可以在没有 AWS 账户的笔记本或 CI runner 上
  # 执行 `terraform validate` 和 `terraform plan`。
  #
  # 凡是准备评审后 apply 的 plan，这个值必须为 false，
  # 否则生成的 plan 没有和真实账户做过校验。
  access_key                  = var.offline_mode ? "offline" : null
  secret_key                  = var.offline_mode ? "offline" : null
  skip_credentials_validation = var.offline_mode
  skip_requesting_account_id  = var.offline_mode
  skip_region_validation      = var.offline_mode
  skip_metadata_api_check     = var.offline_mode ? "true" : "false"

  default_tags {
    tags = local.common_tags
  }
}
