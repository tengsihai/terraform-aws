###############################################################################
# CI/CD bootstrap: GitHub OIDC provider + least-privilege Terraform roles
#
# Apply this ONCE per account with administrator credentials. It creates:
#   * the GitHub OIDC identity provider
#   * a read-only plan role          (used by plan + drift detection)
#   * one write-capable apply role   per environment
#
# Scope of the trust: a workflow can only assume a role from the exact GitHub
# environment named in the subject claim. Fork pull requests never receive an
# OIDC token, and an unprotected environment cannot mint a protected one.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn

  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket_name}"

  repo_subject = "repo:${var.github_owner}/${var.github_repo}"

  # GitHub changed the OIDC subject claim to carry the owner and repository
  # numeric IDs, so the same workflow now produces BOTH of these:
  #
  #   repo:tengsihai/terraform-aws:environment:dev                       (legacy)
  #   repo:tengsihai@40748495/terraform-aws@1445773765:environment:dev   (current)
  #
  # Trust both. The login and the repository name are pinned, and logins cannot
  # contain '@', so the wildcarded numeric IDs do not widen the trust.
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
# OIDC provider
###############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.tags
}

###############################################################################
# Shared: remote state access
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

  # S3-native locking (use_lockfile = true) writes <key>.tflock and must be able
  # to delete it again. Scoped to lock files only: the pattern cannot match the
  # state object itself.
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
# Shared: read-only access Terraform needs to produce a plan
###############################################################################

data "aws_iam_policy_document" "plan_read" {
  #checkov:skip=CKV_AWS_356:A read-only plan role must describe resources it did not create. Describe and Get actions have no resource scoped form and the ARNs belong to the apply role so they cannot be pre-declared here.

  statement {
    sid       = "ReadNetworking"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadStorageConfig"
    effect = "Allow"
    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketEncryption",
      "s3:GetBucketLifecycleConfiguration",
      "s3:GetBucketLocation",
      "s3:GetBucketLogging",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
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
    sid    = "ReadIamForFlowLogsRole"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

###############################################################################
# Apply: mutations this stack performs
###############################################################################

data "aws_iam_policy_document" "apply_mutations" {
  #checkov:skip=CKV_AWS_356:Terraform creates resources whose ARNs do not exist yet so Create actions cannot be scoped to a resource list. The remaining blast radius is the account, which is why apply runs behind a required-reviewer approval.
  #checkov:skip=CKV_AWS_111:Write actions target resources that Terraform owns but has not created yet. The trusted tightening path is an SCP plus permission boundary, tracked as R-21 in docs/RISKS.md.
  #checkov:skip=CKV_AWS_109:See CKV_AWS_111. iam:PassRole is already constrained to vpc-flow-logs.amazonaws.com via iam:PassedToService.
  #checkov:skip=CKV_AWS_108:s3:GetObject and s3:PutObject cover the log bucket the same role creates and the state bucket handled by state_access. Account wide scoping is the current trade-off, tracked as R-21.

  statement {
    sid    = "ManageVpcNetworking"
    effect = "Allow"
    actions = [
      "ec2:AssociateRouteTable",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateEgressOnlyInternetGateway",
      "ec2:CreateInternetGateway",
      "ec2:CreateRoute",
      "ec2:CreateRouteTable",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSubnet",
      "ec2:CreateTags",
      "ec2:CreateVpc",
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteEgressOnlyInternetGateway",
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
}

###############################################################################
# Role definitions
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

  tags = merge(local.tags, { Role = "apply", Environment = each.value })
}

resource "aws_iam_role_policy" "apply" {
  for_each = toset(var.environments)

  name   = "terraform-apply"
  role   = aws_iam_role.apply[each.value].id
  policy = data.aws_iam_policy_document.apply_permissions.json
}
