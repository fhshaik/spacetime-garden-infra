terraform {
  backend "s3" {
    # TODO: replace <bucket-name> with the value from `make bootstrap-state`
    bucket         = "spacetime-garden-tfstate-ef1c35e8"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "spacetime-garden-tfstate-lock"
    encrypt        = true
  }
}
