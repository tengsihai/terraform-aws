variable "name" {
  description = "Name prefix for resources created by this module."
  type        = string
  nullable    = false
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod). Used for tagging and validation only."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for the log archive."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase, digits, dots and hyphens)."
  }
}

variable "account_id" {
  description = "12-digit AWS account ID used in bucket and KMS policies."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before the rotating CMK is destroyed."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "kms_deletion_window_in_days must be between 7 and 30."
  }
}

variable "log_retention_days" {
  description = "Number of days log objects are kept before expiration."
  type        = number
  default     = 365
}

variable "noncurrent_version_retention_days" {
  description = "Days a noncurrent object version is kept after being replaced."
  type        = number
  default     = 90
}

variable "enable_vpc_flow_log_delivery" {
  description = "Allow delivery.logs.amazonaws.com to write VPC flow logs into this bucket (bucket policy + KMS policy)."
  type        = bool
  default     = false
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket even when it still holds objects. Keep false outside disposable sandboxes."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}
