# Production Readiness Review — Spacetime Garden Infra

A senior-engineer review of the proposed architecture. Operational, not academic. Calls out hidden pitfalls, sequencing problems, and overengineering.

**Bottom line up front:** the architecture is sound and rubric-compliant, but there are 6–8 implementation traps that will bite you in the last 24 hours if you don't pre-emptively defuse them. Sections 5 and 11 are the ones to read first.

---

## 0. Ingress decision: ingress-nginx + cert-manager (locked)

You're going with ingress-nginx + cert-manager (not ALB + ACM as the handoff doc recommended). Locked 2026-05-06. This is fine — it's more portable, more configurable, and likely matches what your class taught — but it carries seven additional traps that ALB + ACM doesn't have. **Read `IMPLEMENTATION_TRAPS.md` Section A before writing any Terraform.**

The most important consequences:
- You'll need DNS-01 (not HTTP-01) challenges for cert-manager → IRSA role for Route53 access.
- ingress-nginx's `Service: LoadBalancer` provisions an NLB via annotations — pick the in-tree provisioner OR AWS LB Controller path and don't mix.
- Argo Rollouts canary uses ingress-nginx-specific traffic shaping (canary annotations + a second Service), not ALB target groups.
- Always start cert-manager against the LE *staging* endpoint to avoid burning rate limits during iteration.

The architecture is otherwise unchanged.

---

## 1. Is the end-to-end flow correct?

**Mostly yes, with three corrections:**

1. **"GitHub Actions updates Helm values/manifests"** — be precise about which repo. App-repo CI **must not commit to itself**. It clones the *infra* repo using `INFRA_REPO_TOKEN`, edits `gitops/envs/{uat,prod}/values.yaml`, and pushes. Two repos by design. If you collapse them, the GitOps story breaks because Argo CD watching the infra repo never sees an image-tag change.

2. **"Terraform provisions EC2 worker nodes"** — true but misleading. With EKS managed node groups, you describe a node group resource, AWS provisions the EC2s on your behalf and registers them with the cluster. You don't run individual EC2 instance resources. Use `aws_eks_node_group` (or the `terraform-aws-modules/eks` module's `eks_managed_node_groups`).

3. **"Day 2: node draining during worker updates"** — EKS does this for you when you bump `release_version` on the managed node group, *if* PDBs are configured correctly. The "Day 2 op" you actually do is bump the version and apply; EKS does the drain. The talking point is the PDB/HPA contract that keeps traffic flowing.

The rest of the flow is correct.

---

## 2. Exact deployment sequence (one push to main)

```
T+0     dev pushes commit abc123 to spacetime-garden:main
T+5s    GHA "ci.yaml" starts; OIDC -> AssumeRole(AWS_ROLE_ARN)
T+30s   docker buildx builds 4 images in parallel
T+3m    docker push to ECR with tag = abc123 (full SHA)
        ECR scan-on-push runs in background
T+3m    GHA "promote-uat.yaml" starts (depends on ci success)
        - clones spacetime-garden-infra with INFRA_REPO_TOKEN
        - yq edit gitops/envs/uat/values.yaml: bump 4 image.tag values to abc123
        - git commit + git push
T+3m30s Argo CD's reconciliation loop (default 3min, can shorten to 30s)
        notices the 4 Applications targeting uat are out of sync
T+3m45s Argo CD computes diff, applies in sync waves:
        wave -1: ExternalSecret refresh (DATABASE_URL etc.)
        wave  0: ConfigMaps, Services, ServiceAccounts (no-op, unchanged)
        wave  1: PreSync Job: genome-service-migrate-abc123 runs
                 -> alembic upgrade head against RDS
                 -> exits 0 (or fails, halting the sync)
        wave  2: Rollout spec updated with new image.tag
T+4m    Argo Rollouts controller sees the Rollout spec change
        - creates new ReplicaSet (canary) at 10% weight
        - waits 60s
        - AnalysisRun starts: queries Prometheus every 30s for 5xx rate
T+5m    setWeight 50, pause 60s, AnalysisRun continues
T+6m    setWeight 100, old ReplicaSet scaled to 0
T+7m    Rollout marked Healthy, Argo CD marks Application Synced+Healthy
```

