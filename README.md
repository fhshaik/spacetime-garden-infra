# spacetime-garden-infra

Infrastructure-as-code for the Spacetime Garden DevOps capstone. Provisions EKS, RDS, ECR on AWS via Terraform; deploys 4 microservices via Argo CD + Argo Rollouts; observability via kube-prometheus-stack + Loki.

**Start here:** `SUMMARY.md` for architecture diagram and quickstart.

## Doc map

| Doc | What's in it |
|---|---|
| `SUMMARY.md` | Architecture diagram, quickstart, placeholder inventory |
| `INFRA_HANDOFF.md` | Original spec from planning phase (historical) |
| `HANDOFF_NOTES.md` | Spec distillation + trade-offs + decision log |
| `ARCHITECTURE_REVIEW.md` | Production readiness review |
| `IMPLEMENTATION_TRAPS.md` | 27 implementation pitfalls with fixes |
| `OPEN_ITEMS.md` | Unresolved decisions + open implementation risks |

## Quickstart

```bash
# 0. Pre-flight: validate tools and creds
make preflight

# 1. Fill in terraform/live/dev/terraform.tfvars (copy from .example)

# 2. Bootstrap state backend (one-shot)
make bootstrap-state

# 3. Plan + apply dev environment
make plan-dev
make apply-dev

# 4. After dev is up: configure GitHub repo settings on fhshaik/spacetime-garden
#    (see SUMMARY.md "Cross-repo handshake")

# 5. Bootstrap Argo CD by applying the root app
make argocd-bootstrap-dev

# 6. Open Argo CD dashboard
make argocd-login
```

See `SUMMARY.md` for the full bootstrap sequence and placeholder inventory.

## Repo layout

```
terraform/        Infrastructure as code
  _bootstrap/     One-shot: S3 state bucket + DynamoDB lock table
  modules/
    cluster-bootstrap/   Custom: Helm releases for cluster addons
  live/
    {dev,uat,prod}/      Per-env Terraform stacks

gitops/           Argo CD-managed manifests
  bootstrap/      Argo CD root Application
  apps/           App-of-apps: ApplicationSets for platform + microservices
  charts/
    microservice/        ONE parameterized Helm chart for all 4 services
  cluster-issuers/       cert-manager ClusterIssuers
  platform-values/       Helm values for cluster addons
  dashboards/            Grafana dashboards as ConfigMaps
  alerts/                PrometheusRules
  envs/{dev,uat,prod}/   Per-env service image tags (← bumped by app repo CI)

.github/workflows/   tf-plan and tf-apply CI

scripts/             Helper scripts (bootstrap-state, preflight, argocd-login)
```
