variable "name" {
  description = "Name prefix applied to every resource created by this module."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,30}$ (lowercase letters, digits, hyphens)."
  }
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

variable "account_id" {
  description = "12-digit AWS account ID used in the bucket and KMS policies."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name that stores the site content. Never public: CloudFront reads it through an Origin Access Control."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase, digits, dots and hyphens)."
  }
}

variable "log_bucket_id" {
  description = "Existing bucket that receives the site bucket's server access logs. Its policy must already allow logging.s3.amazonaws.com (the logging-s3 module does)."
  type        = string
  nullable    = false
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

variable "default_root_object" {
  description = "Object returned for requests to the distribution root."
  type        = string
  default     = "index.html"
}

variable "spa_mode" {
  description = "Map 403/404 responses to the default root object with HTTP 200 so client-side routers can handle deep links."
  type        = bool
  default     = false
}

variable "price_class" {
  description = "CloudFront edge location set. PriceClass_200 includes Asia, which matches the ap-northeast-1 origin."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be one of: PriceClass_100, PriceClass_200, PriceClass_All."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days a noncurrent object version is kept after being replaced."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be at least 1."
  }
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