**Three places this can stall and you must know them:**
- **Promotion workflow auth:** PAT scope wrong → `git push` 403. Test it once before demo.
- **PreSync Job failure:** migration error → Argo CD halts the entire sync, old pods keep running. Good behavior but looks scary mid-demo.
- **AnalysisRun NaN:** zero traffic during canary → Prom query returns NaN → analysis fails ambiguously. Generate synthetic traffic during the rollout window or guard the PromQL with `or vector(0)`.

---

## 3. Argo CD vs Argo Rollouts responsibility split

They're orthogonal and they compose. Common student error: assuming one calls the other, or that one supersedes the other.

| | Argo CD | Argo Rollouts |
|---|---|---|
| Input | git repo state | a `Rollout` CRD (in-cluster) |
| Job | reconcile cluster → match git | progress a single rollout through canary/BG steps |
| Knows about git? | yes | no |
| Knows about traffic shifting? | no | yes |
| Knows about analysis (Prom queries)? | no | yes |
| Triggers? | git change OR drift detection | Rollout `spec.template` change |

**The handoff:** Argo CD applies the Rollout manifest to the cluster. When `image.tag` changes in git, Argo CD updates the live Rollout's `spec.template.spec.containers[0].image`. Argo Rollouts notices that change and starts a new revision (new ReplicaSet, traffic steps, analysis). Argo CD goes "Progressing" until Argo Rollouts marks the Rollout `Healthy`.

**Implication for your charts:** every workload that needs progressive delivery is a `kind: Rollout`, not `kind: Deployment`. The single-chart strategy means your `templates/rollout.yaml` produces a Rollout, and only the genome-service migration uses a Deployment-less Job (PreSync hook).

---

## 4. Should Terraform manage Kubernetes workloads?

**Almost never. The exceptions are deliberate and small.**

The clean separation:

| Layer | Owned by | Reason |
|---|---|---|
| AWS infra (VPC/EKS/RDS/ECR/IAM) | Terraform | Only TF can talk to AWS APIs |
| Cluster bootstrap (Argo CD, ESO, AWS LB Ctlr, external-dns) | Terraform Helm provider | Chicken-and-egg: Argo CD can't install itself. ESO needs to exist before it can sync secrets. |
| Platform addons (kube-prometheus-stack, Loki, Argo Rollouts) | Either, but recommend Argo CD-of-charts pattern | Once Argo CD exists, let it manage the rest for drift detection |
| Application workloads | Argo CD only | Zero overlap with TF |

**Why TF should not manage app workloads:**
- `kubernetes_manifest` resource needs the API server reachable at plan time → cyclic dep with cluster creation.
- TF refresh becomes O(N) for every pod-derived state change.
- Two writers fight over the same object → drift, race conditions, panic edits at midnight.
- Rollouts controller is the source of truth for ReplicaSets; TF will never agree with it.

**Concrete rule:** TF stops at `kubectl apply -f argocd-bootstrap.yaml`. Everything else flows through git.

---

## 5. Implementation pitfalls students commonly hit

These are the eight that will actually bite you. Defuse them before Day 4.

1. **PDB + single-replica deadlock.** `replicas: 1` + `PodDisruptionBudget.minAvailable: 1` means a node drain can never evict the pod. Drain hangs forever, AMI patching demo fails. **Fix:** every service ≥ 2 replicas in uat/prod, OR use `maxUnavailable: 0` with replicas ≥ 2.

2. **ECR tag mutability.** Default is `MUTABLE`. If you don't set `image_tag_mutability = "IMMUTABLE"`, someone (or you, accidentally) can overwrite a SHA tag, and "the cluster runs exactly what's in git" becomes false. **Fix:** set it on the ECR module from day 1.

3. **Argo CD doesn't fire Helm hooks.** Helm CLI has `pre-install`/`post-install` hooks. Argo CD does NOT trigger them — it renders the chart and applies manifests. Use `argocd.argoproj.io/hook: PreSync` annotations on Jobs instead. **Symptom if you miss this:** migrations don't run, you only notice when prod schema diverges.

4. **AnalysisTemplate divide-by-zero.** Canary with low traffic → `sum(rate(http_requests_total))` = 0 → 5xx-rate query returns NaN → analysis fails (or passes) unpredictably. **Fix:** `... / (sum(rate(...)) > 0)` guard, OR run a `hey`-based load gen as a CronJob during canary windows.

