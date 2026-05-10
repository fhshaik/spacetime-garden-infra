# Spacetime Garden Infra — Implementation Summary

This repo provisions the EKS / Argo CD / observability substrate that runs the
`spacetime-garden` application. Status: **scaffolded, not yet applied** —
fill in placeholders, run `make bootstrap-state`, then `make plan-dev`.

---

## Architecture diagram

### Top-down

```
                           Internet
                              │ HTTPS (cert-manager + Let's Encrypt, DNS-01 via Route53)
                              ▼
              ┌─────────────────────────────────┐
              │         AWS NLB                  │  ← provisioned by ingress-nginx
              │  (cross-zone routing enabled)    │     Service annotations
              └─────────────────────────────────┘
                              │ TCP 443
                              ▼
              ┌─────────────────────────────────┐
              │       ingress-nginx Pods         │  ← 2+ replicas, PDB minAvail=1
              │       (data path, hot)           │     Trap A.3: NLB target type=ip
              └─────────────────────────────────┘
                              │ HTTP
              ┌───────────────┼───────────────┐
              │               │               │
       /                /api/genomes   /api/breed   /api/gallery
              │               │               │               │
   ┌──────────▼──┐  ┌─────────▼─────────┐ ┌───▼────────────┐ ┌▼───────────────────┐
   │  frontend   │  │  genome-service   │ │ breeding-svc   │ │  gallery-service   │
   │  (nginx)    │  │  + Alembic mig.   │ │ (HPA)          │ │  (RDS reader)      │
   └─────────────┘  └────────┬──────────┘ └────────────────┘ └────────┬───────────┘
                             │                                          │
                             └──────────────┬───────────────────────────┘
                                            ▼
                                  ┌───────────────────┐
                                  │    RDS Postgres   │ ← multi-AZ in prod
                                  └───────────────────┘

   In-cluster platform (TF-managed Helm releases):
   ─────────────────────────────────────────────────────
   Argo CD ────── reconciles cluster from this repo's gitops/
   Argo Rollouts ─ canary controller (nginx traffic shaping, trap A.4)
   kube-prom-stack ─ Prometheus + Grafana + Alertmanager
                     (Grafana behind GitHub OAuth via ESO secret)
   Loki + Promtail ─ logs (cross-service request_id queryable)
   cert-manager ── LE staging + prod issuers, DNS-01 via Route53 IRSA
   external-dns ── Route53 records from Ingress hosts (IRSA)
   ESO ─────────── pulls DATABASE_URL / SMTP / OAuth from Secrets Manager
```

### Deployment data flow (one push to app-repo main → uat)

```
  dev push                                 (this is the cross-repo handshake)
   │
   ▼
  spacetime-garden CI ──── builds 4 images, pushes to ECR (tag = SHA)
   │
   ▼
  promote-uat.yaml ──── clones spacetime-garden-infra, yq-bumps
                        gitops/envs/uat/values.yaml <service>.image.tag, pushes
   │
   ▼
  Argo CD detects git change ──── computes diff, applies in sync waves:
   │                              wave 0: ExternalSecrets (DATABASE_URL etc)
   │                              wave 1: PreSync Job: alembic upgrade head
   │                              wave 2: Rollout spec updated
   ▼
  Argo Rollouts ──── 10% → AnalysisRun (Prom 5xx-rate, > 0 guard)
                     50% → AnalysisRun
                     100% → mark Healthy
                     OR abort + auto-rollback if analysis fails
```

---

## Doc map (read in this order if new)

| File | What for |
|---|---|
| **`SUMMARY.md`** *(this doc)* | Diagram + quickstart + placeholder inventory |
| `README.md` | Brief landing page |
| `INFRA_HANDOFF.md` | Original spec from planning phase (historical) |
| `HANDOFF_NOTES.md` | Spec distillation, trade-off tables, decision log |
| `ARCHITECTURE_REVIEW.md` | Production readiness review, defense Q&A |
| `IMPLEMENTATION_TRAPS.md` | 27 catalogued pitfalls, all preempted in code |
| `OPEN_ITEMS.md` | Unresolved decisions (8) + open implementation risks (10) |

---

## Repo structure

