data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  namespaces = [
    "argocd",
    "argo-rollouts",
    "ingress-nginx",
    "cert-manager",
    "external-dns",
    "external-secrets",
    "monitoring",
  ]

  default_tags = merge({
    Env       = var.env
    Project   = "spacetime-garden"
    ManagedBy = "terraform"
    Component = "cluster-bootstrap"
  }, var.tags)

  # Secrets Manager scope for ExternalSecrets — only this env's secrets.
  secrets_manager_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:garden/${var.env}/*"
}

resource "kubernetes_namespace" "platform" {
  for_each = toset(local.namespaces)
  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "garden.alaris.security/env"   = var.env
    }
  }
}