5. **ESO bootstrap order.** External Secrets Operator starts → tries to assume IRSA role → role doesn't exist yet because TF hasn't created it. Pods crashloop. **Fix:** TF creates the IAM role, IRSA service account binding, *then* installs ESO Helm chart (use explicit `depends_on`).

6. **Secrets in values.yaml.** Tempting to put `database_url` in `values.yaml` "just for dev." It's now in git history forever. **Fix:** all secrets pull through ESO `ExternalSecret` → AWS Secrets Manager. Values files reference secret names, not values.

7. **Default storage class & PV reclaim policy.** Prometheus and Loki need PVs. Default reclaim is `Delete`. If you `kubectl delete pvc`, your historical metrics evaporate. For demo this might be fine; just know. **Fix:** set `reclaimPolicy: Retain` on the StorageClass, or accept and document the loss.

8. **Argo CD self-heal disabled.** Default Application syncPolicy doesn't auto-correct drift. Demo move "I deleted a deployment, watch Argo CD recreate it" requires `syncPolicy.automated.selfHeal: true` and `prune: true`. Set it explicitly.

Bonus traps worth knowing:
- **EKS public/private endpoint:** if you set the API server endpoint to private-only, your local `kubectl` from a coffee shop can't reach it. Use public+private with allowlisted CIDRs.
- **NAT Gateway cost.** $0.045/hr × 730 = $33/mo per AZ. Single NAT (one AZ) is fine for demo, document the prod-DR tradeoff.
- **HPA fights with Argo CD.** HPA mutates `spec.replicas`. Argo CD sees diff, reverts. **Fix:** add `spec.ignoreDifferences` for `/spec/replicas` on Applications that have HPAs.
- **`imagePullPolicy: Always` with SHA tags is wasteful.** Tags are immutable; pull once. Use `IfNotPresent`.

---

## 6. Minimum viable rubric-compliant architecture

Strip to this if time pressure hits:

```
1 VPC, 3 AZs, public + private subnets, 1 NAT Gateway
1 EKS cluster (1.30), 1 managed node group (3 × t3.medium)
3 namespaces: garden-dev, garden-uat, garden-prod
3 RDS Postgres db.t4g.micro (one per env, prod multi-AZ)
4 ECR repos with IMMUTABLE tags
1 NLB fronting ingress-nginx, cert-manager certs (LE via DNS-01), Route53 records via external-dns
1 Argo CD (app-of-apps)
1 Argo Rollouts (canary on all 4 services)
1 kube-prometheus-stack (Prom + Grafana + Alertmanager)
1 Loki + Promtail
1 ESO + 1 Secrets Manager secret per service
1 GitHub OIDC role + ECR push policy
```