```
spacetime-garden-infra/
├── SUMMARY.md                       ← this doc
├── README.md, Makefile, .gitignore, .envrc.example, .editorconfig
├── INFRA_HANDOFF.md, HANDOFF_NOTES.md, ARCHITECTURE_REVIEW.md,
│   IMPLEMENTATION_TRAPS.md, OPEN_ITEMS.md
│
├── scripts/
│   ├── preflight.sh             validate aws/kubectl/gh/tf/helm/yq tooling
│   ├── bootstrap-state.sh       one-shot: S3 bucket + DynamoDB table for tfstate
│   └── argocd-login.sh          fetch admin password + port-forward
│
├── terraform/
│   ├── _bootstrap/              one-shot state backend (local state)
│   ├── modules/
│   │   └── cluster-bootstrap/   THE ONLY custom module
│   │       ├── helm-releases.tf      ingress-nginx, cert-manager, ESO,
│   │       │                         external-dns, Argo CD, Argo Rollouts,
│   │       │                         kube-prom-stack, Loki, Promtail
│   │       ├── irsa.tf               cert-manager + ext-dns + ESO IRSA roles
│   │       ├── cluster-issuers.tf    LE staging + prod (kubectl_manifest)
│   │       ├── secret-store.tf       ESO ClusterSecretStore
│   │       ├── main.tf               namespaces
│   │       ├── variables.tf, outputs.tf, providers.tf
│   └── live/
│       ├── _shared/             ECR (×4), Route53 zone, GitHub OIDC role
│       ├── dev/                 VPC + EKS + RDS + cluster-bootstrap
│       ├── uat/                 same shape, slightly larger
│       └── prod/                multi-AZ, t3.large, db.t4g.small multi-AZ
│
├── gitops/
│   ├── bootstrap/
│   │   └── argocd-root-app.yaml      kubectl apply this once, post-TF
│   ├── apps/
│   │   ├── platform-stack.yaml       Application: dashboards + alerts + ESO
│   │   ├── microservices.yaml        ApplicationSet: 4 svc × 3 envs = 12 Apps
│   │   └── pr-preview.yaml           ApplicationSet PR generator (commented out)
│   ├── charts/
│   │   └── microservice/             ONE parameterized chart for all 4 svc
│   │       ├── Chart.yaml, values.yaml
│   │       └── templates/            (12 templates, all preempt traps)
│   ├── platform-values/              Helm values for cluster addons
│   ├── dashboards/                   Grafana dashboards as ConfigMaps (trap D.5)
│   ├── alerts/                       PrometheusRules (node, pod, cert)
│   ├── monitoring/                   ExternalSecrets for Grafana OAuth + SMTP
│   └── envs/{dev,uat,prod}/
│       └── values.yaml               ← bumped by app-repo CI (locked format)
│
└── .github/workflows/
    ├── tf-plan.yaml                  matrix plan on PR
    └── tf-apply.yaml                 apply with environment approvals (uat/prod)
```

---

## Quickstart (8-step bootstrap)

These 8 steps take a fresh checkout to a working dev environment with the
4 services running. ~30 min if everything goes well.

### 1. Pre-flight
```bash
make preflight
```
Validates aws/terraform/kubectl/helm/gh/yq are installed and AWS creds work.

### 2. Resolve Day-0 blockers
Open `OPEN_ITEMS.md` and resolve §1.1 (domain) + §1.7 (AWS account ID).

### 3. Create TF state backend
```bash
make bootstrap-state
```
Creates `spacetime-garden-tfstate-<random>` S3 bucket + DynamoDB lock table.
Note the bucket name from output.

### 4. Fill in tfvars + backend bucket
For each of `terraform/live/{_shared,dev,uat,prod}/`:
- Copy `terraform.tfvars.example` → `terraform.tfvars`, edit
- Edit `backend.tf`: replace `<bucket-name>` with your bucket from step 3

### 5. Apply `_shared` first
```bash
cd terraform/live/_shared && terraform init && terraform apply
```
Outputs include the Route53 zone NS records — **delegate the domain at your
registrar to those NS values now**, before continuing.

### 6. Apply dev
```bash
make plan-dev
make apply-dev
# ~15 min — VPC + EKS + RDS + 9 Helm releases + IRSA wiring
```

### 7. Configure GitHub on app repo
On `fhshaik/spacetime-garden` Settings → Secrets and variables → Actions:

| Type | Name | Value |
|---|---|---|
| Variable | `AWS_ROLE_ARN` | output of `_shared`: `github_oidc_role_arn` |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `INFRA_REPO` | `fhshaik/spacetime-garden-infra` |
| Secret | `INFRA_REPO_TOKEN` | fine-grained PAT, contents:write on this repo only |

