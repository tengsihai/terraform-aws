###############################################################################
# CI/CD 引导配置：GitHub OIDC provider + 最小权限的 Terraform 角色
#
# 每个账户只需用管理员凭据执行一次，它会创建：
#   * GitHub OIDC 身份提供方
#   * 一个只读的 plan 角色（plan 与 drift 检测使用）
#   * 每个环境一个具备写权限的 apply 角色
#
# 信任范围：工作流只有在 sub 声明指定的那个 GitHub Environment 上下文中，
# 才能换取角色。fork 出来的 PR 拿不到 OIDC token，未受保护的环境也无法
# 签发受环境约束的凭证。
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn

  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket_name}"

  repo_subject = "repo:${var.github_owner}/${var.github_repo}"

  # GitHub 把 OIDC 的 sub 声明改成了带上 owner 和仓库的数字 ID，
  # 所以同一个工作流现在可能发出下面两种格式：
  #
  #   repo:tengsihai/terraform-aws:environment:dev                       （旧格式）
  #   repo:tengsihai@40748495/terraform-aws@1445773765:environment:dev   （当前格式）
  #
  # 两种都信任。login 和仓库名是精确匹配的，而且 login 不能包含 '@'，
  # 所以这里对数字 ID 用通配符并不会放宽信任范围。
  repo_subject_prefixes = [
    "${local.repo_subject}:environment:",
    "repo:${var.github_owner}@*/${var.github_repo}@*:environment:",
  ]

  tags = merge(var.tags, {
    "managed-by" = "terraform"
    "component"  = "ci-cd-oidc"
  })
}

###############################################################################
# OIDC 身份提供方
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.tags
}

###############################################################################
# 公共部分：远端 state 的访问权限
###############################################################################

