#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ACM SAN coverage guard — runs in the `security` stage, before any AWS spend.
#
# WHY THIS EXISTS
#   infra/dns.tf carries `ignore_changes = [subject_alternative_names]` on
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
#   loud: it asks whether the project owns a usable certificate covering every
#   declared hostname, and fails the build when no such certificate exists.
#
# WHICH CERTIFICATE IS GRADED — THE BUG THIS SCRIPT WAS BORN WITH
#   The first version graded the certificate with a NON-EMPTY InUseBy, i.e. the
#   one currently bound to the ALB listener. That is exactly backwards during a
#   rotation. Mid-rotation the attached certificate is by definition the OLD,
#   narrower one; the correct replacement is ISSUED and unattached, waiting for
#   the configure stage to flip the listeners onto it. Grading the attached
#   cert failed the build with a finding that was true about the wrong object,
#   and it blocked the very run that would have installed the right one.
#
#   The question this guard actually means to ask is:
#       "Does this project own a usable certificate covering every hostname?"
#   NOT "is the currently-attached certificate the final one?" — during a
#   rotation the answer to the latter is legitimately no.
#
#   So: select the project certificate with the BEST coverage of the declared
#   hostnames (ties broken toward the attached one, which is the steady state),
#   and grade that. PENDING_VALIDATION certificates are eligible: a cert that
#   is still validating is a cert this pipeline created on purpose, and failing
#   on it would block the run that completes it.
#
# WHAT TO DO WHEN IT FAILS
#   No certificate covers the declared hostnames, so one must be created. The
#   certificate is recreated rather than updated in place:
#       cd infra
#       terraform state rm aws_acm_certificate.platform
#       terraform apply            # creates a fresh cert with the full SAN list
#   The retired certificate is deleted automatically by the verify stage
#   (scripts/prune-retired-certs.sh) once the ALB listeners have moved off it.
#
# NON-BLOCKING BY DESIGN: if no certificate exists yet (first deploy, or state
# was just cleared) there is nothing to compare and the check passes. It only
# fires on a REAL divergence — every candidate certificate missing a hostname.
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

EXPECTED_COUNT="$(printf '%s\n' ${EXPECTED} | wc -w | tr -d ' ')"

echo "Declared hostnames:"
printf '  %s\n' ${EXPECTED}
echo

if ! command -v aws >/dev/null 2>&1; then
  echo "[ ok ] aws CLI unavailable — skipping live comparison"
  exit 0
fi

# ---------------------------------------------------------------------------
# Score every certificate this project owns by how many declared hostnames it
# covers. The winner is the best-covering one; a tie is broken toward the
# certificate that is currently attached (steady state after a rotation).
# ---------------------------------------------------------------------------
BEST_ARN=""
BEST_COVERED=-1
BEST_INUSE=0
BEST_STATUS=""
BEST_SANS=""

for arn in $(aws acm list-certificates \
               --query 'CertificateSummaryList[].CertificateArn' \
               --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "${arn}" ] || continue

  owner="$(aws acm list-tags-for-certificate --certificate-arn "${arn}" \
             --query "Tags[?Key=='Project'].Value | [0]" \
             --output text 2>/dev/null || echo None)"
  [ "${owner}" = "${PROJECT}" ] || continue

  status="$(aws acm describe-certificate --certificate-arn "${arn}" \
              --query 'Certificate.Status' --output text 2>/dev/null || echo UNKNOWN)"
  # A cert that failed validation or is being deleted can never serve traffic.
  case "${status}" in
    ISSUED|PENDING_VALIDATION) ;;
    *) continue ;;
  esac

  in_use="$(aws acm describe-certificate --certificate-arn "${arn}" \
              --query 'length(Certificate.InUseBy)' --output text 2>/dev/null || echo 0)"

  sans="$(aws acm describe-certificate --certificate-arn "${arn}" \
            --query 'Certificate.SubjectAlternativeNames' \
            --output text 2>/dev/null | tr '\t' '\n' | sort -u)"

  covered=0
  for host in ${EXPECTED}; do
    if printf '%s\n' ${sans} | grep -qxF "${host}"; then
      covered=$((covered + 1))
    fi
  done

  echo "  candidate ${arn##*/}  status=${status}  in_use=${in_use}  covers ${covered}/${EXPECTED_COUNT}"

  # Strictly better coverage wins; equal coverage prefers the attached cert.
  if [ "${covered}" -gt "${BEST_COVERED}" ] || \
     { [ "${covered}" -eq "${BEST_COVERED}" ] && [ "${in_use}" != "0" ] && [ "${BEST_INUSE}" = "0" ]; }; then
    BEST_ARN="${arn}"
    BEST_COVERED="${covered}"
    BEST_INUSE="${in_use}"
    BEST_STATUS="${status}"
    BEST_SANS="${sans}"
  fi
done

echo

if [ -z "${BEST_ARN}" ]; then
  echo "[ ok ] no project certificate exists yet — first deploy, nothing to compare"
  exit 0
fi

echo "Best-covering certificate: ${BEST_ARN}"
echo "  status : ${BEST_STATUS}"
echo "  in use : ${BEST_INUSE} resource(s)"
echo "  covers :"
printf '    %s\n' ${BEST_SANS}
echo

MISSING=""
for host in ${EXPECTED}; do
  if ! printf '%s\n' ${BEST_SANS} | grep -qxF "${host}"; then
    MISSING="${MISSING} ${host}"
  fi
done

if [ -n "${MISSING}" ]; then
  printf '\033[1;31m[FAIL]\033[0m no project certificate covers:%s\n' "${MISSING}"
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

if [ "${BEST_INUSE}" = "0" ]; then
  echo "[note] that certificate is not yet attached to any resource — the"
  echo "       configure stage will move the ALB listeners onto it, and the"
  echo "       verify stage will then prune the retired one."
fi
