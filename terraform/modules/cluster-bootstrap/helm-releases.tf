# Helm releases for cluster addons.
#
# Three components (cert-manager, external-dns, external-secrets) require IRSA,
# so they're toggleable via enable_* variables. On Vocareum AWS Academy labs
# (which deny iam:CreateRole), set all three to false.
#
# When disabled:
#   - No HTTPS via Let's Encrypt — ingresses go HTTP-only or use static cert
#   - No automatic Route53 records — create A records manually after NLB is up
#   - No Secrets Manager → K8s Secret sync — create K8s Secrets manually

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = false
  atomic           = true
  timeout          = 600

  values = [
    file("${var.platform_values_path}/ingress-nginx.values.yaml"),
  ]

  # kube-prom-stack installs the ServiceMonitor CRD. ingress-nginx values
  # disable serviceMonitor by default, but we still order it after so a
  # future re-enable doesn't break.
  depends_on = [
    kubernetes_namespace.platform,
    helm_release.kube_prometheus_stack,
  ]
}

resource "helm_release" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = false
  atomic           = true
  timeout          = 600

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Only inject IRSA role-arn when DNS-01 is enabled. HTTP-01 doesn't need
  # cert-manager to talk to AWS at all.
  dynamic "set" {
    for_each = var.cert_manager_dns01_enabled ? [1] : []
    content {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.cert_manager_irsa[0].iam_role_arn
    }
  }

  values = [
    file("${var.platform_values_path}/cert-manager.values.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.platform,
    module.cert_manager_irsa,
  ]
}

resource "helm_release" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "external-dns"
  create_namespace = false
  atomic           = true
  timeout          = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_irsa[0].iam_role_arn
  }
  set {
    name  = "txtOwnerId"
    value = var.cluster_name
  }
  set {
    name  = "domainFilters[0]"
    value = var.domain_name
  }
  set {
    name  = "policy"
    value = "sync"
  }

  values = [
    file("${var.platform_values_path}/external-dns.values.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.platform,
    module.external_dns_irsa,
  ]
}

resource "helm_release" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = false
  atomic           = true
  timeout          = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa[0].iam_role_arn
  }

  values = [
    file("${var.platform_values_path}/external-secrets.values.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.platform,
    module.external_secrets_irsa,
  ]
}

resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = false
  atomic           = true
  timeout          = 900

  values = [
    file("${var.platform_values_path}/argo-cd.values.yaml"),
    var.enable_cert_manager ? yamlencode({
      server = {
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hostname         = "argocd.${var.domain_name}"
          tls              = true
          annotations = {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
            # argo-cd server runs in insecure (HTTP) mode behind ingress;
            # nginx terminates TLS and forwards HTTP to the pod.
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
          }
        }
      }
      }) : yamlencode({
      server = {
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hostname         = "argocd.${var.domain_name}"
          tls              = false
        }
      }
    }),
  ]

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_namespace.platform,
  ]
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.argo_rollouts_chart_version
  namespace        = "argo-rollouts"
  create_namespace = false
  atomic           = true
  timeout          = 600

  values = [
    file("${var.platform_values_path}/argo-rollouts.values.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.platform,
    helm_release.kube_prometheus_stack,
  ]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prom_stack_chart_version
  namespace        = "monitoring"
  create_namespace = false
  atomic           = true
  timeout          = 1200 # CRD install + admission webhook startup is slow

  values = compact([
    file("${var.platform_values_path}/kube-prometheus-stack.values.yaml"),
    # Vocareum mode: skip TLS issuer + Grafana OAuth secret references
    # because cert-manager and ESO aren't installed.
    var.enable_cert_manager ? yamlencode({
      grafana = {
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts            = ["grafana.${var.domain_name}"]
          tls = [{
            secretName = "grafana-tls"
            hosts      = ["grafana.${var.domain_name}"]
          }]
          annotations = {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          }
        }
      }
      alertmanager = {
        config = {
          global = {
            smtp_from          = var.alert_email_from
            smtp_smarthost     = "smtp.gmail.com:587"
            smtp_auth_username = var.alert_email_from
            smtp_require_tls   = true
          }
          route = {
            receiver = "ops-email"
            group_by = ["alertname", "namespace"]
          }
          receivers = [{
            name = "ops-email"
            email_configs = [{
              to                 = var.alert_email_to
              send_resolved      = true
              auth_password_file = "/etc/alertmanager/secrets/alertmanager-smtp/password"
            }]
          }]
        }
      }
      }) : yamlencode({
      grafana = {
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts            = ["grafana.${var.domain_name}"]
        }
      }
    }),
    # Disable persistent storage when ebs-csi (which needs IRSA) is unavailable.
    var.enable_external_secrets ? "" : yamlencode({
      grafana = {
        persistence = { enabled = false }
      }
      prometheus = {
        prometheusSpec = {
          storageSpec = null
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          storage = null
        }
      }
    }),
  ])

  # Reordered for Vocareum: kube-prom-stack provides ServiceMonitor CRD that
  # ingress-nginx + argo-rollouts both want. Install before them.
  depends_on = [
    kubernetes_namespace.platform,
  ]
}

resource "helm_release" "loki" {
  count = var.enable_loki ? 1 : 0

  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = var.loki_chart_version
  namespace        = "monitoring"
  create_namespace = false
  atomic           = true
  timeout          = 600

  values = compact([
    file("${var.platform_values_path}/loki.values.yaml"),
    # No persistent storage on Vocareum (no ebs-csi).
    var.enable_external_secrets ? "" : yamlencode({
      singleBinary = { persistence = { enabled = false } }
    }),
  ])

  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}

resource "helm_release" "promtail" {
  count = var.enable_loki ? 1 : 0

  name             = "promtail"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "promtail"
  version          = var.promtail_chart_version
  namespace        = "monitoring"
  create_namespace = false
  atomic           = true
  timeout          = 600

  values = [
    file("${var.platform_values_path}/promtail.values.yaml"),
  ]

  depends_on = [helm_release.loki]
}
