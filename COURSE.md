# DevOps 401 — Cloud-Native Capstone Walkthrough

> A self-paced course covering the entire `spacetime-garden-infra` project.
> Designed to be paste-able into a tutor (GPT, Claude, etc.) for Q&A study,
> or read straight through for solo prep before defense.

**Course goal.** By the end you can stand in front of an examiner, point at any
file in this repo, and explain (a) what it does, (b) what would break if it
weren't there, and (c) why we picked this approach over the alternatives.

**Prereqs.** You should already understand: what AWS is, what a container is,
roughly what Kubernetes does, what `git push` does. Everything else we build
from there.

**Time to study.** ~6 hours of reading + ~3 hours of self-quiz = comfortable
for defense.

---

## Course outline

| Module | Topic | Why it matters in the defense |
|---|---|---|
| 1  | Course introduction & two-repo split | "Why two repos?" is the first question many examiners ask. |
| 2  | AWS networking fundamentals (VPC, subnets, NAT) | Where pods get IPs. Where load balancers live. Where databases hide. |
| 3  | EKS architecture (control plane, data plane, addons) | "Walk me through what happens when you `kubectl apply`." |
| 4  | Identity & IRSA | The most-confused topic. Critical for explaining secrets + cert-manager. |
| 5  | Terraform patterns (state, multi-stack, modules) | "Why didn't you put it all in one stack?" |
| 6  | Kubernetes object model | Pod/ReplicaSet/Deployment/Service/Ingress mental model. |
| 7  | Argo Rollouts & progressive delivery | "What's a canary and how does yours auto-abort?" |
| 8  | GitOps with Argo CD | "Why GitOps over `kubectl apply` from CI?" |
| 9  | Helm templating (and our merge helper) | "Why one chart for four services?" |
| 10 | Ingress, TLS, DNS | The whole HTTPS path explained end-to-end. |
| 11 | Secrets management (ESO + Secrets Manager) | "Where does the database password live?" |
| 12 | Observability stack | "Show me how alerts flow." |
| 13 | Day-2 operations (AMI patching, migrations) | Two rubric items worth 20% combined. |
| 14 | CI/CD cross-repo handshake | "How does code get from `git push` to production?" |
| 15 | Implementation traps catalog | The 27 things that almost broke us. |
| 16 | Architectural trade-offs (textbook vs ours) | "Why this way?" |
| 17 | Production gaps (what we deferred) | Honest answers when asked "is this prod-ready?" |
| 18 | Demo day playbook | Step-by-step demo script. |
| —  | **Final exam (50+ Qs)** | Self-quiz. |
| —  | **Glossary** | Acronyms in one place. |
| —  | **Cheat sheets** | kubectl/terraform/helm commands you'll need live. |

---

# Module 1 — Course Introduction

## 1.1 What we built

A cloud-native platform that takes application code from a developer's `git push`
and runs it as four microservices on AWS, with HTTPS, observability, automated
canary deployments, and zero manual `kubectl` in the production path.

The system is split across two GitHub repos:
- **`spacetime-garden`** (application repo, already built): React frontend +
  3 FastAPI services + Dockerfiles + GitHub Actions CI.
