output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions to assume for full deployments (main branch)"
  value       = aws_iam_role.github_actions_deploy.arn
}

output "github_actions_plan_role_arn" {
  description = "ARN of the IAM role for GitHub Actions to assume for PR plans (read-only)"
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC Identity Provider"
  value       = aws_iam_openid_connect_provider.github.arn
}