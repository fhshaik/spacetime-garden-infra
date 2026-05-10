# Infra Repo Handoff — `spacetime-garden-infra`

> **Read this first.** This document is a self-contained brief for a Claude
> Code session bootstrapping the *infrastructure* repo for the Spacetime
> Garden DevOps final project. The application repo (`spacetime-garden`) is
> already complete and pushed. Your job is to build the EKS/Terraform/Argo
> CD substrate that runs it.

---

## 1. Context — what you're stepping into

`spacetime-garden` is a black hole genome breeder turned into a
**production-ready DevOps demo** for a final project. Due **Sunday
2026-05-10, 11:59 PM** (today is 2026-05-06; ~4 days). Rubric is in the
app repo's `PLAN.md` — read it before doing anything else.

The work is split across two repos by design:

| Repo | Owns |
|---|---|
| **`spacetime-garden`** (done) | App code: React frontend, 3 FastAPI services, Dockerfiles, GitHub Actions CI, Alembic migration scripts, docker-compose for local dev. |
| **`spacetime-garden-infra`** (your job) | Terraform (VPC, EKS, RDS, ECR, IAM, DNS, ACM), Argo CD app-of-apps, Helm charts/values per service, Argo Rollouts (canary), kube-prometheus-stack + Loki + Promtail, GitHub OAuth for Grafana, Alembic PreSync Job, Alertmanager → email/Slack. |

There is **no overlap**. If something is application code, it lives in
`spacetime-garden`. If it's IaC, manifests, or platform configuration, it
lives in your repo.

### The cross-repo handshake (already in place from the app side)

The app repo's `.github/workflows/ci.yaml` builds & pushes 4 images to
ECR on every push to `main` and on every `v*.*.*` tag. It uses GitHub
OIDC to assume an AWS role:

- **It expects** these GitHub repo *variables*: `AWS_ROLE_ARN`,
  `AWS_REGION`, `INFRA_REPO`.
- **It expects** these GitHub repo *secrets*: `INFRA_REPO_TOKEN`
  (a fine-grained PAT or GitHub App token with `contents:write` on
  *your* infra repo only).

After CI completes successfully:
- On `main` push → `promote-uat.yaml` clones your infra repo and bumps
  `gitops/envs/uat/values.yaml` for all 4 services to the new SHA.
- On `v*.*.*` tag → `promote-prod.yaml` waits for CI on the tagged SHA
  to finish, then bumps `gitops/envs/prod/values.yaml`.

**The promotion workflows expect this YAML shape**, and *only* touch
`<service>.image.tag`:

```yaml
genome-service:
  image:
    repository: 123456789012.dkr.ecr.us-east-1.amazonaws.com/genome-service
    tag: <40-char SHA>
breeding-service:
  image: { repository: ..., tag: ... }
gallery-service:
  image: { repository: ..., tag: ... }
frontend:
  image: { repository: ..., tag: ... }
```

You own the `repository` URLs (and everything else); they own the
`tag` value. Argo CD watches these files and reconciles the cluster.

**Read these app-repo files** before proceeding — they pin the contract:
- `PLAN.md` — the full project plan + rubric coverage matrix
- `README.md` — architecture diagram, port assignments, wire-format rule
- `.github/workflows/ci.yaml` + `.github/workflows/README.md` — the CI side of the handshake
- `services/genome-service/Dockerfile` — note that it bakes Alembic + alembic.ini, so the same image runs migrations
- `frontend/Dockerfile` — note that it expects `API_BASE` env at runtime (envsubst into `/config.js`)

---

## 2. Architecture you're building

