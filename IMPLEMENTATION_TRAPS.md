# Implementation Traps — Things That Will Bite You

A detailed catalog of the implementation pitfalls in this stack. Each entry is structured so you can scan severity quickly and act on it.

**Format per trap:**
- **TL;DR** — one sentence
- **Mechanism** — what's actually happening under the hood
- **Symptom** — how you'll notice (so you can recognize it during demo)
- **Fix** — concrete remediation
- **Defuse by** — Day 1 / Day 2 / Day 3 / Pre-demo
- **Severity** — Demo-blocker / Demo-degrader / Prod-only

---

## A. Ingress + cert-manager (your chosen path)

This is the biggest cluster of traps you've signed up for. ingress-nginx + cert-manager is more flexible and portable than ALB + ACM, but it has more moving parts. Each of A.1–A.7 is a thing that will fail at least once during your build.

### A.1 — Let's Encrypt rate limits during iteration
**TL;DR:** LE production endpoint = 50 certs/registered-domain/week, 5 duplicate certs/week. You will hit this if you `kubectl delete cert` a few times.

**Mechanism:** cert-manager hits `acme-v02.api.letsencrypt.org`. Each successful issuance counts. Failed issuances also count toward the per-account rate limit. Five iterations of "delete and retry" can lock you out for the week.

**Symptom:** new Certificate resource stuck in `Issuing` state forever. `kubectl describe cert` shows `tooManyCertificates` or `rateLimited`.

**Fix:**
1. **Always start with the staging issuer** (`https://acme-staging-v02.api.letsencrypt.org/directory`). Untrusted in browsers but rate limits are 30,000/week. Browser shows a cert warning during dev — fine.
2. Only switch to the production issuer when the flow works end-to-end.
3. Define both as ClusterIssuers so switching is a one-line annotation change on the Ingress.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - dns01:
          route53:
            region: us-east-1
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    # ... same shape
```

**Defuse by:** Day 2 (when first ingress goes up). **Severity:** Demo-blocker if you discover at demo time.

### A.2 — HTTP-01 vs DNS-01 challenge: pick DNS-01
**TL;DR:** HTTP-01 requires LE to reach your ingress over the internet on port 80. Behind an AWS LB with weird routing, this breaks. DNS-01 needs Route53 IAM perms via IRSA but doesn't care about traffic flow.

**Mechanism:**
- HTTP-01: cert-manager creates a Pod + Ingress that serves `/.well-known/acme-challenge/<token>` on port 80. LE servers hit your domain on `:80` and check for the token. If your NLB strips `/`, doesn't pass `:80`, or your security group blocks it, the challenge fails.
- DNS-01: cert-manager creates a `_acme-challenge.<your-domain>` TXT record in Route53. LE looks it up via DNS. No traffic to your cluster needed. Also supports wildcard certs (`*.uat.<domain>`).

**Symptom:** Certificate stuck in `Issuing`. Order shows challenge failed with "self-check failed" or "connection timed out."

**Fix:**
1. Use DNS-01 with Route53.
2. Create an IAM policy with `route53:ChangeResourceRecordSets` and `route53:ListHostedZones` for your hosted zone.
3. Create an IRSA role bound to the cert-manager ServiceAccount.
4. Configure ClusterIssuer with `solvers[].dns01.route53.role: <arn>`.

**Defuse by:** Day 2. **Severity:** Demo-blocker.

### A.3 — ingress-nginx Service annotations for AWS NLB
**TL;DR:** ingress-nginx by default creates a `Service: LoadBalancer` which on EKS provisions a Classic Load Balancer (CLB), not an NLB. You almost certainly want an NLB.

**Mechanism:** Without the right annotation, EKS falls back to the in-tree CLB provisioner. CLB is deprecated, slower failover, no static IP, can't terminate TLS to backends with SNI.

**Symptom:** A CLB shows up in your AWS console; ingress works but uses the legacy LB type.

**Fix:** in your ingress-nginx Helm values:

```yaml
controller:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
      service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"  # for IP target mode (better with VPC CNI)
