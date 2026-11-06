output "account_id" {
  description = "Account the roles were created in. Use it as the sanity check before pointing CI at this account."
  value       = local.account_id
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider."
  value       = local.oidc_provider_arn
}

output "plan_role_arn" {
  description = "Set this as AWS_ROLE_ARN in the terraform-plan GitHub environment."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arns" {
  description = "Map of environment to apply role ARN. Set each as AWS_ROLE_ARN in the matching GitHub environment."
  value       = { for env, role in aws_iam_role.apply : env => role.arn }
}

output "apply_permissions_boundary_arn" {
  description = "Permissions boundary attached to every apply role (allowed services, no IAM user credentials, deploy region only)."
  value       = aws_iam_policy.apply_boundary.arn
}

output "plan_subject_claims" {
  description = "Subject claims the plan role trusts, in both the legacy and the ID-carrying GitHub format."
  value       = [for prefix in local.repo_subject_prefixes : "${prefix}${var.plan_environment_name}"]
}

output "apply_subject_claims" {
  description = "Subject claims each apply role trusts, in both GitHub subject formats."
  value = {
    for env in var.environments : env => [
      for prefix in local.repo_subject_prefixes : "${prefix}${env}"
    ]
  }
}
