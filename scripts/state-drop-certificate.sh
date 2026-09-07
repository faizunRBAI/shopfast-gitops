#!/usr/bin/env bash
#
# ONE-SHOT, MANUALLY TRIGGERED: stop terraform tracking the platform ACM
# certificate, so the next apply creates a fresh one with the CURRENT SAN list.
#
# THIS SCRIPT IS NOT PART OF THE DEPLOY PIPELINE AND MUST NEVER BE.
# It is run only by .github/workflows/state-fix.yml, which is dispatch-only
# (no push trigger, not in the deploy stage graph). Two earlier attempts put
# state repair INTO the deploy path; both failed and both cost a run. The
# lesson kept from those attempts is not "never touch state" — it is "never
# let a state mutation run automatically on every deploy".
#
# WHY IT IS NEEDED (verified 2026-09-07)
# --------------------------------------
# infra/dns.tf carried `ignore_changes = [subject_alternative_names]`. That was
# added to break an 18-minute destroy deadlock, and it worked — but it also
# meant the SAN list is read at CREATE time only, so terraform would NEVER
# replace the existing certificate. State therefore holds the OLD 2-SAN
# certificate (argocd + apex, no grafana) permanently:
#
#   a305f33d  argocd.shopfast + shopfast (apex)   ISSUED   attached to the ALB
#   76478185  argocd.shopfast + apex + grafana    ISSUED   orphan, not in state
#
# Every deploy read the 2-SAN certificate from state, committed its ARN into
# the ingress annotations, and Grafana kept mismatching. A stable wrong
# fixed point. The `ignore_changes` has been removed in the same change as
# this script; dropping the resource from state is what lets the next apply
# create a certificate covering all three names.
#
# The state entry also carries a DEPOSED object (19b0aa2c) stranded by the
# cancelled create_before_destroy. Removing the resource address takes the
# current object AND the deposed one in a single operation — which is why this
# uses a literal address and does no discovery. `terraform state list` cannot
# see deposed objects at all (verified: that is exactly how attempt 22's
# discovery script silently no-opped), so any script that searches for its own
# target here is wrong by construction.
#
# WHAT IT DOES TO AWS
# -------------------
# NOTHING. `terraform state rm` only edits terraform's own bookkeeping. Both
# certificates remain in ACM, the ALB keeps serving a305f33d, and all three
# hostnames keep working while this runs. It is safe to run with the site live.
#
# AFTER THIS RUNS
# ---------------
#   provision   -> no certificate in state, so terraform CREATES one with all
#                  three SANs. No destroy is planned, so nothing can deadlock.
#                  Prints the validation CNAMEs for cPanel.
#   build_push  -> commits the new ARN into the ingress annotations.
#   configure   -> the ALB listeners move onto the new certificate.
#   verify      -> prune-retired-certs.sh deletes a305f33d and the 76478185
#                  orphan once their InUseBy lists are empty.
#
# IDEMPOTENT: running it twice is harmless. The second run finds nothing to
# remove and exits 0 with a clear message.

set -euo pipefail

ADDRESS="aws_acm_certificate.platform"

echo "=================================================================="
echo "  One-shot state repair: drop ${ADDRESS} from terraform state"
echo "=================================================================="
echo
echo "  This removes a STATE ENTRY only."
echo "  No certificate is deleted in ACM. No AWS resource is touched."
echo "  The ALB keeps serving its current certificate throughout."
echo

cd infra

echo "--- tracked resources BEFORE ---"
terraform state list

# `terraform state list` cannot show deposed objects, so it is used here ONLY
# as a human-readable before/after record — never as the thing that decides
# whether the removal is needed. The address is literal and unconditional.
echo
echo "--- removing ${ADDRESS} ---"
if terraform state rm "${ADDRESS}"; then
  echo "Removed. Terraform no longer tracks the platform certificate."
else
  # A non-zero exit here is almost always "no matching objects" from a second
  # run. That is the desired end state, not a failure.
  echo
  echo "terraform state rm reported no change."
  echo "If the address is already absent below, the repair is DONE — this"
  echo "script is idempotent and a repeat run is expected to say this."
fi

echo
echo "--- tracked resources AFTER ---"
terraform state list

echo
if terraform state list | grep -qx "${ADDRESS}"; then
  echo "FAILED: ${ADDRESS} is STILL tracked. Do not deploy yet."
  exit 1
fi

echo "=================================================================="
echo "  SUCCESS — ${ADDRESS} is no longer in terraform state."
echo
echo "  Next: run the deploy. The provision stage will create a fresh"
echo "  certificate covering all three hostnames and print the validation"
echo "  CNAMEs to add in cPanel."
echo "=================================================================="
