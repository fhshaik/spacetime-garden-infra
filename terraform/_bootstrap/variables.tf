variable "aws_region" {
  description = "AWS region for the state backend."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project prefix for the bucket and table names."
  type        = string
  default     = "spacetime-garden"
}
