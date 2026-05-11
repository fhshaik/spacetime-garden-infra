locals {
  env          = "dev"
  cluster_name = "garden-${local.env}"
  cidr         = "10.10.0.0/16"

  # Three AZs for cluster resilience; private subnets get the workloads.
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24", "10.10.103.0/24"]

  tags = {
    Env       = local.env
    Project   = "spacetime-garden"
    ManagedBy = "terraform"
  }
}

# Shared resources (Route53 zone, ECR repos, GH OIDC role).
data "aws_caller_identity" "current" {}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "shared/terraform.tfstate"
    region = var.aws_region
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = local.cluster_name
  cidr = local.cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required for AWS LB Controller / ingress-nginx Service-of-type-LoadBalancer
  # discovery — though we mostly use ingress-nginx, keeping these tags is safe.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS cluster + managed node group + AWS-managed addons
# ─────────────────────────────────────────────────────────────────────────────

# ─── VOCAREUM-ADAPTED ────────────────────────────────────────────────────────
# AWS Academy Lab denies iam:CreateRole + iam:CreateOpenIDConnectProvider.
# We use lab-provided pre-existing roles. IRSA is disabled.
# ─────────────────────────────────────────────────────────────────────────────

# Look up the pre-created Vocareum EKS roles by name pattern (the lab generates
# unique suffixes per session, so we filter dynamically).
data "aws_iam_roles" "lab_eks_cluster_role" {
  name_regex = ".*LabEksClusterRole.*"
}

data "aws_iam_roles" "lab_eks_node_role" {
  name_regex = ".*LabEksNodeRole.*"
}

locals {
  lab_eks_cluster_role_arn = tolist(data.aws_iam_roles.lab_eks_cluster_role.arns)[0]
  lab_eks_node_role_arn    = tolist(data.aws_iam_roles.lab_eks_node_role.arns)[0]
}

# Vocareum: writing raw EKS resources instead of the community module, because
# the module does an iam:GetRole on the assumed-role's source role (voclabs),
# which the lab explicitly denies. Raw resources skip that lookup.
#
# This is a "fake module" approach — we lose some convenience features (managed
# node group polling, automatic addons mgmt) but gain control over IAM calls.

resource "aws_security_group" "cluster" {
  name        = "${local.cluster_name}-cluster"
  description = "EKS cluster control plane comms"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.cluster_name}-cluster" })
}

resource "aws_security_group" "node" {
  name        = "${local.cluster_name}-node"
  description = "EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.cluster_name}-node" })
}

resource "aws_security_group_rule" "node_to_node" {
  description              = "Node-to-node all"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.node.id
}

resource "aws_security_group_rule" "cluster_to_node" {
  description              = "Cluster API to nodes"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "node_to_cluster" {
  description              = "Nodes to cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.node.id
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = local.lab_eks_cluster_role_arn

  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    endpoint_public_access  = true
    endpoint_private_access = true
    security_group_ids      = [aws_security_group.cluster.id]
  }

  # API_AND_CONFIG_MAP lets us use Access Entries (no IAM needed) plus
  # the legacy aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = local.tags
}

# AWS-managed cluster addons. ebs-csi-driver skipped (needs IRSA).
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = local.lab_eks_node_role_arn
  subnet_ids      = module.vpc.private_subnets
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable_percentage = 25
  }

  tags = local.tags

  depends_on = [aws_eks_cluster.this]
}

