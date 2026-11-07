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

###############################################################################
# 独立工程的部署角色
#
# 每个工程一个角色，只信任自己的仓库，只授予自己需要的权限。
# 它们不共用 terraform-apply-<env>（那是本仓库的基础设施写角色）。
###############################################################################

variable "react_aws_github_repo" {
  description = "GitHub repository (owner/repo) for the static frontend pipeline."
  type        = string
  default     = "tengsihai/react-aws"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.react_aws_github_repo))
    error_message = "react_aws_github_repo must look like owner/repo."
  }
}

variable "react_aws_site_bucket_arns" {
  description = "Buckets (bucket ARN only) the react-aws role may publish static content to."
  type        = list(string)
  default     = []
}

variable "react_aws_distribution_arns" {
  description = "CloudFront distribution ARNs the react-aws role may invalidate."
  type        = list(string)
  default     = []
}

variable "react_aws_site_kms_key_arns" {
  description = "KMS key ARNs encrypting the react-aws site bucket. PutObject with SSE-KMS needs GenerateDataKey; GetObject needs Decrypt."
  type        = list(string)
  default     = []
}

variable "lambda_aws_github_repo" {
  description = "GitHub repository (owner/repo) for the Lambda + API Gateway pipeline."
  type        = string
  default     = "tengsihai/lambda-aws"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.lambda_aws_github_repo))
    error_message = "lambda_aws_github_repo must look like owner/repo."
  }
}

variable "lambda_aws_artifact_bucket_arns" {
  description = "S3 buckets (bucket ARN only) the lambda-aws role may read/write SAM artifacts from. Include the aws-sam-cli-managed-default-* prefix when using sam deploy --resolve-s3."
  type        = list(string)
  default     = []
}

variable "lambda_execution_role_arns" {
  description = "Lambda execution role ARNs the lambda-aws deploy role may pass to lambda.amazonaws.com. These roles are created by the environment roots in this repository."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every role."
  type        = map(string)
  default     = {}
}
