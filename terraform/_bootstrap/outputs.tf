output "state_bucket_name" {
  description = "S3 bucket holding remote tfstate. Wire into terraform/live/*/backend.tf."
  value       = aws_s3_bucket.tfstate.bucket
}

output "lock_table_name" {
  description = "DynamoDB table for state locks."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "aws_region" {
  description = "Region the state backend is in."
  value       = var.aws_region
}