### 8. Bootstrap Argo CD
```bash
make kubeconfig
make argocd-bootstrap
make argocd-login   # in another terminal: opens https://localhost:8080
```
Argo CD reconciles `gitops/bootstrap/argocd-root-app.yaml`, which fans out to
the 4 services via the ApplicationSet. ~5 min for first sync.

Trigger an app-repo build to populate ECR. Verify dev URL serves the app:
`https://dev.spacetimegarden.dev`.

---

## Placeholder inventory

Search the repo for `TODO` or `<ACCOUNT>` to find every spot that needs your
input. Summary:

| File | Placeholder | What to fill in |
|---|---|---|
| `terraform/live/_shared/terraform.tfvars` | `domain_name` | Your bought domain |
| `terraform/live/{env}/terraform.tfvars` | `domain_name`, `alert_email_to`, `alert_email_from`, `tfstate_bucket` | After bootstrap-state runs |
| `terraform/live/*/backend.tf` | `<bucket-name>` | S3 bucket name from `_bootstrap` output |
| `gitops/envs/{env}/values.yaml` | `<ACCOUNT>` | Your 12-digit AWS account ID |
| `gitops/bootstrap/argocd-root-app.yaml` | `repoURL` | Your fork's URL if forked |
| `gitops/apps/*.yaml` | `repoURL` | Same |
| `gitops/monitoring/{alertmanager-smtp,grafana-oauth}-externalsecret.yaml` | `key: garden/dev/...` | Per-env path; replicate the file per env if needed |

External-system tasks (no code change, you do these by hand):
- Buy domain, delegate to Route53 NS records (after step 5)
- Create AWS Secrets Manager secrets:
  - `garden/{env}/alertmanager/smtp` (key: `password` = Gmail app password)
  - `garden/{env}/grafana/oauth` (keys: `client_id`, `client_secret`)
  - Per-service `garden/{env}/<service>/db` is auto-populated by Terraform
- Create GitHub OAuth App at github.com/settings/developers
  - Callback: `https://grafana.<domain>/login/github`
- Create fine-grained PAT for `INFRA_REPO_TOKEN`

---

## Trap → file mapping

Every trap from `IMPLEMENTATION_TRAPS.md` is preempted in code. Index:

| Trap | Where preempted |
|---|---|
| A.1 LE rate limits | `gitops/envs/dev/values.yaml` defaults to `letsencrypt-staging` |
| A.2 HTTP-01 vs DNS-01 | `terraform/modules/cluster-bootstrap/cluster-issuers.tf` uses DNS-01 |
| A.3 NLB annotations | `gitops/platform-values/ingress-nginx.values.yaml` |
| A.4 Rollouts nginx integration | `gitops/charts/microservice/templates/rollout.yaml` `trafficRouting.nginx` + `service-{stable,canary}.yaml` |
| A.5 Cert renewal silent fail | `gitops/alerts/node-and-cluster-rules.yaml` `CertExpiringSoon` rule |
| A.6 IngressClass confusion | All ingresses set `ingressClassName: nginx` |
| A.7 cert-manager IRSA order | `terraform/modules/cluster-bootstrap/helm-releases.tf` `depends_on` chain |
| B.1 Argo CD doesn't fire Helm hooks | `gitops/charts/microservice/templates/presync-migrate.yaml` uses `argocd.argoproj.io/hook` |
| B.2 Analysis divide-by-zero | `gitops/charts/microservice/templates/analysistemplate.yaml` `or > 0` guard |
| B.3 HPA fights Argo CD | `gitops/apps/microservices.yaml` `ignoreDifferences` for `/spec/replicas` |
| B.4 Self-heal off by default | `gitops/apps/microservices.yaml` enables `automated.{prune,selfHeal}` for dev/uat |
| B.5 Sync waves per-Application | One Application per (svc × env), migration Job lives in same Application as Rollout |
| B.6 Rollout vs Deployment | Chart's rollout.yaml uses `Rollout` CR exclusively |
| C.1 PDB + single-replica deadlock | `templates/pdb.yaml` only emits PDB when replicas ≥ 2 |
| C.2 ECR tag mutability | `terraform/live/_shared/main.tf` ECR module sets `IMMUTABLE` |
| C.3 ESO bootstrap order | `helm-releases.tf` `depends_on = [module.external_secrets_irsa]` |
| C.4 EBS PVs AZ-bound | Documented; only Prom/Loki have PVs, services are stateless |
| D.1 Secrets in values.yaml | `externalsecret.yaml` template; values files only reference Secrets Manager paths |
| D.2 Reclaim policy | Documented; demo uses defaults |
| D.3 imagePullPolicy | `values.yaml` defaults to `IfNotPresent` |
| D.4 delete vs drain | Documented in `ARCHITECTURE_REVIEW.md` |
| D.5 Grafana dashboards as ConfigMaps | `gitops/dashboards/golden-signals.configmap.yaml` |
| D.6 Loki cardinality | `gitops/platform-values/promtail.values.yaml` strips request_id from labels |
| D.7 OAuth callback exact match | `OPEN_ITEMS.md` §1.6 spells out the format |

