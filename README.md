# ShopFast — GitOps Application Delivery Platform

A complete, from-scratch delivery platform on AWS: Terraform-provisioned EKS,
a Spring Boot service shipped as immutable images to ECR, and Argo CD driving
Blue/Green and Canary rollouts with Argo Rollouts. Metrics and dashboards are
managed as code through the same GitOps flow.

```
GitHub → GitHub Actions → Test + Security Scan → Docker Build → ECR
                                                                 ↓
                              EKS ← Argo CD ← GitOps update (image tag commit)
                               ↓
                        Argo Rollouts (Blue/Green | Canary)
```

---

## 1. Architecture

| Layer | Choice | Why |
|---|---|---|
| Compute | EKS 1.31, managed node group, private subnets | Nodes never hold public IPs |
| Registry | ECR with `IMMUTABLE` tags | A Git SHA tag can never be overwritten |
| Ingress | One shared ALB (AWS Load Balancer Controller) | HTTPS from anywhere; one LB, not three |
| TLS | ACM, DNS-validated | Auto-renewing certificates |
| Delivery | Argo CD (App-of-Apps) | Git is the only source of cluster truth |
| Progressive delivery | Argo Rollouts | Blue/Green + Canary from one chart |
| Metrics | VictoriaMetrics (Prometheus API) + Grafana | Lower footprint, same PromQL |
| CI | GitHub Actions, static AWS keys in encrypted secrets | **No OIDC**, per requirement |

**The single-writer rule:** CI never runs `kubectl apply`. It builds, scans,
pushes, and commits a new image tag. Argo CD is the only actor that changes the
cluster — so there is no drift war between two writers.

---

## 2. Monorepo structure

```
.
├── application/                    Spring Boot service + its Helm chart
│   ├── src/                        ShopFast source and tests
│   ├── pom.xml
│   ├── owasp-suppressions.xml      CPE-mismatch suppressions (policy documented inside)
│   ├── Dockerfile                  Multi-stage, non-root, healthcheck
│   └── helm/shopfast/              ONE chart, three strategies
│       └── templates/
│           ├── _validate.tpl       Fail-fast guards (strategy, immutable tag)
│           ├── deployment.yaml     Renders ONLY when strategy=standard
│           ├── rollout.yaml        Renders ONLY for bluegreen|canary
│           ├── service.yaml        active + preview services
│           ├── ingress.yaml        ALB, HTTPS
│           ├── analysistemplate.yaml
│           └── servicescrape.yaml
├── infra/                          Terraform (remote S3 state)
│   ├── network.tf  eks.tf  ecr.tf  dns.tf  iam_alb.tf  outputs.tf  variables.tf  versions.tf
├── gitops/
│   ├── bootstrap/                  bootstrap.sh, verify.sh, argocd-values.yaml
│   ├── apps/
│   │   ├── root-app.yaml           App-of-Apps root
│   │   └── children/               argo-rollouts, monitoring, dashboards, shopfast
│   ├── applications/shopfast/      values.yaml ← CI rewrites the image tag here
│   └── monitoring/dashboards/      Grafana dashboards as ConfigMaps
├── scripts/
│   ├── verify-chart-exclusivity.sh Proves Blue/Green & Canary never render a Deployment
│   ├── verify-gitops-manifests.sh  Proves no placeholder survives into git
│   ├── verify-cert-sans.sh         Proves the ACM cert covers every hostname
│   ├── prune-retired-certs.sh      Retires superseded (detached) ACM certs
│   ├── dependency-scan.sh          OWASP scan + findings summary
│   ├── scan-image.sh               Trivy container image scan
│   └── set-image.py                The GitOps image-tag bump
├── docs/
│   ├── DNS-CPANEL.md               ← domain setup (read this)
│   ├── DEPENDENCY-SCANNING.md      why the OWASP scan runs out-of-band
│   └── ROLLOUTS.md                 promotion / rollback runbook
└── .udap/pipeline.yaml             CI spec (workflows are rendered from it)
```

---

## 3. AWS resources

| Resource | Detail |
|---|---|
| VPC | `10.42.0.0/16`, 2 AZs, public + private subnets, EKS discovery tags |
| NAT Gateway | 1 (cost trade-off; egress not HA across AZs) |
| EKS | v1.31, API access-entry auth, control-plane logging |
| Node group | 3 × `t3.large`, private subnets, min 2 / max 5 |
| Addons | vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver (IRSA) |
| ECR | `<project>-shopfast`, immutable tags, scan-on-push, keep last 30 |
| IAM | Cluster role, node role, EBS CSI (IRSA), ALB controller (IRSA) |
| Route 53 | Public hosted zone for `royalbengal.xyz` |
| ACM | Cert for `argocd.shopfast.…` + `shopfast.…` + `grafana.shopfast.…` |
| S3 | Remote Terraform state (platform-managed bucket) |

---

## 4. Kubernetes namespaces

