variable "offline_mode" {
  description = "CI-only escape hatch: run validate/plan without any AWS credentials or API calls. Never enable this for a plan that is going to be reviewed and applied."
  type        = bool
  default     = false
}

variable "project" {
  description = "Project slug used as the resource name prefix."
  type        = string
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/hyphen and at most 21 characters."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "12-digit AWS account ID. The value in env.tfvars is a PLACEHOLDER and must be replaced before any real plan or apply."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "azs" {
  description = "Exactly three availability zones."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

  validation {
    condition     = length(var.azs) == 3 && length(distinct(var.azs)) == 3
    error_message = "azs must contain exactly three distinct availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "Three IPv4 CIDRs for the public tier, one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "public_subnet_cidrs must contain exactly three CIDRs."
  }
}

variable "private_subnet_cidrs" {
  description = "Three IPv4 CIDRs for the private tier, one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "private_subnet_cidrs must contain exactly three CIDRs."
  }
}

variable "ipv6_enabled" {
  description = "Dual-stack the VPC with an AWS-generated /56 IPv6 CIDR."
  type        = bool
  default     = true
}

variable "public_subnet_ipv6_netnums" {
  description = "IPv6 /64 net numbers for the public subnets."
  type        = list(number)
  default     = [0, 1, 2]
}

variable "private_subnet_ipv6_netnums" {
  description = "IPv6 /64 net numbers for the private subnets."
  type        = list(number)
  default     = [8, 9, 10]
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign public IPv4 addresses in public subnets. Defaults to false (secure by default)."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Short service names to expose through Interface endpoints, e.g. [\"ssm\", \"ssmmessages\", \"ec2messages\"]."
  type        = set(string)
  default     = []
}

variable "additional_security_groups" {
  description = "Extra security groups. Ingress from 0.0.0.0/0 or ::/0 is rejected by the vpc module."
  type = map(object({
    description = string
    ingress = optional(list(object({
      description      = string
      from_port        = number
      to_port          = number
      protocol         = string
      cidr_blocks      = optional(list(string), [])
      ipv6_cidr_blocks = optional(list(string), [])
    })), [])
    egress = optional(list(object({
      description      = string
      from_port        = number
      to_port          = number
      protocol         = string
      cidr_blocks      = optional(list(string), [])
      ipv6_cidr_blocks = optional(list(string), [])
    })), [])
  }))
  default = {}
}

variable "flow_logs_retention_in_days" {
  description = "CloudWatch Logs retention for VPC flow logs."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "S3 log bucket object retention."
  type        = number
  default     = 90
}

variable "enable_s3_flow_logs" {
  description = "Also deliver VPC flow logs to the encrypted S3 log bucket."
  type        = bool
  default     = false
}