```
                       Internet (HTTPS, ACM cert, Route53)
                                │
                          ┌─────┴──────┐
                          │   ALB      │  ← AWS LB Controller
                          │   path-    │     URL-rewrite annotation strips
                          │   based    │     /api/ before forwarding
                          └─────┬──────┘
                                │
        ┌───────┬───────────────┼─────────────────────┐
        │       │               │                     │
       /    /api/genomes   /api/breed           /api/gallery
        │       │               │                     │
   ┌────▼────┐  │  ┌────────────▼─────┐  ┌────────────▼────────┐
   │frontend │  │  │ breeding-service │  │   gallery-service   │
   │ nginx   │  │  │   (no DB)        │  │     (RDS reader)    │
   │ + SPA   │  │  └──────────────────┘  └─────────┬───────────┘
   └─────────┘  │                                   │
                │  ┌────────────────┐               │
                └──▶ genome-service │───────────────┤
                   │   (RDS owner)  │               │
                   │  + Alembic     │               │
                   └───────┬────────┘               │
                           │                        │
                           └─────────┬──────────────┘
                                     │
                              ┌──────▼───────┐
                              │ RDS Postgres │
                              │  (multi-AZ   │
                              │   in prod)   │
                              └──────────────┘

   In-cluster:
   - Argo CD (app-of-apps) ─── reconciles from this repo's gitops/
   - Argo Rollouts ─────────── canary deploys with Prom analysis gate
   - kube-prometheus-stack ── metrics; Grafana behind GH OAuth
   - Loki + Promtail ──────── logs; queryable in Grafana
   - cert-manager ─────────── if needed for in-cluster certs
   - External Secrets Op ─── pulls from AWS Secrets Manager via IRSA
   - external-dns ─────────── manages Route53 records from Ingress hosts
   - aws-load-balancer-controller ── provisions the ALB
```

Three EKS environments (dev, uat, prod) — separate clusters or shared
cluster with namespaces. **Recommendation: one cluster, three
namespaces** (`garden-dev`, `garden-uat`, `garden-prod`). EKS control
plane is $0.10/hr each; running three is wasteful for a 4-day demo.
Three namespaces is rubric-compliant and demonstrates the same
promotion logic.

Each namespace has its own RDS instance to avoid cross-env data
contamination; if budget is a concern, a single RDS with three
databases is acceptable. Document which you chose in your repo's
README.

---

## 3. The split — what app vs infra owns

| Concern | App | Infra |
|---|:---:|:---:|
| Frontend & service code | ✅ | |
| Dockerfiles | ✅ | |
| Alembic migration *scripts* | ✅ (`services/genome-service/alembic/versions/`) | |
| GitHub Actions CI (build/test/push images) | ✅ | |
| GitHub Actions promotion (PR-bumps `gitops/envs/*/values.yaml`) | ✅ | |
| Terraform (VPC, EKS, RDS, ECR, IAM, Route53, ACM) | | ✅ |
| ECR repository creation + IMMUTABLE tag policy | | ✅ |
| GitHub OIDC role for app CI | | ✅ |
| Helm charts (per-service Deployment/Service/ServiceAccount/HPA/PDB/Ingress) | | ✅ |
| Argo Rollouts `Rollout` + `AnalysisTemplate` | | ✅ |
| Alembic `PreSync` Job manifest | | ✅ |
| Argo CD bootstrap + app-of-apps | | ✅ |
| kube-prometheus-stack, Loki, Promtail, Alertmanager | | ✅ |
| External Secrets Operator + IAM IRSA wiring | | ✅ |
| Grafana GitHub OAuth config | | ✅ |
| Alertmanager email/Slack receivers | | ✅ |

---

## 4. Required outputs from your repo back to the app repo

When you finish, the app repo's CI needs three repo *variables* and one
*secret* set in GitHub Settings → Secrets and variables → Actions on
the **`fhshaik/spacetime-garden`** repo:

| Where | Name | Source in your repo |
|---|---|---|
| Variable | `AWS_ROLE_ARN` | Terraform output: the ARN of the IAM role for `aws-actions/configure-aws-credentials` to assume via OIDC. The role's trust policy must allow `sts:AssumeRoleWithWebIdentity` from `token.actions.githubusercontent.com` for `repo:fhshaik/spacetime-garden:ref:refs/heads/main` and tag pushes. |
| Variable | `AWS_REGION` | The region you deploy to (recommend `us-east-1`). |
| Variable | `INFRA_REPO` | `fhshaik/spacetime-garden-infra` (the owner/name of *your* repo). |
| Secret | `INFRA_REPO_TOKEN` | A fine-grained GitHub PAT (or GitHub App installation token) with `contents:write` on *your* repo only. The app repo's promotion workflows clone, edit `gitops/envs/{uat,prod}/values.yaml`, and `git push`. |

