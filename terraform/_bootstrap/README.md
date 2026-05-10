# Terraform State Backend Bootstrap

One-shot module that creates the S3 bucket + DynamoDB lock table used by every other Terraform stack in this repo. Run **once per AWS account**.

## Run it

```bash
cd terraform/_bootstrap
terraform init
terraform apply
```

Or use the helper:

```bash
make bootstrap-state
```

After apply, the outputs print the bucket and lock-table names. Wire those into each `terraform/live/{env}/backend.tf` file (replace `<bucket-name>` placeholder).

## Why this is separate

This module uses local state (no `backend.tf`). It can't store its own state in the bucket it's about to create. After it runs, every other module uses S3 backend.

## Don't destroy

Destroying this also destroys the state bucket — and with it, the state of every env. If you genuinely need to start over, run `terraform destroy` in each env first, then this last.
