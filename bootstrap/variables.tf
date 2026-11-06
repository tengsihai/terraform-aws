###############################################################################
# GitHub 仓库标识
###############################################################################

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository, e.g. \"acme\"."
  type        = string
  nullable    = false
}

variable "github_repo" {
  description = "Repository name, without the owner, e.g. \"terraform-aws\"."
  type        = string
  nullable    = false
}

###############################################################################
# GitHub OIDC 身份提供方
###############################################################################

variable "create_oidc_provider" {
  description = "Create the token.actions.githubusercontent.com OIDC provider. Set to false when the account already has one."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "Existing OIDC provider ARN. Required when create_oidc_provider is false."
  type        = string
  default     = null

  validation {
    condition     = var.create_oidc_provider || var.oidc_provider_arn != null
    error_message = "oidc_provider_arn must be set when create_oidc_provider is false."
  }
}

###############################################################################
# 角色需要访问的 state 后端
###############################################################################

variable "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state."
  type        = string
  nullable    = false
}

variable "state_kms_key_arn" {
  description = "Optional KMS key ARN encrypting the state object."
  type        = string
  default     = null
}

variable "state_key_prefix" {
  description = "Key prefix under which environment states live."
  type        = string
  default     = "network"
}

###############################################################################
# 部署区域
###############################################################################

variable "aws_region" {
  description = "Region the apply roles are allowed to manage (permissions boundary condition) and the region hinted in output."
  type        = string
  default     = "ap-northeast-1"
}

###############################################################################
# 角色
###############################################################################

variable "environments" {
  description = "Environments that get a dedicated apply role. Start with [\"dev\"]; adding staging/prod later means re-applying this bootstrap so the extra roles and trust policies exist."
  type        = list(string)
  default     = ["dev"]

  validation {
    condition     = alltrue([for e in var.environments : contains(["dev", "staging", "prod"], e)])
    error_message = "environments may only contain dev, staging, prod."
  }
}

variable "plan_role_name" {
  description = "Name of the read-only role used by plan and drift detection."
  type        = string
  default     = "terraform-plan"
}

variable "apply_role_name_prefix" {
  description = "Prefix for the write-capable per-environment apply roles."
  type        = string
  default     = "terraform-apply"
}

variable "plan_environment_name" {
  description = "GitHub environment name that plan jobs use. Must match the `environment:` in plan.yml and drift-detection.yml."
  type        = string
  default     = "terraform-plan"
}

variable "tags" {
  description = "Tags applied to every role."
  type        = map(string)
  default     = {}
}
