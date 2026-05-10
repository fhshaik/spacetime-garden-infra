output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "kubeconfig_command" {
  description = "Run this to add the cluster to your kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name} --alias ${aws_eks_cluster.this.name}"
}

output "rds_endpoint" {
  value     = module.rds.db_instance_endpoint
  sensitive = true
}

output "ecr_registry_url" {
  description = "Set as repo variable AWS_REGISTRY_URL on fhshaik/spacetime-garden."
  value       = data.terraform_remote_state.shared.outputs.ecr_registry_url
}

# GitHub OIDC role disabled on Vocareum.
# output "github_oidc_role_arn" {
#   value = data.terraform_remote_state.shared.outputs.github_oidc_role_arn
# }
