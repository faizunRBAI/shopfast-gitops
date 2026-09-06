#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ACM SAN coverage guard — runs in the `security` stage, before any AWS spend.
#
# WHY THIS EXISTS
#   infra/dns.tf now carries `ignore_changes = [subject_alternative_names]` on
#   aws_acm_certificate.platform. That flag is what broke the destroy-deadlock
#   (terraform no longer replaces the certificate mid-apply, so it never waits
#   18 minutes on a delete ACM refuses while the ALB still holds the cert).
#
#   But it buys that at a price, and this guard is the price tag:
#
#     ignore_changes means EDITING THE SAN LIST HAS NO EFFECT on an existing
#     certificate. Add a fourth hostname, run the pipeline, watch it go green —
#     and the certificate never changes. The new hostname then serves a cert
#     that does not name it, and every browser shows a name-mismatch error.
#     Terraform reports no drift, because it was told not to look.
#
#   That is a silent failure, which is the worst kind. This script makes it
#   loud: it compares the hostnames the pipeline DECLARES against the SANs the
#   live certificate actually carries, and fails the build when they diverge.
#
# WHAT TO DO WHEN IT FAILS
#   The certificate must be recreated rather than updated in place:
#       cd infra
#       terraform state rm aws_acm_certificate.platform
#       terraform apply            # creates a fresh cert with the full SAN list
#   The retired certificate is deleted automatically by the verify stage
#   (scripts/prune-retired-certs.sh) once the ALB listeners have moved off it.
#
# NON-BLOCKING BY DESIGN IN ONE CASE: if no certificate exists yet (first
# deploy, or state was just cleared) there is nothing to compare and the check
# passes. It only fires on a REAL divergence.
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT="${PROJECT:-${1:-}}"

# Hostnames this pipeline intends the certificate to cover. Sourced from the
# same env the provision stage passes to terraform, so the two cannot drift.
EXPECTED="$(printf '%s\n' \
  "${TF_VAR_argocd_hostname:-}" \
  "${TF_VAR_app_hostname:-}" \
  "${TF_VAR_grafana_hostname:-}" \
  | grep -v '^$' | sort -u)"

echo "=== ACM SAN coverage verification ==="

if [ -z "${EXPECTED}" ]; then
  echo "[ ok ] no hostnames declared in the environment — nothing to verify"
  exit 0
fi

echo "Declared hostnames:"
printf '  %s\n' ${EXPECTED}

if ! command -v aws >/dev/null 2>&1; then
  echo "[ ok ] aws CLI unavailable — skipping live comparison"
  exit 0
fi

# Find this project's ISSUED/PENDING certificate that covers the argocd name.
# We deliberately do NOT read terraform state here: this guard runs in the
# security stage, before provision, and must not require backend credentials.
CERT_ARN=""
for arn in $(aws acm list-certificates \
               --query 'CertificateSummaryList[].CertificateArn' \
               --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "${arn}" ] || continue
  owner="$(aws acm list-tags-for-certificate --certificate-arn "${arn}" \
             --query "Tags[?Key=='Project'].Value | [0]" \
             --output text 2>/dev/null || echo None)"
  [ "${owner}" = "${PROJECT}" ] || continue

  # Prefer a certificate that is actually attached to something; that is the
  # one serving traffic and therefore the one that matters.
  in_use="$(aws acm describe-certificate --certificate-arn "${arn}" \
              --query 'length(Certificate.InUseBy)' --output text 2>/dev/null || echo 0)"
  if [ "${in_use}" != "0" ]; then
    CERT_ARN="${arn}"
    break
  fi
  [ -n "${CERT_ARN}" ] || CERT_ARN="${arn}"
done

if [ -z "${CERT_ARN}" ]; then
  echo "[ ok ] no project certificate exists yet — first deploy, nothing to compare"
  exit 0
fi

echo "Live certificate: ${CERT_ARN}"

ACTUAL="$(aws acm describe-certificate --certificate-arn "${CERT_ARN}" \
            --query 'Certificate.SubjectAlternativeNames' \
            --output text 2>/dev/null | tr '\t' '\n' | sort -u)"

echo "Certificate covers:"
printf '  %s\n' ${ACTUAL}

MISSING=""
for host in ${EXPECTED}; do
  if ! printf '%s\n' ${ACTUAL} | grep -qxF "${host}"; then
    MISSING="${MISSING} ${host}"
  fi
done

echo
if [ -n "${MISSING}" ]; then
  printf '\033[1;31m[FAIL]\033[0m certificate does not cover:%s\n' "${MISSING}"
  echo
  echo "  infra/dns.tf sets ignore_changes = [subject_alternative_names], so"
  echo "  editing the SAN list does NOT update an existing certificate — the"
  echo "  build would go green while these hostnames served a mismatched cert."
  echo
  echo "  To add them, let the certificate be recreated:"
  echo "      cd infra"
  echo "      terraform state rm aws_acm_certificate.platform"
  echo "      terraform apply"
  echo
  echo "  The old certificate is pruned automatically by the verify stage once"
  echo "  the ALB listeners have moved off it."
  exit 1
fi

printf '\033[1;32m[ ok ] certificate covers every declared hostname.\033[0m\n'
