# Open Items & Unresolved Risks

Consolidated punch list of everything not yet decided or fully solved. Read this before starting Day 1; revisit at start of each day.

Two categories:
1. **Open decisions** — TBD items the user must resolve, blocking certain build steps.
2. **Open implementation risks** — known gaps in the plan where the doc describes the *what* but not the *exact how*. These need an implementation choice during build.

---

## 1. Open decisions

### 1.1 — Domain name
**Status:** TBD, user is purchasing.
**Blocks:** cert-manager ClusterIssuer config, Route53 hosted zone Terraform, ingress hostnames, GitHub OAuth App callback URL, Grafana `root_url`, Alertmanager `from` address.
**Default plan if unspecified:** none — this genuinely blocks. Cannot scaffold ingress, cert-manager, or Grafana OAuth without a domain.
**Recommended:** `spacetimegarden.dev` via Route53. NS propagation for `.dev` is fast since it's Route53-registered. If you go elsewhere (e.g., Namecheap), delegate the zone to Route53 or your DNS-01 challenges fail.
**Decide by:** Day 1 morning. If not bought yet, treat as Day 0 blocker.

### 1.2 — Stretch goals to scaffold
**Status:** TBD. User initially leaned toward PR Preview.
**Blocks:** ApplicationSet template choice, kubecost Helm release, cosign IAM policy.
**Default plan if unspecified:**
- ✅ PR Preview (ApplicationSet with PR generator on app repo) — 3-4 hr, high impact
- ✅ kubecost (Helm release in platform stack) — 1 hr, easy polish
- ✅ Cosign signing on ECR pushes — 30 min, free rubric bonus
- ❌ Chaos Mesh — too risky for live demo
- ❌ OpenTelemetry/Tempo — crosses into app code territory
**Decide by:** Day 3 (when platform stack is otherwise complete).

### 1.3 — Alertmanager email setup
**Status:** TBD.
**Blocks:** Alertmanager Helm values, ESO ExternalSecret for SMTP password, Secrets Manager secret creation, end-to-end alert test.
**Default plan if unspecified:** Gmail SMTP via app password.
- User creates a Gmail app password at `https://myaccount.google.com/apppasswords`
- Stored in AWS Secrets Manager under `garden/alertmanager/smtp` (key: `password`)
- ESO `ExternalSecret` in `monitoring` namespace syncs to a K8s Secret
- Alertmanager Helm values reference the secret via `auth_password_file` or `existingSecret`
**Required from user:** Gmail address, app password.
**Decide by:** Day 3 morning (before observability segment).

### 1.4 — TF state backend specifics
**Status:** Backend choice locked (S3 + DynamoDB), specifics TBD.
**Blocks:** `terraform/_bootstrap/main.tf`, every env's `backend.tf`.
**Default plan if unspecified:**
- S3 bucket: `spacetime-garden-tfstate-${random_id}` (lowercase, 6-char suffix)
- Versioning enabled, server-side encryption (AES256), public access blocked
- DynamoDB lock table: `spacetime-garden-tfstate-lock`, billing mode `PAY_PER_REQUEST`, hash key `LockID` (string)
- Created in us-east-1 via one-shot apply with local state, then state moved to itself
**Decide by:** Day 1 first 30 min. Default plan is fine for ~99% of cases; just confirm the bucket-name suffix strategy.

### 1.5 — Scaffold depth (developer ergonomics)
**Status:** TBD. Default leaned full + Makefile.
**Blocks:** nothing strictly, but determines what tooling exists at Day 1.
**Default plan if unspecified:**
- Full scaffold: every TF module, Helm chart, Argo CD manifest, GH Action
- `Makefile` at repo root: `make plan-dev`, `make apply-dev`, `make destroy-dev`, `make bootstrap-state`, `make argocd-port-forward`, etc.
- `scripts/bootstrap-state.sh` — one-shot state backend creation
- `scripts/preflight.sh` — validates AWS creds, kubectl context, gh auth before you start
- `.envrc` (direnv) for `AWS_PROFILE`, `KUBE_CONFIG_PATH` per worktree
**Decide by:** Day 1 setup phase.

