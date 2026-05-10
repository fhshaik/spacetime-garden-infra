# IRSA roles for cluster addons. Each role's trust policy is scoped to a single
# K8s ServiceAccount in a single namespace.
#
# Bootstrap order (preempts trap C.3 / A.7): the role must exist BEFORE the helm
# release whose pod assumes it. Helm releases declare depends_on these modules.
#
# These modules are gated by the enable_* variables so we can disable them
# wholesale on Vocareum labs that block iam:CreateRole.

module "cert_manager_irsa" {
  # Only needed for DNS-01 challenge (Route53 access). HTTP-01 solver
  # doesn't need any AWS perms.
  count   = var.enable_cert_manager && var.cert_manager_dns01_enabled ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                     = "${var.cluster_name}-cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  tags = local.default_tags
}

module "external_dns_irsa" {
  count   = var.enable_external_dns ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                     = "${var.cluster_name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = local.default_tags
}

module "external_secrets_irsa" {
  count   = var.enable_external_secrets ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                             = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = [local.secrets_manager_arn_pattern]
  external_secrets_kms_key_arns         = ["arn:aws:kms:${var.aws_region}:${local.account_id}:key/*"]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = local.default_tags
}