# Compatibility shim: cluster-bootstrap module + provider blocks expect
# `module.eks.cluster_*` outputs. We expose them via locals.
locals {
  cluster_endpoint_resolved        = aws_eks_cluster.this.endpoint
  cluster_ca_certificate_data      = aws_eks_cluster.this.certificate_authority[0].data
  cluster_name_resolved            = aws_eks_cluster.this.name
  node_security_group_id_resolved  = aws_security_group.node.id
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS Postgres — one per env (locked decision). Multi-AZ in prod only.
# Master password lives in Secrets Manager; ESO syncs DATABASE_URL into
# K8s Secrets per-service.
# ─────────────────────────────────────────────────────────────────────────────

resource "random_password" "rds_master" {
  length           = 32
  special          = true
  # Alphanumeric + safe chars only. % breaks Alembic configparser; @:/?# break URLs.
  override_special = "-_"
}

# Vocareum: Secrets Manager creation may be restricted. RDS password is in
# Terraform state (encrypted at rest in S3). For real AWS, restore the
# Secrets Manager resources here.

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.7"

  identifier        = "garden-${local.env}"
  engine            = "postgres"
  engine_version    = "16"
  family            = "postgres16"
  major_engine_version = "16"
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_allocated_storage
  storage_encrypted = true

  db_name  = "garden"
  username = "garden_admin"
  password = random_password.rds_master.result
  port     = 5432

  manage_master_user_password = false # we manage it ourselves
  multi_az                    = var.rds_multi_az
  publicly_accessible         = false

  # Vocareum: skip enhanced monitoring (creates an IAM role).
  create_monitoring_role = false
  monitoring_interval    = 0

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.rds.name

  backup_retention_period = local.env == "prod" ? 7 : 1
  deletion_protection     = local.env == "prod"
  skip_final_snapshot     = local.env != "prod"

  tags = local.tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "garden-${local.env}"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_security_group" "rds" {
  name        = "garden-${local.env}-rds"
  description = "Allow Postgres from EKS"
  vpc_id      = module.vpc.vpc_id

  # Pods get ENIs in the EKS-managed cluster SG (vpc-cni default), not our
  # node SG. Allow both so app pods AND any host-network workloads connect.
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id, aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Vocareum: per-service Secrets Manager secrets are skipped. After cluster is
# up, create K8s Secrets manually:
#   kubectl create secret generic genome-service-db -n garden-uat \
#     --from-literal=DATABASE_URL="postgresql+psycopg://garden_admin:${PASSWORD}@${RDS_ENDPOINT}:5432/garden"

output "rds_master_password_for_manual_secrets" {
  description = "Use this with kubectl create secret to wire up DATABASE_URL"
  value       = random_password.rds_master.result
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Route53 DNS records for ingresses.
# Standard subdomains use CNAMEs to the NLB hostname.
# The apex (spacetimegarden.xyz) uses an ALIAS — Route53's proprietary record
# type that resolves to the NLB dynamically. DNS spec forbids CNAMEs at apex
# (they'd conflict with the SOA/NS records).
# ─────────────────────────────────────────────────────────────────────────────

data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
  depends_on = [module.cluster_bootstrap]
}

locals {
  nlb_hostname = data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].hostname
  # us-east-1 NLB canonical zone ID. Static AWS-wide value, documented:
  # https://docs.aws.amazon.com/general/latest/gr/elb.html
  nlb_canonical_zone_id = "Z26RNL4JYFTOTI"
}

# Apex domain — ALIAS to NLB. Validates the cert-manager HTTP-01 path for prod
# whose hostname is the bare apex (e.g. https://spacetimegarden.xyz/).
resource "aws_route53_record" "apex" {
  zone_id = data.terraform_remote_state.shared.outputs.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = local.nlb_hostname
    zone_id                = local.nlb_canonical_zone_id
    evaluate_target_health = true
  }
}

# Subdomain CNAMEs — for dev/uat/argocd/grafana that are already pointing
# via the manual aws cli we ran earlier. Including here so re-applies are
# idempotent.
resource "aws_route53_record" "subdomain" {
  for_each = toset(["dev", "qa", "uat", "argocd", "grafana"])

  zone_id         = data.terraform_remote_state.shared.outputs.route53_zone_id
  name            = "${each.key}.${var.domain_name}"
  type            = "CNAME"
  ttl             = 60
  records         = [local.nlb_hostname]
  allow_overwrite = true   # records pre-existed from earlier manual CLI
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster bootstrap (Helm releases for cluster addons)
# Vocareum-mode: skips IRSA + cert-manager + external-dns + ESO.
# ─────────────────────────────────────────────────────────────────────────────

module "cluster_bootstrap" {
  source = "../../modules/cluster-bootstrap"

  env          = local.env
  cluster_name = aws_eks_cluster.this.name
  aws_region   = var.aws_region

  # IRSA disabled on Vocareum; pass empty string.
  oidc_provider_arn = ""

  route53_zone_id = data.terraform_remote_state.shared.outputs.route53_zone_id
  domain_name     = var.domain_name

  alert_email_to   = var.alert_email_to
  alert_email_from = var.alert_email_from

  # cert-manager re-enabled with HTTP-01 challenge mode (no IRSA required).
  # External LE servers fetch /.well-known/acme-challenge/<token> through the
  # public NLB → ingress-nginx → cert-manager solver pod. Zero AWS API calls.
  enable_cert_manager        = true
  cert_manager_dns01_enabled = false   # HTTP-01 mode

  # Still disabled (genuinely need IRSA / not worth the workaround time):
  enable_external_dns     = false   # using manual Route53 records
  enable_external_secrets = false   # using kubectl create secret
  enable_loki             = false   # times out; skipping for demo

  tags = local.tags

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.default,
  ]
}