| Namespace | Contents |
|---|---|
| `argocd` | Argo CD server, repo-server, controller, Applications |
| `argo-rollouts` | Rollouts controller + dashboard |
| `shopfast` | ShopFast Rollout/Deployment, services, ingress |
| `monitoring` | VictoriaMetrics, vmagent, Grafana, kube-state-metrics |
| `kube-system` | AWS Load Balancer Controller, core addons |

---

## 5. GitHub Actions design

The deploy workflow is rendered from `.udap/pipeline.yaml`:

| Stage | Does |
|---|---|
| `lint` | `mvn compile` |
| `test` | `mvn test` — asserts `/api/hello`, `/actuator/health`, `/actuator/prometheus` |
| `security` | `helm lint` on **all three strategies** + chart-exclusivity test + GitOps manifest resolution + ACM SAN coverage |
| `provision` | `terraform init/validate/apply`; prints Route 53 nameservers |
| `build_push` | Build jar → Docker → **ECR with `${GITHUB_SHA::7}`** → Trivy scan → commit new tag into `gitops/` |
| `configure` | ALB controller → Argo CD (HTTPS ingress) → App-of-Apps handover |
| `verify` | Real AWS/EKS/Argo state checks (see §8) + retire superseded ACM certs |

A second workflow, **`security-deps`**, runs OWASP dependency-check on demand —
see §9 and [`docs/DEPENDENCY-SCANNING.md`](docs/DEPENDENCY-SCANNING.md).

Every stage that runs `terraform` re-runs `init` with identical backend flags and
reads outputs itself — no infrastructure values are threaded between jobs
(GitHub silently drops job outputs containing secret substrings).

---

## 6. Required GitHub Secrets

Set automatically by the platform:

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS auth (**no OIDC**, per requirement) |
| `AWS_SECRET_ACCESS_KEY` | AWS auth |
| `PROJECT_NAME` | Resource name prefix |
| `TF_STATE_BUCKET` | Remote Terraform state bucket |

Set for this project:

| Secret | Purpose |
|---|---|
| `ARGOCD_ADMIN_PASSWORD` | Argo CD `admin` password — bcrypt-hashed at install time, **never committed** |
| `NVD_API_KEY` | *(optional)* authenticated NVD feed for the `security-deps` workflow |

No credential is ever written to a file, a manifest, or a log.

---

## 7. Bootstrap sequence

1. **Push the repo** and set the secrets above.
2. **Run the deploy workflow.** `provision` creates VPC → EKS → ECR → Route 53 → ACM.
3. **Point the domain at Route 53** — see [`docs/DNS-CPANEL.md`](docs/DNS-CPANEL.md). ← *required for public HTTPS*
4. `build_push` publishes the first image and commits its SHA to `gitops/`.
5. `configure` installs the ALB controller and Argo CD, then applies the root App-of-Apps.
6. Argo CD creates Argo Rollouts → monitoring → dashboards → ShopFast (sync waves 0 → 10 → 15 → 20).
7. `verify` proves the result against live AWS/EKS/Argo state.

---

## 8. Deployment flow

```
commit → lint → test → security checks → terraform apply
       → docker build → ECR (tag = git SHA, immutable) → Trivy scan
       → CI commits that tag into gitops/applications/shopfast/values.yaml
       → Argo CD detects drift and syncs
       → Argo Rollouts executes blue/green or canary
       → verify checks the real cluster
```

Switch strategy by editing one line in `gitops/applications/shopfast/values.yaml`:

```yaml
strategy: bluegreen   # standard | bluegreen | canary
```

See [`docs/ROLLOUTS.md`](docs/ROLLOUTS.md) for promotion and rollback.

---

## 9. Security model

- **No OIDC** (explicit requirement). AWS access via encrypted GitHub Secrets only.
- **No secrets in git.** The Argo CD password is hashed in-memory at install;
  Grafana's is set out-of-band. Manifests carry placeholders, never values.
- **IRSA** for in-cluster AWS access (ALB controller, EBS CSI) — no node-wide creds.
- **Private nodes.** Workloads have no public IPs; egress via NAT.
- **Least-privilege pods**: non-root (UID 10001), `readOnlyRootFilesystem`,
  all capabilities dropped, `RuntimeDefault` seccomp, no auto-mounted SA token.
- **Immutable images** at the registry level; `latest` is refused by the chart.
- **Supply chain**: OWASP dependency-check (out-of-band, §9.2) + Trivy image scan
  in `build_push` + ECR scan-on-push.
- **Argo CD RBAC** defaults to `role:readonly`; TLS terminated at the ALB with ACM.

### 9.1 ⚠️ Accepted risk — dependency scanning runs in REPORTING mode

**Decision: project owner, 2026-09-06.**

`security.failBuildOnCVSS` in `application/pom.xml` is set to **11** — above the
maximum CVSS score — so dependency findings **do not fail the build**. The scan
still uploads its full HTML + JSON report as an artifact; the job log prints a
HIGH/CRITICAL summary and a warning annotation.

**Why:** Spring Boot 3.5.16 (the newest release of its line) ships transitive
dependencies with unpatched criticals in the HTTP stack:

