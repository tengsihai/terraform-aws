provider "aws" {
  region = var.aws_region

  # Offline / CI syntax checks only.
  #
  # When `offline_mode` is true the provider never calls AWS: credentials are
  # placeholders and every remote lookup is skipped. That is what lets
  # `terraform validate` and `terraform plan` run on a laptop or CI runner with
  # no AWS account.
  #
  # It MUST be false for any plan that is meant to be reviewed before an apply,
  # because the resulting plan is not checked against the real account.
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
