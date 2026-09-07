#!/usr/bin/env bash
#
# ONE-SHOT STATE REPAIR — remove a stranded DEPOSED aws_acm_certificate object.
#
# WHY THIS EXISTS
# ---------------
# aws_acm_certificate.platform carries create_before_destroy = true. A SAN
# change therefore runs in two halves:
#   1. create the replacement certificate            (fast)
#   2. mark the old object DEPOSED, then destroy it  (blocked while in use)
#
# ACM refuses to delete a certificate that is still attached to an ALB
# listener. The listener flip happens in the CONFIGURE stage, which runs AFTER
# provision — so the destroy in step 2 waits for something that cannot happen
# yet. On 2026-09-06 that deadlock burned 18 minutes and the job was cancelled
# mid-destroy, leaving the old certificate parked in state as a deposed object.
#
# A deposed object is already condemned: there is no configuration to compare
# it against, so NO lifecycle rule suppresses it — not ignore_changes, not
# prevent_destroy. Terraform retries the impossible delete on EVERY apply, and
# provision can never reach configure to break the cycle. The only exit is to
# remove the deposed object from state.
#
# ---------------------------------------------------------------------------
# 2026-09-07 CORRECTION — WHY v1 OF THIS SCRIPT SILENTLY DID NOTHING
# ---------------------------------------------------------------------------
# v1 discovered its target with:
#     terraform state list | grep -i deposed
# That matches ZERO lines by construction. `terraform state list` enumerates
# RESOURCE INSTANCES only — confirmed from `terraform -help state list`: "This
# command lists resource instances in the Terraform state". A deposed object is
# NOT an instance; it is a prior object parked under the instance's `deposed`
# map. There is no flag to include one.
#
# So v1 exited 0 in one second reporting "nothing to repair" while the very
# next step's refresh printed:
#     aws_acm_certificate.platform (deposed object 19b0aa2c): Refreshing state...
# The object was there the whole time. Every other guard in v1 was correct and
# entirely irrelevant, because the SELECTOR could never produce a candidate.
#
# Two consequences, both fixed below:
#   * Discovery now uses `terraform show -json`, which DOES expose deposed
#     objects (each carries a "deposed_key"). That is the only supported way to
#     enumerate them.
#   * "Nothing found" is no longer silently treated as success when we have
#     reason to believe an object exists. A repair that finds nothing is
#     indistinguishable from a repair that is broken — v1 proved exactly that —
#     so this version reports loudly which branch it took.
#
# WHAT `state rm` ACTUALLY DOES (the reason this is safe)
# ------------------------------------------------------
# It removes terraform's RECORD of the object. It does NOT delete anything in
# AWS. The certificate keeps serving traffic, completely untouched. It is later
# retired by scripts/prune-retired-certs.sh, which refuses to delete any
# certificate whose InUseBy list is non-empty. So the worst case here is an
# unmanaged certificate that costs nothing and gets cleaned up on a later run —
# never an outage, never a deleted live resource.
#
# VERIFIED 2026-09-07: the ALB HTTPS listener is still serving a305f33d (the
# deposed certificate). `aws acm list-certificates` reported InUseBy null for
# it, which is a summary field and UNDERSTATES attachment — describe-listeners
# is the authoritative check. This is why the destroy is still blocked, and why
# removing the state record (rather than deleting the cert) is the correct move.
#
# SAFETY PROPERTIES
#   1. Only DEPOSED objects of aws_acm_certificate.platform are ever
#      considered. Current objects and every other resource are ignored.
#   2. The address is composed from the deposed_key terraform itself reported
#      in `terraform show -json`, in terraform's own documented address form,
#      and is rehearsed before use.
#   3. Every removal is rehearsed with `terraform state rm -dry-run` first. If
#      the rehearsal fails, the real removal is not attempted.
#   4. It no-ops when there is genuinely no deposed object — but says so
#      explicitly, and distinguishes that from "I could not look".
#   5. It never touches the CURRENT object, so the live certificate stays fully
#      managed by terraform.
#
# THIS STEP IS TEMPORARY. Once provision completes and the deposed object is
# gone, delete this script and its pipeline step. A state-mutating command
# living permanently in CI is a hazard, not a feature.
#
set -euo pipefail

