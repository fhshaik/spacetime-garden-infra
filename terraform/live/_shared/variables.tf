variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Apex domain. Route53 hosted zone is created for this name."
  type        = string
}

variable "app_repo" {
  description = "GitHub owner/name of the application repo (CI assumes the OIDC role to push to ECR)."
  type        = string
  default     = "fhshaik/spacetime-garden"
}

variable "infra_repo" {
  description = "GitHub owner/name of this infra repo (read-only reference for documentation)."
  type        = string
  default     = "fhshaik/spacetime-garden-infra"
}

variable "services" {
  description = "Microservice names. Each becomes an ECR repo with IMMUTABLE tags."
  type        = list(string)
  default     = ["genome-service", "breeding-service", "gallery-service", "frontend"]
}
