locals {
  env          = "prod"
  cluster_name = "garden-${local.env}"
  cidr         = "10.30.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.30.1.0/24", "10.30.2.0/24", "10.30.3.0/24"]
  public_subnets  = ["10.30.101.0/24", "10.30.102.0/24", "10.30.103.0/24"]

  tags = {
    Env       = local.env
    Project   = "spacetime-garden"
    ManagedBy = "terraform"
  }
}

# Shared resources (Route53 zone, ECR repos, GH OIDC role).
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

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.20"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # AWS-managed addons (free, lifecycle-managed by AWS)
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      name           = "default"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # PDB-aware drain (trap C.1).
      update_config = {
        max_unavailable_percentage = 25
      }
    }
  }

  # Allow node-to-node traffic for Loki/Prometheus stack.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = local.tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${local.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS Postgres — one per env (locked decision). Multi-AZ in prod only.
# Master password lives in Secrets Manager; ESO syncs DATABASE_URL into
# K8s Secrets per-service.
# ─────────────────────────────────────────────────────────────────────────────

resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_master" {
  name = "garden/${local.env}/rds/master"
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = "garden_admin"
    password = random_password.rds_master.result
    engine   = "postgres"
    port     = 5432
  })
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.7"

  identifier        = "garden-${local.env}"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_allocated_storage
  storage_encrypted = true

  db_name  = "garden"
  username = "garden_admin"
  password = random_password.rds_master.result
  port     = 5432

  manage_master_user_password = false # we manage it ourselves via Secrets Manager
  multi_az                    = var.rds_multi_az
  publicly_accessible         = false

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
  description = "Allow Postgres from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Per-service DATABASE_URL secrets — these are populated by the user (or via a
# follow-up null_resource); ESO ExternalSecrets sync them into K8s.
resource "aws_secretsmanager_secret" "service_db" {
  for_each = toset(["genome-service", "gallery-service"])
  name     = "garden/${local.env}/${each.value}/db"
}

resource "aws_secretsmanager_secret_version" "service_db" {
  for_each  = aws_secretsmanager_secret.service_db
  secret_id = each.value.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql+psycopg://garden_admin:${random_password.rds_master.result}@${module.rds.db_instance_address}:5432/garden"
  })
}

# Placeholder secrets the user fills in manually post-apply.
resource "aws_secretsmanager_secret" "alertmanager_smtp" {
  name        = "garden/${local.env}/alertmanager/smtp"
  description = "Gmail SMTP app password — fill in via console or aws cli"
}

resource "aws_secretsmanager_secret" "grafana_oauth" {
  name        = "garden/${local.env}/grafana/oauth"
  description = "GitHub OAuth client_id + client_secret for Grafana — fill in via console"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cluster bootstrap (Helm releases for cluster addons)
# ─────────────────────────────────────────────────────────────────────────────

module "cluster_bootstrap" {
  source = "../../modules/cluster-bootstrap"

  env               = local.env
  cluster_name      = module.eks.cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn

  route53_zone_id = data.terraform_remote_state.shared.outputs.route53_zone_id
  domain_name     = var.domain_name

  alert_email_to               = var.alert_email_to
  alert_email_from             = var.alert_email_from
  alertmanager_smtp_secret_arn = aws_secretsmanager_secret.alertmanager_smtp.arn
  grafana_oauth_secret_arn     = aws_secretsmanager_secret.grafana_oauth.arn

  tags = local.tags
}