### 1.6 — GitHub OAuth App for Grafana
**Status:** TBD, user-created (cannot be Terraformed).
**Blocks:** Grafana auth config, demo-time login.
**Required from user:**
- Create OAuth App at `https://github.com/settings/developers`
- Application name: `Spacetime Garden Grafana`
- Homepage URL: `https://grafana.<domain>`
- Authorization callback URL: `https://grafana.<domain>/login/github` (no trailing slash, exact match)
- Generate client secret, store both in AWS Secrets Manager under `garden/grafana/oauth`
**Decide by:** Day 3 (when Grafana goes up). Depends on §1.1 (domain) being resolved first.

### 1.7 — AWS account ID
**Status:** TBD.
**Blocks:** ECR registry URL templating, IAM role ARN templating in any docs/READMEs, IRSA trust policies that hardcode account ID.
**Required from user:** AWS account ID (12-digit number, found in AWS console top-right).
**Decide by:** Day 1 first hour.

### 1.8 — Slack webhook (optional)
**Status:** TBD, not blocking anything.
**Default plan if unspecified:** skip — email is rubric-sufficient. Add Slack later if time permits.
**Decide by:** Day 4 polish (or skip).

---

## 2. Open implementation risks

These are places where the architecture docs describe the destination but the path has a fork that needs a choice during build.

### 2.1 — Cross-Application sync ordering
**Where described:** `IMPLEMENTATION_TRAPS.md` §B.5
**The risk:** Argo CD `argocd.argoproj.io/sync-wave` orders resources within *one* Application. Migration Job (PreSync hook on genome-service) and the genome-service Rollout must be in the same Application, or the wave ordering doesn't apply.
**Implementation forks:**
- (A) **One Application per service** (recommended). The genome-service Application contains the Rollout, Service, Ingress, ExternalSecret, ServiceMonitor, AND the migration Job. Sync waves order them within. ApplicationSet generates 4 such Applications.
- (B) **One Application for migrations, one per service.** Decoupled; uses Argo CD `Application` finalizers + sync waves on the parent Applications. More complex, more failure modes.
**Pick:** (A). Verify when writing the ApplicationSet template that *all* templates from `gitops/charts/microservice/` end up in one Application per service, including `presync-migrate.yaml` (gated on `.Values.runMigrations` so only genome-service triggers it).
**Decide by:** Day 3, when writing the ApplicationSet.

