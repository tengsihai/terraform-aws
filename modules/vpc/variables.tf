###############################################################################
# 标识与归属
###############################################################################

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
  description = "Region the VPC lives in. Used to build the S3 gateway endpoint service name."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID. Used only when this module creates its own flow-log KMS key."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "tags" {
  description = "Additional tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}

###############################################################################
# 地址规划
###############################################################################

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC (e.g. 10.10.0.0/16). Must be large enough for six subnets."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 20
    )
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a /20 or larger address space (e.g. /16)."
  }
}

variable "azs" {
  description = "Exactly three distinct availability zones, one public + one private subnet per AZ."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.azs) == 3 && length(distinct(var.azs)) == 3
    error_message = "azs must contain exactly three distinct availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "Three IPv4 CIDRs, one per AZ, for the public tier."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "public_subnet_cidrs must contain exactly three CIDRs."
  }
}

variable "private_subnet_cidrs" {
  description = "Three IPv4 CIDRs, one per AZ, for the private tier."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "private_subnet_cidrs must contain exactly three CIDRs."
  }
}

variable "ipv6_enabled" {
  description = "Request an AWS-generated /56 IPv6 CIDR and dual-stack the VPC and all subnets."
  type        = bool
  default     = true
}

variable "public_subnet_ipv6_netnums" {
  description = "IPv6 /64 net numbers (0-255) carved out of the VPC /56 for the public subnets."
  type        = list(number)
  default     = [0, 1, 2]

  validation {
    condition = (
      length(var.public_subnet_ipv6_netnums) == 3 &&
      alltrue([for n in var.public_subnet_ipv6_netnums : n >= 0 && n <= 255])
    )
    error_message = "public_subnet_ipv6_netnums must contain exactly three numbers in the range 0-255."
  }
}

variable "private_subnet_ipv6_netnums" {
  description = "IPv6 /64 net numbers (0-255) carved out of the VPC /56 for the private subnets."
  type        = list(number)
  default     = [8, 9, 10]

  validation {
    condition = (
      length(var.private_subnet_ipv6_netnums) == 3 &&
      alltrue([for n in var.private_subnet_ipv6_netnums : n >= 0 && n <= 255])
    )
    error_message = "private_subnet_ipv6_netnums must contain exactly three numbers in the range 0-255."
  }
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign a public IPv4 address to ENIs in public subnets. Defaults to false: opt in per workload with an EIP."
  type        = bool
  default     = false
}

variable "assign_ipv6_address_on_creation" {
  description = "Auto-assign IPv6 addresses to ENIs in public subnets. Private subnets always default to false."
  type        = bool
  default     = false
}

variable "enable_dns_support" {
  description = "Enable DNS resolution inside the VPC."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Assign DNS hostnames to instances with public IPs. Required by many VPC endpoints."
  type        = bool
  default     = true
}

###############################################################################
# VPC 终端节点
###############################################################################

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway VPC endpoint. Required: this VPC has no NAT gateway, so S3 must be reached privately."
  type        = bool
  default     = true
}

variable "s3_endpoint_policy_json" {
  description = "Optional override for the S3 gateway endpoint policy. When null the module applies a data-plane-only policy; authorization remains enforced by IAM and bucket policies."
  type        = string
  default     = null
}

variable "interface_endpoint_services" {
  description = "Short service names (e.g. \"ssm\", \"ecr.api\") to expose through Interface endpoints. Interface endpoints carry an hourly + data cost, so the default is empty."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.interface_endpoint_services : !startswith(s, "com.amazonaws.")])
    error_message = "interface_endpoint_services expects short names such as \"ssm\", not full service names."
  }
}

variable "interface_endpoint_private_dns_enabled" {
  description = "Associate private hosted zones with the Interface endpoints so the default AWS DNS names resolve inside the VPC."
  type        = bool
  default     = true
}

###############################################################################
# Flow 日志
###############################################################################

variable "flow_logs_enabled" {
  description = "Publish VPC flow logs. Strongly recommended; turning this off fails the Checkov baseline."
  type        = bool
  default     = true
}

variable "flow_logs_traffic_type" {
  description = "Which traffic to capture: ALL, ACCEPT or REJECT."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be one of: ALL, ACCEPT, REJECT."
  }
}

variable "flow_logs_max_aggregation_interval" {
  description = "Flow log aggregation interval in seconds (60 or 600). 60 gives near-real-time security visibility."
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 600], var.flow_logs_max_aggregation_interval)
    error_message = "flow_logs_max_aggregation_interval must be 60 or 600."
  }
}

variable "flow_logs_retention_in_days" {
  description = "CloudWatch Logs retention for flow logs."
  type        = number
  default     = 365
}

variable "flow_logs_kms_key_arn" {
  description = "Existing KMS key for the flow-log log group. When null the module creates a dedicated rotating CMK."
  type        = string
  default     = null
}

variable "flow_logs_s3_bucket_arn" {
  description = "Optional second flow-log destination: an S3 bucket for long-term storage. Ignored unless flow_logs_s3_enabled is true."
  type        = string
  default     = null
}

variable "flow_logs_s3_enabled" {
  description = "Deliver flow logs to flow_logs_s3_bucket_arn as well. A separate flag is required because the bucket ARN is unknown at plan time and `count` may only depend on values known during planning."
  type        = bool
  default     = false
}

###############################################################################
# 附加安全组
###############################################################################

variable "additional_security_groups" {
  description = <<-EOT
    Extra security groups created inside the VPC.

    Public ingress is forbidden by design: any rule containing 0.0.0.0/0 or ::/0 in
    an inbound rule fails variable validation. Expose workloads through a load
    balancer, VPN or Transit Gateway instead.
  EOT
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

  validation {
    condition = alltrue([
      for sg in values(var.additional_security_groups) : alltrue([
        for rule in sg.ingress :
        !contains(rule.cidr_blocks, "0.0.0.0/0") && !contains(rule.ipv6_cidr_blocks, "::/0")
      ])
    ])
    error_message = "Ingress rules must not use 0.0.0.0/0 or ::/0. Public ingress is forbidden by this module's contract; terminate traffic at a load balancer, VPN or Transit Gateway instead."
  }

  validation {
    condition = alltrue([
      for sg in values(var.additional_security_groups) : alltrue([
        for rule in concat(sg.ingress, sg.egress) : length(trimspace(rule.description)) > 0
      ])
    ])
    error_message = "Every security group rule must carry a non-empty description (Checkov CKV_AWS_23)."
  }
}
