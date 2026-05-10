output "route53_zone_id" {
  description = "Route53 hosted zone ID. Pass into per-env stacks."
  value       = aws_route53_zone.main.zone_id
}

output "route53_zone_name_servers" {
  description = "NS records to set at the domain registrar to delegate to Route53."
  value       = aws_route53_zone.main.name_servers
}

output "ecr_registry_url" {
  description = "ECR registry URL. Set as repo variable AWS_REGISTRY_URL on the app repo."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "Per-service ECR URLs. Used in gitops/envs/*/values.yaml."
  value       = { for s in var.services : s => module.ecr[s].repository_url }
}

# GitHub OIDC role disabled on Vocareum (no iam:CreateOpenIDConnectProvider).
# In a real AWS account, restore this output.
# output "github_oidc_role_arn" {
#   value = aws_iam_role.github_oidc_app_ci.arn
# }

output "aws_account_id" {
  description = "AWS account ID."
  value       = data.aws_caller_identity.current.account_id
}
