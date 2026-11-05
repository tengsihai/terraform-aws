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

output "plan_subject_claim" {
  description = "Subject claim the plan role trusts."
  value       = "${local.repo_subject}:environment:${var.plan_environment_name}"
}

output "apply_subject_claims" {
  description = "Subject claims the apply roles trust."
  value       = { for env in var.environments : env => "${local.repo_subject}:environment:${env}" }
}
