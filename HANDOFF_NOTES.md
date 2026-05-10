# Spacetime Garden Infra — Study Notes

Distillation of `INFRA_HANDOFF.md` (587 lines → scannable summary) plus trade-off analysis on the open architectural decisions. Use this to restudy / cross-check against class material before committing the repo structure.

---

## Part 1: Section-by-section distillation

### §1 Context

Two-repo split: `spacetime-garden` (app, done) and `spacetime-garden-infra` (yours). The app repo's CI already builds 4 images to ECR via GitHub OIDC, then runs a promotion workflow that bumps SHA tags in *your* `gitops/envs/{uat,prod}/values.yaml`. Your repo must honor that exact YAML shape (`<service>.image.tag`) — that's the contract.

The handshake requires you to set 4 things in the app repo's GitHub settings: `AWS_ROLE_ARN`, `AWS_REGION`, `INFRA_REPO` (variables) + `INFRA_REPO_TOKEN` (secret). The IAM role and ECR registry come from your Terraform outputs; the PAT is created manually.

### §2 Architecture

> **Diverges from `INFRA_HANDOFF.md`:** the original spec used ALB + ACM. We've locked ingress-nginx + cert-manager (DNS-01 via Route53). See decision log + `IMPLEMENTATION_TRAPS.md` Section A.

Internet → Route53 → NLB (provisioned via ingress-nginx Service annotations) → ingress-nginx Pods → 4 services on EKS (frontend, breeding, genome, gallery). Path-based routing strips `/api/` prefix at the ingress-nginx layer. cert-manager issues TLS certs from Let's Encrypt (DNS-01 challenge). Genome owns RDS writes + Alembic migrations; gallery is a read replica. RDS Postgres backs everything, multi-AZ in prod.

In-cluster: Argo CD (app-of-apps), Argo Rollouts (canary), kube-prometheus-stack, Loki+Promtail, cert-manager (with IRSA for Route53), External Secrets Operator (IRSA → Secrets Manager), external-dns, ingress-nginx. Recommendation: one cluster + three namespaces (`garden-dev/uat/prod`) — saves $0.10/hr × 2 control planes for a 4-day demo.

### §3 The split

App owns: frontend code, service code, Dockerfiles, migration *scripts*, CI build/push, promotion workflows. Infra owns: Terraform (VPC/EKS/RDS/ECR/IAM/Route53), Helm charts, ingress-nginx + cert-manager, Argo Rollouts manifests, the migration *runtime* (PreSync hook), Argo CD bootstrap, observability stack, ESO+IRSA, Grafana OAuth, alertmanager.

The boundary is sharp: if you find yourself rewriting Pydantic models or genetics logic, you've crossed it. If something is a Kubernetes manifest or a `*.tf`, it's yours.

### §4 Outputs back to app repo

Four GitHub config values must be set on `fhshaik/spacetime-garden`: role ARN, region, infra repo name, and a fine-grained PAT with `contents:write` on this repo only. The role's trust policy must allow `sts:AssumeRoleWithWebIdentity` from `token.actions.githubusercontent.com` for the app repo's main branch + tag pushes.