- **`spacetime-garden-infra`** (this repo, what we're studying): everything
  needed to *run* the application — Terraform for AWS resources, Helm charts
  for Kubernetes manifests, Argo CD for continuous deployment, Prometheus +
  Grafana + Loki for observability.

## 1.2 Why two repos

Three reasons examiners care about:

1. **Separation of concerns.** Application code changes much more often than
   infrastructure. Different review pipelines.
2. **Different ownership in the real world.** Devs own the app repo;
   platform/SRE teams own infra.
3. **Security boundary.** App-repo CI has minimal AWS permissions
   (push to ECR only). It cannot touch infra.

The two repos communicate via a **GitOps handshake**: the app repo's CI builds
images, pushes them to ECR, then commits the new image SHA into a values file
in the infra repo. Argo CD watches that file and reconciles.

## 1.3 Course learning objectives

After this course you can:
1. Explain the entire deployment lifecycle from `git push` to a running pod.
2. Identify which file in the repo handles any given concern (PDB, IRSA,
   canary analysis, etc.).
3. Defend each architectural choice against alternatives ("why ingress-nginx
   instead of ALB?").
4. Recognize the 27 catalogued implementation traps when they appear in
   logs/UI, and know which file fixes each.
5. Walk through the demo scenarios (canary abort, schema migration, AMI
   patching) and explain what's happening at each step.

## 1.4 Defense questions (Module 1)

| Q | A |
|---|---|
| Why two repos? | Separation of concerns (app changes faster than infra), security boundary (app CI has narrow AWS perms), different review processes. |
| What's the hand-off between them? | App CI builds + pushes 4 images to ECR, then commits the SHA into `gitops/envs/{uat,prod}/values.yaml` in this infra repo. Argo CD reconciles from there. |
| Could you collapse them? | Yes, but you lose the security boundary and review separation. Common in small teams; problematic at scale. |

---

# Module 2 — AWS Networking Fundamentals

## 2.1 Mental model

All AWS networking happens inside a **VPC** (Virtual Private Cloud). Inside a
VPC you have **subnets**. Each subnet lives in one **Availability Zone** (a
physically isolated datacenter within a region). Subnets are either:

- **Public** — has a route to an **Internet Gateway** (IGW). Things in public
  subnets can be reached from the internet *if* their security group allows it.
- **Private** — no IGW route. Things in private subnets cannot be reached from
  the internet directly. To make outbound calls (e.g., `apt-get update`,
  `docker pull`), they route through a **NAT Gateway** in a public subnet.

## 2.2 What the project provisions

Our VPC has 3 AZs (us-east-1a, b, c). Each AZ gets one public subnet and one
private subnet. Workloads (EKS nodes, RDS) run in private subnets. The NLB
(load balancer for ingress-nginx) lives in public subnets.

```
VPC (10.10.0.0/16)
├── AZ us-east-1a
│   ├── public subnet  10.10.101.0/24 ─── NLB target, NAT GW, IGW route
│   └── private subnet 10.10.1.0/24   ─── EKS nodes, RDS
├── AZ us-east-1b
│   ├── public subnet  10.10.102.0/24
│   └── private subnet 10.10.2.0/24
└── AZ us-east-1c
    ├── public subnet  10.10.103.0/24
    └── private subnet 10.10.3.0/24
```

## 2.3 NAT Gateway

EC2 instances in private subnets need outbound internet access for image
pulls, package updates, AWS API calls. NAT Gateway sits in a public subnet
and forwards their traffic.

**Cost trade-off:** $0.045/hr per NAT (~$33/mo each). For HA you'd run one
per AZ ($99/mo). For a demo, a single NAT in one AZ is fine — but if that AZ
fails, all nodes lose internet. We use single NAT for dev/uat, per-AZ NAT for
prod.

## 2.4 Security Groups

Stateful firewall rules attached to ENIs (network interfaces). We use SGs to
restrict what can reach RDS — only the EKS node SG. The cluster API endpoint
has its own SG, controlled by EKS.

## 2.5 In this repo

`terraform/live/dev/main.tf`:
```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24", "10.10.103.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway   # true for dev/uat
}
```

The `kubernetes.io/role/elb` (public) and `kubernetes.io/role/internal-elb`
(private) tags on subnets are required so EKS-aware load balancer controllers
know where to provision LBs.

## 2.6 Defense questions

| Q | A |
|---|---|
| Why 3 AZs? | Cluster + multi-AZ RDS need ≥3 for proper failover. Two AZs leave a single AZ as the only failover target. |
| Why private subnets for nodes? | Pods get internal IPs not reachable from internet. Public access goes through the NLB only. Defense in depth. |
| What happens if your NAT GW fails? | Nodes lose outbound internet (image pulls, AWS APIs). Existing pods keep running until they need to pull. Single NAT is a SPOF in dev/uat by design. |

---

# Module 3 — EKS Architecture

## 3.1 Control plane vs data plane

Kubernetes has two layers:

- **Control plane:** API server, etcd, scheduler, controller-manager. In EKS,
  AWS runs and patches these for you (you pay $0.10/hr per cluster).
- **Data plane:** the worker nodes that actually run your pods. You provision
  these as EC2 instances grouped into a "managed node group."

Your `kubectl` commands talk to the control plane API server. The API server
writes desired state to etcd. Controllers reconcile actual state to match.

## 3.2 Managed node groups

A "managed node group" is an EKS abstraction over an EC2 Auto Scaling Group.
You declare instance type, min/max/desired count, and an AMI version. EKS
provisions the instances, joins them to the cluster, and handles rolling
upgrades when you bump the AMI version.

## 3.3 Cluster addons

EKS supports first-party addons it manages for you (you don't run their
Helm releases). We use four:

- **vpc-cni** — assigns pod IPs from the VPC's address space (each pod gets
  a real ENI-routable IP, not an overlay address).
- **coredns** — in-cluster DNS resolver (`my-service.my-namespace.svc.cluster.local`).
- **kube-proxy** — programs iptables/ipvs rules so Service ClusterIPs work.
- **aws-ebs-csi-driver** — provisions EBS volumes when a Pod requests a PVC
  with the default StorageClass. Needed for Prometheus & Loki persistent
  storage.

## 3.4 OIDC provider

EKS exposes an OIDC issuer URL per cluster. AWS IAM trusts that OIDC issuer
when configured. This lets pods (via service accounts) assume IAM roles —
the foundation of IRSA (next module).

## 3.5 In this repo

`terraform/live/dev/main.tf`:
```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  cluster_name    = "garden-dev"
  cluster_version = "1.30"
  cluster_addons = {
    coredns          = { most_recent = true }
    kube-proxy       = { most_recent = true }
    vpc-cni          = { most_recent = true }
    aws-ebs-csi-driver = { ... }
  }
  enable_irsa = true   # creates the OIDC provider
  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size = 2; max_size = 4; desired_size = 2
    }
  }
}
```

## 3.6 Defense questions

| Q | A |
|---|---|
| What does EKS actually give you over self-managed Kubernetes? | Managed control plane (no etcd to babysit), managed addons, AWS API integration via IRSA, integrated with VPC/IAM. |
| What happens if all your nodes die simultaneously? | Control plane stays up. Pods are unschedulable until ASG provisions new nodes. Argo CD will recreate them. |
| Why managed node groups instead of self-managed? | EKS handles graceful drain on AMI upgrade, ASG integration, IAM via instance profile, no manual kubelet config. |

---

# Module 4 — Identity & IRSA

This is the most-confused topic in the project. Spend extra time here.

## 4.1 The problem

Pods often need AWS API access — to read a secret, write to S3, manage Route53
records. Three bad ways to do this:

1. **Static AWS access keys in Pod env vars.** Leaks via logs, history,
   anyone who can `kubectl get pod -o yaml`.
2. **Instance profile permissions.** Every pod on the node has the same perms;
   no per-workload scoping.
3. **kube2iam-style proxy.** Eats traffic, has CVEs, deprecated.

## 4.2 The IRSA solution

IRSA = **IAM Roles for Service Accounts**. Per-pod, no static creds, scoped to
exactly the AWS resources that pod needs.

The flow:
1. EKS exposes an OIDC issuer (`https://oidc.eks.us-east-1.amazonaws.com/id/<id>`).
2. AWS IAM has an OIDC provider configured trusting that issuer.
3. You create an IAM role with a *trust policy* that says: "I trust this OIDC
   issuer, but only for the JWT claim `system:serviceaccount:my-namespace:my-sa`."
4. Your Kubernetes ServiceAccount has annotation
   `eks.amazonaws.com/role-arn: arn:aws:iam::...:role/my-role`.
5. The EKS Pod Identity webhook injects an OIDC token + AWS env vars into pods
   using that ServiceAccount.
6. AWS SDK in the pod reads the token, calls `sts:AssumeRoleWithWebIdentity`,
   gets temporary credentials, makes AWS API calls.

No static credentials anywhere. The IAM trust policy ties specifically to one
ServiceAccount in one namespace.

## 4.3 What IRSA roles we have

In `terraform/modules/cluster-bootstrap/irsa.tf`:

| Role | What it can do | Used by |
|---|---|---|
| `garden-{env}-cert-manager` | Read/write Route53 records (for DNS-01 challenges) | cert-manager pod |
| `garden-{env}-external-dns` | Read/write Route53 records (for ingress hostnames) | external-dns pod |
| `garden-{env}-external-secrets` | Read AWS Secrets Manager `garden/{env}/*` | ESO operator pod |
| `garden-{env}-ebs-csi` | Provision EBS volumes for PVCs | ebs-csi-driver pod |

We use the community module submodule `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`, which has built-in policy templates for common addons.

## 4.4 The bootstrap order trap

If the IAM role doesn't exist yet, the pod that tries to assume it gets
`WebIdentityErr` and CrashLoopBackOff. So Terraform must create the role
*before* the Helm release that installs the pod.

We enforce this with explicit `depends_on`:
```hcl
resource "helm_release" "external_secrets" {
  ...
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }
  depends_on = [module.external_secrets_irsa]
}
```

This is `IMPLEMENTATION_TRAPS.md` §C.3 (ESO) and §A.7 (cert-manager).

## 4.5 Defense questions

| Q | A |
|---|---|
| How do pods authenticate to AWS without static credentials? | IRSA. Pod's ServiceAccount has annotation pointing to an IAM role. Webhook injects OIDC token. SDK calls AssumeRoleWithWebIdentity. |
| What stops one pod from assuming another's role? | The IAM role's trust policy only allows the specific ServiceAccount path (`system:serviceaccount:cert-manager:cert-manager`). Other pods' tokens fail the trust check. |
| What if you need a pod to read a Secret in the cluster but not from AWS? | Then no IRSA — just give the SA RBAC permission to read the Secret. IRSA is for AWS access only. |
| Can two pods share a role? | Yes, by sharing a ServiceAccount. The trust policy can also list multiple SA paths. Useful for sidecars. |

---

# Module 5 — Terraform Patterns

## 5.1 What Terraform actually does

`terraform plan` reads your `.tf` files, queries the providers (AWS, helm,
kubernetes) for current state, computes a diff, prints it. `terraform apply`
calls the providers' APIs to reconcile actual to desired.

Terraform's job is **declarative state management**. You describe the desired
end state; it figures out the API calls to get there.

## 5.2 State

Terraform must remember what it created (which IDs, ARNs, etc.) to compute
diffs next time. That's "state."

State has to live somewhere shared if multiple people will run TF or if you
run from CI. Standard pattern: **S3 for state file + DynamoDB table for
locking** (so two `terraform apply` runs can't race).

This repo has `terraform/_bootstrap/` — a one-shot stack that creates the S3
bucket and DynamoDB table. It can't store its own state in the bucket it's
about to create, so it uses local state. After it runs, every other stack
uses S3 backend.

## 5.3 Multi-stack design

We have FOUR stacks:

```
terraform/
├── _bootstrap/      one-shot: state backend (local state)
└── live/
    ├── _shared/     account-scoped: ECR, Route53 zone, GitHub OIDC role
    ├── dev/         per-env: VPC, EKS, RDS, cluster-bootstrap
    ├── uat/
    └── prod/
```

Why split:
- **_shared resources** (ECR repos, Route53 zone, GH OIDC role) are
  account-level. Creating them three times (once per env) would conflict.
- **Per-env stacks** isolate blast radius. `apply` on dev can't accidentally
  touch prod.

Stacks communicate via `terraform_remote_state` data sources. dev/uat/prod
read `_shared`'s outputs (Route53 zone ID, ECR registry URL, etc.).

## 5.4 Modules: community vs custom

A "module" in TF is a reusable bundle of resources. Two flavors:

- **Community modules** from the registry (`terraform-aws-modules/vpc/aws`,
  `.../eks/aws`, `.../rds/aws`). These encapsulate hundreds of best-practice
  resources behind a clean interface. Don't reinvent these.
- **Custom modules** written by you. Use only when nothing upstream fits.

Our only custom module is `terraform/modules/cluster-bootstrap/`. It bundles
the Helm releases for cluster addons + IRSA roles + ClusterIssuers. There's
no community module for "install all my favorite K8s addons in the right
order with IRSA wiring," so we wrote it.

## 5.5 Providers

Terraform talks to APIs through *providers*. We use:
- `hashicorp/aws` — for AWS resources
- `hashicorp/helm` — for `helm_release` (installs Helm charts)
- `hashicorp/kubernetes` — for `kubernetes_namespace` and similar
- `gavinbunney/kubectl` — for `kubectl_manifest` (more tolerant of missing
  CRDs at plan time than the official kubernetes provider)
- `hashicorp/random`, `hashicorp/tls`

The helm/kubernetes/kubectl providers need cluster connection info, which
comes from the EKS module's outputs. That's why our per-env stacks have
provider blocks like:
```hcl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec { ... }   # uses `aws eks get-token` for auth
}
```

## 5.6 The dependency graph

Terraform builds a DAG (directed acyclic graph) of resources from references.
If resource B uses `resource.A.id`, B implicitly depends on A. TF creates A
first.

When references aren't enough, you use explicit `depends_on`. We use it for:
- IRSA → Helm release (the role must exist before the pod tries to assume it)
- cert-manager → ClusterIssuer (the CRDs must be installed first)
- ESO → ClusterSecretStore (same reason)

## 5.7 Defense questions

| Q | A |
|---|---|
| Why not put everything in one stack? | Account-level resources (ECR, Route53) shouldn't be re-provisioned per env. Plus blast radius — apply errors in one env shouldn't touch others. |
| Why use community modules? | Battle-tested, handle edge cases (subnet tagging, OIDC thumbprints, IRSA trust policies) that you'd miss writing from scratch. |
| What's `depends_on` for if TF figures out dependencies from references? | Implicit deps work when one resource references another's attribute. When the dep is *temporal* (X must exist before Y starts) but there's no reference, you need explicit `depends_on`. IRSA is a classic case: the Helm chart's `set` block doesn't directly reference the IAM role's ID at plan time. |
| What does `terraform_remote_state` do? | Reads outputs from another stack's state file. We use it so dev/uat/prod can consume `_shared`'s outputs (zone ID, ECR URLs). |

---

# Module 6 — Kubernetes Object Model

## 6.1 The basic objects

| Object | What it is |
|---|---|
| **Pod** | One or more containers + shared network/storage. Smallest deployable unit. |
| **ReplicaSet** | "Run N identical Pods." Maintains pod count. |
| **Deployment** | "Manage a ReplicaSet, support rolling updates." Most common workload. |
| **Service** | Stable virtual IP/DNS name for a set of Pods. Pods come and go; the Service IP doesn't. |
| **Ingress** | HTTP routing layer. Maps hostnames + paths to Services. |
| **ConfigMap / Secret** | Key-value config (Secret is base64 + encrypted-at-rest in etcd). |
| **PersistentVolume / PersistentVolumeClaim** | Persistent disk storage outside pod lifecycle. |
| **Namespace** | Logical scope for names. `garden-dev` is one namespace. |

## 6.2 Labels and selectors

Labels are key-value tags on objects (`app.kubernetes.io/name: genome-service`).
Selectors are label-based queries. Services find their Pods via selectors;
ReplicaSets find their Pods the same way.

This is how everything is "wired" — there are no hard pointers, just label
matching. It's what makes K8s flexible (and, when wrong, confusing).

## 6.3 Pod lifecycle

```
Pending → Running → Succeeded (Job) | Failed | (Pod deleted)
                 ↘ Terminating
```

Probes:
- **Liveness probe** — if it fails, kubelet restarts the container. "Are you
  alive?"
- **Readiness probe** — if it fails, the Pod is removed from Service endpoints.
  "Are you ready to serve traffic?"
- **Startup probe** — gives slow-starting apps grace before liveness kicks in.

Our chart sets liveness + readiness on `/healthz`.

## 6.4 What replaces Deployment in this project: Rollout

We use `argoproj.io/v1alpha1/Rollout` (a CRD installed by Argo Rollouts)
*instead of* `apps/v1/Deployment`. Same idea (manage ReplicaSets), but with
canary/blue-green strategies built in.

When you adopt Argo Rollouts, you stop creating Deployments for that workload.
The Rollout CR replaces it. `kubectl get deploy` shows nothing for our services;
`kubectl get rollout` shows them.

## 6.5 Service vs Endpoint

A Service has a `selector`. The Endpoints controller watches that selector and
maintains a list of Pod IPs ready to receive traffic. kube-proxy programs
iptables/ipvs rules on each node to forward Service ClusterIP → real Pod IPs.

When a Pod becomes unready, the Endpoints controller drops its IP from the
list. Traffic stops going there.

## 6.6 Defense questions

| Q | A |
|---|---|
| What's the difference between Pod and ReplicaSet? | Pod = single instance. ReplicaSet = controller maintaining N pods. You almost never create Pods directly — you create a workload controller (Deployment/Rollout) that manages ReplicaSets. |
| If a Pod crashes, what happens? | If owned by a ReplicaSet (which is owned by a Deployment/Rollout), the ReplicaSet creates a replacement. Bare Pods aren't recreated. |
| How do Pods of one service find another? | DNS. CoreDNS serves `<service>.<namespace>.svc.cluster.local`. So `breeding-service.garden-uat.svc.cluster.local:80`. |
| Why have liveness AND readiness probes? | Liveness restarts unhealthy pods. Readiness pulls them out of Service endpoints (drains traffic) without restarting. They solve different problems. |

---

# Module 7 — Argo Rollouts & Progressive Delivery

## 7.1 The problem

Default Kubernetes Deployments do **rolling updates**: gradually replace old
pods with new ones, monitored only by readiness probes. If the new version
has a subtle bug (e.g., 5xx-rate spike), the rolling update has no idea — it
keeps progressing because pods report `ready`.

Progressive delivery adds **traffic-based gating**: shift a small % of traffic
to the new version, observe metrics, only continue if metrics look good.

## 7.2 Canary vs Blue/Green

**Canary:** new version coexists with old, gets X% of traffic. Increase X
gradually, abort if metrics degrade. Resource overhead = ~10-20% extra during
rollout.

**Blue/Green:** stand up a complete new copy ("green") alongside running
("blue"). Run smoke tests. Switch all traffic. Resource overhead = 100%
duplication during cutover.

We picked canary. Reasons:
- Demo: continuous progress bar in Argo Rollouts dashboard is visually
  compelling. Switch-flip in B/G is binary.
- Auto-abort on bad metrics is built-in.
- Lower resource cost during rollout.

## 7.3 The Rollout CRD

Replaces Deployment. Same pod template, but `spec.strategy` is `canary` or
`blueGreen`:

```yaml
spec:
  strategy:
    canary:
      canaryService: genome-service-canary
      stableService: genome-service-stable
      trafficRouting:
        nginx:
          stableIngress: genome-service
      analysis:
        templates: [{ templateName: genome-service-success-rate }]
        startingStep: 1
      steps:
        - setWeight: 10
        - pause: { duration: 60 }
        - setWeight: 50
        - pause: { duration: 60 }
        - setWeight: 100
```

## 7.4 Traffic routing with ingress-nginx

Argo Rollouts integrates per ingress controller. The nginx integration:
1. You create two Services: `<svc>-stable` and `<svc>-canary`. Both have the
   same selector at the chart-templating level.
2. You create one stable Ingress pointing at `<svc>-stable`.
3. Argo Rollouts (during a canary) creates a *second* Ingress with
   `nginx.ingress.kubernetes.io/canary: "true"` and `canary-weight: "10"`.
   This second Ingress points at `<svc>-canary`.
4. Argo Rollouts mutates the canary Service's selector to include the new
   ReplicaSet's pod-template-hash, so canary Service only points at canary
   pods. (Stable Service keeps original selector → stable pods only.)
5. ingress-nginx interprets the `canary-weight` annotation and splits traffic.

Trap: this only works because of the dual Service + dual Ingress + selector
mutation pattern. With ALB you'd use target group weights instead. Different
mental model.

## 7.5 AnalysisTemplate

Defines a Prometheus query and a success condition. Argo Rollouts runs it on
schedule during canary steps.

```yaml
spec:
  metrics:
    - name: success-rate
      successCondition: "result[0] >= 0.99"
      failureLimit: 1
      provider:
        prometheus:
          query: |
            sum(rate(http_requests_total{...,status!~"5.."}[2m]))
            /
            (sum(rate(http_requests_total{...}[2m])) > 0)
```

The `> 0` denominator guard is critical: without it, zero traffic gives
`0/0 = NaN`, the success condition `NaN >= 0.99` evaluates false, and
the analysis aborts spuriously. Trap B.2.

## 7.6 What "auto-abort" looks like

If `failureLimit: 1` is hit, Rollouts:
1. Stops advancing weight (no more `setWeight` steps execute).
2. Scales the canary ReplicaSet to 0.
3. Sends 100% traffic to the stable ReplicaSet.
4. Marks the Rollout `Degraded` so Argo CD shows red.

The user/operator hasn't done anything. The rollback was automatic.

## 7.7 Defense questions

| Q | A |
|---|---|
| Why canary not blue/green? | Visual demo, automated metric-gated abort, lower resource cost during rollout. |
| What if your canary has zero traffic? | The `or vector(0)` guard in the AnalysisTemplate handles divide-by-zero. In practice we'd run synthetic load via a CronJob during canary windows. |
| Show me how a bad image is caught. | Push deliberate regression. CI builds, promotes. Argo CD updates Rollout. Rollouts shifts 10% traffic. AnalysisRun queries Prom for 5xx rate. Threshold breached. failureLimit:1 hit. Rollout aborts, traffic shifts back to stable. 0% manual intervention. |
| What replaces `kubectl rollout status deployment/X`? | `kubectl argo rollouts get rollout X`. |

---

# Module 8 — GitOps with Argo CD

## 8.1 What GitOps actually means

Two principles:
1. **Git is the single source of truth.** Cluster state should always equal
   what's in git.
2. **Reconciliation, not imperative apply.** Don't `kubectl apply` from CI.
   Instead, an in-cluster controller (Argo CD) continuously compares cluster
   to git and reconciles.

Benefits: full audit trail (every change is a commit), one-click rollback
(revert the commit), drift detection (Argo CD reports OutOfSync), separation
of duties (deployer doesn't need cluster credentials).

## 8.2 Argo CD architecture

Argo CD runs in-cluster as a set of pods:
- **argocd-server** — UI/API
- **argocd-application-controller** — the reconciliation loop
- **argocd-repo-server** — clones git, renders Helm/Kustomize/plain manifests
- **argocd-applicationset-controller** — generates Applications from generators
- **argocd-redis** — caches state
- **argocd-dex** (optional) — SSO bridge

You interact via:
- Web UI: see Applications, sync status, manifests, events
- CLI: `argocd app sync`, `argocd app rollback`
- `kubectl` directly: Applications, ApplicationSets are CRDs

## 8.3 Application

An `Application` CR points at a git repo path and a destination cluster +
namespace. Argo CD renders manifests at that path and applies them to the
destination.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: my-app, namespace: argocd }
spec:
  source:
    repoURL: https://github.com/me/my-repo.git
    path: charts/my-chart
    targetRevision: main
    helm:
      valueFiles: [values-prod.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

## 8.4 App-of-apps

Bootstrap pattern: one root Application points at a directory of child
Applications. The root is what you `kubectl apply` once; everything else
flows from there.

`gitops/bootstrap/argocd-root-app.yaml` is our root. It points at
`gitops/apps/`, which contains `platform-stack.yaml` and `microservices.yaml`.

## 8.5 ApplicationSet

A higher-order Application factory. Generators produce parameter sets;
template substitutes them into Application specs. We use a `matrix` generator
that crosses 4 services × 3 envs = 12 Applications.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
spec:
  generators:
    - matrix:
        generators:
          - list: { elements: [ {env: dev, ...}, {env: uat, ...}, {env: prod, ...} ] }
          - list: { elements: [ {service: genome-service}, ... ] }
  template:
    metadata: { name: '{{.service}}-{{.env}}' }
    spec: { ... }
```

Adding a 5th service or 4th env = 1 line change. No new files.

## 8.6 Sync

When Argo CD detects git ≠ cluster, it computes a diff and applies it. The
sync runs in **phases** (PreSync → Sync → PostSync) and within each phase,
**waves** (sync-wave annotation, lower numbers first).

Trap B.5: waves are *per-Application*. They don't order resources across
Applications. So our migration Job (PreSync, wave 1) lives in the same
Application as the genome-service Rollout (Sync, default wave) — that's why
the ApplicationSet creates one App per (service × env) pair.

## 8.7 Hooks

Annotations that mark a resource as a sync hook:
- `argocd.argoproj.io/hook: PreSync` — runs before the Sync phase
- `argocd.argoproj.io/hook: PostSync` — runs after
- `argocd.argoproj.io/hook: SyncFail` — runs if Sync fails
- `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation | HookSucceeded | ...`

Trap B.1: Argo CD's hooks are NOT Helm's hooks. Helm CLI runs `pre-install`,
`post-install` etc., but Argo CD uses `helm template` (which doesn't fire
those). You must use Argo CD's annotations on the resource directly.

Our migration Job (`templates/presync-migrate.yaml`) uses Argo CD annotations.

## 8.8 Sync policy

```yaml
syncPolicy:
  automated:
    prune: true       # delete cluster resources removed from git
    selfHeal: true    # revert manual changes (drift correction)
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
```

Trap B.4: defaults are off. Without `selfHeal: true`, the "delete a Deployment,
watch Argo CD recreate it" demo doesn't work.

## 8.9 In this repo

```
gitops/
├── bootstrap/argocd-root-app.yaml       root app — applied once via kubectl
├── apps/
│   ├── platform-stack.yaml              dashboards, alerts, ESO secrets
│   ├── microservices.yaml               ApplicationSet (4 svc × 3 env)
│   └── pr-preview.yaml                  ApplicationSet w/ PR generator (off)
```

## 8.10 Defense questions

| Q | A |
|---|---|
| Why GitOps over `kubectl apply` from CI? | Audit trail (every change is a commit), one-click rollback (revert the commit), separation of duties (deployer doesn't need cluster creds), drift detection. |
| What does "reconciliation" mean? | Argo CD continuously compares cluster state to git state. When they differ, it applies the diff. Not "fire and forget" like a CI pipeline. |
| Why one Application per service-env instead of one for everything? | Sync waves are per-Application. Migration Job (PreSync wave 1) needs to be in the same App as the Rollout that depends on it. |
| What happens if you push a bad commit? | Argo CD syncs. If a manifest is invalid, sync fails — old resources keep running. Argo Rollouts gates the actual pod rollout via canary analysis. To rollback, revert the commit. |

---

# Module 9 — Helm Templating (and Our Merge Helper)

## 9.1 What Helm is

A templating engine + package manager for Kubernetes manifests. Two artifacts:
- **Chart** — a directory with `Chart.yaml`, `values.yaml`, `templates/`. The
  templates use Go template syntax, can iterate, conditional, etc.
- **Release** — an instance of a chart installed in a cluster, with values
  applied.

`helm install` and `helm template` both render the chart. The first applies
to a cluster (and tracks state in K8s as a release secret); the second prints
to stdout and stops.

## 9.2 What we DON'T use Helm for

`helm install` is for installing things from your laptop or CI. We don't run
`helm install` on app workloads — Argo CD does.

For app workloads, Argo CD reads our chart, runs `helm template` internally,
and applies the rendered manifests via the K8s API. Helm is purely a
templating engine here. No release secrets, no Helm hooks fire.

For platform addons (ingress-nginx, cert-manager, etc.) we DO use `helm install`
via the Terraform `helm_release` provider. That's because Argo CD itself is
one of those addons — it can't install itself.

## 9.3 Chart anatomy

```
microservice/
├── Chart.yaml         metadata: name, version, description
├── values.yaml        default values
└── templates/
    ├── _helpers.tpl   reusable template definitions (named templates)
    ├── rollout.yaml
    ├── service-stable.yaml
    ├── service-canary.yaml
    ├── ingress.yaml
    ├── ...
```

`Chart.yaml` is metadata. `values.yaml` is the parameter defaults. Each
file in `templates/` becomes a Kubernetes manifest after rendering.

## 9.4 Template syntax (just enough)

```
{{ .Values.image.repository }}      → reference a value
{{ if .Values.hpa.enabled }}...{{ end }}     → conditional
{{ range .Values.list }}...{{ end }}         → loop
{{ include "microservice.labels" . }}        → include another template
{{- ... -}}                                  → trim whitespace before/after
```

`.Values` is the merged values (chart defaults + CLI `-f` overrides + `--set`).
`.Release` has install metadata (`Name`, `Namespace`).
`.Chart` has Chart.yaml fields.

## 9.5 Why one chart for four services

Without parameterization, you'd write four near-identical charts (~80%
duplicate YAML). Worse: any operational improvement (new probe, label, etc.)
requires updating 4 places.

With parameterization, the differences (`database.enabled`, `hpa.enabled`,
ingress path, etc.) become flags. ~80% YAML reduction. Demonstrates engineering
taste.

## 9.6 The merge helper (the project's spiciest piece of Helm)

**The constraint.** The application repo's CI promotion workflow bumps
`<service>.image.tag` in `gitops/envs/{env}/values.yaml`. So the values file
has per-service blocks at the top level:

```yaml
genome-service:
  image: { repository: ..., tag: main }
  database: { enabled: true }
breeding-service:
  image: { ... }
gallery-service:
  image: { ... }
frontend:
  image: { ... }
```

But Helm chart templates expect flat values like `.Values.image.repository`.
We need the chart to "select" the right service's block based on a parameter.

**The solution.** A named template `microservice.merged` in `_helpers.tpl`:

```
{{- define "microservice.merged" -}}
{{- $svcName := required "serviceName must be set" .Values.serviceName -}}
{{- $svcBlock := index .Values $svcName | default dict -}}
{{- $merged := mergeOverwrite (deepCopy .Values) (deepCopy $svcBlock) -}}
{{- $merged | toYaml -}}
{{- end -}}
```

Walkthrough:
1. `$svcName` = the service to render (passed via ApplicationSet parameter).
2. `$svcBlock` = the per-service map, e.g. `{ image: {...}, database: {...} }`.
3. `mergeOverwrite (deepCopy .Values) $svcBlock` = chart defaults overridden
   by service-specific values.
4. Returns YAML string of the merged map.

Templates use:
```
{{- $v := include "microservice.merged" . | fromYaml -}}
image: "{{ $v.image.repository }}:{{ $v.image.tag }}"
```

`$v` is the per-service merged values. Templates reference fields uniformly
without caring which service they're rendering.

## 9.7 Conditional resources

The chart has 12 templates. Some emit only under certain conditions:

| Template | Emitted when |
|---|---|
| `pdb.yaml` | `pdb.enabled` AND `replicas >= 2` (trap C.1) |
| `hpa.yaml` | `hpa.enabled` (only breeding-service in our setup) |
| `externalsecret.yaml` | `database.enabled` AND `externalSecret.enabled` |
| `presync-migrate.yaml` | `runMigrations` (only genome-service) |
| `analysistemplate.yaml` | `canary.enabled` AND `canary.analysis.enabled` |
| `prometheusrule.yaml` | `monitoring.prometheusRule.enabled` |
| `servicemonitor.yaml` | `monitoring.serviceMonitor.enabled` |

The frontend service disables `monitoring.*` because nginx doesn't expose
Prometheus metrics by default.

## 9.8 Defense questions

| Q | A |
|---|---|
| Why one chart for four services? | Less duplication, single place to evolve operational concerns, demonstrates engineering taste. |
| How does the chart pick the right service's values from the env file? | The `microservice.merged` helper looks up `.Values[.Values.serviceName]` and merges that block on top of chart defaults, returning a flat map the templates use. |
| Why not 12 separate values files (one per service per env)? | The app-repo's CI bumps `<service>.image.tag` in one file per env. That format is locked. We honored it. |
| Where do Helm hooks fit? | They DON'T fire under Argo CD. We use Argo CD's hook annotations on the migration Job instead. |

---

# Module 10 — Ingress, TLS, DNS

## 10.1 The full HTTPS path

```
Browser
  │ HTTPS (TLS terminated at NLB or at ingress-nginx)
  ▼
Route53 DNS lookup → returns NLB hostname/IPs
  │
  ▼
AWS NLB (Network Load Balancer)
  │ Layer 4 (TCP)
  ▼
ingress-nginx Pods (cluster, hostNetwork=false, behind ClusterIP via NLB targets)
  │ HTTP routing based on Host: header + path
  ▼
Service (ClusterIP) for the app
  │ kube-proxy iptables rules
  ▼
App Pod
```

## 10.2 ingress-nginx

A Helm chart that deploys:
- A `Deployment` of nginx-controller pods (the data path)
- A `Service` of type `LoadBalancer` (provisions the NLB)
- An `IngressClass` that says "I handle Ingresses with `ingressClassName: nginx`"

When you create an `Ingress` resource, the controller pods notice, regenerate
their nginx.conf, and reload. Routing is done in nginx based on `host` and
`path` rules.

Trap A.3: by default, Service of type LoadBalancer on EKS provisions a
Classic Load Balancer (CLB), which is deprecated. We add annotations to force
NLB.

## 10.3 cert-manager + Let's Encrypt

cert-manager is a controller that watches `Certificate`/`Ingress` resources
and provisions TLS certs from configured issuers. We use Let's Encrypt (free,
automatically renewed every 60 days).

LE proves you own the domain via an **ACME challenge**. Two methods:
- **HTTP-01:** ACME server fetches a token from `http://yourdomain/.well-known/
  acme-challenge/<token>`. Requires port 80 exposed and reachable.
- **DNS-01:** cert-manager creates a TXT record at `_acme-challenge.yourdomain`.
  ACME server queries DNS. No port-80 dance.

We use DNS-01. Trap A.2 — HTTP-01 has weird interactions with NLBs.

DNS-01 needs cert-manager to write to Route53. That's IRSA territory: the
`cert-manager` ServiceAccount gets an IRSA role that can manipulate the
project's Route53 zone.

## 10.4 ClusterIssuer

cert-manager has two CRDs:
- `Issuer` — namespace-scoped certificate authority config
- `ClusterIssuer` — cluster-scoped (every namespace can use it)

We define two ClusterIssuers (in TF, applied via kubectl_manifest):
- `letsencrypt-staging` — uses LE staging endpoint (high rate limits, untrusted certs in browser)
- `letsencrypt-prod` — uses LE prod endpoint (trusted certs, 50/week limit)

Trap A.1: always start with staging during iteration. Switch to prod only
when the flow works end-to-end.

## 10.5 external-dns

A controller that watches Ingress (and Service) resources and creates Route53
records to match. So when our Ingress says `host: dev.spacetimegarden.dev`,
external-dns creates a CNAME pointing at the NLB hostname.

Without external-dns, you'd manually maintain DNS records — error-prone and
breaks when NLB DNS changes.

external-dns also needs Route53 IAM perms (its own IRSA role).

## 10.6 Cert request flow (concrete)

1. User creates Ingress with `cert-manager.io/cluster-issuer: letsencrypt-prod`
   annotation and a `tls` block.
2. cert-manager controller sees the Ingress, creates a `Certificate` resource.
3. Certificate triggers `CertificateRequest` → `Order` → `Challenge` resources.
4. Challenge tells cert-manager: "create TXT record `_acme-challenge.<host>=<token>`".
5. cert-manager assumes its IRSA role, calls Route53 API to create the TXT.
6. Challenge waits for the TXT to propagate (usually 30-60s).
7. Challenge tells LE: "the TXT is ready, please verify."
8. LE queries DNS, sees TXT, issues cert.
9. cert-manager stores cert in K8s Secret named in the Ingress's `tls.secretName`.
10. ingress-nginx reloads, picks up cert, serves HTTPS.

If anything in this chain fails, the cert is stuck `Issuing`. Common causes:
- Route53 zone not delegated at registrar
- IRSA role missing or wrong trust policy
- Hit LE rate limits (use staging)
- DNS propagation delay (just wait)

## 10.7 Defense questions

| Q | A |
|---|---|
| Why DNS-01 over HTTP-01? | HTTP-01 needs the LE servers to reach our cluster on port 80. Behind NLB with port forwarding, that's fragile. DNS-01 just needs cert-manager to write a TXT record — much more reliable. |
| Why ingress-nginx instead of ALB Controller? | Class chose it; more portable; explicit ingress class. Adds a Pod-tier hop (NLB → ingress-nginx pods → app Pod) which isn't needed with ALB, but works fine. |
| What if cert-manager's IRSA role doesn't exist when its pod starts? | Pod CrashLoopBackOff with WebIdentityErr. We prevent this with `depends_on = [module.cert_manager_irsa]` on the Helm release. |
| How does the certificate auto-renew? | cert-manager checks expiry every 12hr. At T-30 days it triggers a renewal automatically. We have a Prometheus alert if it fails. |

---

# Module 11 — Secrets Management

## 11.1 The problem

Database passwords, OAuth client secrets, SMTP app passwords. They must be
available in pods but should never appear in:
- Git history
- Docker image layers
- ConfigMaps
- Environment variables visible via `kubectl describe pod`

## 11.2 The pattern: AWS Secrets Manager + ESO

```
AWS Secrets Manager
   garden/dev/genome-service/db
   garden/dev/grafana/oauth
   garden/dev/alertmanager/smtp
        │
        │ AWS API: GetSecretValue (via IRSA)
        ▼
External Secrets Operator (ESO)
   reconciles ExternalSecret CRs into K8s Secrets
        │
        ▼
Kubernetes Secret (in pod's namespace)
        │
        │ envFrom or volumeMount
        ▼
Application Pod
```

Step by step:
1. Operator creates secret in Secrets Manager (manually via AWS console or CLI,
   or for service DB URLs via Terraform).
2. ESO has an IRSA role allowed to read `garden/{env}/*` secrets.
3. We define a `ClusterSecretStore` once: "use AWS Secrets Manager via this SA".
4. The microservice chart emits an `ExternalSecret` per service: "pull
   `DATABASE_URL` from `garden/{env}/genome-service/db` and put it in a K8s
   Secret named `genome-service-db`."
5. ESO reconciles: hits AWS API every `refreshInterval` (default 1h), creates/
   updates the K8s Secret.
6. Pod's `envFrom: secretRef: name: genome-service-db` picks up `DATABASE_URL`
   as env var.

## 11.3 Why this is better than alternatives

- **vs sealed-secrets:** still puts encrypted secrets in git. AWS Secrets
  Manager is the source of truth and supports rotation Lambdas.
- **vs init container with aws CLI:** every pod needs AWS perms; harder
  rotation; harder testing.
- **vs Vault:** Vault is more powerful but another whole platform to operate.
  AWS Secrets Manager is one less thing.

## 11.4 In this repo

- `terraform/modules/cluster-bootstrap/secret-store.tf` — defines the
  `ClusterSecretStore` named `aws-secrets-manager`.
- `gitops/charts/microservice/templates/externalsecret.yaml` — emits
  `ExternalSecret` per service that's `database.enabled`.
- `gitops/monitoring/grafana-oauth-externalsecret.yaml` — pulls Grafana OAuth
  creds.
- `gitops/monitoring/alertmanager-smtp-externalsecret.yaml` — pulls Gmail SMTP
  password.

## 11.5 Defense questions

| Q | A |
|---|---|
| Where does the database password live? | AWS Secrets Manager at `garden/{env}/genome-service/db`. Never in git. |
| How does the pod read it? | ESO syncs it into a K8s Secret in the pod's namespace. Pod uses `envFrom: secretRef:` to pick it up as env var `DATABASE_URL`. |
| What stops other pods from reading it? | K8s RBAC + secret namespacing. Only pods in the same namespace can read it, and only via their ServiceAccount's permissions. |
| What about rotation? | Secrets Manager supports rotation Lambdas (we don't have one yet — production gap). When the secret value changes, ESO refreshes the K8s Secret on its `refreshInterval`. Pods pick up new env vars on next restart. |

---

# Module 12 — Observability Stack

## 12.1 Three pillars

| Pillar | What it answers | Tool |
|---|---|---|
| **Metrics** | "Is the service healthy? How fast?" | Prometheus + Grafana |
| **Logs** | "What did this specific request do?" | Loki + Promtail (collected) + Grafana (queried) |
| **Traces** | "How did a request propagate across services?" | (out of scope for this project) |

## 12.2 kube-prometheus-stack

A monolithic Helm chart that bundles:
- **Prometheus** + Prometheus Operator (manages Prometheus instances declaratively)
- **Grafana** with default dashboards
- **Alertmanager** (alert routing + dedup)
- **node-exporter** (per-node OS metrics)
- **kube-state-metrics** (cluster-state metrics)
- **CRDs:** ServiceMonitor, PodMonitor, PrometheusRule, AlertmanagerConfig

You install one Helm chart, get the whole stack pre-wired.

## 12.3 ServiceMonitor

A CRD that tells Prometheus Operator: "scrape these endpoints." Without it,
Prometheus has no way to discover your app.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
spec:
  selector: { matchLabels: { app.kubernetes.io/name: genome-service } }
  endpoints: [{ port: http, path: /metrics, interval: 30s }]
```

Prom Operator notices, generates a scrape config, reloads Prometheus.

Trap: ServiceMonitor must have label `release: kube-prometheus-stack` for the
default Prom instance to pick it up. Our chart does this.

## 12.4 PrometheusRule

A CRD that defines alert rules. Operator translates to Prom config.

```yaml
spec:
  groups:
    - name: my-app
      rules:
        - alert: ServiceErrorRateHigh
          expr: ...                # PromQL
          for: 5m                  # must hold for 5m before firing
          labels: { severity: critical }
          annotations: { summary: "..." }
```

Alerts go to Alertmanager. AM groups by labels, dedups, routes to receivers
(email, Slack, PagerDuty).

## 12.5 Grafana

Visualization. Reads from Prom (metrics) and Loki (logs). Dashboards are JSON
configs.

Trap D.5: dashboards saved via Grafana UI live in Grafana's sqlite. Lost on
pod restart. Solution: dashboards as ConfigMaps with `grafana_dashboard: "1"`
label. Grafana's sidecar auto-imports them.

We have one custom dashboard: `gitops/dashboards/golden-signals.configmap.yaml`
with RPS, latency p50/p95/p99, error rate panels.

## 12.6 Loki + Promtail

- **Promtail** runs as a DaemonSet (one Pod per node). Tails container log
  files in `/var/log/containers/`. Enriches with K8s metadata (pod name,
  namespace, labels). Ships to Loki.
- **Loki** stores logs. Indexes by labels only (NOT log content). Cheap.
- Querying via LogQL in Grafana: `{namespace="garden-uat",app="genome"} |= "error"`.

Trap D.6: don't make labels high-cardinality. `request_id` as a label
explodes the index. Extract it from log content via `| json | request_id="X"`
in LogQL instead.

## 12.7 Alertmanager flow

```
Prometheus rule fires
  │
  ▼
Alertmanager receives alert
  │ groups by labels (alertname, namespace)
  │ dedups (one alert per unique label set)
  │ routes by `match` rules
  ▼
Receiver: ops-email (Gmail SMTP)
  │
  ▼
You get an email
```

We have one route by default (`receiver: ops-email`) with severity-based
sub-route. SMTP password comes from Secrets Manager via ESO.

## 12.8 Required alerts (rubric)

In `gitops/alerts/node-and-cluster-rules.yaml`:
- `NodeCpuHigh`, `NodeMemoryHigh`, `NodeDiskHigh` — node resource pressure
- `PodCrashLoopBackOff`, `PodOOMKilled` — pod stability
- `CertExpiringSoon` — cert-manager renewal failed silently

Service-level alerts (`ServiceErrorRateHigh`, `ServiceLatencyHigh`) are
emitted per-service by the microservice chart's `prometheusrule.yaml`.

## 12.9 Defense questions

| Q | A |
|---|---|
| How does Prometheus know which endpoints to scrape? | ServiceMonitor CRDs select Services by label. Prom Operator regenerates scrape config and reloads Prom. |
| How do alerts reach you? | PrometheusRule fires alert → Alertmanager groups/routes → Gmail SMTP receiver → email. |
| Where do logs go? | Promtail DaemonSet tails container logs, enriches with K8s metadata, ships to Loki. Grafana queries via LogQL. |
| Why not put `request_id` as a Loki label? | High-cardinality labels OOM Loki. Extract from JSON log content via LogQL instead. |
| Where do Grafana dashboards live? | As ConfigMaps in this repo (`gitops/dashboards/`). Grafana's sidecar imports them based on label. UI-saved dashboards are NOT persisted across pod restarts. |

---

# Module 13 — Day-2 Operations

## 13.1 AMI patching (10% of rubric)

The flow:
1. AWS publishes a new EKS-optimized AMI release (security patches, kernel
   updates).
2. You bump `release_version` in the EKS managed node group config.
3. `terraform apply` triggers a managed-node-group update.
4. EKS does a **rolling node replacement**:
   - Cordons one node (no new pods scheduled here).
   - Drains it (evicts pods, respecting PDBs).
   - Terminates the node, ASG provisions a new one with new AMI.
   - Repeats for next node.
5. PDBs are what keep traffic flowing — they prevent the drain from killing
   all replicas of a service simultaneously.

What you'd demo: bump the AMI, run `kubectl get nodes -w` in one window, run
a load generator (`hey`) in another. Show zero requests dropped.

PDB requirement: `replicas >= 2` and `minAvailable: 1`. Single replica + PDB
hangs the drain forever (trap C.1).

## 13.2 Schema migration (10% of rubric)

The challenge: deploy a new app version that requires a DB schema change
without taking the running version offline.

**Expand-migrate-contract pattern:**
1. **Expand:** add new column (nullable, default value). Old code ignores it,
   new code uses it. Both work.
2. **Migrate:** backfill data if needed. Both versions still work.
3. **Contract:** drop the old column (or change types) once all old pods
   are gone.

For our project, the demo migration `0002_add_gallery_likes.py` adds a new
column `likes` to a table. It's an "expand" step — old code can ignore it,
new code reads it.

## 13.3 The PreSync Job

Argo CD doesn't fire Helm hooks (trap B.1). We use a `Job` with Argo CD
hook annotations:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
```

When Argo CD syncs (because someone bumped `image.tag`):
- **Wave 0:** ExternalSecrets sync (DATABASE_URL is fresh).
- **Wave 1 (PreSync):** migration Job runs `alembic upgrade head` from the
  new image's bin. If it fails, Argo CD aborts the sync — old pods keep
  running.
- **Wave 2 (Sync):** Rollout updates. New pods come up. Argo Rollouts canary
  starts.

Job name includes the image-tag SHA prefix so each release is a distinct Job.

## 13.4 Drain mechanics

`kubectl drain <node>`:
1. Cordons the node (kubectl mark unschedulable).
2. Evicts each pod via the Eviction API.
3. Eviction respects PDBs (returns 429 if minAvailable would be violated).

Drain blocks until all pods leave. PDBs prevent killing the last replica.
With `replicas >= 2` and `minAvailable: 1`, drain evicts one replica, waits
for new one to come up on another node, evicts the next. Traffic continues.

Don't use `kubectl delete node` for chaos demos. It removes the node object
but doesn't drain — pods are orphaned briefly. Trap D.4.

## 13.5 Defense questions

| Q | A |
|---|---|
| How do you patch nodes without downtime? | Bump `release_version` in tfvars, `terraform apply`. EKS rolls one node at a time, respecting PDBs. PDBs require ≥2 replicas + minAvailable: 1. |
| Walk me through the migration flow. | Push commit. CI builds image. Promotion bumps SHA in env values. Argo CD syncs in waves: ExternalSecrets first (wave 0), migration Job PreSync (wave 1), Rollout last (wave 2). New schema in place before new pods cut over. |
| What if the migration breaks the running version? | Don't make breaking changes in one migration. Use expand-migrate-contract: nullable column first, deploy new code, backfill, drop old. The pattern guarantees both old and new code work mid-migration. |
| What happens if drain hangs? | Usually means single replica + minAvailable: 1 PDB = deadlock. Bump replicas to 2+ or remove the PDB temporarily. |

---

# Module 14 — CI/CD Cross-Repo Handshake

## 14.1 The end-to-end flow

```
Developer pushes to spacetime-garden:main
  │
  ▼
GitHub Actions: ci.yaml
  - OIDC: assume AWS_ROLE_ARN
  - docker build × 4
  - docker push to ECR (tag = full git SHA)
  │
  ▼
GitHub Actions: promote-uat.yaml
  - Clone spacetime-garden-infra (using INFRA_REPO_TOKEN)
  - yq edit gitops/envs/uat/values.yaml: bump <service>.image.tag for all 4
  - git commit + git push
  │
  ▼ (3 min reconcile interval)
Argo CD detects git change
  - Computes diff
  - Runs sync: PreSync (migration) → Sync (Rollout update) → PostSync
  │
  ▼
Argo Rollouts starts canary
  - 10% traffic to new ReplicaSet
  - AnalysisRun queries Prom for 5xx rate
  - If passes: 50% → 100%
  - If fails: scale canary to 0, mark Degraded
  │
  ▼
New version live in uat
```

For prod: app-repo CI triggers on `v*.*.*` tag pushes via `promote-prod.yaml`,
bumping `gitops/envs/prod/values.yaml`. Argo CD's prod App is set to manual
sync — operator clicks "Sync" in the UI.

## 14.2 GitHub OIDC (the no-static-creds AWS auth)

GitHub Actions workflows can request OIDC tokens. AWS IAM trusts GitHub's
OIDC issuer (we set up the OIDC provider in `_shared`).

The IAM role's trust policy allows `sts:AssumeRoleWithWebIdentity` IF the
JWT's `sub` claim matches a specific repo + ref:

```json
{
  "StringLike": {
    "token.actions.githubusercontent.com:sub": [
      "repo:fhshaik/spacetime-garden:ref:refs/heads/main",
      "repo:fhshaik/spacetime-garden:ref:refs/tags/v*",
      "repo:fhshaik/spacetime-garden:pull_request"
    ]
  }
}
```

So `main` pushes, `v*` tags, and PRs from `fhshaik/spacetime-garden` can
assume the role. Forks, other repos, other branches cannot.

Workflow uses `aws-actions/configure-aws-credentials@v4` with the role ARN.
No static credentials.

## 14.3 INFRA_REPO_TOKEN

The promotion workflow needs to push to *this* infra repo. OIDC is for AWS;
GitHub-to-GitHub auth needs a different mechanism.

We use a **fine-grained PAT** (Personal Access Token) scoped to:
- This repo only
- Permission: contents:write

Stored as a GitHub Secret on the app repo. App-repo workflow uses it to
clone + push. Narrow scope = if leaked, impact is limited to this infra repo.

## 14.4 Repo variables vs secrets

Variables: visible to anyone who can read the repo. We use them for
non-sensitive values: AWS_ROLE_ARN, AWS_REGION, INFRA_REPO.

Secrets: encrypted, only injected at workflow runtime. We use this for
INFRA_REPO_TOKEN.

Both are set under app-repo Settings → Secrets and variables → Actions.

## 14.5 Why this is the right architecture

- **No long-lived AWS keys** anywhere. OIDC is short-lived (15 min default).
- **Auditable.** Every promotion is a git commit in the infra repo. You can
  see which app SHA is running where, when it got there, by whom.
- **Reversible.** Revert the commit in infra repo, Argo CD reconciles back.
- **Decoupled.** App devs don't have cluster access. Infra repo doesn't have
  app source.

## 14.6 Defense questions

| Q | A |
|---|---|
| Walk me through what happens when you push code. | (Recite the flow from 14.1.) |
| How does CI authenticate to AWS? | GitHub OIDC. Workflow gets a JWT, exchanges via STS:AssumeRoleWithWebIdentity for short-lived AWS credentials. Trust policy locks to specific repo+ref. |
| What's the PAT for? | Cross-repo: app-repo CI pushing commits to this infra repo. OIDC is AWS-only. |
| What if someone forks the app repo? | The OIDC trust policy `sub` claim wouldn't match (different repo path). Fork's OIDC token can't assume the role. |
| How would you roll back a bad deploy? | Revert the commit on this infra repo. Argo CD reconciles to the prior image SHA. ~3 min. |

---

# Module 15 — Implementation Traps Catalog (summarized)

We catalogued 27 traps in `IMPLEMENTATION_TRAPS.md`. Here's the categorical
summary — which classes of mistakes recur, and the principle behind each fix.

## A. Ingress + cert-manager (7 traps)

The longest section, because ingress-nginx + cert-manager has more moving
parts than ALB + ACM.

| Principle | Traps |
|---|---|
| Always start at LE staging during iteration. Production rate limits are 50/week. | A.1 |
| Use DNS-01, not HTTP-01, for challenges behind any LB. | A.2 |
| Force NLB explicitly via Service annotations; default is deprecated CLB. | A.3 |
| Argo Rollouts' nginx integration requires two Services + a stable Ingress. | A.4 |
| Cert renewal can fail silently — alert on it. | A.5 |
| Always set `ingressClassName` explicitly. Don't rely on default. | A.6 |
| cert-manager IRSA must exist before its pod starts. | A.7 |

## B. Argo CD + Argo Rollouts (6 traps)

| Principle | Traps |
|---|---|
| Argo CD does NOT fire Helm hooks. Use Argo CD's hook annotations. | B.1 |
| AnalysisTemplate PromQL must guard against divide-by-zero. | B.2 |
| HPA fights Argo CD over `spec.replicas`. Use `ignoreDifferences`. | B.3 |
| `automated.selfHeal` is OFF by default. Turn it on for the demo. | B.4 |
| Sync waves are per-Application. Resources that need ordering must share an Application. | B.5 |
| Rollout REPLACES Deployment, doesn't supplement it. `kubectl get deploy` shows nothing. | B.6 |

## C. Kubernetes / EKS (4 traps)

| Principle | Traps |
|---|---|
| PDB `minAvailable: 1` requires `replicas >= 2`, else drain hangs forever. | C.1 |
| ECR tags default to MUTABLE. Set to IMMUTABLE for "build once, promote everywhere." | C.2 |
| ESO IRSA must exist before ESO Helm release. | C.3 |
| EBS PVs are AZ-bound. Multi-AZ HA needs stateless apps + RDS. | C.4 |

## D. Demo / operational hygiene (7 traps)

| Principle | Traps |
|---|---|
| Secrets never in values.yaml or git. Always via ESO from Secrets Manager. | D.1 |
| Default StorageClass reclaim is Delete. PV gone if you delete the PVC. | D.2 |
| `imagePullPolicy: Always` with SHA tags is wasteful. Use IfNotPresent. | D.3 |
| `kubectl delete node` doesn't drain. Use `kubectl drain` for chaos demos. | D.4 |
| Grafana dashboards as ConfigMaps. UI-saved dashboards die on pod restart. | D.5 |
| Loki labels must be low-cardinality. Don't label by request_id. | D.6 |
| OAuth callback URL must exact-match GitHub OAuth App config. | D.7 |

## E. Quick-fire (10 minor)

EKS endpoint privacy, NAT GW costs, ECR scan-on-push not blocking, RDS deletion
protection, Argo CD admin password rotation, Prom retention defaults, Promtail
non-root issues, Helm appVersion meaningless, kubectl events 1hr retention,
LB security groups too permissive.

## How traps map to defense answers

Examiners often ask "what could go wrong with X." Answer with: trap name +
mechanism + how we preempted it. E.g.:

- "What could go wrong with the canary?" → "Trap B.2: AnalysisTemplate
  divide-by-zero on no-traffic. We preempt with `or vector(0)` denominator
  guard in the PromQL."

---

# Module 16 — Architectural Trade-offs (Textbook vs Ours)

The 27 traps drove ~20 specific choices that deviate from the naive textbook
implementation. We covered this in detail in the previous chat — quick
reference here.

| Dimension | Textbook | Ours | Trap addressed |
|---|---|---|---|
| TF stacks | One per env, monolithic | 4 stacks (`_bootstrap`, `_shared`, `dev/uat/prod`) | State conflicts on shared resources |
| Custom modules | Hand-roll everything | Community + 1 custom | Wheel reinvention |
| Helm charts | 4 (one per service) | 1 parameterized | Code duplication |
| Argo CD Apps | 12 hand-written | 1 ApplicationSet w/ matrix | Maintenance burden |
| Workload kind | Deployment | Rollout | No progressive delivery |
| Migration mechanism | Helm pre-install hook | Argo CD PreSync hook annotation | B.1 |
| Canary analysis | Naive PromQL | `or vector(0)` guard | B.2 |
| PDB | Always `minAvailable: 1` | Conditional on replicas≥2 | C.1 |
| ECR tags | MUTABLE | IMMUTABLE | C.2 |
| Cert challenge | HTTP-01 | DNS-01 with IRSA | A.2 |
| Cert iteration | Prod issuer | Staging issuer first | A.1 |
| Service shape | One Service | stable + canary Services | A.4 |
| TF→K8s ordering | Hope it works | Explicit `depends_on` | A.7, C.3 |
| ClusterIssuer apply | kubernetes_manifest | kubectl_manifest (gavinbunney) | CRD-at-plan-time issue |
| HPA + GitOps | Default | `ignoreDifferences` | B.3 |
| Self-heal | Default off | Explicitly on for dev/uat | B.4 |
| Prod sync | Auto | Manual | "Real prod approval gate" |
| Loki labels | Naive | Low-cardinality enforced | D.6 |
| Dashboards | UI-saved | ConfigMaps | D.5 |
| Secrets | values.yaml | ESO + Secrets Manager | D.1 |

Each deviation earns its keep — preempts a known failure, honors a locked
constraint, or buys demo reliability.

---

# Module 17 — Production Gaps (What We Deferred)

Honest answers when an examiner asks "is this prod-ready?" — no, and here's
why we deferred each.

## 17.1 What's missing for "real prod"

| Gap | What it means | Why we skipped |
|---|---|---|
| SLOs / error budgets | "Up" isn't an SLO. Real shop: 99.9% availability, p95 latency target. | Rubric-irrelevant; would take 1 day to define properly. |
| Runbooks per alert | Each alert should have a `runbook_url` annotation pointing to "what to do when this fires." | Time. |
| Backup / DR plan | RDS auto-backups exist; no documented restore procedure or cross-region replica. | Out of demo scope. |
| Network policies | All-or-nothing in-cluster networking. Real shop = NetworkPolicy or Cilium. | Time + complexity. |
| Pod Security Standards / Kyverno | No admission-time gating of pod specs. | Time. |
| Image scanning gate | ECR scans on push but doesn't block. Trivy in CI would. | Time. |
| Multi-region | Single region (us-east-1). Real DR = standby in us-west-2. | Cost + time. |
| NAT per AZ | We use single NAT (SPOF) in dev/uat. | Cost. |
| Cost guardrails | No AWS Budgets, no autoscaler max bound, no Karpenter consolidation. | Time. |
| Secret rotation | No rotation Lambdas wired up. | Time. |
| Load testing | We don't know real capacity. | Out of demo scope. |
| Grafana RBAC | Anyone in org can view all metrics. Real shop = team-based access. | Time. |
| Cosign signing | Image provenance. Free rubric bonus we deferred for time. | Time. |

## 17.2 How to answer "is this prod-ready?"

> "It's demo-ready and rubric-compliant. For real production I'd add ten
> things: SLO definitions and error budget tracking, runbooks on every alert,
> a documented DR plan with cross-region RDS replica, network policies for
> in-cluster segmentation, Pod Security Standards admission, blocking image
> scans in CI, multi-region failover, NAT-per-AZ, AWS Budgets with alerts,
> and Cosign signing on ECR pushes. Each is a clear next step; none are
> blocking the rubric."

This answer is strong because it shows you know what's missing and have a
prioritized list — not "it's perfect" or "I don't know."

---

# Module 18 — Demo Day Playbook

## 18.1 Pre-demo morning

1. Run `make plan-dev` — confirm no drift.
2. Push a no-op commit to app repo, watch full pipeline succeed.
3. Open in tabs: Argo CD UI, Grafana, Argo Rollouts dashboard, AWS Console.
4. Have a rollback commit prepared as an open PR.
5. Pre-fire one alert (`kubectl delete pod`) to confirm Gmail isn't in spam.
6. Run synthetic load if no real users: `hey -z 30m -c 5 https://uat.<domain>/api/breed`.

## 18.2 The 10-minute demo script

| Min | What | Show |
|---|---|---|
| 0-1 | Architecture diagram | SUMMARY.md ASCII diagram |
| 1-2 | Push code to app repo | GitHub UI — commit lands |
| 2-3 | CI builds + pushes to ECR | GitHub Actions UI |
| 3-4 | Promotion bumps values.yaml | GitHub UI showing the auto-commit |
| 4-5 | Argo CD syncs | Argo CD UI: Application goes Progressing → Healthy |
| 5-6 | Argo Rollouts canary | Argo Rollouts dashboard: 10% → 50% → 100% |
| 6-7 | Auto-abort scenario | Push deliberate regression; show analysis fail + auto-rollback |
| 7-8 | Schema migration | PreSync Job runs `alembic upgrade head` |
| 8-9 | Observability | Grafana dashboard: RPS, p99, error rate panels |
| 9-10 | Alert email | Trigger one alert; show Gmail arrival |

## 18.3 Live commands you'll need

```bash
# Cluster context
aws eks update-kubeconfig --region us-east-1 --name garden-uat --alias garden-uat

# Watch rollouts
kubectl argo rollouts get rollout breeding-service -n garden-uat -w

# Watch nodes during AMI patching demo
kubectl get nodes -w

# Generate synthetic load
hey -z 5m -c 10 https://uat.spacetimegarden.dev/api/breed

# Check who's running where
kubectl get pods -n garden-uat -o wide

# Logs for a specific pod
kubectl logs -n garden-uat -l app.kubernetes.io/name=genome-service --tail=50

# Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## 18.4 If something breaks live

| Symptom | Quick fix |
|---|---|
| Argo CD shows OutOfSync but stuck | Force sync: `argocd app sync <name>` |
| Pod ImagePullBackOff | Wrong tag or ECR perms — check `kubectl describe pod` |
| Cert showing browser warning | You're on staging issuer; switch to letsencrypt-prod for prod hostnames |
| Canary aborts unexpectedly | Generate synthetic load (`hey`) to populate Prom metrics |
| Grafana login loops | OAuth callback URL mismatch — check exact match including trailing slash |
| Metrics dashboard empty | ServiceMonitor missing `release: kube-prometheus-stack` label |

---

# Module 19 — Verifying It Works

How to take this from scaffold to running infrastructure without burning
money or time on dead ends. Test in layers: each layer gates the next, and
each layer is cheap enough to retry.

## 19.1 Layer 0 — Offline validation (free, ~30 min)

Catches ~80% of bugs before AWS sees a request. Run before any apply.

```bash
# Tools present
make preflight

# Terraform: format + syntax + provider/module resolution
for stack in _bootstrap live/_shared live/dev live/uat live/prod; do
  cd terraform/$stack
  terraform fmt -check -recursive .
  terraform init -backend=false
  terraform validate
  cd -
done

# Helm chart renders cleanly with each env's values × each service
helm lint gitops/charts/microservice
for env in dev uat prod; do
  for svc in genome-service breeding-service gallery-service frontend; do
    helm template $svc gitops/charts/microservice \
      -f gitops/envs/$env/values.yaml \
      --set serviceName=$svc --set envName=$env > /dev/null \
      || echo "FAILED: $env/$svc"
  done
done

# Argo CD manifests are valid YAML
kubectl apply --dry-run=client -f gitops/bootstrap/argocd-root-app.yaml
kubectl apply --dry-run=client -f gitops/apps/
```

**Gate:** all commands exit 0. If `helm template` fails, the merge helper has
a bug. If `terraform validate` fails, you have a syntax/type error or a
provider version mismatch.

## 19.2 Layer 1 — External-system setup (no AWS spend, ~1 hour)

Lead-time tasks. Do these before Layer 2 because they unblock later layers.

1. **Buy domain.** Route53 .dev is fastest (NS propagates in minutes).
2. **Verify AWS quotas:** need ≥3 EIPs (NAT GW), ≥1 VPC, EKS supported in
   region. `aws service-quotas list-service-quotas --service-code ec2`.
3. **Get Gmail app password** for SMTP at myaccount.google.com/apppasswords.
4. **Create fine-grained PAT** for `INFRA_REPO_TOKEN`. Repo-scoped,
   contents:write only.

Defer GitHub OAuth App creation until Layer 4 — you need the real domain.

## 19.3 Layer 2 — Cheap incremental apply (~$0.50/day idle)

The cheapest steps. Each gates the next.

### 2a. State backend
```bash
make bootstrap-state
# Creates spacetime-garden-tfstate-<random> S3 bucket + DDB lock table
```
Cost: ~$0.50/mo. **Don't destroy this.**

### 2b. _shared stack
Edit `terraform/live/_shared/{backend.tf,terraform.tfvars}`, then:
```bash
cd terraform/live/_shared && terraform init && terraform apply
terraform output -json route53_zone_name_servers
```

**Now delegate the domain at your registrar to those NS values.**

Verify NS delegation:
```bash
dig +short NS yourdomain.dev
# Should return AWS NS values within minutes
```

Cost: ~$0.50/mo (Route53 zone + 4 ECR repos with no images).

## 19.4 Layer 3 — Full dev cluster ($7-10/day, ~30 min)

This is where it gets expensive.

```bash
# Edit terraform/live/dev/{backend.tf,terraform.tfvars}
make plan-dev
make apply-dev
# 15-20 min. Coffee.

make kubeconfig

# Smoke test — every namespace's pods Running
kubectl get nodes                     # 2 nodes Ready
kubectl get pods -A | grep -v Running # should be empty
```

**Gates by namespace:**
| Namespace | What you should see |
|---|---|
| `kube-system` | coredns, kube-proxy, vpc-cni, ebs-csi-* (all Running) |
| `cert-manager` | 3 pods Running |
| `ingress-nginx` | 2 controller pods Running |
| `external-dns` | 1 pod Running |
| `external-secrets` | 3 pods Running |
| `argocd` | 5+ pods Running |
| `argo-rollouts` | 2 controller pods Running |
| `monitoring` | prometheus-*, grafana-*, alertmanager-*, loki-*, promtail-* (all Running) |

**Common Layer 3 failures and fixes:**

| Symptom | Cause | Fix |
|---|---|---|
| ESO pods CrashLoopBackOff with `WebIdentityErr` | IRSA timing race (trap C.3) | `kubectl rollout restart deploy -n external-secrets` |
| cert-manager pods CrashLoopBackOff with `AccessDenied` | Same family (trap A.7) | Same fix; or check the IRSA trust policy SA path |
| `helm_release.kube_prometheus_stack` timeout | Slow link or first-run | Re-run `terraform apply` — Helm releases are idempotent |
| `kubectl_manifest.letsencrypt_*` fails | cert-manager CRDs not installed yet | Re-run `terraform apply` |
| Apply partial, want to start over | NEVER `terraform destroy` mid-debug | Re-run `terraform apply` — TF reconciles from current state |

## 19.5 Layer 4 — Argo CD bootstrap + first deploy (~5 min)

```bash
# 1. Configure GitHub on app repo (per SUMMARY.md "Quickstart step 7")
#    Set 4 vars/secrets on fhshaik/spacetime-garden

# 2. Apply the Argo CD root app
make argocd-bootstrap

# 3. Open Argo CD UI
make argocd-login    # password printed; port-forward starts on :8080

# Visit https://localhost:8080
# Should see: garden-root + garden-platform-stack + 12 microservice Applications
# Initial state: most show "Missing" because ECR is empty

# 4. Trigger app-repo CI to populate ECR
#    Push a commit (or empty commit) on fhshaik/spacetime-garden:main
#    Watch GitHub Actions:
#      - ci.yaml builds + pushes 4 images to ECR (uses OIDC)
#      - promote-uat.yaml clones this repo, bumps gitops/envs/uat/values.yaml

# 5. Argo CD picks up the values.yaml change within 3 min
kubectl get rollout -A
kubectl argo rollouts get rollout genome-service -n garden-uat
```

**Gate:** all 12 Applications Synced + Healthy in Argo CD UI. Pods Running
in `garden-uat` namespace.

## 19.6 Layer 5 — End-to-end smoke (~10 min)

The "does the system actually work" gate.

### Network path
```bash
# Cert issued?
kubectl get cert -n garden-uat
# Should show Ready=True. If still Issuing, wait 2-3 min for DNS-01 propagation.

# DNS records created?
dig +short uat.spacetimegarden.dev
# Should return the NLB hostname's IPs

# HTTP path works?
curl -v https://uat.spacetimegarden.dev/healthz
curl -v https://uat.spacetimegarden.dev/api/genomes/healthz
# Both 200 OK
```

### Database
```bash
# Did migrations run?
kubectl get jobs -n garden-uat
kubectl logs job/genome-service-migrate-<sha7> -n garden-uat | grep alembic
```

### Observability
```bash
# Grafana
open https://grafana.spacetimegarden.dev
# Should redirect to GitHub OAuth, then to dashboards

# Trigger alert
kubectl delete pod -n garden-uat -l app.kubernetes.io/name=breeding-service
# Wait 5 min; Alertmanager should email you (check spam first time)
```

## 19.7 Layer 6 — The hero demo (canary auto-abort)

```bash
# In app repo, push a commit that 5xx's 30% of /breed calls
# CI builds, promote-uat bumps SHA, Argo CD syncs, Rollouts starts canary

# Watch live:
kubectl argo rollouts get rollout breeding-service -n garden-uat -w

# Expected: at step 1 (10%), AnalysisRun queries Prom for 5xx,
# threshold breached (failureLimit:1 hit), Rollout aborts,
# traffic stays on stable, email alert fires.
```

If AnalysisRun returns NaN (zero traffic), generate synthetic load:
```bash
hey -z 5m -c 10 https://uat.spacetimegarden.dev/api/breed
```

## 19.8 Layer 7 — Chaos verification (~15 min, optional)

Validates each demo scenario is reproducible.

```bash
# Pod kill survival
kubectl delete pod -n garden-uat -l app.kubernetes.io/name=genome-service
# Verify: ReplicaSet recreates pod within 5s; traffic continues via other replica

# Node drain (PDB validation)
NODE=$(kubectl get nodes -o name | head -1)
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
# Verify: pods migrate, no requests dropped (run hey in parallel)
kubectl uncordon $NODE

# Argo CD self-heal
kubectl delete deployment <something> -n garden-uat
# Wait ~30s; watch Argo CD recreate it
```

## 19.9 Tear down between sessions (save money)

```bash
make destroy-dev
# Destroys cluster + RDS but keeps ECR + Route53 + state
# Cost when destroyed: ~$0.50/day for state + zone + ECR
```

When you come back:
```bash
make apply-dev          # ~15 min
make argocd-bootstrap   # ~3 min
# Cluster back up
```

## 19.10 What you cannot test without spending

A few things only show up live, not in offline validation:
- **DNS-01 propagation timing.** Route53 + LE + registrar NS delegation only
  validates by issuing a real cert.
- **NLB cross-zone failover.** Needs a real LB in front of real pods.
- **Multi-AZ RDS failover.** Only meaningful in prod.
- **AnalysisRun with real Prom data.** Needs Prometheus scraping real services.

For first-pass demo prep: Layer 0 → 1 → 2 → 3 → 4 → 5 → 6. Skip Layer 7
until everything else is green.

## 19.11 Time + cost budget

| Layer | Time | Cost while running | Cost when destroyed |
|---|---|---|---|
| 0 (offline) | 30 min | $0 | $0 |
| 1 (external) | 1 hr | $0 (domain ~$12/yr) | same |
| 2 (state + shared) | 30 min | ~$0.50/day | ~$0.50/day |
| 3 (dev cluster up) | 30 min | ~$7/day | ~$0.50/day |
| 4 (argo bootstrap) | 15 min | same | same |
| 5 (smoke) | 30 min | same | same |
| 6 (hero demo) | 30 min | same | same |
| 7 (chaos) | 30 min | same | same |

Realistic first pass: 4-5 hrs of active work. Subsequent re-applies after
teardown: ~15 min.

## 19.12 The "is it working?" decision tree

```
Did `make plan-dev` succeed?
├── No  → fix terraform errors first; recheck variables.tf + tfvars
└── Yes → Did `make apply-dev` succeed?
         ├── No  → check IRSA timing (trap C.3); re-run apply
         └── Yes → Are all platform pods Running?
                  ├── No  → kubectl describe pod <crashing-one>; usually IRSA or storage
                  └── Yes → Does Argo CD show 12 Apps Synced?
                           ├── No  → ECR empty? push a commit on app repo to populate
                           └── Yes → Does HTTPS work end-to-end?
                                    ├── No  → cert-manager: DNS-01 stuck? NS not delegated?
                                    └── Yes → You're good. Run hero demo (Layer 6).
```

## 19.13 Defense questions

| Q | A |
|---|---|
| How would you verify a fresh apply works? | Layer-by-layer: offline validation, then state backend, then shared, then dev cluster, then Argo CD bootstrap, then end-to-end HTTPS smoke. Each layer is a gate. |
| What's the most likely thing to fail on first apply? | IRSA timing — ESO or cert-manager pod starts before its IAM role is fully propagated. We preempt with `depends_on`, but AWS IAM eventual-consistency can still bite. Fix: re-run `terraform apply` or `kubectl rollout restart`. |
| What can't you test without real AWS? | DNS-01 cert issuance, NLB cross-zone behavior, multi-AZ RDS failover, real Prometheus scraping. |

---

# FINAL EXAM

50 questions. Test yourself before defense. Write answers in your head, then
check against the modules.

## Foundations
1. Why are there two repos? Name three reasons.
2. What's the cross-repo handshake mechanism? Be specific about which file
   gets bumped.
3. What four GitHub repo settings does the app repo need? Which are vars,
   which are secrets?

## AWS networking
4. Difference between public and private subnets?
5. Why do private-subnet pods need a NAT Gateway?
6. Why 3 AZs minimum?
7. What does the `kubernetes.io/role/elb` subnet tag do?

## EKS
8. What's the difference between control plane and data plane?
9. Name 4 EKS-managed addons we use and what each does.
10. What's an OIDC provider on an EKS cluster, and why does it exist?

## IRSA
11. Walk me through the IRSA flow from pod startup to AWS API call.
12. What's the role of the trust policy?
13. Why does cert-manager need IRSA but our app pods don't?
14. What goes wrong if the IRSA role doesn't exist when ESO starts?

## Terraform
15. Why is `_bootstrap` a separate stack with local state?
16. What does `terraform_remote_state` do?
17. When do you need explicit `depends_on`?
18. Why community modules over custom?
19. What's the difference between Helm provider and Kubernetes provider?

## Kubernetes basics
20. Difference between Pod, ReplicaSet, Deployment?
21. How does a Service find its Pods?
22. Liveness vs readiness probe — when does each fire?
23. What's a CRD?

## Argo Rollouts
24. Canary vs blue-green: name two differences.
25. Why two Services (stable + canary)?
26. What does `or vector(0)` in the PromQL prevent?
27. How does a Rollout "auto-abort"?

## Argo CD
28. What's the difference between Application and ApplicationSet?
29. Why one App per service-env instead of one for everything?
30. What does `automated.selfHeal: true` do?
31. Why doesn't Argo CD fire Helm `pre-install` hooks?
32. What's the app-of-apps pattern?

## Helm
33. Why one chart for four services?
34. What does the `microservice.merged` helper do?
35. When does the chart emit a PDB?
36. Why does the env values file have per-service blocks at top level?

## Ingress / TLS / DNS
37. Why DNS-01 over HTTP-01?
38. What does external-dns do?
39. What's the difference between letsencrypt-staging and letsencrypt-prod?
40. Walk me through cert issuance from Ingress creation to live HTTPS.

## Secrets
41. Where does the database password live?
42. How does ESO know which AWS secret to read?
43. Why not put DATABASE_URL in values.yaml?

## Observability
44. How does Prom know what to scrape?
45. Where do logs go and how does Loki index them?
46. Why Grafana dashboards as ConfigMaps?
47. How does an alert reach your inbox?

## Day-2
48. How does AMI patching work without downtime?
49. What's the expand-migrate-contract pattern?
50. What's wrong with `kubectl delete node` for chaos demos?

---

# GLOSSARY

| Term | Definition |
|---|---|
| **ACM** | AWS Certificate Manager. AWS-native cert service. We don't use it. |
| **ACME** | Automatic Certificate Management Environment. Protocol Let's Encrypt uses. |
| **ALB** | Application Load Balancer. AWS L7 load balancer. We don't use it. |
| **AnalysisTemplate** | Argo Rollouts CRD defining a metric-based gating query. |
| **Application** | Argo CD CRD: "deploy this git path to this namespace." |
| **ApplicationSet** | Argo CD CRD: factory that generates Applications from generators. |
| **Argo CD** | GitOps reconciler — keeps cluster state matching git. |
| **Argo Rollouts** | Progressive delivery controller — canary/blue-green for K8s. |
| **AZ** | Availability Zone. Physically isolated datacenter within an AWS region. |
| **Canary** | Progressive delivery strategy: gradually shift traffic to new version. |
| **CRD** | Custom Resource Definition. K8s extension mechanism. |
| **CRI** | Container Runtime Interface. K8s pluggability for container runtimes. |
| **DaemonSet** | K8s workload type: one Pod per node. Used for Promtail. |
| **Deployment** | K8s workload type managing ReplicaSets with rolling updates. |
| **DNS-01** | ACME challenge type using DNS TXT records. |
| **EBS** | Elastic Block Store. AWS block storage. AZ-bound. |
| **ECR** | Elastic Container Registry. AWS Docker registry. |
| **EKS** | Elastic Kubernetes Service. Managed Kubernetes on AWS. |
| **ENI** | Elastic Network Interface. Virtual NIC on AWS. |
| **ESO** | External Secrets Operator. Syncs external secret stores into K8s Secrets. |
| **ExternalSecret** | ESO CRD describing what to sync from where. |
| **GitOps** | Operating model: git is source of truth, controllers reconcile. |
| **Helm** | K8s package manager / templating engine. |
| **HPA** | Horizontal Pod Autoscaler. Scales replicas based on metrics. |
| **HTTP-01** | ACME challenge type using HTTP path /well-known/acme-challenge. |
| **IGW** | Internet Gateway. VPC component allowing public-subnet routing. |
| **Ingress** | K8s HTTP routing CRD. |
| **ingress-nginx** | Open-source Ingress controller (nginx-based). |
| **IRSA** | IAM Roles for Service Accounts. Pod-level AWS auth via OIDC. |
| **JWT** | JSON Web Token. Used by OIDC for short-lived auth. |
| **kube-prometheus-stack** | Helm chart bundling Prometheus + Grafana + Alertmanager + operator. |
| **Kubelet** | Per-node K8s agent. Manages Pods on the node. |
| **LB** | Load Balancer. |
| **Loki** | Log aggregator (Grafana Labs). |
| **NAT GW** | NAT Gateway. Outbound-only internet for private subnets. |
| **NLB** | Network Load Balancer. AWS L4 LB. We use this. |
| **OIDC** | OpenID Connect. Federated auth protocol. |
| **PDB** | PodDisruptionBudget. Constraint preventing too many evictions. |
| **PromQL** | Prometheus Query Language. |
| **Promtail** | Log collector for Loki. |
| **PV / PVC** | PersistentVolume / Claim. Storage abstractions. |
| **RBAC** | Role-Based Access Control. K8s authorization. |
| **ReplicaSet** | K8s controller maintaining N pod replicas. |
| **Rollout** | Argo Rollouts CRD replacing Deployment. |
| **Route53** | AWS DNS service. |
| **SA** | ServiceAccount. K8s identity object for pods. |
| **ServiceMonitor** | Prometheus Operator CRD: "scrape these endpoints." |
| **SG** | Security Group. AWS stateful firewall. |
| **SLO** | Service Level Objective. Quantitative reliability target. |
| **STS** | Security Token Service. AWS short-lived credentials. |
| **VPC** | Virtual Private Cloud. AWS network isolation. |

---

# CHEAT SHEETS

## kubectl

```bash
# Context
kubectl config current-context
kubectl config use-context garden-uat

# General navigation
kubectl get pods -A                              # all namespaces
kubectl get pods -n garden-uat
kubectl get pods -n garden-uat -o wide           # show node + IP
kubectl describe pod <name> -n <ns>
kubectl logs <pod> -n <ns> --tail=50 -f
kubectl logs -l app.kubernetes.io/name=X -n <ns> --tail=20

# Argo Rollouts
kubectl argo rollouts list rollouts -A
kubectl argo rollouts get rollout <name> -n <ns> -w
kubectl argo rollouts dashboard                  # opens UI on :3100
kubectl argo rollouts abort <name> -n <ns>
kubectl argo rollouts promote <name> -n <ns>

# Argo CD (CLI)
argocd login localhost:8080 --insecure
argocd app list
argocd app sync <app-name>
argocd app rollback <app-name> <revision>

# Drain a node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node-name>

# Events for debugging
kubectl get events -n <ns> --sort-by='.lastTimestamp' --field-selector type=Warning

# Get Argo CD initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## terraform

```bash
terraform init                  # download providers, modules
terraform init -upgrade         # update providers/modules
terraform fmt -recursive .      # format all .tf files
terraform validate              # syntax + provider schema check
terraform plan -out=tfplan      # plan to file
terraform apply tfplan          # apply specific plan
terraform apply -auto-approve   # plan + apply, no prompt (CI)
terraform output                # show all outputs
terraform output -json X        # specific output as JSON
terraform state list            # what's tracked
terraform destroy               # tear down (use carefully!)
```

## helm

```bash
helm lint <chart-dir>
helm template <release> <chart-dir> -f values.yaml --set k=v
helm install <release> <chart-or-repo>
helm upgrade <release> <chart>
helm list -A
helm uninstall <release>
helm repo add <name> <url>
helm repo update
```

## AWS CLI quick

```bash
aws sts get-caller-identity                   # who am I
aws eks update-kubeconfig --region <r> --name <c> --alias <a>
aws ecr describe-repositories
aws ecr get-login-password | docker login --username AWS --password-stdin <registry>
aws secretsmanager list-secrets
aws secretsmanager get-secret-value --secret-id garden/dev/genome-service/db
```

---

# How to use this doc with GPT/Claude

Paste the entire doc into the assistant with a prompt like:

> "I'm preparing for a college DevOps capstone defense. The attached document
> is the entire course material for my project. Quiz me on it. Start with
> beginner questions, escalate to advanced. Tell me when I'm wrong and explain
> why. Don't move past a question I miss until I've understood the underlying
> concept."

Or for targeted study:

> "Focus only on Module 4 (IRSA). Quiz me until I can explain the entire flow
> from pod startup to AWS API call without referring to notes."

Or for deep-end practice:

> "Roleplay as a hostile examiner who's looking for weaknesses. Ask me
> questions that try to expose what I don't know. Don't be polite — push
> back when my answers are vague."

---

**End of course.** Total: 18 modules, 50-question final, glossary, cheat
sheets. ~12,000 words. Self-contained — should not require referring back to
the original repo files for defense prep.
