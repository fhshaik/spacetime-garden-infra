#!/usr/bin/env bash
# One-shot: create S3 bucket + DynamoDB table for Terraform state.
# After this runs, copy the bucket name into terraform/live/*/backend.tf.
set -euo pipefail

cd "$(dirname "$0")/.."

cd terraform/_bootstrap
terraform init
terraform apply -auto-approve

echo
echo "State backend created. Update each terraform/live/*/backend.tf with:"
terraform output -json | jq -r '"  bucket = \"" + .state_bucket_name.value + "\"\n  region = \"" + .aws_region.value + "\"\n  dynamodb_table = \"" + .lock_table_name.value + "\""'