The role needs ECR push permissions (`ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, etc.) on the four ECR repos. Put role ARN, region, and registry URL in `outputs.tf` for easy lookup.

### §5 Terraform layout

`modules/` for vpc/eks/rds/ecr/github-oidc/dns/cluster-addons. `envs/{dev,uat,prod}/` each with their own `main.tf`, `backend.tf`, `terraform.tfvars`. `gitops/` holds the Argo CD bootstrap, app-of-apps manifests, *one* parameterized `microservice` Helm chart used by all 4 services, and per-env values files.

Key tip: one chart, not four. The differences (DB or no DB, HPA or no HPA) become flags in `values.yaml`. Saves ~80% YAML and demonstrates better engineering taste.

### §6 Platform stack

Install via the Helm provider in `cluster-bootstrap` module (not Argo CD — they *provide* Argo CD, can't be managed by it). Bootstrap order under our chosen ingress path: ingress-nginx → cert-manager (with Route53 IRSA) → external-dns → ESO → argo-cd → argo-rollouts → kube-prometheus-stack → loki+promtail.

Three landmines: (1) ESO's IAM role must exist before ESO syncs (split apply or `depends_on`); (2) AnalysisTemplate divides by zero with no traffic — guard PromQL with `or vector(0)`; (3) Argo CD doesn't fire Helm hooks the way the CLI does — use `argocd.argoproj.io/hook: PreSync` annotations on Jobs with sync waves instead. Set `image_tag_mutability = "IMMUTABLE"` on ECR.

### §7 Canary

Steps: 10% → pause 60s → 50% → pause 60s → 100%. AnalysisTemplate runs Prometheus query for 5xx rate, gate at ≥99% success, fail after 1 bad check. Critical: the `> 0` divide-by-zero guard in the PromQL.

Demo move: deploy a regression that 5xx's 30% of `/breed` calls mid-rollout and let the gate auto-rollback. Strongest visual moment of the demo.

### §8 Day-2 scenarios

**AMI patching (10%):** bump `release_version` in tfvars, `terraform apply`, EKS rolls nodes one-at-a-time respecting PDBs (`minAvailable: 1` is what makes this work). Show with `kubectl get nodes -w` + load generator showing zero dropped requests.

**Schema migration (10%):** script lives in app repo, baked into genome-service image. Infra provides the runtime: a `PreSync` Job in genome-service's chart that runs `alembic upgrade head` from the same image *before* new pods cut over. Talking point is "expand → migrate → contract"; demo migration is `0002_add_gallery_likes.py`.

### §9 Observability (15%)

Metrics: kube-prometheus-stack out-of-the-box gives you Prom/Grafana/Alertmanager + dashboards. Add `ServiceMonitor` resources to scrape app `/metrics`. Build a Golden Signals dashboard (RPS, p50/p95/p99 latency, error rate per service).

Logs: Loki+Promtail DaemonSet. App emits JSON logs with `request_id` propagated via `x-request-id` header — demo cross-service log queries by following one request_id. Grafana behind GitHub OAuth at `grafana.<domain>` (no admin user, OAuth auto-login). Alertmanager → Gmail SMTP with rules for node CPU/mem/disk + service 5xx + CrashLoopBackOff. Fire one alert intentionally during chaos defense.

### §10 Bootstrap sequence

1. Create S3+DDB state backend.
2. `cd envs/dev && terraform apply` — VPC+EKS+RDS+ECR+OIDC+DNS+addons, ~15 min.
3. Capture outputs.
4. Set 4 GitHub repo vars/secrets.
5. Trigger app CI build.
6. `kubectl apply` Argo CD bootstrap pointing at `gitops/apps/root.yaml`.
7. Verify app loads.
8. Repeat for uat/prod.

The whole thing should be `terraform apply` away from reproducible — that's the rubric's "Day 1 fully automated" requirement.

### §11 Stretch / WOW

Five candidates: (1) PR Preview Envs via Argo CD ApplicationSet — 3-4 hrs, very impressive. (2) kubecost — 1 hr, easy polish. (3) Chaos Mesh — 2 hrs, high risk + memorable. (4) OTel traces in Tempo — 3 hrs. (5) Cosign signing — 30 min, free bonus.

Recommended pick: #1 + #2. High perceived effort, low risk.

### §12 Locked decisions

Don't relitigate: EKS (not ECS/Fargate), RDS Postgres (not Aurora/Dynamo), canary (not blue/green), Loki+Promtail (not ELK), GitHub OAuth (not Google/Okta), us-east-1, `uv` for Python tooling, Terraform (not Pulumi/CDK), image tag = full SHA.

### §13 Open questions

Domain name, AWS account/region, cluster topology, Gmail+app password, Slack webhook (optional), GitHub OAuth client ID/secret (manually create OAuth App, callback `https://grafana.<domain>/login/github`).

### §14 Final reminders

Read app repo's `PLAN.md` first. Don't duplicate app code. Test cross-repo flow end-to-end (push commit → SHA in values.yaml → Argo CD sync → canary roll → new pods). No ClickOps — if reaching for Console, write Terraform. Budget $7-10/day idle, tear down between sessions.

---

## Part 2: Trade-offs on the open decisions

### Cluster topology — 1 cluster + 3 namespaces vs 3 clusters

| Axis | 1 cluster + 3 ns | 3 clusters |
|---|---|---|
| EKS control plane cost | $0.10/hr (~$2.40/day) | $0.30/hr (~$7.20/day) |
| Node group cost | Shared, 2-3 t3.medium | Triple it |
| Demo "prod isolation" story | Weaker — same control plane | Strong — true blast radius separation |
| Promotion logic complexity | Identical (Argo CD targets namespace) | Identical (Argo CD targets cluster) |
| AMI patching demo | One rolling-update for all 3 envs (or per-namespace nodepool) | Three separate rotations to demo |
| Setup time | ~15 min | ~45 min × repeat-pain |
| Rubric compliance | ✅ Three envs is what's required | ✅ |

**The honest call:** for a 4-day capstone, 1+3 wins on every axis except "true isolation story." If your professor specifically said "show me cluster-level isolation in prod," go 3 clusters. Otherwise the saved $15-20/day funds Chaos Mesh time.

### RDS — per-env vs shared instance with three databases

| Axis | Per-env (3 instances) | Shared (1 instance, 3 DBs) |
|---|---|---|
| Cost (db.t4g.micro) | ~$45-60/mo | ~$15-20/mo |
| Data isolation | Strong (failure isolation too) | Logical only |
| Backup story | 3 separate snapshots | 1 snapshot |
| Multi-AZ in prod | Easy — flip a flag on prod's instance | Awkward — multi-AZ for dev too, or split anyway |
| Demo narrative | "real prod isolation" | "multi-tenant Postgres" (also valid) |
| Migration testing | True (each env is a real migration target) | True |

**The honest call:** if prod must be multi-AZ (rubric usually wants this), per-env actually wins because shared multi-AZ wastes money on dev. If prod doesn't need multi-AZ, shared is fine. Per-env is the "more professional" answer.

### Argo Rollouts canary vs Blue/Green (already locked, but worth knowing why)

| Axis | Canary | Blue/Green |
|---|---|---|
| Visual demo | Beautiful — % bar moves in Argo dashboard | Binary — switch flips |
| Traffic gating | Built-in metric-based abort | Possible but more setup |
| Cost | Both versions briefly co-exist (same as B/G) | Both versions co-exist |
| Rubric narrative | "automated metric gate aborts the bad deploy" | "instant rollback by switching" |

Doc locked canary because the live abort moment is the strongest narrative beat. Don't re-open this.

### Platform stack management — TF Helm provider vs Argo CD

| Axis | TF Helm provider | Argo CD manages it |
|---|---|---|
| Bootstrap order | Clean — TF installs Argo CD, then it manages apps | Chicken-and-egg — Argo CD can't manage itself cleanly |
| GitOps purity | Mixed (TF for platform, Argo CD for apps) | Pure GitOps (everything in git) |
| Drift detection on platform | Manual (`terraform plan`) | Automatic (Argo CD) |
| Demo story | "Two-tier: platform IaC, apps GitOps" | "Everything is GitOps" |

Doc recommends TF Helm provider for platform addons + Argo CD for apps. This is the standard pattern; the "everything is Argo CD" story is purer but the bootstrap order is genuinely painful.

### Stretch goal selection

| Pick | Time | Demo impact | Risk |
|---|---|---|---|
| PR Preview | 3-4 hr | High — "every PR gets its own URL" is genuinely impressive | Medium — ApplicationSet PR generator + cleanup logic + cost guardrails |
| kubecost | 1 hr | Medium — "$/service in Grafana" is a nice screenshot | Low |
| Cosign | 30 min | Low (rubric checkbox) | Low |
| Chaos Mesh | 2 hr | High — instructor picks chaos type live | **High** — can break demo if chaos doesn't recover |
| OTel/Tempo | 3 hr | Medium — distributed tracing visualization | Medium — app may need code changes (crosses the boundary) |

If you have time after PR Preview, **kubecost + Cosign** is ~1.5 hrs total for two more rubric/polish wins. Skip Chaos Mesh unless your professor has emphasized chaos engineering — too much demo risk.

---

## Decision log (fill in as you decide)

| Decision | Choice | Date | Notes |
|---|---|---|---|
| Cluster topology | 1 cluster + 3 namespaces | 2026-05-06 | Confirmed |
| RDS strategy | One instance per env | 2026-05-06 | Confirmed |
| Region | us-east-1 | 2026-05-06 | Confirmed |
| Ingress | ingress-nginx + cert-manager (DNS-01 via Route53) | 2026-05-06 | Confirmed. Diverges from handoff doc's ALB+ACM. See `IMPLEMENTATION_TRAPS.md` Section A. |
| Terraform modules | Community (`terraform-aws-modules/*`); custom `cluster-bootstrap` only | 2026-05-06 | Don't recode VPC/EKS/RDS/ECR/IRSA — use the community modules directly. |
| Domain | TBD — user buying | — | Will configure once purchased |
| Stretch goals | TBD | — | Lean toward PR Preview + kubecost + Cosign |
| Alertmanager | TBD | — | Default plan: Gmail SMTP via ESO |
| TF state backend | TBD | — | Default plan: S3 + DynamoDB lock |
| Scaffold depth | TBD | — | Default plan: full scaffold + Makefile |

## Next steps

1. Restudy class material (lectures, labs, rubric).
2. Cross-check class emphasis against the trade-off tables above. Flag anywhere your class diverges from the doc's recommendations.
3. Resolve open items in `OPEN_ITEMS.md` — Day-0 blockers are domain name (§1.1) and AWS account ID (§1.7).
4. Resume scaffolding the repo.

## Doc map

- `INFRA_HANDOFF.md` — original spec from planning phase (preserved as historical reference; ALB+ACM there is *not* the current direction)
- `HANDOFF_NOTES.md` — this doc; section distillation + trade-offs + decision log
- `ARCHITECTURE_REVIEW.md` — production readiness review (operational pitfalls, defense prep, repo layout)
- `IMPLEMENTATION_TRAPS.md` — detailed catalog of 27 implementation pitfalls with fixes
- `OPEN_ITEMS.md` — punch list of unresolved decisions and known implementation risks