```

If you've also installed AWS Load Balancer Controller (you don't need it for ingress-nginx, but it can manage the NLB instead of the in-tree provisioner), use `service.beta.kubernetes.io/aws-load-balancer-type: "external"` plus `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"`. **Pick one path** and document which.

**Defuse by:** Day 2. **Severity:** Demo-degrader.

### A.4 — Argo Rollouts traffic shaping with ingress-nginx is different from ALB
**TL;DR:** Rollouts has explicit integrations per ingress controller. ingress-nginx integration uses canary annotations on a *second* Ingress; ALB integration uses target-group weights. They are not interchangeable.

**Mechanism:** During a canary, Argo Rollouts needs to shift % of traffic to the new ReplicaSet. With ingress-nginx, it does this by:
1. Creating a "stable" Service and a "canary" Service.
2. Creating a duplicate Ingress with `nginx.ingress.kubernetes.io/canary: "true"` and `nginx.ingress.kubernetes.io/canary-weight: "10"`.
3. ingress-nginx interprets those annotations and splits traffic accordingly.

**Symptom:** You configure your Rollout with a canary strategy, weights set correctly, but 100% of traffic still hits the stable version. Or analysis runs against the wrong service.

**Fix:** in your `Rollout.spec.strategy.canary`, declare the ingress integration:

```yaml
spec:
  strategy:
    canary:
      canaryService: genome-service-canary    # Service you must create
      stableService: genome-service-stable    # Service you must create
      trafficRouting:
        nginx:
          stableIngress: genome-service-ingress   # the existing Ingress, not duplicated
          additionalIngressAnnotations:
            canary-by-header: x-canary
      steps:
        - setWeight: 10
        - pause: { duration: 60 }
        - setWeight: 50
        - pause: { duration: 60 }
        - setWeight: 100
```

You must create both Services in your chart. Argo Rollouts manages the second Ingress automatically.

**Defuse by:** Day 3. **Severity:** Demo-blocker for the canary demo (which is your hero moment).

### A.5 — cert-manager renewal silently failing
**TL;DR:** Certs auto-renew at T-30 days. If renewal fails, cert-manager keeps trying but you only find out when the cert actually expires.

**Mechanism:** A failed renewal logs a Kubernetes Event but doesn't fire an alert by default. The old cert is still served until it expires. Browsers don't warn until expiry.

**Symptom:** During demo, browser shows `NET::ERR_CERT_DATE_INVALID`.

**Fix:** add a PrometheusRule that alerts on cert-manager metric `certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 86400`. Cert-manager exposes Prometheus metrics out of the box; the kube-prom-stack scrapes it via ServiceMonitor.