data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListAndDescribeStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadWriteStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.state_bucket_arn}/${var.state_key_prefix}/*"]
  }

  # S3 原生锁（use_lockfile = true）会写入 <key>.tflock，也必须能把它删掉。
  # 这里只作用于锁文件：这个模式匹配不到 state 对象本身。
  statement {
    sid       = "ManageStateLockFiles"
    effect    = "Allow"
    actions   = ["s3:DeleteObject"]
    resources = ["${local.state_bucket_arn}/${var.state_key_prefix}/*.tflock*"]
  }

  dynamic "statement" {
    for_each = var.state_kms_key_arn == null ? [] : [var.state_kms_key_arn]

    content {
      sid       = "UseStateEncryptionKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = [statement.value]
    }
  }
}

###############################################################################
# 公共部分：生成 plan 所需的只读权限
###############################################################################

data "aws_iam_policy_document" "plan_read" {
  #checkov:skip=CKV_AWS_356:A read-only plan role must describe resources it did not create. Describe and Get actions have no resource scoped form and the ARNs belong to the apply role so they cannot be pre-declared here.

  statement {
    sid       = "ReadNetworking"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  # 刷新 S3 桶时会调用一组固定的桶配置 API。有些 IAM action 名和 API 名不一致
  # （GetAccelerateConfiguration 与 GetBucketAccelerateConfiguration），而 IAM
  # 对未知 action 名是静默忽略的，所以两种拼写都列上。这两种写法都不授予对象读取：
  # s3:GetObject 是作用在对象 ARN 上的，这里没有列。
  statement {
    sid    = "ReadStorageConfig"
    effect = "Allow"
    actions = [
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketEncryption",
      "s3:GetBucketLifecycleConfiguration",
      "s3:GetBucketLocation",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetBucketNotificationConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetRequestPaymentConfiguration",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadKeys"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListResourceTags",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadIamForWorkloadRoles"
    effect = "Allow"
    actions = [
      "iam:GetInstanceProfile",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfileTags",
      "iam:ListInstanceProfiles",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
    ]
    resources = ["*"]
  }

  # RDS 与 RDS 托管的主用户密钥都只做只读查询：
  # 密钥内容永远不会被 Terraform 读取，这里也没有 GetSecretValue。
  statement {
    sid    = "ReadDatabase"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBSnapshots",
      "rds:DescribeDBSubnetGroups",
      "rds:ListTagsForResource",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadDatabaseSecretsMetadata"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListTagsForResource",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAutoScaling"
    effect    = "Allow"
    actions   = ["autoscaling:Describe*"]
    resources = ["*"]
  }
}

###############################################################################
# Apply：本套配置会执行的变更操作
###############################################################################

data "aws_iam_policy_document" "apply_mutations" {
  #checkov:skip=CKV_AWS_356:Terraform creates resources whose ARNs do not exist yet so Create actions cannot be scoped to a resource list. The remaining blast radius is the account, which is why apply runs behind a required-reviewer approval.
  #checkov:skip=CKV_AWS_111:Write actions target resources that Terraform owns but has not created yet. The trusted tightening path is an SCP plus permission boundary, tracked as R-21 in docs/RISKS.md.
  #checkov:skip=CKV_AWS_109:See CKV_AWS_111. Both iam:PassRole statements are constrained by iam:PassedToService (vpc-flow-logs.amazonaws.com and ec2.amazonaws.com).
  #checkov:skip=CKV_AWS_108:s3:GetObject and s3:PutObject cover the log bucket the same role creates and the state bucket handled by state_access. Account wide scoping is the current trade-off, tracked as R-21.

  statement {
    sid    = "ManageVpcNetworking"
    effect = "Allow"
    actions = [
      "ec2:AssociateRouteTable",
      "ec2:AttachInternetGateway",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateEgressOnlyInternetGateway",
      "ec2:CreateFlowLogs",
      "ec2:CreateInternetGateway",
      "ec2:CreateRoute",
      "ec2:CreateRouteTable",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSubnet",
      "ec2:CreateTags",
      "ec2:CreateVpc",
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteEgressOnlyInternetGateway",
      "ec2:DeleteFlowLogs",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteRoute",
      "ec2:DeleteRouteTable",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSubnet",
      "ec2:DeleteTags",
      "ec2:DeleteVpc",
      "ec2:DeleteVpcEndpoints",
      "ec2:DetachInternetGateway",
      "ec2:DisassociateRouteTable",
      "ec2:ModifySubnetAttribute",
      "ec2:ModifyVpcAttribute",
      "ec2:ModifyVpcEndpoint",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["*"]
  }

  # 跳板机：RunInstances 会连带创建 EBS 卷和 ENI，EIP 需要独立分配/关联。
  statement {
    sid    = "ManageBastionInstances"
    effect = "Allow"
    actions = [
      "ec2:AllocateAddress",
      "ec2:AssociateAddress",
      "ec2:AssociateIamInstanceProfile",
      "ec2:AttachVolume",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:DetachVolume",
      "ec2:DisassociateAddress",
      "ec2:DisassociateIamInstanceProfile",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:ModifyVolume",
      "ec2:ReleaseAddress",
      "ec2:ReplaceIamInstanceProfileAssociation",
      "ec2:RunInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageDatabase"
    effect = "Allow"
    actions = [
      "rds:AddTagsToResource",
      "rds:CreateDBInstance",
      "rds:CreateDBSnapshot",
      "rds:CreateDBSubnetGroup",
      "rds:DeleteDBInstance",
      "rds:DeleteDBSubnetGroup",
      "rds:ModifyDBInstance",
      "rds:ModifyDBSubnetGroup",
      "rds:RemoveTagsFromResource",
      "rds:RestoreDBInstanceFromDBSnapshot",
    ]
    resources = ["*"]
  }

  # 跳板机是 ASG + Launch Template：实例由 ASG 拉起，没有 aws_instance 资源。
  statement {
    sid    = "ManageBastionAutoScaling"
    effect = "Allow"
    actions = [
      "autoscaling:CreateAutoScalingGroup",
      "autoscaling:CreateOrUpdateTags",
      "autoscaling:DeleteAutoScalingGroup",
      "autoscaling:DeleteTags",
      "autoscaling:UpdateAutoScalingGroup",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion",
      "ec2:DeleteLaunchTemplate",
      "ec2:DeleteLaunchTemplateVersions",
      "ec2:ModifyLaunchTemplate",
    ]
    resources = ["*"]
  }

  # 账户里第一次创建 ASG 时 AWS 会自动创建服务相关角色；
  # 这里把权限限定到 autoscaling 的服务相关角色 ARN 上。
  statement {
    sid       = "CreateAutoScalingServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
  }

  # 第一次创建 RDS 实例时，RDS 会以调用者身份创建 AWSServiceRoleForRDS。
  # 少了这条，CreateDBInstance 会报 "Verify that you have permission to
  # create service linked role"。
  statement {
    sid       = "CreateRdsServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS"]
  }

  # manage_master_user_password = true：RDS 以调用者身份在 Secrets Manager 里
  # 创建并轮转主用户密钥，所以 apply 角色需要这些动作（内容不会被 Terraform 读取）。
  statement {
    sid    = "ManageDatabaseSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListTagsForResource",
      "secretsmanager:PutSecretValue",
      "secretsmanager:RestoreSecret",
      "secretsmanager:RotateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = ["*"]
  }

  # 跳板机的实例角色、实例配置文件和挂在它上面的内联策略。
  statement {
    sid    = "ManageInstanceRoles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:DetachRolePolicy",
      "iam:GetInstanceProfile",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageLogBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutBucketEncryption",
      "s3:PutBucketLifecycleConfiguration",
      "s3:PutBucketLogging",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageLogKeys"
    effect = "Allow"
    actions = [
      "kms:CancelKeyDeletion",
      "kms:CreateAlias",
      "kms:CreateKey",
      "kms:DeleteAlias",
      "kms:DisableKey",
      "kms:EnableKey",
      "kms:EnableKeyRotation",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:UpdateAlias",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageFlowLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteLogStream",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageFlowLogsRole"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassFlowLogsRoleToVpcFlowLogs"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["vpc-flow-logs.amazonaws.com"]
    }
  }

  # EC2 启动跳板机时要代入它的实例角色。
  statement {
    sid       = "PassBastionRoleToEc2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

###############################################################################
# Apply 角色的权限边界（R-21）
#
# 身份策略（apply_mutations）已经按服务收窄；边界是第二道硬上限：
#   1. 只允许本仓库实际使用的服务；
#   2. 禁止创建 IAM 用户 / 访问密钥 / 登录配置 —— 这是最常见的提权路径；
#   3. 区域型 API 只允许部署区域，全球型 API（IAM、STS）不受影响
#      （StringNotEqualsIfExists 在请求没有该键时不会命中 Deny）。
###############################################################################

data "aws_iam_policy_document" "apply_boundary" {
  #checkov:skip=CKV_AWS_356: 权限边界本身按服务列出动作，具体资源由身份策略约束；边界的目的是收紧最大权限而不是重复资源白名单。
  #checkov:skip=CKV_AWS_111: 边界的 Allow 只是上限，实际写权限仍受 apply_mutations 身份策略的约束。
  #checkov:skip=CKV_AWS_109: 见 CKV_AWS_111；IAM 提权动作已在 DenyIdentityEscalation 中显式拒绝。
  #checkov:skip=CKV_AWS_108: 见 CKV_AWS_111。
  #checkov:skip=CKV_AWS_107: DenyOutsideDeployRegion 是 Deny 语句；not_action 只用来限定「这条拒绝作用于哪些动作」，不是在授予凭据访问。
  #checkov:skip=CKV_AWS_110: 同 CKV_AWS_107；Allow 语句只有服务白名单，提权动作由 DenyIdentityEscalation 显式拒绝。

  statement {
    sid    = "AllowedServices"
    effect = "Allow"
    actions = [
      "autoscaling:*",
      "ec2:*",
      "kms:*",
      "logs:*",
      "rds:*",
      "s3:*",
      "secretsmanager:*",
      "sts:*",
      # IAM 只列本仓库实际用到的动作：角色、内联策略、实例配置文件、
      # PassRole（由身份策略再按 iam:PassedToService 约束）和服务相关角色。
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:CreateRole",
      "iam:CreateServiceLinkedRole",
      "iam:DeleteInstanceProfile",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetInstanceProfile",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfileTags",
      "iam:ListInstanceProfiles",
      "iam:ListInstanceProfilesForRole",
      "iam:ListPolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:TagRole",
      "iam:UntagInstanceProfile",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyIdentityEscalation"
    effect = "Deny"
    actions = [
      "iam:AddUserToGroup",
      "iam:AttachUserPolicy",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateUser",
      "iam:PutUserPolicy",
      "iam:UpdateLoginProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid         = "DenyOutsideDeployRegion"
    effect      = "Deny"
    not_actions = ["iam:*", "sts:*"]
    resources   = ["*"]

    # 用 StringNotEquals 而不是 StringNotEqualsIfExists：IfExists 语句在请求里
    # **没有** aws:RequestedRegion 时也会命中，等于把所有全球型调用全部拒绝。
    # 全球型服务（IAM、STS）不携带这个键，这里用 NotAction 直接豁免。
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_policy" "apply_boundary" {
  name        = "${var.apply_role_name_prefix}-permissions-boundary"
  description = "Permissions boundary for Terraform apply roles (R-21): approved services only, no IAM user credentials, deploy region only."
  policy      = data.aws_iam_policy_document.apply_boundary.json

  tags = local.tags
}

###############################################################################
# 角色定义
###############################################################################

data "aws_iam_policy_document" "plan_permissions" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_access.json,
    data.aws_iam_policy_document.plan_read.json,
  ]
}

data "aws_iam_policy_document" "apply_permissions" {
  source_policy_documents = [
    data.aws_iam_policy_document.state_access.json,
    data.aws_iam_policy_document.plan_read.json,
    data.aws_iam_policy_document.apply_mutations.json,
  ]
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    sid     = "GitHubActionsPlan"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for prefix in local.repo_subject_prefixes : "${prefix}${var.plan_environment_name}"]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  for_each = toset(var.environments)

  statement {
    sid     = "GitHubActionsApply"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for prefix in local.repo_subject_prefixes : "${prefix}${each.value}"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = var.plan_role_name
  description          = "Read-only Terraform plan role for GitHub Actions"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600

  tags = merge(local.tags, { Role = "plan" })
}

resource "aws_iam_role_policy" "plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_permissions.json
}

resource "aws_iam_role" "apply" {
  for_each = toset(var.environments)

  name                 = "${var.apply_role_name_prefix}-${each.value}"
  description          = "Terraform apply role for the ${each.value} environment (human-approved runs only)"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust[each.value].json
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.apply_boundary.arn

  tags = merge(local.tags, { Role = "apply", Environment = each.value })
}

resource "aws_iam_role_policy" "apply" {
  for_each = toset(var.environments)

  name   = "terraform-apply"
  role   = aws_iam_role.apply[each.value].id
  policy = data.aws_iam_policy_document.apply_permissions.json
}