The IAM role minimally needs to:
- `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`,
  `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`,
  `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`,
  `ecr:CompleteLayerUpload`, `ecr:PutImage` on the four ECR repos.

Put the role ARN, region, and registry URL into a Terraform `outputs.tf`
so they're easy to read post-apply. Document the four GitHub
configuration values in your repo's README.

---

## 5. Suggested Terraform layout

```
spacetime-garden-infra/
├── README.md
├── modules/
│   ├── vpc/                    # 3 AZs, public + private subnets, single NAT
│   ├── eks/                    # cluster + 1 managed node group, OIDC, IRSA helpers
│   ├── rds/                    # Postgres 16, encrypted, password in Secrets Manager
│   ├── ecr/                    # 4 repos, IMMUTABLE tags, scan-on-push, lifecycle (keep last 20)
│   ├── github-oidc/            # IAM OIDC provider + ECR-push role for the app repo
│   ├── dns/                    # Route53 zone reference, ACM cert (DNS validation)
│   └── cluster-addons/         # everything installed via Helm provider (see §6)
├── envs/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── backend.tf          # S3 bucket: spacetime-garden-tfstate, key: dev/terraform.tfstate, DDB lock table
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   ├── uat/                    # same structure, larger sizing
│   └── prod/                   # multi-AZ RDS, more nodes
├── gitops/
│   ├── platform/               # bootstrap manifests applied once
│   │   ├── argocd-bootstrap.yaml          # the root Argo CD Application that watches gitops/apps
│   │   └── (charts referenced by addons module: prom-stack values, loki values, etc.)
│   ├── apps/                   # Argo CD Applications (app-of-apps)
│   │   ├── root.yaml           # parent app pointing at apps/*.yaml
│   │   ├── genome-service.yaml
│   │   ├── breeding-service.yaml
│   │   ├── gallery-service.yaml
│   │   ├── frontend.yaml
│   │   └── platform-stack.yaml # prom-stack, loki, etc., if managed via Argo CD instead of TF Helm provider
│   ├── charts/
│   │   └── microservice/       # ONE parameterized chart used by all 4 services
│   │       ├── Chart.yaml
│   │       ├── values.yaml     # default values
│   │       └── templates/
│   │           ├── rollout.yaml          # Argo Rollouts Rollout (canary)
│   │           ├── service.yaml
│   │           ├── ingress.yaml          # ALB ingress (path-based, /api/ strip)
│   │           ├── serviceaccount.yaml   # for IRSA on services that need AWS access
│   │           ├── externalsecret.yaml   # ESO ExternalSecret pulling DATABASE_URL etc.
│   │           ├── hpa.yaml              # HPA on breeding-service only
│   │           ├── pdb.yaml              # PDB minAvailable: 1 on every service
│   │           ├── analysistemplate.yaml # Prom 5xx-rate gate for canary
│   │           └── presync-migrate.yaml  # Job that runs `alembic upgrade head` (genome-service only)
│   └── envs/
│       ├── dev/values.yaml     # repository URLs (locked), tags (default to "main"), env-specific replicas
│       ├── uat/values.yaml     # ← bumped by app repo's promote-uat.yaml
│       └── prod/values.yaml    # ← bumped by app repo's promote-prod.yaml
└── .github/workflows/
    ├── tf-plan.yaml            # PR runs `terraform plan` against all envs
    └── tf-apply.yaml           # main merge runs `terraform apply` (manual approval gate on prod)
```

Use one parameterized `microservice` chart instead of four near-identical
charts — saves ~80% of YAML and demonstrates better engineering taste.
The differences between services (DB or no DB, HPA or no HPA, etc.)
become flags in `values.yaml`.

---

## 6. The platform stack (cluster-addons module)

Install via the Helm provider in the `cluster-addons` module — they're
infrastructure, so they should `terraform apply` rather than be managed
by the very Argo CD they're providing. Bootstrap order matters:

