output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager (empty if disabled)."
  value       = try(module.cert_manager_irsa[0].iam_role_arn, "")
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for external-dns (empty if disabled)."
  value       = try(module.external_dns_irsa[0].iam_role_arn, "")
}

output "external_secrets_role_arn" {
  description = "IRSA role ARN for ESO (empty if disabled)."
  value       = try(module.external_secrets_irsa[0].iam_role_arn, "")
}

output "argocd_namespace" {
  description = "Namespace where Argo CD is installed."
  value       = "argocd"
}

output "secrets_manager_arn_pattern" {
  description = "ARN pattern that ESO is permitted to read."
  value       = local.secrets_manager_arn_pattern
}
