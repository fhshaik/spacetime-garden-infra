# cert-manager ClusterIssuers (LE staging + prod).
#
# Two solver modes:
#   - DNS-01 via Route53: needs IRSA → blocked on Vocareum.
#   - HTTP-01 via ingress-nginx: zero AWS perms. Just port 80 reachable.
# Selected by var.cert_manager_dns01_enabled.

locals {
  acme_staging_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
  acme_prod_url    = "https://acme-v02.api.letsencrypt.org/directory"

  # DNS-01 solver block (used when cert_manager_dns01_enabled = true)
  dns01_solver = {
    selector = {}
    dns01 = {
      route53 = {
        region       = var.aws_region
        hostedZoneID = var.route53_zone_id
      }
    }
  }

  # HTTP-01 solver block (used when cert_manager_dns01_enabled = false)
  # cert-manager creates a temp Ingress with cert-manager.io/cluster-issuer
  # annotation; ingress-nginx routes /.well-known/acme-challenge/<token>
  # to the cert-manager-acme-http-solver pod. Zero AWS API needed.
  http01_solver = {
    selector = {}
    http01 = {
      ingress = {
        class = "nginx"
      }
    }
  }

  active_solver = var.cert_manager_dns01_enabled ? local.dns01_solver : local.http01_solver
}

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
        server = local.acme_staging_url
        email  = var.alert_email_to
        privateKeySecretRef = {
          name = "letsencrypt-staging-key"
        }
        solvers = [local.active_solver]
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
        server = local.acme_prod_url
        email  = var.alert_email_to
        privateKeySecretRef = {
          name = "letsencrypt-prod-key"
        }
        solvers = [local.active_solver]
      }
    }
  })

  depends_on = [helm_release.cert_manager]
}