| Artifact | Findings (CVSS ≥ 9) |
|---|---|
| `spring-core` / `spring-web` 6.2.19 | CVE-2026-59313 (9.8), CVE-2026-47892 (9.8), CVE-2026-47891 (9.8), CVE-2026-47890 (9.8), CVE-2026-59283 (9.1) |
| `tomcat-embed-core` 10.1.55 | CVE-2026-65905 (9.8), CVE-2026-65637 (9.8), + 6 more ≥ 9.0 |

These are **not** false positives — each artifact matches its own correct CPE.
No upstream version resolves them today, so the choice was between never
deploying and accepting the risk with the findings kept visible. Reporting mode
was chosen over suppression precisely because it keeps them auditable.

**Compensating controls remain active:** Trivy image scanning, ECR scan-on-push,
non-root/read-only pods with all capabilities dropped, and a minimal exposed
surface (`/api/hello` plus three actuator endpoints).

**Revisit when** upstream ships patched `spring-framework` / `tomcat` versions —
then set the threshold back to `9` and upgrade. **Re-evaluate before this service
handles real user data.**

Genuine *false positives* are handled separately and narrowly in
[`application/owasp-suppressions.xml`](application/owasp-suppressions.xml), which
documents the four conditions a suppression must satisfy.

### 9.2 Dependency scanning runs out-of-band

**Decision: project owner, 2026-09-07.**

The OWASP scan runs in its own **`security-deps`** workflow rather than in the
deploy pipeline. dependency-check must download the entire ~387,000-record NVD
corpus before it can inspect a single JAR, which made every deployment gated on
`nvd.nist.gov` throughput — measured between ~2,600 and ~97,000 records/minute on
consecutive days, with one run aborted by NVD itself.

**Nothing was disabled or weakened**: same script, same threshold, same report.
The change is that a third-party feed outage now delays a *report* instead of
blocking a *deployment*. Full rationale, measurements and operating instructions:
[`docs/DEPENDENCY-SCANNING.md`](docs/DEPENDENCY-SCANNING.md).

Run it with `gh workflow run security-deps.yml`, or from **Actions → security-deps
→ Run workflow**. Run it after any dependency change.

---

## 10. Important decisions

| Decision | Rationale |
|---|---|
| One chart, template-guarded strategies | `deployment.yaml` renders only for `standard`; a Deployment and Rollout can never coexist and fight over ReplicaSets. Proven by `scripts/verify-chart-exclusivity.sh` in CI and re-checked in `verify.sh`. |
| Argo CD is the sole cluster writer | Eliminates CI-vs-GitOps drift. |
| Shared ALB via `group.name` | One load balancer for Argo CD + ShopFast + Grafana (~$36/mo saved). |
| EKS access entries, not `aws-auth` | Declarative, survives cluster recreation. |
| VictoriaMetrics over kube-prometheus-stack | Same PromQL/Prometheus API, materially lower memory. |
| Non-blocking ACM validation | Pending DNS delegation cannot hang `terraform apply`. |
| Manual promotion by default | A first deploy has no metric history to analyse; opt into automation later. |
| Single NAT gateway | Deliberate cost trade-off; noted as a known limitation. |
| Dependency scan in reporting mode | See §9.1 — accepted risk, documented and revisitable. |
| Dependency scan out of the deploy path | See §9.2 — an unstable third-party feed must not gate delivery. |

**Estimated cost:** ~US$310–340/month (EKS $73 · 3×t3.large ~$190 · NAT ~$33 · ALB ~$18).

---

## Operations quick reference

```bash
# Cluster access
aws eks update-kubeconfig --region us-east-1 --name <project>-eks

# Argo CD dashboard
open https://argocd.shopfast.royalbengal.xyz     # user: admin

# Grafana dashboard
open https://grafana.shopfast.royalbengal.xyz    # user: admin

# Rollout state
kubectl -n shopfast get rollout shopfast -o wide

# Dependency vulnerability scan (out-of-band — see §9.2)
gh workflow run security-deps.yml

# Prove the strategy invariant locally
bash scripts/verify-chart-exclusivity.sh
```

> Grafana is published on the shared ALB with its own ACM SAN and hardened
> `grafana.ini` (anonymous access off, sign-up off, brute-force protection,
> secure cookies, HSTS, CSP). Its admin password is set out-of-band and is
> never committed.

## Known limitations

- **Dependency scanning is in reporting mode** — see §9.1. Known criticals exist
  in the Spring/Tomcat HTTP stack with no upstream fix available.
- **The dependency scan is manual** — see §9.2. The pipeline renderer emits
  `workflow_dispatch` only, so `security-deps` must be triggered (or scheduled by
  adding a `schedule:` trigger in GitHub). Run it after any dependency change.
- `royalbengal.xyz` stays on cPanel — public HTTPS depends on the CNAME records
  in `docs/DNS-CPANEL.md`, and those must be updated by hand if the ALB is
  recreated.
- Single NAT gateway — egress is not HA across AZs.
- Rollout analysis is scaffolded but disabled by default (manual promotion).