---

## Demo-day reference

Have these bookmarked + open in tabs:
- Argo CD: `https://argocd.<domain>` (admin/<password from `make argocd-login`>)
- Grafana: `https://grafana.<domain>` (GitHub OAuth)
- Argo Rollouts dashboard: `kubectl argo rollouts dashboard` → `http://localhost:3100`
- AWS Console: ECR, RDS, EKS

`kubectl` aliases (add to `.envrc`):
```bash
alias k=kubectl
alias kgp='kubectl get pods'
alias kar='kubectl argo rollouts'
```

Demo path that hits the most rubric items in 10 minutes:
1. **Push code → canary** — push commit on app repo, watch promotion → Argo CD → canary roll
2. **Bad-image abort** — push a deliberate regression, watch AnalysisRun fail and auto-rollback
3. **AMI patching** — bump `release_version`, `terraform apply`, `kubectl get nodes -w` showing zero dropped requests
4. **Schema migration** — push the gallery_likes migration, watch PreSync Job run before pods cut over
5. **Alert email** — `kubectl delete pod -l app=...` to trigger CrashLoopBackOff alert, show Gmail arrival
6. **Cross-service log trace** — pick a request_id, query Loki across services to follow the request

---

## If something breaks

| Symptom | Look here |
|---|---|
| `terraform apply` fails on EKS module | Check AWS quotas (EIP, vCPU); IAM perms |
| ESO pods CrashLoopBackOff with WebIdentityErr | `IMPLEMENTATION_TRAPS.md` C.3 — IRSA timing |
| cert-manager Cert stuck `Issuing` | A.1 (LE rate limits) or A.2 (DNS-01 perms) |
| Argo CD Application Degraded | `kubectl describe rollout` + `kubectl argo rollouts get rollout` |
| Canary aborts at step 1 with no traffic | B.2 — generate synthetic traffic during canary |
| Browser cert warning | Using LE staging issuer — switch to `letsencrypt-prod` |
| Grafana 500 on login | OAuth callback URL mismatch (D.7) |
| ApplicationSet not generating Apps | Check `kubectl get appset -n argocd` events |
| Pods stuck Pending | `kubectl describe pod` — usually node capacity or PV-AZ binding (C.4) |

For deeper triage, see `ARCHITECTURE_REVIEW.md` §11 (defense Q&A — has 30-second
answers for every "what if X breaks" question).

---

## Decision log

| Decision | Choice | Source |
|---|---|---|
| Cluster topology | 1 cluster + 3 namespaces | `OPEN_ITEMS.md` §1.x |
| RDS strategy | Per-env instances | Same |
| Region | us-east-1 | Same |
| Ingress | ingress-nginx + cert-manager (DNS-01) | Same |
| Progressive delivery | Canary via Argo Rollouts | Same |
| TF modules | Community (`terraform-aws-modules/*`) + 1 custom | `feedback_terraform_modules` memory |
| Image tags | Full git SHA, ECR IMMUTABLE | `INFRA_HANDOFF.md` §12 |
| Stretch goals scaffolded | PR Preview (commented), kubecost values (off) | OPEN_ITEMS.md §1.2 |

Open items remaining in `OPEN_ITEMS.md`: domain name purchase, Gmail app
password, GitHub OAuth App creation. None block scaffolding; all block runtime.

---

## File count

80 files generated across 11 directories. Code-to-reuse ratio: ~25:75 — most
heavy lifting is delegated to `terraform-aws-modules/*` and upstream Helm
charts.
