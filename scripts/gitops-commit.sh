#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps desired-state commit.
#
# This is THE deployment trigger. CI never touches the cluster: it rewrites the
# deployed values files and pushes that commit. Argo CD observes the change and
# reconciles. If this push does not land, the new image exists in ECR but
# nothing deploys it.
#
# WHAT THIS WRITES
#   gitops/applications/shopfast/values.yaml
#     image.repository / image.tag  — the immutable Git SHA image reference
#     ingress.certificateArn        — the ACM cert ARN, when CERT_ARN is provided
#
#   gitops/monitoring/values.yaml
#     grafana ingress certificate-arn annotation — same ACM cert ARN
#
#   TARGET MOVED 2026-09-07: the Grafana ARN used to live inside
#   gitops/apps/children/monitoring.yaml, in that Application's inline Helm
#   values. The monitoring Application is now multi-source and its values are a
#   plain file, so this script rewrites a values file rather than an Argo CD
#   Application definition. That decoupling is deliberate — see the docstring
#   in scripts/set-grafana-cert.py for the deadlock it removes.
#
#   The certificate ARN belongs HERE, in git, and not as a Helm parameter
#   patched onto the Applications at bootstrap time. The root App-of-Apps
#   reconciles those Applications from git; an apply-time patch is a second
#   writer for the same field, so root reverts it, bootstrap re-adds it, and
#   the Application stays OutOfSync forever with its workload never created.
#   One writer, one source of truth.
#
#   ONE CERTIFICATE, THREE HOSTNAMES: argocd / shopfast / grafana share a single
#   ACM certificate. Adding a SAN replaces it and mints a NEW ARN, so both files
#   below must be re-pointed together in the SAME commit — otherwise one
#   hostname keeps a dangling reference to a certificate that is being retired.
#   scripts/verify-gitops-manifests.sh check 5 proves they agree.
#
# THE COMMIT MESSAGE IS LOAD-BEARING
#   The "ci: deploy shopfast <tag>" form below is parsed by
#   scripts/rollback-resolve.sh to reconstruct the deploy history and find the
#   previous tag. Changing this format breaks rollback target resolution.
#
# AUTHENTICATION
#   Handled by scripts/gitops-push.sh, which this script sources. See that file
#   for the GIT_ASKPASS reasoning — do NOT reimplement it here.
#
# Required env: REGISTRY, TAG, REPO_NAME, GITHUB_REPOSITORY, BRANCH
# Optional env: CERT_ARN, GITOPS_PUSH_TOKEN
# ---------------------------------------------------------------------------
set -euo pipefail

: "${REGISTRY:?REGISTRY must be set}"
: "${TAG:?TAG must be set}"
: "${REPO_NAME:?REPO_NAME must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${BRANCH:?BRANCH must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gitops-push.sh
. "${SCRIPT_DIR}/gitops-push.sh"

VALUES="gitops/applications/shopfast/values.yaml"
# The monitoring stack's Helm values (multi-source $values file), NOT the
# Application manifest.
MONITORING_VALUES="gitops/monitoring/values.yaml"

SET_IMAGE_ARGS=(
  --values "${VALUES}"
  --repository "${REGISTRY}/${REPO_NAME}-shopfast"
  --tag "${TAG}"
)

# The ARN is only written once ACM has actually issued the certificate. Writing
# an ARN for a PENDING_VALIDATION certificate is harmless (the controller simply
# cannot attach it yet), so it is included whenever terraform reports one.
if [ -n "${CERT_ARN:-}" ]; then
  SET_IMAGE_ARGS+=(--certificate-arn "${CERT_ARN}")
  echo "Certificate ARN resolved from terraform state — writing it into ${VALUES}."
else
  echo "::warning title=No certificate ARN::CERT_ARN was empty; leaving" \
       "ingress.certificateArn unchanged. The ShopFast ingress will have no" \
       "HTTPS listener until an ARN is committed."
fi

python3 scripts/set-image.py "${SET_IMAGE_ARGS[@]}"

# Grafana's ingress annotation is nested under grafana.ingress.annotations, so
# it needs its own precise rewriter (see scripts/set-grafana-cert.py).
if [ -n "${CERT_ARN:-}" ]; then
  python3 scripts/set-grafana-cert.py \
    --manifest "${MONITORING_VALUES}" \
    --certificate-arn "${CERT_ARN}"
fi

git add "${VALUES}" "${MONITORING_VALUES}"

# NOTE: the message format is parsed by scripts/rollback-resolve.sh.
if gitops_push "ci: deploy shopfast ${TAG}"; then
  echo "GitOps update pushed. Argo CD will reconcile shopfast to ${TAG}."
else
  echo "::error title=GitOps push failed::The image is in ECR but nothing will" \
       "deploy it until this commit lands."
  exit 1
fi
