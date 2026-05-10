data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# Route53 hosted zone for the project domain. The user must update the
# domain registrar's NS records to delegate to the NS values output by this
# module before cert-manager DNS-01 challenges can succeed.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_route53_zone" "main" {
  name = var.domain_name
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR repositories — one per microservice. Tags IMMUTABLE so the same SHA can
# never be repointed at a different image (trap C.2). Scan-on-push enabled.
# Lifecycle policy keeps the last 20 images per repo.
# ─────────────────────────────────────────────────────────────────────────────

module "ecr" {
  source   = "terraform-aws-modules/ecr/aws"
  version  = "~> 2.2"
  for_each = toset(var.services)

  repository_name                 = each.value
  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# GitHub OIDC role for app-repo CI is DISABLED on Vocareum AWS Academy labs.
# The lab denies iam:CreateOpenIDConnectProvider and iam:CreateRole.
#
# Workaround: app-repo CI cannot push to ECR via OIDC. Push images manually
# from your laptop using lab credentials, or set static AWS_ACCESS_KEY_ID +
# AWS_SECRET_ACCESS_KEY repo secrets (rotated when lab session refreshes).
#
# In a real AWS account, restore this block to enable the standard OIDC flow.
# See ARCHITECTURE_REVIEW.md §4 for the design rationale.
# ─────────────────────────────────────────────────────────────────────────────
