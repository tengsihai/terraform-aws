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

variable "bastion_ami_id" {
  description = "Amazon Linux 2023 (arm64) AMI ID for the bastion. Refresh it from the public SSM parameter before rebuilding the instance."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.bastion_ami_id))
    error_message = "bastion_ami_id must look like ami-0123456789abcdef0."
  }
}

variable "bastion_instance_type" {
  description = "Bastion launch template instance type. Must match the arm64 AMI."
  type        = string
  default     = "t4g.micro"
}

variable "bastion_min_size" {
  description = "Bastion ASG minimum size. 0 means no instance and no compute/EBS cost by default."
  type        = number
  default     = 0
}

variable "bastion_max_size" {
  description = "Bastion ASG maximum size. The design caps the bastion at one instance."
  type        = number
  default     = 1
}

variable "bastion_desired_capacity" {
  description = "Bastion ASG desired capacity. Scale to 1 manually while a database session is needed."
  type        = number
  default     = 0
}

variable "db_local_port" {
  description = "Local port used by the SSM port-forwarding example and by DBeaver/Navicat."
  type        = number
  default     = 13306
}

variable "db_engine_version" {
  description = "MySQL engine version for RDS. A major.minor value such as \"8.4\" lets RDS pick the latest minor release."
  type        = string
  default     = "8.4"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Initial database created inside the RDS instance."
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  description = "RDS master user name. The password is generated and rotated by RDS in AWS Secrets Manager."
  type        = string
  default     = "admin"
}

variable "db_deletion_protection" {
  description = "Block deletion of the RDS instance."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final RDS snapshot on deletion."
  type        = bool
  default     = true
}
