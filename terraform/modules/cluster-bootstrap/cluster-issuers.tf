# cert-manager ClusterIssuers (LE staging + prod) with DNS-01 via Route53.
# Gated on enable_cert_manager — Vocareum labs that block iam:CreateRole
# can't run cert-manager, so these are skipped.

resource "kubectl_manifest" "letsencrypt_staging" {
  count = var.enable_cert_manager ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        email  = var.alert_email_to
        privateKeySecretRef = {
          name = "letsencrypt-staging-key"
        }
        solvers = [{
          selector = {}
          dns01 = {
            route53 = {
              region       = var.aws_region
              hostedZoneID = var.route53_zone_id
            }
          }
        }]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "letsencrypt_prod" {
  count = var.enable_cert_manager ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.alert_email_to
        privateKeySecretRef = {
          name = "letsencrypt-prod-key"
        }
        solvers = [{
          selector = {}
          dns01 = {
            route53 = {
              region       = var.aws_region
              hostedZoneID = var.route53_zone_id
            }
          }
        }]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}