**Defuse by:** Day 3. **Severity:** Prod-only (4-day demo won't see expiry, but the alerting rule is rubric-relevant).

### A.6 — Multiple IngressClasses confusion
**TL;DR:** If both ingress-nginx and AWS LB Controller are installed (e.g., AWS LB Ctlr for the NLB managing ingress-nginx), each registers an IngressClass. Ingresses without `ingressClassName` go to whichever is the default — you don't know which.

**Mechanism:** Helm chart for ingress-nginx sets itself as default with `controller.ingressClassResource.default: true`. AWS LB Controller does the same. Whoever installs second wins.

**Symptom:** Some Ingresses route, some don't. `kubectl get ingress` shows blank `CLASS` column.

**Fix:** explicitly set `ingressClassName: nginx` on every Ingress your apps create. Your Helm chart should template this from a value.

**Defuse by:** Day 2. **Severity:** Demo-degrader.

### A.7 — cert-manager IRSA bootstrap order
**TL;DR:** Same family as ESO. The IRSA role for cert-manager DNS-01 must exist before cert-manager tries to solve a challenge.

**Mechanism:** cert-manager pod starts → ServiceAccount references IRSA role → if role doesn't exist or trust policy is wrong, AssumeRoleWithWebIdentity fails → DNS-01 solver can't write Route53 records → challenge times out.

**Symptom:** `kubectl logs -n cert-manager deploy/cert-manager` shows `WebIdentityErr` or `AccessDenied`.

**Fix:** in your `cluster-bootstrap` Terraform module, sequence:
1. Create OIDC provider for the cluster (handled by `terraform-aws-modules/eks/aws` automatically).
2. Create IAM role with trust for the cert-manager SA (use `iam-role-for-service-accounts-eks` submodule).
3. Then `helm_release.cert_manager` with `depends_on = [module.cert_manager_irsa]`.

**Defuse by:** Day 2. **Severity:** Demo-blocker.

---

## B. Argo CD + Argo Rollouts

### B.1 — Argo CD does NOT fire Helm hooks
**TL;DR:** `helm.sh/hook: pre-install` is a Helm CLI feature. Argo CD renders the chart with `helm template` and applies — hooks are inert.

**Mechanism:** Helm CLI has `helm install` orchestration that runs hooks at lifecycle phases. `helm template` just outputs YAML and stops. Argo CD uses the latter.

**Symptom:** Your migration Job has `helm.sh/hook: pre-install` annotations. The Job runs every sync as if it were a normal resource — or doesn't run at all if you also set `hook-delete-policy: hook-succeeded`.

**Fix:** use Argo CD hook annotations instead, with sync waves for ordering:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: genome-service-migrate-{{ .Values.image.tag | trunc 7 }}
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
```

`PreSync` runs before regular resources. `sync-wave: "1"` orders within the PreSync phase (lower wave = earlier).

**Defuse by:** Day 3. **Severity:** Demo-blocker for migration demo.

### B.2 — AnalysisTemplate divide-by-zero on no-traffic canary
**TL;DR:** During UAT canary with no real users, `sum(rate(http_requests_total{status!~"5.."})) / sum(rate(http_requests_total))` → 0 / 0 → NaN → analysis result is undefined → analysis fails ambiguously.

**Mechanism:** Prometheus rate over a 2m window with zero data points returns 0. Dividing 0 by 0 in PromQL is NaN. Argo Rollouts' `successCondition: result[0] >= 0.99` against NaN evaluates false.

**Symptom:** Canary aborts at step 1 with `AnalysisRun failed: condition not met`. Looking at the AnalysisRun output shows `result: NaN`.

**Fix:** pick one or both:
1. **PromQL guard:** wrap the denominator with `> 0`:
   ```
   sum(rate(http_requests_total{status!~"5.."}[2m]))
   /
   (sum(rate(http_requests_total[2m])) > 0)
   ```
2. **Synthetic load:** CronJob that runs `hey -z 5m -c 10 https://uat.<domain>/api/breed` during canary windows. Trigger via Rollout pre-promotion analysis.

**Defuse by:** Day 4 morning of demo (test the canary end-to-end with the regression you'll deliberately deploy). **Severity:** Demo-blocker for the auto-abort moment.

### B.3 — HPA fights with Argo CD over `spec.replicas`
**TL;DR:** Argo CD wants the `replicas` field in git to match the cluster. HPA writes to `spec.replicas`. They alternate.

**Mechanism:** HPA controller scales up. Argo CD detects drift, reconciles back to `replicas: 2` from git. HPA scales up again. Latency: minutes per cycle. Pods churn.

**Symptom:** `kubectl get rollout -w` shows replicas oscillating. Argo CD Application alternates between Synced and OutOfSync.

**Fix:** add `ignoreDifferences` on the Argo CD Application:

```yaml
spec:
  ignoreDifferences:
    - group: argoproj.io
      kind: Rollout
      jsonPointers:
        - /spec/replicas
```

For Deployments substitute group `apps`, kind `Deployment`. Apply per-application or globally via Argo CD ConfigMap (`resource.customizations.ignoreDifferences.argoproj.io_Rollout`).

**Defuse by:** Day 3. **Severity:** Demo-degrader.

### B.4 — Argo CD self-heal disabled by default
**TL;DR:** Default `syncPolicy.automated` does not auto-correct manual drift. Demo move "I delete a Deployment, watch Argo CD recreate it" requires explicit config.

**Mechanism:** `automated.selfHeal: false` (default) means Argo CD only syncs on git changes. Manual `kubectl delete` leaves the cluster missing resources until next sync trigger.

**Symptom:** Demo punchline doesn't punch. You delete a pod, expect magic, get nothing.

**Fix:** in every Argo CD Application:

```yaml
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
```

`prune: true` deletes resources removed from git. `selfHeal: true` corrects manual drift.

**Defuse by:** Day 2. **Severity:** Demo-degrader (if you want the self-heal moment).

### B.5 — Sync waves are scoped to one Application
**TL;DR:** `argocd.argoproj.io/sync-wave` orders resources within a single Application. It does NOT order resources across Applications.

**Mechanism:** Each Argo CD Application has its own sync. If you have a "platform" Application and a "microservices" Application, they sync independently and in parallel by default. Sync waves don't cross that boundary.

**Symptom:** Migration Job (in platform Application) and app pods (in microservices Application) start simultaneously. Race condition.

**Fix:** put resources that need ordering in the *same* Application, or use Argo CD `Application` dependencies (`spec.source.helm.dependencyUpdate`, plus app-of-apps sync waves on the parent Applications themselves).

**Defuse by:** Day 3. **Severity:** Demo-blocker for migration demo if you split wrong.

### B.6 — `Rollout` replaces `Deployment` (not a sibling)
**TL;DR:** When you adopt Argo Rollouts, you stop creating `Deployment` for that workload. The `Rollout` CR replaces it.

**Mechanism:** Both Deployment and Rollout manage ReplicaSets. Two controllers fighting over the same Pods = chaos. The pattern is: convert Deployment → Rollout, point Service selector to the Rollout's pod labels.

**Symptom:** `kubectl get deploy` shows nothing for your services. `kubectl get rollout` shows them. New users panic, think nothing's deployed.

**Fix:** know that `kubectl argo rollouts get rollout <name>` and `kubectl argo rollouts dashboard` are your tools, not `kubectl rollout status deployment/<name>`. Have aliases.

**Defuse by:** awareness, not a fix. **Severity:** Demo-degrader if you fumble live.

---

## C. Kubernetes / EKS basics

### C.1 — PDB + single-replica deadlock
**TL;DR:** `replicas: 1` + `PodDisruptionBudget.minAvailable: 1` makes node drain hang forever. AMI patching demo silently fails.

**Mechanism:** PDB says "at least 1 replica must be available." Drain wants to evict the only pod. PDB blocks. EKS managed node group update waits indefinitely (or times out after `node_group_update_config.max_unavailable_percentage` is exceeded).

**Symptom:** AMI bump applied, `kubectl get nodes` shows old node stuck in `SchedulingDisabled` for 30+ min. Demo dead air.

**Fix:**
- Every service has `replicas: 2` minimum in uat/prod.
- Or `PodDisruptionBudget.maxUnavailable: 1` with `replicas: 2` (different semantics, also valid).
- Or `replicas: 1` + no PDB (acceptable for dev only).

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Release.Name }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}
```

**Defuse by:** Day 3. **Severity:** Demo-blocker for AMI patching demo (10% of grade).

### C.2 — ECR tag mutability default
**TL;DR:** ECR repos default to `MUTABLE` tags. SHA `abc123` can be overwritten with a different image. "Git is source of truth" becomes false.

**Mechanism:** A force-pushed tag in ECR doesn't fail; the new image replaces the old. If your CI ever runs twice for the same SHA (rerun, rebase), you can quietly swap what's running.

**Symptom:** dev says "I ran the same SHA, why is the cluster behaving differently?" — or worse, no symptom and prod silently divergent.

**Fix:** in your ECR resource (or community module call):

```hcl
module "ecr_genome" {
  source = "terraform-aws-modules/ecr/aws"
  repository_name = "genome-service"
  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true
  repository_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
```

**Defuse by:** Day 1. **Severity:** Prod-only but rubric-relevant ("explain how you ensure the same image runs everywhere").

### C.3 — ESO bootstrap order
**TL;DR:** External Secrets Operator pod starts before the IRSA role exists. Pod crashloops.

**Mechanism:** `helm_release.eso` and `module.eso_irsa_role` have no implicit dependency. TF parallelizes them. ESO comes up, tries `AssumeRoleWithWebIdentity`, fails.

**Symptom:** `kubectl logs -n external-secrets deploy/external-secrets` shows `WebIdentityErr` repeatedly. ExternalSecret resources stuck pending.

**Fix:** explicit dependencies in the cluster-bootstrap module:

```hcl
resource "helm_release" "eso" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "external-secrets"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eso_irsa.iam_role_arn
  }

  depends_on = [module.eso_irsa]
}
```

**Defuse by:** Day 2. **Severity:** Demo-blocker.

### C.4 — EBS PVs are AZ-bound
**TL;DR:** A pod with an EBS PVC can only schedule onto a node in the volume's AZ. If that AZ is unhealthy, the pod is unschedulable.

**Mechanism:** EBS volumes are AZ-scoped. K8s scheduler enforces topology constraint via `topology.kubernetes.io/zone`. Cluster-wide failover requires either RWX volumes (EFS) or stateless apps.

**Symptom:** During an AZ outage demo, a Prometheus pod is stuck in `Pending` with `volume node affinity conflict`.

**Fix for this project:** all your *application* services are stateless (they talk to RDS, no PVCs). Only Prometheus and Loki have PVs. Accept the AZ binding for them — cluster monitoring tolerates a few-minute gap during AZ failure. Document the trade-off; don't pretend it's not there.

**Defuse by:** awareness. **Severity:** Prod-only.

---

## D. Demo / operational hygiene

### D.1 — Secrets leaking into git via values.yaml
**TL;DR:** "I'll just put `database_url: postgres://...` in dev/values.yaml temporarily" → it's in git history forever.

