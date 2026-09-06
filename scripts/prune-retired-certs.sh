#!/usr/bin/env bash
#
# Delete ACM certificates this project has RETIRED, once nothing is using them.
#
# WHY THIS EXISTS
# ---------------
# infra/dns.tf no longer lets terraform destroy the previous platform
# certificate during apply. That destroy deadlocked: ACM refuses to delete a
# certificate that is still attached to an ALB listener, and the listener is
# only moved off it by the CONFIGURE stage — which cannot run until provision
# finishes. Provision waited 18 minutes on the delete and was cancelled.
#
# So the retirement happens here instead, in the VERIFY stage, which runs AFTER
# configure has flipped the listeners. By then the old certificate is detached
# and deletes instantly.
#
# SAFETY PROPERTY (the only thing that really matters in this script)
# ------------------------------------------------------------------
# A certificate is deleted ONLY when all four hold:
#   1. it is tagged Project=<project>  — ours, not a bystander certificate that
#      happens to share a domain name;
#   2. its ARN is NOT the certificate currently in terraform state;
#   3. its InUseBy list is EMPTY — nothing (ALB, CloudFront, API GW) references
#      it. This is ACM's own view, not an inference of ours;
#   4. it is not still PENDING_VALIDATION — a pending certificate may be a
#      replacement mid-rollout, and deleting it would undo an in-flight change.
#
# VERIFIED 2026-09-06 against the live account: both the old (a305f33d) and the
# replacement (76478185) certificate carry identical Project/ManagedBy/Stack
# tags (they come from the provider's default_tags). Tags therefore CANNOT
# distinguish keep-from-delete — check 2, the ARN read from terraform state, is
# the only thing that does. That is why this script takes the current ARN as a
# required argument and refuses to run without a well-formed one, rather than
# discovering it by tag or by domain name.
#
# Also verified: the old certificate currently reports InUseBy = 1 ALB, so a run
# TODAY correctly SKIPS it. It only becomes deletable after configure moves the
# listeners.
#
# If any check fails the certificate is SKIPPED and reported. Nothing is forced,
# nothing is retried, and the script never fails the build for a skip: leaving a
# stale certificate costs nothing (ACM certificates are free and there is no
# per-certificate quota pressure at this scale), while deleting a live one is an
# outage. The asymmetry is deliberate.
#
# NO PYTHON: every field is extracted with the AWS CLI's own --query (JMESPath).
# The sandbox has no python3 and a CI runner's is not worth depending on for
# something this simple.
#
# Usage:
#   scripts/prune-retired-certs.sh <project-name> <current-certificate-arn>

set -euo pipefail

PROJECT="${1:?usage: prune-retired-certs.sh <project> <current-cert-arn>}"
CURRENT_ARN="${2:?usage: prune-retired-certs.sh <project> <current-cert-arn>}"

# Guard: an empty or malformed "current" ARN would make every project
# certificate look superseded, including the live one. Refuse loudly.
if [[ "${CURRENT_ARN}" != arn:aws:acm:* ]]; then
  echo "error: second argument is not an ACM ARN: '${CURRENT_ARN}'" >&2
  echo "       Refusing to run — without a valid current ARN this script" >&2
  echo "       cannot tell the live certificate from a retired one." >&2
  exit 1
fi

echo "=================================================================="
echo "  Retiring superseded ACM certificates for ${PROJECT}"
echo "=================================================================="
echo "  Keeping (current, from terraform state):"
echo "    ${CURRENT_ARN}"
echo

ARNS="$(aws acm list-certificates \
  --query 'CertificateSummaryList[].CertificateArn' \
  --output text | tr '\t' '\n')"

if [[ -z "${ARNS}" ]]; then
  echo "No ACM certificates in this account/region. Nothing to do."
  exit 0
fi

deleted=0
skipped=0

while IFS= read -r arn; do
  [[ -n "${arn}" ]] || continue

  # Check 2: never touch the certificate terraform is currently using.
  if [[ "${arn}" == "${CURRENT_ARN}" ]]; then
    continue
  fi

  # Check 1: ownership. An untagged or foreign certificate is none of our
  # business, even if it carries the same domain names.
  owner="$(aws acm list-tags-for-certificate \
    --certificate-arn "${arn}" \
    --query "Tags[?Key=='Project'].Value | [0]" \
    --output text 2>/dev/null || echo "None")"

  if [[ "${owner}" != "${PROJECT}" ]]; then
    continue
  fi

  status="$(aws acm describe-certificate --certificate-arn "${arn}" \
    --query 'Certificate.Status' --output text)"
  in_use="$(aws acm describe-certificate --certificate-arn "${arn}" \
    --query 'length(Certificate.InUseBy)' --output text)"

  echo "-- ${arn}"
  echo "     status: ${status}   in-use-by: ${in_use} resource(s)"

  # Check 4: a pending certificate may be a replacement mid-rollout.
  if [[ "${status}" == "PENDING_VALIDATION" ]]; then
    echo "     SKIP — PENDING_VALIDATION (may be an in-flight replacement)."
    skipped=$((skipped + 1))
    continue
  fi

  # Check 3: THE safety property. Still attached => still serving traffic.
  if [[ "${in_use}" != "0" ]]; then
    echo "     SKIP — still attached to ${in_use} resource(s)."
    echo "            Listeners have not moved off it yet; it will be pruned"
    echo "            on a later run. Never forced."
    skipped=$((skipped + 1))
    continue
  fi

  echo "     DELETE — superseded, tagged ${PROJECT}, referenced by nothing."
  if aws acm delete-certificate --certificate-arn "${arn}"; then
    deleted=$((deleted + 1))
  else
    echo "     WARN — delete failed; leaving it in place (not fatal)."
    skipped=$((skipped + 1))
  fi
done <<< "${ARNS}"

echo
echo "Retired: ${deleted}   Skipped: ${skipped}"
echo "A skip is a normal outcome, never a build failure."