RESOURCE="aws_acm_certificate.platform"

echo "=================================================================="
echo "  Deposed ACM certificate state check"
echo "=================================================================="

# ---------------------------------------------------------------------------
# DISCOVERY — via `terraform show -json`, NOT `terraform state list`.
# `state list` cannot see deposed objects at all (see header). The JSON state
# representation exposes them: each instance object that is deposed carries a
# "deposed_key" field alongside its address.
# ---------------------------------------------------------------------------
if ! state_json="$(terraform show -json 2>&1)"; then
  echo "[FAIL] could not read terraform state as JSON:"
  printf '%s\n' "${state_json}"
  exit 1
fi

# Emit one "<address>|<deposed_key>" line per deposed object of this resource.
# jq is present on GitHub-hosted runners.
deposed_pairs="$(printf '%s' "${state_json}" | jq -r --arg res "${RESOURCE}" '
  [ .values.root_module?.resources[]?,
    (.values.root_module?.child_modules[]?.resources[]?) ]
  | map(select(.address == $res and (.deposed_key // "") != ""))
  | .[] | "\(.address)|\(.deposed_key)"
' 2>/dev/null || true)"

if [ -z "${deposed_pairs}" ]; then
  echo "No deposed ${RESOURCE} object found via terraform show -json."
  echo
  echo "NOTE: this is the EXPECTED result once the one-time repair has been"
  echo "      applied. If provision then fails again on a blocked ACM destroy,"
  echo "      do NOT assume this script is fine — v1 of it reported exactly"
  echo "      this message while the object was demonstrably present, because"
  echo "      it looked in 'terraform state list', which never shows deposed"
  echo "      objects. Cross-check the apply log for the marker:"
  echo "          ${RESOURCE} (deposed object <key>)"
  echo
  echo "This script and its pipeline step should be deleted once a run"
  echo "confirms the repair is done."
  exit 0
fi

echo "Found deposed object(s) stranded by the cancelled destroy:"
printf '%s\n' "${deposed_pairs}" | sed 's/^/    /'
echo
echo "These are objects terraform has condemned but cannot delete, because ACM"
echo "blocks deleting a certificate that is still attached to the ALB listener."
echo "Removing them from state lets provision finish; the certificate itself is"
echo "NOT deleted and keeps serving traffic."
echo

removed=0

while IFS='|' read -r addr key; do
  [ -n "${addr}" ] || continue
  [ -n "${key}" ] || continue

  # Paranoia: re-assert the target really is what we think it is, immediately
  # before acting on it. Cheap, and the failure mode it guards against
  # (removing the wrong object) is unrecoverable.
  if [ "${addr}" != "${RESOURCE}" ]; then
    echo "  [SKIP] '${addr}' is not ${RESOURCE} — refusing to touch it."
    continue
  fi

  # Terraform's address form for a deposed object.
  target="${addr} (deposed ${key})"

  echo "::group::${target}"
  echo "  Rehearsing removal (-dry-run, changes nothing):"

  if ! terraform state rm -dry-run "${target}"; then
    echo "  [SKIP] dry-run failed for this address — not removing it."
    echo "         Provision will still fail on the blocked destroy; that is"
    echo "         preferable to guessing at a state mutation."
    echo "::endgroup::"
    continue
  fi

  echo "  Dry-run succeeded. Removing for real:"
  terraform state rm "${target}"
  removed=$((removed + 1))

  echo "::endgroup::"
done <<< "${deposed_pairs}"

echo
if [ "${removed}" -eq 0 ]; then
  echo "[FAIL] deposed object(s) were found but NONE could be removed."
  echo "       Failing loudly rather than letting provision spend 20 minutes"
  echo "       re-discovering the same blocked destroy."
  exit 1
fi

echo "[OK] removed ${removed} deposed object(s) from state."
echo "     terraform will no longer attempt the blocked in-apply destroy, so"
echo "     provision can complete, configure can flip the ALB listeners onto"
echo "     the current certificate, and verify's pruner retires the old one"
echo "     once ACM reports it detached."
