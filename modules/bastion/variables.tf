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

variable "aws_region" {
  description = "Region used in ARNs and in the generated CLI commands."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID used to build the instance ARN in the developer policy."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "vpc_id" {
  description = "VPC the bastion security group is created in."
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "Subnet IDs the Auto Scaling group launches into. Public subnets in this design, so the SSM agent can reach the public SSM endpoints through the IGW."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) >= 1 && length(distinct(var.subnet_ids)) == length(var.subnet_ids)
    error_message = "subnet_ids must contain at least one distinct subnet ID."
  }
}

variable "ami_id" {
  description = "Amazon Linux 2023 arm64 AMI ID. Must match the architecture of instance_type."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "instance_type" {
  description = "Instance type for the launch template. The requirement is t4g.micro (arm64)."
  type        = string
  default     = "t4g.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB (gp3, encrypted, DeleteOnTermination = true)."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "root_volume_size must be at least 8 GiB."
  }
}

variable "min_size" {
  description = "ASG minimum size. Default 0: no instance (and no compute/EBS cost) unless someone scales it up."
  type        = number
  default     = 0

  validation {
    condition     = var.min_size >= 0
    error_message = "min_size must be 0 or greater."
  }
}

variable "max_size" {
  description = "ASG maximum size. The design caps the bastion at a single instance."
  type        = number
  default     = 1

  validation {
    condition     = var.max_size >= 1
    error_message = "max_size must be at least 1."
  }
}

variable "desired_capacity" {
  description = "ASG desired capacity. Default 0; scale to 1 manually while a database session is needed. Terraform ignores later manual changes."
  type        = number
  default     = 0

  validation {
    condition     = var.desired_capacity >= 0 && var.desired_capacity <= var.max_size
    error_message = "desired_capacity must be between 0 and max_size."
  }
}

variable "bastion_tag_key" {
  description = "Tag key put on every bastion instance and used as the condition in the developer IAM policy."
  type        = string
  default     = "Bastion"
}

variable "tags" {
  description = "Additional tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}