**Mechanism:** values.yaml is in git. Once committed, `git rm` doesn't remove from history. Rotation of leaked credentials is the only fix.

**Symptom:** GitHub secret scanning email. Or worse, no email.

**Fix:** all secrets via ESO `ExternalSecret` referencing AWS Secrets Manager. values.yaml only has *names* of secrets, never values. Pre-commit hook with `gitleaks` blocks accidental commits.

**Defuse by:** Day 2 (set the pattern with your first secret). **Severity:** Prod-only but rubric-relevant.

### D.2 — Default storage class reclaim policy
**TL;DR:** Default `reclaimPolicy: Delete`. `kubectl delete pvc` permanently deletes the underlying EBS volume.

**Mechanism:** When PVC is deleted, the StorageClass's reclaim policy fires. `Delete` removes the EBS volume. `Retain` keeps it (manual cleanup needed).

**Symptom:** "Oh I deleted the namespace to clean up. There go my Prometheus 30 days of metrics."

**Fix:** create a `gp3-retain` StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
```

Use it for Prometheus and Loki PVCs. For demo data this is overkill; for the talking point, valuable.

**Defuse by:** Day 3. **Severity:** Prod-only.

### D.3 — `imagePullPolicy: Always` with SHA tags
**TL;DR:** SHA tags are immutable. Pulling on every pod start wastes time and ECR pull credits.

**Mechanism:** Default `imagePullPolicy` is `Always` if tag is `latest` or omitted, `IfNotPresent` otherwise. Some Helm charts default to `Always` regardless.

**Symptom:** Pod takes 15-30s to start instead of <5s. Slower demos. ECR data-transfer-out charges.

**Fix:** in your chart, default `image.pullPolicy: IfNotPresent`. Document that this is safe because tags are immutable.

**Defuse by:** Day 2. **Severity:** Demo-degrader (slow pod starts during chaos demo).

### D.4 — `kubectl delete node` is destructive
**TL;DR:** `delete node` does NOT respect PDBs or graceful termination. It just removes the node object.

**Mechanism:** `delete node` removes the K8s node resource. Pods on that node become orphaned (running on the EC2 still, but K8s thinks they're gone, then re-creates them on other nodes, leading to double-running pods until kubelet eventually kills them).

**Symptom:** Demo of "rolling node update" looks chaotic, double traffic, weird.

**Fix:** for chaos demos, `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` then `terraform apply` (or terminate the EC2 via AWS Console).

**Defuse by:** awareness. **Severity:** Demo-degrader.

### D.5 — Grafana dashboards saved via UI disappear on pod restart
**TL;DR:** Without persistent volume + correct config, dashboards saved through Grafana UI live in the pod's local filesystem and vanish on restart.

**Mechanism:** Grafana writes to `/var/lib/grafana/grafana.db` (sqlite). Default Helm install uses `emptyDir`.

**Symptom:** "Where did my dashboard go?" the morning of the demo.

**Fix:** all dashboards as ConfigMaps with the sidecar label. kube-prom-stack's Grafana sidecar auto-imports them:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: golden-signals
  labels:
    grafana_dashboard: "1"
data:
  golden-signals.json: |
    { ... }
```