1. `aws-load-balancer-controller` (with IRSA via the eks module's OIDC)
2. `external-dns` (with IRSA, owns Route53 records)
3. `cert-manager` (likely not needed if all certs come from ACM, but harmless)
4. `external-secrets-operator` (with IRSA → AWS Secrets Manager)
5. `argo-cd` (the GitOps reconciler)
6. `argo-rollouts` (Rollout CRDs)
7. `kube-prometheus-stack` (Prometheus, Grafana, node-exporter, kube-state-metrics, Alertmanager)
8. `loki` + `promtail` (logs into Grafana)

After Argo CD is up, point it at this repo's `gitops/apps/root.yaml` —
that root Application then declares all the per-service Applications
(app-of-apps).

### Specific gotchas

- **ESO bootstrap order:** the IAM role ESO uses must exist *before* ESO
  starts trying to sync ExternalSecrets. Either split into two
  `terraform apply` phases, or use `depends_on` carefully.
- **Argo Rollouts AnalysisTemplate needs traffic.** During UAT canary
  with no real users, the 5xx-rate query divides by zero and returns
  NaN, failing the analysis spuriously. Either run a synthetic-traffic
  CronJob during canary windows (`hey` against `/healthz` or `/breed`),
  or guard the PromQL with `or vector(0)`. Discover this on Day 4, not
  during the live demo.
- **Migrations are NOT a Helm hook in this stack.** Argo CD doesn't
  trigger Helm hooks the way the Helm CLI does. Use the
  `argocd.argoproj.io/hook: PreSync` annotation on a Kubernetes Job in
  the genome-service chart's templates. Sync waves: ExternalSecrets in
  wave 0, migration Job in wave 1, deployments in wave 2.
- **Image tag immutability** must be set on ECR repos
  (`image_tag_mutability = "IMMUTABLE"`), so the same SHA tag can never
  be repointed at a different build. This is what makes the "build
  once, promote everywhere" GitOps story actually safe.

---

## 7. Argo Rollouts canary configuration

The rubric requires "justify Blue/Green or Canary". Pick canary —
visually richer for the demo, supports automated metric-based gating.

For each service's Rollout:

```yaml
strategy:
  canary:
    steps:
      - setWeight: 10
      - pause: { duration: 60 }
      - setWeight: 50
      - pause: { duration: 60 }
      - setWeight: 100
    analysis:
      templates:
        - templateName: success-rate
      startingStep: 1
```

The `success-rate` AnalysisTemplate runs a Prometheus query like:

```yaml
metrics:
  - name: success-rate
    interval: 30s
    successCondition: result[0] >= 0.99
    failureLimit: 1
    provider:
      prometheus:
        address: http://prometheus-operated.monitoring:9090
        query: |
          sum(rate(http_requests_total{namespace="{{args.namespace}}",
                                       service="{{args.service}}",
                                       status!~"5.."}[2m]))
          /
          (sum(rate(http_requests_total{namespace="{{args.namespace}}",
                                        service="{{args.service}}"}[2m])) > 0)
```

The `> 0` guard is the critical bit — without it, zero traffic returns
NaN and the analysis fails open or closed unpredictably.

For the demo, intentionally deploy a regression that trips the gate
mid-rollout (e.g. throw 5xx in 30% of `/breed` calls). The visible
abort + auto-rollback is one of the strongest moments of the demo.

---

## 8. Day-2 scenarios (rubric items)

### AMI / OS patching (10% of grade)

The EKS managed node group has a `release_version` argument. Your
runbook is:

1. Look up the latest EKS-optimized AMI release version for your
   cluster's K8s version.
2. Bump the `release_version` variable in your env's tfvars.
3. `terraform apply`.
4. EKS rolls nodes one at a time, respecting PodDisruptionBudgets.
5. Demo with `kubectl get nodes -w` + a load generator
   (`hey -z 5m -c 50 https://uat.<domain>/api/breed`) showing zero
   dropped requests through the rotation.

PDBs (`minAvailable: 1`) on every service's chart are what make this
work. If a service has a single replica and `minAvailable: 1`, the
node drain blocks until a replacement pod is ready elsewhere — that's
the point.

### Schema migration (10% of grade)

Migration script lives in the *app* repo
(`services/genome-service/alembic/versions/`) and is baked into the
genome-service image. The infra repo provides the *runtime* mechanism:
an Argo CD `PreSync` hook Job in the genome-service chart that runs
`alembic upgrade head` from that image *before* the new pods cut over.

Pattern:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: genome-service-migrate-{{ .Values.image.tag | trunc 7 }}
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"   # after ExternalSecrets (wave 0)
spec:
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: genome-service     # for IRSA + ESO secret
      containers:
        - name: migrate
          image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
          command: ["alembic", "upgrade", "head"]
          envFrom:
            - secretRef:
                name: genome-service-db-secret
```

The "expand → migrate → contract" pattern is the talking point. The app
repo's migration `0002_add_gallery_likes.py` is the live demo: it adds
a new (nullable) column without breaking the running service.

---

## 9. Observability (15% of grade)

### Metrics

- `kube-prometheus-stack` Helm chart. Out of the box you get Prometheus,
  Grafana, node-exporter, kube-state-metrics, Alertmanager, and a fleet
  of pre-built dashboards (cluster, namespaces, pods).
- The app's services expose `/metrics` on port 8000 and emit
  `http_requests_total` + `http_request_duration_seconds`. Add
  `ServiceMonitor` resources to scrape them.
- Build/import a "Service Golden Signals" Grafana dashboard: RPS,
  latency p50/p95/p99, error rate, per service.

### Logs

- Loki + Promtail. Promtail runs as a DaemonSet, scrapes all pod logs.
- App services emit JSON logs with `service`, `request_id`, `path`,
  `status`, `duration_ms` — the request_id is propagated via
  `x-request-id` header, so cross-service log queries work. Show this
  off in the demo: pick a request_id from one service's logs, find the
  same id in another.

### Grafana access (rubric: no username/password, OAuth required)

Grafana exposed via its own Ingress at `grafana.<domain>` with ACM
cert. In `kube-prometheus-stack`'s `grafana.values`:

```yaml
grafana:
  admin:
    existingSecret: ""              # disable admin user
  grafana.ini:
    auth:
      disable_login_form: true
      disable_signout_menu: false
      oauth_auto_login: true
    auth.github:
      enabled: true
      allow_sign_up: true
      client_id: ${GH_OAUTH_CLIENT_ID}
      client_secret: ${GH_OAUTH_CLIENT_SECRET}
      scopes: user:email,read:org
      auth_url: https://github.com/login/oauth/authorize
      token_url: https://github.com/login/oauth/access_token
      api_url: https://api.github.com/user
      allowed_organizations: <your-org-or-personal-account-name>
    server:
      root_url: https://grafana.<domain>
```

The OAuth client ID and secret come from a GitHub OAuth App you create
manually (it's not Terraform-able). Store the secret in AWS Secrets
Manager; ESO syncs it into a K8s Secret that the Grafana Helm release
reads via `existingSecret`.

### Alerts (rubric: must fire to email)

Alertmanager config (in `kube-prometheus-stack` values):

```yaml
alertmanager:
  config:
    route:
      receiver: ops-email
      routes:
        - match: { severity: critical }
          receiver: ops-email
    receivers:
      - name: ops-email
        email_configs:
          - to: <your-email>
            from: garden-alerts@<domain>
            smarthost: smtp.gmail.com:587
            auth_username: <gmail-address>
            auth_password_file: /etc/alertmanager/secrets/smtp-password/password
            require_tls: true
```

Required alerting rules (rubric: CPU/memory/disk per node):
- `NodeCpuHigh` — `avg(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (node) > 0.85`
- `NodeMemoryHigh` — `(node_memory_MemTotal - node_memory_MemAvailable) / node_memory_MemTotal > 0.85`
- `NodeDiskHigh` — `(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes > 0.80`
- `ServiceErrorRateHigh` — service-level `http_requests_total{status=~"5.."}` rate
- `PodCrashLoopBackOff` — `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0`

For the demo, fire one alert intentionally during the chaos defense
segment to show the email landing.

---

## 10. Bootstrap sequence (run in this order)

1. **Bootstrap Terraform state backend.** Create S3 bucket
   `spacetime-garden-tfstate-<random>` and DynamoDB lock table
   `spacetime-garden-tfstate-lock`. Hand-rolled or via a one-shot
   Terraform run with local state.
2. **First env apply (dev).** `cd envs/dev && terraform apply`. Builds
   VPC + EKS + RDS + ECR + GH-OIDC role + DNS + cluster addons. ~15 min.
3. **Capture outputs.** `terraform output` → copy `aws_role_arn`,
   `aws_region`, and `ecr_registry_url`.
4. **Configure GitHub.** Set the four repo variables/secrets on the
   `fhshaik/spacetime-garden` repo (see §4).
5. **Trigger a build in the app repo.** Push a no-op commit on `main`,
   watch CI's `build-push` job succeed (it'll fail before this step).
6. **Bootstrap Argo CD.** `kubectl apply -f gitops/platform/argocd-bootstrap.yaml`
   pointing at this infra repo's `gitops/apps/root.yaml`. Argo CD
   reconciles all 4 services.
7. **Verify.** `https://dev.<domain>` loads the app; click Breed; rows
   land in RDS.
8. **Repeat for uat and prod.** Either separate clusters or shared
   cluster with namespaces — your call.

The whole thing is `terraform apply` away from being reproducible.
That's the rubric's "Day 1 fully automated" requirement.

---

## 11. Stretch / WOW factor candidates

The app repo's `PLAN.md` §7 lists these. The infra-side ones:

1. **PR Preview Environments.** Argo CD `ApplicationSet` with a
   PR generator. Each PR opened on the app repo spins up an isolated
   namespace + ephemeral subdomain (`pr-42.<domain>`). 3-4 hours of
   work, very impressive in the demo.
2. **kubecost.** Helm chart, free tier. Shows $/service in Grafana.
   ~1 hr.
3. **Chaos Mesh.** Pre-installed, the instructor picks a chaos type
   from a menu during defense. ~2 hrs. High risk / very memorable.
4. **OpenTelemetry traces in Tempo.** Grafana panel showing a request
   flowing across services. ~3 hrs.
5. **Cosign signing on ECR pushes.** Free rubric bonus. ~30 min once
   the IAM role has KMS perms.

Pick #1 + #2 if you have time. They're high-perceived-effort, low-risk.

---

## 12. Locked decisions (don't relitigate)

These were decided in the planning phase for `spacetime-garden`. Do
not change them unilaterally:

- **EKS, not ECS or Fargate-only.** Rubric requires self-hosted
  Prometheus *inside* the cluster.
- **RDS Postgres**, not Aurora or DynamoDB. Single migration owner is
  `genome-service`.
- **Canary, not Blue/Green.** Better demo narrative.
- **Loki + Promtail**, not ELK. RAM cost matters in a small cluster.
- **GitHub OAuth for Grafana**, not Google or Okta. Lowest setup cost.
- **us-east-1.** Cheapest, broadest service coverage.
- **uv** for any Python tooling in the infra repo (e.g. helper
  scripts). Matches the app repo.
- **Terraform**, not Pulumi or CDK. Rubric-mandated.
- **Image tag = full SHA**, not semver or branch name. The app repo's
  CI is locked to `${{ github.sha }}` — don't introduce a different
  scheme on the infra side.

## 13. Open questions for the user (ask if not specified)

- Domain name. Recommend `spacetimegarden.dev` if available; otherwise
  the user should buy one in Route53 today (NS propagation takes
  minutes for `.dev` since it's Route53-registered).
- AWS account ID + region (default `us-east-1`).
- Whether the user wants three EKS clusters or one cluster + three
  namespaces (recommend the latter for cost).
- Gmail address + app password for SMTP (Alertmanager).
- Slack webhook URL (optional; email is sufficient for the rubric).
- GitHub OAuth client ID/secret — user creates the OAuth App manually
  at `https://github.com/settings/developers`, callback
  `https://grafana.<domain>/login/github`.

---

## 14. Final reminders

- **Read `PLAN.md` in the app repo first.** It has the rubric, the
  presentation outline, the day-by-day execution plan. Your work
  must hook into the timeline laid out there.
- **Don't duplicate app code.** If you find yourself rewriting
  Pydantic models or genetics logic, you've crossed the boundary.
- **Test the cross-repo flow end-to-end** before declaring done:
  push a commit to the app repo's `main`, watch the SHA appear in
  your `gitops/envs/uat/values.yaml`, watch Argo CD sync, watch the
  canary roll, watch the new pods come up. This is the demo.
- **The rubric explicitly forbids ClickOps.** If you find yourself
  reaching for the AWS Console to fix something, write Terraform for
  it instead.
- **Budget ~$7-10/day** while the cluster is running idle. Tear it
  down between sessions.
