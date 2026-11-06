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
  description = "Deployment environment. Used for tagging and validation only."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_id" {
  description = "VPC the database security group is created in."
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group. AWS requires at least two subnets in different AZs."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) >= 2 && length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "subnet_ids must contain at least two distinct subnet IDs in different availability zones."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to open MySQL connections to this instance (the bastion's group). No other ingress is created."
  type        = list(string)
  default     = []
}

variable "engine_version" {
  description = "MySQL engine version. A major.minor value such as \"8.4\" lets RDS pick the latest minor release."
  type        = string
  default     = "8.4"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "allocated_storage must be at least 20 GiB for MySQL."
  }
}

variable "max_allocated_storage" {
  description = "Upper bound in GiB for RDS storage autoscaling. Set to 0 to disable autoscaling."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Name of the initial database created inside the instance."
  type        = string
  default     = "appdb"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,63}$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, digits and underscores (max 64)."
  }
}

variable "master_username" {
  description = "Master user name. The password is generated and rotated by RDS in AWS Secrets Manager."
  type        = string
  default     = "admin"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,15}$", var.master_username))
    error_message = "master_username must start with a letter and contain only letters, digits and underscores (max 16)."
  }
}

variable "port" {
  description = "TCP port the database listens on."
  type        = number
  default     = 3306
  nullable    = false
}

variable "backup_retention_period" {
  description = "Automated backup retention in days. 0 disables backups, which this module does not allow."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35 days."
  }
}

variable "deletion_protection" {
  description = "Block the instance from being deleted. Recommended for staging/prod, off for disposable environments."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on deletion. Keep false outside disposable environments."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of during the next maintenance window."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "Existing KMS key used for storage encryption. When null RDS uses the AWS-managed aws/rds key."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}
