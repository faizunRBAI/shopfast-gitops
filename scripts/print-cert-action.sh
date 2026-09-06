#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Print the ONE DNS record the operator must create by hand, and say plainly
# what stays broken until they do.
#
# CONTEXT
#   royalbengal.xyz is NOT delegated to Route 53 — it is hosted on cPanel, whose
#   Zone Editor has no NS record type. Terraform creates the validation records
#   in its own (unused) hosted zone, so ACM never sees them. Every validation
#   CNAME therefore has to be copied into cPanel by a human.
#
#   Adding the Grafana hostname as a SAN REPLACES the platform certificate, so
#   the new one is PENDING_VALIDATION and the ALB serves it for argocd,
#   shopfast AND grafana. Until this record exists, HTTPS is broken on all
#   three. That is the accepted cost of the single-shot rollout, and the
#   operator closes the window by adding the record below.
#
# Run from the infra/ directory (terraform state is read from there).
# ---------------------------------------------------------------------------
set -euo pipefail

echo ""
echo "================================================================"
echo "  ACTION REQUIRED — add this CNAME in the cPanel Zone Editor"
echo "================================================================"
echo ""

if ! RECORD_JSON="$(terraform output -json grafana_certificate_validation_record 2>/dev/null)"; then
  echo "::warning title=Validation record not available::terraform could not" \
       "read grafana_certificate_validation_record. Fall back to the full" \
       "'All ACM validation records' group printed by the next step."
  exit 0
fi

# `one()` yields null when ACM has not yet published the option for this name.
if [ -z "${RECORD_JSON}" ] || [ "${RECORD_JSON}" = "null" ]; then
  echo "::warning title=Validation record not yet published::ACM has not" \
       "returned a validation option for the Grafana hostname yet. Re-run the" \
       "deploy, or read the record from the ACM console."
  exit 0
fi

NAME="$(printf '%s' "${RECORD_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
TYPE="$(printf '%s' "${RECORD_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["type"])')"
VALUE="$(printf '%s' "${RECORD_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"

echo "  Type : ${TYPE}"
echo "  Name : ${NAME}"
echo "  Value: ${VALUE}"
echo ""
echo "  cPanel strips the trailing dot and appends the domain automatically."
echo "  If cPanel rejects the full name, enter only the part before"
echo "  '.royalbengal.xyz'."
echo ""
echo "  ALSO REQUIRED (traffic record, if not already present):"
echo "    Type : CNAME"
echo "    Name : grafana.shopfast"
echo "    Value: <same ALB hostname as your existing argocd.shopfast record>"
echo ""
echo "  UNTIL THE VALIDATION RECORD RESOLVES, the replacement certificate stays"
echo "  PENDING_VALIDATION and HTTPS is rejected on argocd.shopfast,"
echo "  shopfast and grafana.shopfast. ACM issues within minutes of the"
echo "  record propagating; no redeploy is needed afterwards."
echo "================================================================"
echo ""