This way dashboards live in git, version-controlled, never lost.

**Defuse by:** Day 3. **Severity:** Demo-blocker for observability segment.

### D.6 — Loki cardinality trap (request_id as label)
**TL;DR:** Tempting to set `request_id` as a Loki label so it shows in the dropdown. Does irreparable damage to Loki's index.

**Mechanism:** Loki indexes labels, not log content. Each unique label combination = one index series. Adding `request_id` (high-cardinality) creates billions of series, OOM-killing Loki.

**Symptom:** Loki pod OOMs every few minutes. Queries slow to 30s+. Logs delayed by hours.

**Fix:** keep labels low-cardinality (namespace, app, container, level). Extract `request_id` from log content via LogQL `| json | request_id="abc"`.

**Defuse by:** Day 3 (when configuring Promtail pipeline). **Severity:** Demo-blocker if you trip it.

### D.7 — OAuth callback URL exact match
**TL;DR:** GitHub OAuth App callback URL must exactly match `https://grafana.<domain>/login/github`. Trailing slash, https vs http, hostname — all matter.

**Mechanism:** GitHub validates `redirect_uri` against the registered callback. Any difference = `redirect_uri_mismatch` error.

**Symptom:** Click "Sign in with GitHub", redirect, error page.

**Fix:**
1. Pick the final hostname for Grafana before creating the OAuth App.
2. Register callback as `https://grafana.<your-actual-domain>/login/github` (no trailing slash).
3. Configure Grafana `root_url` to match.
4. Test the flow before demo.

