variable "env" {
  description = "Environment name (dev|uat|prod)."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "aws_region" {
  description = "AWS region the cluster lives in."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (output of the eks module). Empty string in Vocareum mode."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the project domain."
  type        = string
}

variable "domain_name" {
  description = "Apex domain or subdomain delegated to this project (e.g. spacetimegarden.xyz)."
  type        = string
}

variable "alert_email_to" {
  description = "Email address Alertmanager sends critical alerts to."
  type        = string
}

variable "alert_email_from" {
  description = "From address used by Alertmanager (e.g. garden-alerts@<domain>)."
  type        = string
}

variable "alertmanager_smtp_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret holding the Gmail SMTP app password (key: password)."
  type        = string
  default     = ""
}

variable "grafana_oauth_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret holding GitHub OAuth client_id/client_secret for Grafana."
  type        = string
  default     = ""
}

variable "platform_values_path" {
  description = "Filesystem path to the gitops/platform-values directory (relative to the calling stack)."
  type        = string
  default     = "../../../gitops/platform-values"
}

variable "github_org" {
  description = "GitHub org/user whose members can sign into Grafana."
  type        = string
  default     = "fhshaik"
}

variable "tags" {
  description = "Tags applied to IAM roles."
  type        = map(string)
  default     = {}
}

# Component toggles — flip off in dev to save resources.
variable "enable_kubecost" {
  description = "Install kubecost (stretch goal)."
  type        = bool
  default     = false
}

# Vocareum-style restricted IAM toggles.
variable "enable_cert_manager" {
  description = "Install cert-manager + ClusterIssuers."
  type        = bool
  default     = true
}

variable "cert_manager_dns01_enabled" {
  description = "Use DNS-01 challenge (requires Route53 IRSA). Set to false for HTTP-01 — works without any AWS IAM, suitable for restricted labs."
  type        = bool
  default     = true
}

variable "enable_external_dns" {
  description = "Install external-dns + IRSA. Disable on labs that block iam:CreateRole."
  type        = bool
  default     = true
}

variable "enable_external_secrets" {
  description = "Install ESO + IRSA + ClusterSecretStore. Disable on labs that block iam:CreateRole."
  type        = bool
  default     = true
}

variable "enable_loki" {
  description = "Install Loki + Promtail. Disable in restricted environments where the Helm release times out."
  type        = bool
  default     = true
}

variable "argocd_chart_version" {
  type    = string
  default = "7.3.11"
}
variable "argo_rollouts_chart_version" {
  type    = string
  default = "2.37.0"
}
variable "ingress_nginx_chart_version" {
  type    = string
  default = "4.10.1"
}
variable "cert_manager_chart_version" {
  type    = string
  default = "v1.15.1"
}
variable "external_dns_chart_version" {
  type    = string
  default = "1.14.5"
}
variable "external_secrets_chart_version" {
  type    = string
  default = "0.9.20"
}
variable "kube_prom_stack_chart_version" {
  type    = string
  default = "61.3.2"
}
variable "loki_chart_version" {
  type    = string
  default = "6.6.4"
}
variable "promtail_chart_version" {
  type    = string
  default = "6.16.4"
}
