output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this to add the cluster to your kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

output "rds_endpoint" {
  value     = module.rds.db_instance_endpoint
  sensitive = true
}

output "rds_secret_arn" {
  value = aws_secretsmanager_secret.db_master.arn
}

output "ecr_registry_url" {
  description = "Set as repo variable AWS_REGISTRY_URL on fhshaik/spacetime-garden."
  value       = data.terraform_remote_state.shared.outputs.ecr_registry_url
}

output "github_oidc_role_arn" {
  description = "Set as repo variable AWS_ROLE_ARN on fhshaik/spacetime-garden."
  value       = data.terraform_remote_state.shared.outputs.github_oidc_role_arn
}