### 2.2 — Synthetic traffic strategy during canary
**Where described:** `IMPLEMENTATION_TRAPS.md` §B.2
**The risk:** Canary 5xx-rate AnalysisTemplate divides by zero with no traffic, even with `or vector(0)` guard the analysis is essentially meaningless. Need real-ish traffic during canary windows.
**Implementation forks:**
- (A) **Continuous synthetic load in uat** (CronJob runs `hey -z 30s -c 5 https://uat.<domain>/api/breed` every 1 min). Always-on, predictable. Costs ~$0 but adds noise.
- (B) **Pre-promotion analysis hook** (Argo Rollouts `prePromotionAnalysis` triggers a Job that runs `hey` for the duration of each step). Cleaner — only runs during canary. Slightly more YAML.
- (C) **Just rely on the PromQL `or vector(0)` guard** and accept that with zero traffic the analysis passes vacuously. Worst option for demo (gate doesn't actually gate anything if no traffic).
**Pick:** (B) for prod, (A) for uat. Demo value comes from showing the gate fire on a deliberate regression, which requires traffic during the canary window.
**Decide by:** Day 3, when writing AnalysisTemplate.

### 2.3 — ingress-nginx Service: which provisioner for the NLB?
**Where described:** `IMPLEMENTATION_TRAPS.md` §A.3
**The risk:** Two ways to provision the NLB that fronts ingress-nginx:
- (A) **In-tree provisioner** via Service annotations (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`). Simpler, fewer moving parts.
- (B) **AWS Load Balancer Controller** managing the NLB (annotation `service.beta.kubernetes.io/aws-load-balancer-type: external`). Modern, more features (target type IP, IRSA-based auth), one more controller to operate.
**Pick:** (A) for this project. AWS LB Controller is overkill if you're not using ALBs anywhere. Document the choice; do not install AWS LB Controller at all.
**Decide by:** Day 2, when scaffolding ingress-nginx Helm values.

### 2.4 — Argo Rollouts canary integration mode
**Where described:** `IMPLEMENTATION_TRAPS.md` §A.4
**The risk:** Argo Rollouts' nginx integration requires:
- Two K8s Services: `<svc>-stable` and `<svc>-canary`
- The existing Ingress (with `nginx.ingress.kubernetes.io/canary: "true"` annotation managed by Rollouts on a duplicate)
- `Rollout.spec.strategy.canary.trafficRouting.nginx.stableIngress` set
**Implementation fork:** which Service is the "real" one users hit?
- The stable Ingress points to `<svc>-stable`. Argo Rollouts duplicates the Ingress and points the duplicate at `<svc>-canary` with weight annotations. ingress-nginx merges the two.
**Pick:** the chart must template both Services and the stable Ingress. Argo Rollouts manages the canary Ingress automatically.
**Decide by:** Day 3, when writing the `microservice` chart templates.

### 2.5 — RDS connection management under load
**Where described:** `IMPLEMENTATION_TRAPS.md` §E.4 implicitly; `ARCHITECTURE_REVIEW.md` §14 chaos table
**The risk:** db.t4g.micro has a default `max_connections` of ~85. Three services + HPA scaling + migration Job can exhaust this during a chaos demo.
**Implementation forks:**
- (A) **Per-service connection pool tuning.** SQLAlchemy `pool_size=5`, `max_overflow=10`. Limits each replica to 15 concurrent connections.
- (B) **PgBouncer sidecar** in each pod. Adds a layer; overkill for demo.
- (C) **Bigger RDS** (db.t4g.small, ~$30/mo). Skips the problem.
**Pick:** (A). Verify the app's SQLAlchemy config matches; if it doesn't, file an issue in the app repo (don't fix it in this repo — that's app-side).
**Decide by:** Day 4 pre-demo (during chaos rehearsal).

### 2.6 — Argo CD Application sync policy per env
**Where described:** `IMPLEMENTATION_TRAPS.md` §B.4
**The risk:** Auto-sync in prod is convenient for the demo (push commit → see it deploy live), but a real shop would want manual approval on prod.
**Implementation forks:**
- (A) **Auto-sync everywhere** (dev, uat, prod). Best for demo. Simplest ApplicationSet template.
- (B) **Auto-sync dev/uat, manual sync prod.** More realistic. Talking point: "prod requires explicit approval." Need to demo the Sync button click during presentation.
**Pick:** (B). The "explicit prod approval" story is rubric-relevant and adds 30 seconds to the demo. Configure `syncPolicy.automated` only for dev/uat in the ApplicationSet template.
**Decide by:** Day 2, when writing the ApplicationSet.

### 2.7 — Argo CD admin access during build
**Where described:** not explicitly anywhere yet
**The risk:** Argo CD installs with a randomized admin password in `argocd-initial-admin-secret`. You'll need to retrieve it, port-forward, log in. If you tear down and rebuild, password changes.
**Implementation forks:**
- (A) **Use the random password** via `kubectl get secret argocd-initial-admin-secret`. Standard, secure, slightly painful.
- (B) **Disable the admin user, rely on GitHub OAuth via Dex** (Argo CD's bundled SSO bridge). Realistic for prod, more setup.
- (C) **Set a known password via Helm values** (insecure, but fine for a 4-day demo behind a private cluster URL).
**Pick:** (A) for build, (B) optionally as a stretch for the demo. Helper script `scripts/argocd-login.sh` should fetch the password and open a port-forward.
**Decide by:** Day 2, when bootstrapping Argo CD.

### 2.8 — Prometheus/Loki retention vs disk
**Where described:** `IMPLEMENTATION_TRAPS.md` §E.6
**The risk:** Default Prometheus retention is 10 days, default storage request is small. Loki same. PVCs fill up, scrapes/ingests fail, dashboards go blank.
**Implementation forks:**
- (A) **Default retention, small disk.** Demo fine, no real data after 10d.
- (B) **Tuned retention** (`retentionSize: "10GB"`, `retention: "7d"`) with explicit storage request.
**Pick:** (B). Explicit values make the talking point ("we considered storage trade-offs") real.
**Decide by:** Day 3, when configuring kube-prom-stack values.

### 2.9 — Grafana dashboards as code
**Where described:** `IMPLEMENTATION_TRAPS.md` §D.5
**The risk:** Dashboards saved via UI vanish on pod restart unless persisted. ConfigMap pattern is the fix, but where do the JSON dashboards come from?
**Implementation forks:**
- (A) **Hand-write JSON.** Painful.
- (B) **Build in UI, export, commit JSON to git.** Reasonable.
- (C) **Use community dashboards from grafana.com** (e.g., dashboard ID 12740 for kube-prom-stack), commit IDs as ConfigMaps.
**Pick:** (C) for cluster/namespace/pod dashboards, (B) for the bespoke "Service Golden Signals" dashboard. Best of both.
**Decide by:** Day 3.

### 2.10 — PR Preview cleanup strategy
**Where described:** `INFRA_HANDOFF.md` §11
**The risk:** ApplicationSet PR generator creates a namespace per PR. Without cleanup, namespaces accumulate forever, costing money and cluster resources.
**Implementation forks:**
- (A) **Argo CD's built-in PR generator** auto-prunes when PR closes. Set `template.spec.syncPolicy.automated.prune: true`.
- (B) **Manual cleanup script** as a CronJob.
**Pick:** (A). Standard pattern, no extra code. Verify when scaffolding that the generator is configured with `requeueAfterSeconds: 300` so closed PRs are detected within 5 min.
**Decide by:** Day 4, if PR Preview is in scope (§1.2).

---

## Quick-reference checklist

| # | Item | Type | Day | Blocker? |
|---|---|---|---|---|
| 1.1 | Domain name | Decision | 0/1 | YES |
| 1.7 | AWS account ID | Decision | 1 | YES |
| 1.4 | TF state backend specifics | Decision | 1 | partial |
| 1.5 | Scaffold depth | Decision | 1 | NO (defaults work) |
| 2.3 | ingress-nginx NLB provisioner | Risk | 2 | NO |
| 2.6 | Argo CD sync policy per env | Risk | 2 | NO |
| 2.7 | Argo CD admin access | Risk | 2 | NO |
| 1.3 | Alertmanager email | Decision | 3 | partial |
| 1.6 | GitHub OAuth App | Decision | 3 | YES (for Grafana) |
| 2.1 | Cross-Application sync ordering | Risk | 3 | NO (default plan handles it) |
| 2.2 | Synthetic traffic strategy | Risk | 3 | NO |
| 2.4 | Argo Rollouts canary integration | Risk | 3 | NO |
| 2.8 | Prom/Loki retention | Risk | 3 | NO |
| 2.9 | Grafana dashboards as code | Risk | 3 | NO |
| 1.2 | Stretch goals | Decision | 3 | NO |
| 2.5 | RDS connection limits | Risk | 4 | NO |
| 2.10 | PR Preview cleanup | Risk | 4 | only if §1.2 picks PR Preview |
| 1.8 | Slack webhook | Decision | — | NO |

**Day-0 blockers:** 1.1 (domain), 1.7 (AWS account ID). Resolve these before opening Terraform.

**Day-3 hard requirements:** 1.3 (Gmail app password), 1.6 (GitHub OAuth App). Both are external-system tasks that need user action and have lead time (creating an OAuth App takes 5 min once, but you need the domain first).