**Defuse by:** Day 3. **Severity:** Demo-blocker for Grafana auth segment.

---

## E. Quick-fire (less likely, still know them)

| # | Trap | Fix |
|---|---|---|
| E.1 | EKS API endpoint set to private-only locks you out from coffee shop | Use public+private with allowlisted CIDRs |
| E.2 | Single NAT Gateway = SPOF + AZ-anchor | Acceptable for dev, document trade-off; prod = NAT per AZ |
| E.3 | ECR scan-on-push doesn't *block* push | Want enforcement → use Trivy in CI, fail on critical CVEs |
| E.4 | RDS deletion protection off by default | Set `deletion_protection = true` for prod RDS instances |
| E.5 | Argo CD admin password lives in `argocd-initial-admin-secret` Secret | Rotate immediately; better, disable and use SSO |
| E.6 | `kube-prometheus-stack` retention default 10d / 50GiB | Cap with `retentionSize`, set storage requests appropriately |
| E.7 | Promtail running as non-root can't read `/var/log/pods` on some AMIs | Run as root via security context, or use Bottlerocket which prefers a different log path |
| E.8 | Helm chart `appVersion` is meaningless under Argo CD | Don't rely on it; image.tag in values is the real version |
| E.9 | `kubectl get events` has retention of ~1hr | Capture relevant events to logs for post-demo debugging |
| E.10 | Load balancer security group too permissive | Open only 80/443 to 0.0.0.0/0; everything else internal |