**What you can drop without rubric loss:**
- Cosign signing (nice to have, low rubric weight on most rubrics)
- Chaos Mesh (high risk, only do if you've tested chaos types)
- OpenTelemetry/Tempo (crosses into app code territory)
- PR Preview environments (great if time, drop if not)
- kubecost (1 hour, easy win — keep if possible)
- The dev environment entirely (scope to uat + prod if dev costs/complexity hurt)

**What you cannot drop:**
- Three environments (rubric explicit)
- Prom + Grafana + Alertmanager with email firing (rubric explicit, 15%)
- AMI patching demo (rubric explicit, 10%)
- Schema migration demo (rubric explicit, 10%)
- HTTPS with real cert (rubric usually requires)
- GitOps (rubric requirement for this kind of class)
- Either canary or B/G with metric gate

---

## 7. Canary vs Blue/Green — the operational case

Both are rubric-compliant. Pick canary for this demo.

| | Canary | Blue/Green |
|---|---|---|
| Resource cost during rollout | Old + new co-exist for ~5 min, % weighted | Full duplicate stack until cutover |
| Visual demo (Argo Rollouts dashboard) | Continuous % bar moves, multi-step pauses | Two boxes, one switch flips |
| Auto-abort on bad metrics | Built-in via AnalysisTemplate | Possible but more setup |
| Rollback speed | Step-back canary weight to 0% | Switch DNS / Service selector back to blue |
| "I caused a regression mid-demo" moment | **Strong** — gate aborts on screen | Weaker — manual rollback |
| Complexity | Higher (analysis templates, traffic shaping) | Lower (two environments) |

**Verdict for this project: canary.** The auto-abort moment is the single most demo-able feature in the entire stack. You set it up once, you ship a deliberate regression in your demo script, the gate catches it, the dashboard shows it, you talk through the metric query. That's a 5-minute segment that hits multiple rubric items at once.

---

## 8. Helm's exact role here

Helm in this stack is **a templating engine**, not a deployer. This is a common point of confusion.

**What Helm does in your repo:**
- `gitops/charts/microservice/` is one parameterized chart that templates Rollouts/Services/Ingresses/HPAs/etc. for all 4 services.
- `values.yaml` per env feeds different `image.tag`, `replicas`, `resources`.
- The chart exists; nothing ever runs `helm install` against your cluster.

**What does the deploying:**
- For app workloads: Argo CD reads `spec.source.helm.values`, runs `helm template` internally, applies the rendered YAML via the K8s API.
- For platform addons: Terraform Helm provider runs `helm install/upgrade` directly.

**What this means in practice:**
- `helm install` from your laptop is for local debugging only — never the production path.
- Helm hooks (`pre-install`, `post-install`) **do not fire under Argo CD**. Use `argocd.argoproj.io/hook` instead.
- Helm tests (`helm test`) don't run under Argo CD either.
- The chart's `Chart.yaml` `appVersion` is meaningless here — your version of truth is the image tag in the env's values file.

**One-chart-for-four-services is the right call.** It demonstrates engineering taste. Conditional template branches (`if .Values.database.enabled`, `if .Values.hpa.enabled`) handle the per-service differences. About 80% less YAML.

---

## 9. Prometheus / Grafana / Loki integration with Kubernetes

This is the part most students underexplain in defense. Specifics:

### Prometheus (via prometheus-operator from kube-prometheus-stack)
- Service discovery via two CRDs: `ServiceMonitor` (scrapes by Service label selector) and `PodMonitor` (direct pod scrape). Stack out-of-box scrapes node-exporter, kube-state-metrics, kubelet, etcd, kube-controller-manager.
- Your apps emit `/metrics` on port 8000. **You add one `ServiceMonitor` per service** (or one chart-templated ServiceMonitor parameterized by service name). The operator picks it up and scrape jobs appear automatically.
- PV-backed storage. Default retention 10 days. For demo: fine. Set `retentionSize` to cap disk.

### Grafana
- Bundled in kube-prometheus-stack. Comes with Prom data source pre-wired and ~20 default dashboards (cluster overview, namespace, pod, node).
- Loki data source: add via Helm values `grafana.additionalDataSources` or post-install via UI.
- GitHub OAuth: configured via `grafana.grafana.ini` Helm values (handoff doc has the exact block). **Caveat:** the OAuth callback URL must match exactly what GitHub OAuth App is configured for, including trailing slashes. Test before demo.
- Persistent storage on PVC. Without it, dashboards saved via UI disappear on pod restart. For your repo, **do all dashboards as ConfigMaps** with the `grafana_dashboard: "1"` label — they auto-import and survive everything.

### Loki + Promtail
- Promtail = DaemonSet, one pod per node, mounts `/var/log/containers` and `/var/log/pods`.
- Promtail tails container log files (which kubelet writes), enriches with K8s metadata via the K8s API (pod name, namespace, container name, labels), ships to Loki.
- Loki indexes only labels, not log content. Querying via LogQL: `{namespace="garden-uat",app="genome-service"} |= "request_id=abc"`.
- **Cardinality trap:** don't label by `request_id` or anything high-cardinality. Loki's index will explode.
- Your app already emits JSON logs with `request_id` field. Use `| json` in LogQL to extract: `{...} | json | request_id="abc123"`.

### How they actually compose for the demo
- Prometheus alerts via `PrometheusRule` CRDs → Alertmanager → Gmail SMTP.
- Grafana shows Prom dashboards + Loki log panels side-by-side.
- The cross-service log trace demo: pick a request_id from genome-service logs, run the same LogQL across all services, watch the request flow.

---

## 10. Kubernetes concepts you may still be misunderstanding

A few things the original architecture sketch hinted at imprecisely:

1. **"Pods managed by Deployments."** With Argo Rollouts, your pods are managed by ReplicaSets owned by a `Rollout` CR (not Deployment). You will see *two* ReplicaSets during a canary — one stable, one canary. `kubectl get deploy` will show nothing. `kubectl argo rollouts get rollout <name>` is your friend.

2. **"Service routes traffic to pods."** True, but during a canary with ingress-nginx, you have two Services (stable-svc + canary-svc) and Argo Rollouts creates a *second* Ingress with `nginx.ingress.kubernetes.io/canary: "true"` + `canary-weight: "10"` annotations. ingress-nginx interprets those annotations and splits traffic. Both Service templates must exist in your chart. (The ALB equivalent uses target-group weights; you're not on that path.)

3. **"Ingress controller is HTTP routing."** With ingress-nginx, the controller Pods themselves are in the data path: `client → NLB → ingress-nginx Pod → Service → app Pod`. This is unlike ALB where the controller is control-plane only. Practical implication: ingress-nginx Pods are a hot path — give them resource requests, run ≥2 replicas, give them a PDB.

4. **HPA and progressive delivery interact.** HPA scales the Rollout's `spec.replicas`. During a canary, Argo Rollouts and HPA both want to write that field. Use `spec.scaleDownDelaySeconds` and HPA `behavior` to avoid thrash, and add `ignoreDifferences` on the Argo CD Application.

5. **PVs are AZ-bound (EBS).** A pod with an EBS PVC can only schedule onto a node in the same AZ as the volume. If that AZ goes down, the pod is unschedulable until the AZ comes back. Multi-AZ HA needs RWX volumes (EFS) or no PV at all (12-factor stateless apps + RDS). Your stateless services + RDS pattern is correct; just know why.

6. **Drain ≠ delete.** Cordoning a node + draining respects PDBs and graceful termination. `kubectl delete node` does NOT — it just removes the node object, leaving pods orphaned. Never demo with `delete node`.

7. **Sync waves are per-Application.** The `argocd.argoproj.io/sync-wave` annotation orders resources within one Argo CD Application. It does NOT order across Applications. If you want migration → app order across Applications, use Argo CD `Application` dependencies (or one Application with multi-resource manifests).

---

## 11. What you absolutely need to know for live defense

If a professor asks any of these, you should answer in 30 seconds without `kubectl`:

| Question | Answer in your head |
|---|---|
| "Walk me through what happens when you push code." | The 14-line sequence in §2. Memorize it. |
| "Show me how a bad deploy is caught." | Demo the deliberate-regression canary abort. Open Argo Rollouts dashboard, point at AnalysisRun output, point at Prometheus query. |
| "How do you patch nodes without downtime?" | "Bump `release_version` in tfvars, `terraform apply`. EKS rolls one node at a time, respects PDBs. PDBs are why a single replica would block — we run ≥2." |
| "How do schema migrations work without breaking running pods?" | Expand-migrate-contract pattern. PreSync hook in sync wave 1 runs `alembic upgrade head` from the new image. New column is nullable so old code still works. Then deploy in wave 2. Demo with `0002_add_gallery_likes.py`. |
| "Where are secrets?" | AWS Secrets Manager. ESO syncs to in-cluster Secret via IRSA. Pods envFrom that Secret. Nothing in git. |
| "What happens if RDS dies?" | Multi-AZ failover ~60-90s. Apps reconnect via the RDS endpoint DNS (which retargets to the replica). Connection pool retries. Show the alert firing. |
| "What's your blast radius for a bad image?" | Caught at canary 10% step within 60s by the AnalysisTemplate. Auto-abort, no manual intervention. |
| "Show me HA." | Multi-AZ node group + multi-AZ RDS + PDBs + NLB cross-zone routing + ingress-nginx ≥2 replicas. Kill a pod live, show K8s reschedule. |
| "What's the cost of this stack?" | EKS $73/mo control plane, 3 × t3.medium ~$90/mo, 3 × RDS t4g.micro ~$45-60/mo, NLB ~$16/mo + LCU, NAT $33/mo, ECR/EBS/data-transfer ~$10. ~$275/mo all-in. Tear down between sessions for $7-10/day idle. |
| "Why didn't you use Aurora / DynamoDB / Fargate / ECS?" | Locked in §12 of the handoff. Have the one-line reason for each. |
| "How do you authenticate Grafana?" | GitHub OAuth via Grafana's built-in OAuth client. Restricted to your GitHub username. Demo the login flow live. |
| "How do alerts reach you?" | PrometheusRule CRDs → Alertmanager → Gmail SMTP receiver. Show the email arriving live during chaos segment. |
| "What if your AWS account gets compromised?" | Fine-grained PAT scoped to one repo, OIDC role with least-privilege ECR perms, no long-lived AWS keys in CI. Audit trail in CloudTrail. |
| "Why GitOps over `kubectl apply` from CI?" | Drift detection, audit trail (every change is a git commit), one-click rollback (revert the commit), separation of duties (ops doesn't need cluster access to deploy). |
| "How do you do canary analysis with no traffic?" | Synthetic traffic CronJob runs `hey` against `/healthz` and `/breed` during canary windows. Plus the `or vector(0)` PromQL guard. |

Have these dashboards bookmarked: Argo CD home, Argo Rollouts dashboard, Grafana cluster overview, Grafana service golden signals, AWS Console → CloudWatch → EKS log group. Have your `kubectl` aliases ready (`k`, `kgp`, `kgn`, `kar` for argo rollouts).

---

## 12. Recommended repo structure

**Constraint: don't recode Terraform modules that already exist.** Use community modules from `terraform-aws-modules/*` for VPC, EKS, RDS, ECR, IRSA, GitHub OIDC. The only custom Terraform module you need is `cluster-bootstrap` (Helm releases for the platform stack) — that orchestration is project-specific.

Layout:

```
spacetime-garden-infra/
├── README.md
├── INFRA_HANDOFF.md                   # spec
├── HANDOFF_NOTES.md                   # study summary + trade-offs
├── ARCHITECTURE_REVIEW.md             # this doc
├── IMPLEMENTATION_TRAPS.md            # operational pitfall catalog
├── Makefile                           # tf-plan-dev, tf-apply-dev, etc.
│
├── terraform/
│   ├── _bootstrap/                    # S3 state bucket + DDB lock (one-shot)
│   ├── modules/
│   │   └── cluster-bootstrap/         # ONLY custom module: helm_release for
│   │                                  # ingress-nginx, cert-manager, ESO,
│   │                                  # external-dns, argo-cd, argo-rollouts,
│   │                                  # kube-prom-stack, loki + IRSA wiring
│   └── live/
│       ├── dev/main.tf                # composes community modules:
│       │                              #   terraform-aws-modules/vpc/aws
│       │                              #   terraform-aws-modules/eks/aws
│       │                              #   terraform-aws-modules/rds/aws
│       │                              #   terraform-aws-modules/ecr/aws (×4)
│       │                              #   iam-role-for-service-accounts-eks (×N)
│       │                              #   iam-github-oidc-role
│       │                              #   plus module.cluster_bootstrap
│       ├── uat/main.tf
│       └── prod/main.tf
│
├── gitops/
│   ├── bootstrap/
│   │   └── argocd-root-app.yaml
│   ├── apps/
│   │   ├── platform-stack.yaml        # kube-prom-stack, loki, argo-rollouts (if Argo-CD-managed)
│   │   ├── microservices.yaml         # ApplicationSet fanning out to 4 services
│   │   └── pr-preview.yaml            # ApplicationSet w/ PR generator (stretch)
│   ├── charts/
│   │   └── microservice/              # ONE chart for all 4 services
│   │       ├── Chart.yaml
│   │       ├── values.yaml
│   │       └── templates/
│   │           ├── rollout.yaml
│   │           ├── service-stable.yaml
│   │           ├── service-canary.yaml         # required for nginx canary
│   │           ├── ingress.yaml                # ingressClassName: nginx
│   │           ├── serviceaccount.yaml
│   │           ├── externalsecret.yaml
│   │           ├── servicemonitor.yaml
│   │           ├── prometheusrule.yaml
│   │           ├── hpa.yaml
│   │           ├── pdb.yaml
│   │           ├── analysistemplate.yaml
│   │           └── presync-migrate.yaml        # gated on .Values.runMigrations
│   ├── platform-values/
│   │   ├── ingress-nginx.values.yaml
│   │   ├── cert-manager.values.yaml
│   │   ├── kube-prometheus-stack.values.yaml
│   │   ├── loki.values.yaml
│   │   └── argo-rollouts.values.yaml
│   └── envs/
│       ├── dev/values.yaml
│       ├── uat/values.yaml            # ← bumped by promote-uat.yaml
│       └── prod/values.yaml           # ← bumped by promote-prod.yaml
│
└── .github/workflows/
    ├── tf-plan.yaml
    └── tf-apply.yaml
```

**Notes:**
- One `microservice` chart, four ApplicationSet generators, four sets of values. Differences are flags (`database.enabled`, `hpa.enabled`).
- Two Service templates (stable + canary) are required for ingress-nginx canary integration with Argo Rollouts. With ALB you'd have one Service. See `IMPLEMENTATION_TRAPS.md` A.4.
- `cluster-bootstrap` is the *only* TF module that talks to Kubernetes. After it, everything is git.
- `live/{env}/main.tf` is mostly module composition — you should be writing very little raw HCL.
- Use AWS-managed EKS addons for `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver` (configured via the EKS module's `cluster_addons` argument). Free, AWS lifecycle-managed.

---

## 13. Safest deployment flow

```
PRs to app repo:
  app CI runs unit tests + builds
  if PR -> dev env auto-deploy on merge to a long-lived dev branch (optional)

Merge to app repo main:
  app CI builds, pushes ECR with full SHA
  promote-uat.yaml clones infra repo, bumps uat values, pushes
  Argo CD syncs uat (auto)
  Argo Rollouts canaries (auto)
  Smoke test runs against uat URL

Tag v*.*.*  on app repo:
  promote-prod.yaml waits for CI green on the SHA
  bumps prod values, pushes
  Argo CD prod is set to manual sync OR auto with approval
  Once approved/synced, Argo Rollouts canaries
  Manual smoke test + Grafana dashboard check
```

**Rollback paths:**
- Mid-canary regression: AnalysisRun aborts automatically. No human action required.
- Post-deploy regression: revert the values.yaml commit in infra repo. Argo CD reconciles back. ~3 minutes.
- Disaster: `terraform destroy` and rebuild. ~30 minutes.

**Pre-demo checklist (run morning of):**
1. `terraform plan` all envs — must be clean (no drift).
2. Push a no-op commit, watch full pipeline succeed.
3. Open Argo CD, Grafana, AWS Console, terminal with kubectl context set.
4. Have a rollback commit prepared as an open PR you can merge live.
5. Pre-fire one alert intentionally to confirm Gmail isn't in spam.

---

## 14. Chaos scenarios and recovery behavior

These are likely defense questions. Know the recovery story for each.

| Chaos | What happens | What you point at on screen |
|---|---|---|
| `kubectl delete pod <one>` | ReplicaSet recreates pod within ~5s, traffic continues via other replica | `kubectl get pod -w`, NLB target health in EC2 console |
| Node terminated (simulate AZ failure) | Pods evicted, scheduler places on other nodes; NLB drops dead targets within ~30s | `kubectl get nodes`, NLB target group health |
| RDS primary failure (multi-AZ) | Failover ~60-90s, RDS endpoint DNS retargets, app reconnects via pool | RDS event log, app error rate transient spike, recovery |
| Bad image deployed | Canary 10% → AnalysisRun fails on 5xx rate → auto-abort | Argo Rollouts dashboard shows aborted, Prometheus query screenshot |
| Image pull failure (ECR perms gone) | Pod stuck in `ImagePullBackOff`, old ReplicaSet keeps serving | `kubectl describe pod`, events |
| Out-of-memory pod | Kubelet OOMKills, ReplicaSet restarts | OOMKill metric in Grafana, alert fires |
| DNS failure (external-dns down) | New ingresses don't get DNS records; existing records still served via cached entries | external-dns logs, event for missing record |
| Disk full on Prometheus PV | Prometheus stops accepting scrapes, WAL corruption possible | Grafana shows gap, alert on `prometheus_tsdb_storage_blocks_bytes` |
| RDS connection storm (too many clients) | Apps get connection refused; need PgBouncer or pool tuning | RDS connection count metric |

**Demo recommendation:** pick `kubectl delete pod` + bad-image canary abort + node drain. Three chaos types in 5 minutes, each rubric-relevant.

---

## 15. Production readiness critique

Treating this as a real prod handoff, here's where it falls short of "I'd ship this":

**Strengths:**
- GitOps source-of-truth is clean (no manual `kubectl apply` in the production path).
- Image tag immutability + SHA-pinning makes "what's running where" answerable from git.
- IRSA + ESO pattern is the modern AWS-native secret story.
- Canary + analysis is real progressive delivery.

**Gaps a production reviewer would flag (rubric-irrelevant but know they exist):**

1. **No SLOs/SLIs defined.** "Service is up" isn't an SLO. Real shop: 99.9% availability, p95 latency < 500ms, error budget tracked in Grafana.

2. **No runbooks.** Alerts fire to email but nothing tells the on-call what to do. Each alert needs a `runbook_url` annotation.

3. **No backup/DR plan.** RDS automated backups exist by default (7-day PITR) but there's no documented restore procedure. No cross-region replica.

4. **No network policies.** Anything in the cluster can talk to anything. NetworkPolicy resources or Cilium would lock down service-to-service.

5. **No admission control.** No Pod Security Standards enforcement, no Kyverno/OPA, no image scanning gate. ECR scan-on-push exists but doesn't *block*.

6. **Single NAT Gateway = SPOF + AZ-anchor for egress.** Real prod = NAT per AZ. Costs ~$70/mo more.

7. **No cost guardrails.** No AWS Budget alerts, no cluster autoscaler max bound, no Karpenter consolidation.

8. **Secrets rotation is manual.** Secrets Manager supports rotation Lambdas, ESO has a `refreshInterval`, but rotating the RDS master password is not automated.

9. **No load testing.** You don't know your real capacity. For demo, that's fine; for prod, that's a launch-blocker.

10. **Grafana auth allowlists by org membership only.** Anyone in the org can view all metrics. Real shop: RBAC by team, or separate Grafana orgs.

**For the rubric: skip all 10 of these.** None are rubric-weighted on a typical capstone, and trying to address them on Day 4 will burn time you need for the demo polish. But have the list memorized — if a professor asks "what would you do for prod?", reciting these in 90 seconds is a strong answer.

---

## 16. Final recommended architecture

Cohesive picture, ordered by what to build first:

**Day 1 (today, after you finish studying):**
1. `terraform/_bootstrap/` — S3 state + DDB lock. One-shot apply.
2. `terraform/modules/vpc/` + `terraform/modules/eks/` + `terraform/modules/rds/` + `terraform/modules/ecr/` + `terraform/modules/github-oidc/` + `terraform/modules/dns/`.
3. `terraform/live/dev/main.tf` — wire all modules.
4. `terraform apply` for dev. Capture outputs.
5. Configure GitHub variables/secrets on app repo.
6. Push test commit, confirm CI builds and pushes to ECR.

**Day 2:**
7. `terraform/modules/cluster-bootstrap/` — Helm provider installs ingress-nginx, cert-manager (with Route53 IRSA), external-dns, ESO, Argo CD. Apply against dev.
8. `gitops/charts/microservice/` — write the parameterized chart.
9. `gitops/envs/dev/values.yaml` + `gitops/apps/microservices.yaml` ApplicationSet.
10. `kubectl apply -f gitops/bootstrap/argocd-root-app.yaml`.
11. Verify dev URL loads, click Breed, row in RDS.

**Day 3:**
12. Add Argo Rollouts to platform stack, convert chart to use `Rollout` instead of Deployment.
13. Add `AnalysisTemplate`, test deliberate regression.
14. Add kube-prometheus-stack + Loki + Promtail to platform stack.
15. Wire ServiceMonitors, build Golden Signals dashboard as ConfigMap.
16. Wire Grafana GitHub OAuth + Alertmanager Gmail SMTP.
17. Apply to uat. Smoke test.

**Day 4:**
18. Apply to prod (multi-AZ RDS, larger nodes).
19. PreSync migration Job, test with `0002_add_gallery_likes.py`.
20. AMI patching demo: bump release_version, watch rolling drain.
21. PR Preview ApplicationSet (stretch, only if days 1-3 finished early).
22. kubecost (1 hour, easy stretch).
23. Pre-demo checklist (§13).
24. Demo dry-run.

**The two architectural calls that matter most:**
- **Bootstrap layer = TF, app layer = Argo CD, no overlap.** This is the line that, if you draw it cleanly, the whole rest of the design falls out naturally.
- **One Helm chart, four services, four values.** This is the engineering-taste lever that says "I designed this, I didn't just stitch four tutorials together."

Hit those two and the rest is execution.
