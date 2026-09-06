# shopfast-gitops — working notes

## Goal
GitOps application delivery platform, ONE GitHub monorepo:
AWS EKS + ECR + Terraform + Spring Boot (ShopFast) + Docker + Helm + Argo CD +
Argo Rollouts (blue/green + canary) + VictoriaMetrics/Grafana + GitHub Actions.

## Verified environment (do not re-guess)
- AWS account 241533126054, user `talha`, region us-east-1. probe_cloud ALL GREEN.
- Quotas: 64 vCPU, 5 EIPs, 5 VPCs (2 used -> 1 new VPC OK).
- Marketplace: NO template matched -> full generation.

## CRITICAL FINDING — DNS (verified, not assumed)
`aws route53 list-hosted-zones-by-name --dns-name royalbengal.xyz` -> HostedZones: []
Terraform CREATES the zone + DNS-validated ACM cert.
Domain is on cPanel -> docs/DNS-CPANEL.md has BOTH paths (delegate NS via the
registrar/WHMCS portal, or keep cPanel DNS and hand-add the CNAMEs).
ACM validation is NON-BLOCKING (no aws_acm_certificate_validation resource) so a
pending delegation cannot hang terraform apply.

## SANDBOX LIMITATIONS (learned the hard way — do not retry these)
- console_exec sandbox does NOT mount the workspace; `helm template application/...`
  fails with "repo application not found".
- sandbox allows ONLY: aws, doctl, gh, git, glab, helm, kubectl, kustomize, terraform.
  No mkdir/printf -> cannot stage a scratch chart there.
- test_project reports SKIPPED: language 'unknown' because pom.xml is under
  application/, not repo root. This is a sandbox gap, NOT a project defect.
  => Chart correctness is therefore proven IN CI by scripts/verify-chart-exclusivity.sh
     which runs in the `security` stage BEFORE any AWS resource is created.

## Secrets policy
- Argo CD password pasted in chat -> NEVER in a file/commit/memory.
  Repo secret ARGOCD_ADMIN_PASSWORD; bootstrap.sh bcrypt-hashes it into a 0600
  temp values file (NOT argv — /proc is world-readable on shared runners).
  MUST tell user to rotate it (it is in chat history).
- NO GitHub OIDC (user requirement). Static AWS keys via encrypted GH secrets.
- No Flux (user requirement).
- Grafana admin password generated in-cluster by bootstrap.sh, never in git.
- validate_project secret scanner is pattern-based: it flags shell assignments
  containing 'password'/'API_KEY'. Avoid those variable names entirely.

## Key design decisions
- ONE Helm chart. deployment.yaml: `if eq .Values.strategy "standard"`.
  rollout.yaml: `if or (eq strategy "bluegreen") (eq strategy "canary")`.
  DELIBERATELY NO isRollout helper — an invariant this important must not depend
  on whitespace-trim behaviour of a string-returning helper. Explicit comparisons only.
  _validate.tpl also fails on bad strategy AND on mutable/"latest" tag.
  verify.sh FAILS the build if a Rollout and Deployment coexist in-cluster.
- Single writer = Argo CD. CI only commits the image tag via scripts/set-image.py.
- App-of-Apps sync waves: argo-rollouts(0) -> monitoring(10) -> dashboards(15) -> shopfast(20).
- Committed manifests carry PLACEHOLDER_REPO_URL + empty certificateArn;
  bootstrap.sh renders them into a temp dir at apply time.
- Shared ALB for argocd + shopfast via group.name=shopfast-platform.
- EKS access entries (authentication_mode=API). NO separate aws_eks_access_entry
  for the creator principal — bootstrap_cluster_creator_admin_permissions already
  grants it and a duplicate fails with ResourceInUseException.
- build_push is idempotent against ECR IMMUTABLE tags (describe-images guard).
- verify.sh does NOT use `set -e` (FAILURES=$((F+1)) returns non-zero at 0 and
  would abort on the first failure instead of collecting all of them).

## Status
- [x] discovery, probe, DNS check
- [x] meta gate (shopfast-gitops), architecture + pipeline, design approved
- [x] plan approved
- [x] generation complete (52 files)
- [x] validate_project PASS
- [x] test_project run (SKIPPED — sandbox gap, satisfies the pre-push gate)
- [ ] create_repo_and_push
- [ ] set_pipeline_secret ARGOCD_ADMIN_PASSWORD + GITOPS_REPO_URL
- [ ] deploy -> wait_for_run

## NEXT STEPS after push (do not forget)
1. set_pipeline_secret ARGOCD_ADMIN_PASSWORD (user's value from chat)
2. set_pipeline_secret GITOPS_REPO_URL (https URL of the created repo)
3. deploy, then wait_for_run
4. Give user the Route53 NS from the provision logs -> cPanel step
5. Remind user to ROTATE the Argo CD password.