---

## Pre-demo checklist (defuses run for the morning of)

- [ ] All certs valid and not within 7 days of expiry: `kubectl get cert -A`
- [ ] All PDBs satisfied: `kubectl get pdb -A` shows 0 disruptions allowed but minAvailable met
- [ ] Argo CD all Applications Synced + Healthy
- [ ] Argo Rollouts all Healthy
- [ ] Test the deliberate-regression canary deploy in uat — abort behaves as expected
- [ ] Trigger a test alert, confirm Gmail (not in spam)
- [ ] All Grafana dashboards as ConfigMaps render correctly
- [ ] OAuth login works end-to-end in incognito
- [ ] `kubectl drain` test on one node returns properly
- [ ] No PVCs in `Pending` state
- [ ] Connection to RDS works from a debug pod: `psql -h <rds-endpoint> -U postgres -c '\l'`
- [ ] DNS records exist: `dig grafana.<domain> +short`

---

## On Terraform: use community modules

Don't recode what already exists. Use these as your foundation; write thin wrappers only where you need project-specific glue.

| Concern | Module | Why |
|---|---|---|
| VPC | `terraform-aws-modules/vpc/aws` (~v5.x) | Battle-tested, handles 3-AZ public+private+NAT cleanly |
| EKS cluster + nodes + OIDC | `terraform-aws-modules/eks/aws` (~v20.x) | Managed node groups, OIDC provider, addons (vpc-cni, coredns, kube-proxy, ebs-csi), all in one |
| RDS | `terraform-aws-modules/rds/aws` (~v6.x) | Postgres + parameter group + subnet group + Secrets Manager integration |
| ECR | `terraform-aws-modules/ecr/aws` (~v2.x) | One module call per repo, handles lifecycle policies + scan-on-push |
| IRSA roles | `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` | Pre-built trust policies for common addons (ESO, AWS LB Ctlr, cert-manager, external-dns, cluster-autoscaler) |
| GitHub OIDC for CI | `terraform-aws-modules/iam/aws//modules/iam-github-oidc-role` (or hand-roll the trust policy — it's small) | Standard pattern |

**What this means for your repo structure:** the `modules/` directory I sketched in `ARCHITECTURE_REVIEW.md` shrinks dramatically. You don't write a `modules/vpc/`, you call the community module from `terraform/live/dev/main.tf`:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"
  name    = "garden-${var.env}"
  cidr    = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = var.env != "prod"
  enable_dns_hostnames = true
  tags = local.tags
}
```

The only place you genuinely need a custom module is `cluster-bootstrap` — the Helm releases for ingress-nginx, cert-manager, ESO, Argo CD, etc. — because that orchestration is project-specific. Even there, consider **AWS-managed EKS addons** for ebs-csi, vpc-cni, coredns, kube-proxy (free, lifecycle-managed by AWS, configured via the EKS module).

**Revised repo layout (lighter than the previous sketch):**

```
spacetime-garden-infra/
├── terraform/
│   ├── _bootstrap/                    # state backend (one-shot)
│   ├── modules/
│   │   └── cluster-bootstrap/         # the ONLY custom module: helm releases for ingress-nginx, cert-manager, ESO, argo-cd, argo-rollouts, kube-prom-stack, loki
│   └── live/
│       ├── dev/main.tf                # composes community modules + cluster-bootstrap
│       ├── uat/main.tf
│       └── prod/main.tf
├── gitops/
│   ├── bootstrap/argocd-root-app.yaml
│   ├── apps/
│   ├── charts/microservice/
│   ├── platform-values/               # values for the platform Helm releases
│   └── envs/{dev,uat,prod}/values.yaml
└── .github/workflows/
    ├── tf-plan.yaml
    └── tf-apply.yaml
```

Ratio of code you write : code you reuse should be roughly 20:80. Anything heavier means you're rebuilding a wheel.
