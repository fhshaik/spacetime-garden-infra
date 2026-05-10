variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Apex domain (must match the one in _shared)."
  type        = string
}

variable "alert_email_to" {
  description = "Where Alertmanager sends critical alerts."
  type        = string
}

variable "alert_email_from" {
  description = "From address Alertmanager uses (e.g. garden-alerts@<domain>)."
  type        = string
}

variable "tfstate_bucket" {
  description = "Name of the S3 bucket holding shared TF state (output of _bootstrap)."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  type    = number
  default = 20
}

variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "single_nat_gateway" {
  description = "Single NAT Gateway across AZs (cost saver, SPOF). True for dev/uat, false for prod."
  type        = bool
  default     = true
}
