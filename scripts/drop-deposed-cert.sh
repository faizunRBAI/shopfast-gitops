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
# WHAT `state rm` ACTUALLY DOES (the reason this is safe)
# ------------------------------------------------------
# It removes terraform's RECORD of the object. It does NOT delete anything in
# AWS. The certificate keeps serving traffic, completely untouched. It is later
# retired by scripts/prune-retired-certs.sh, which refuses to delete any
# certificate whose InUseBy list is non-empty. So the worst case here is an
# unmanaged certificate that costs nothing and gets cleaned up on a later run —
# never an outage, never a deleted live resource.
#
# SAFETY PROPERTIES
#   1. Only addresses containing BOTH "aws_acm_certificate.platform" AND a
#      deposed marker are ever considered. Everything else in state is ignored.
#   2. The address is used EXACTLY as terraform printed it — never reassembled
#      from parsed fragments. Two guards in this project have already failed by
#      selecting the wrong object; string-rebuilding an address is that same
#      mistake with delete power attached, so it is not done here.
#   3. Every removal is rehearsed with `terraform state rm -dry-run` first. If
#      the rehearsal fails, the real removal is not attempted.
#   4. It NO-OPS when there is no deposed object — the normal result on every
#      run after this one.
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

if ! state_list="$(terraform state list 2>&1)"; then
  echo "[FAIL] could not read terraform state:"
  printf '%s\n' "${state_list}"
  exit 1
fi

# Select deposed objects of this ONE resource.
#
# Terraform's exact spelling of the deposed marker is a documented-nowhere
# implementation detail (`terraform -help state list` does not describe it), so
# rather than betting on one spelling this matches case-insensitively on the
# word "deposed" appearing alongside the resource address. The matched line is
# then used VERBATIM as the address — whatever the format, terraform printed it
# and terraform will accept it back.
deposed_addrs="$(printf '%s\n' "${state_list}" \
  | grep -F "${RESOURCE}" \
  | grep -i "deposed" \
  || true)"

if [ -z "${deposed_addrs}" ]; then
  echo "No deposed ${RESOURCE} object in state — nothing to repair."
  echo "(Expected result on every run after the one-time fix. This script and"
  echo " its pipeline step should be deleted once that is the case.)"
  exit 0
fi

echo "Found deposed object(s) stranded by the cancelled destroy:"
printf '%s\n' "${deposed_addrs}" | sed 's/^/    /'
echo
echo "These are objects terraform has condemned but cannot delete, because ACM"
echo "blocks deleting a certificate that is still attached to the ALB listener."
echo "Removing them from state lets provision finish; the certificate itself is"
echo "NOT deleted and keeps serving traffic."
echo

removed=0

while IFS= read -r addr; do
  [ -n "${addr}" ] || continue

  # Strip only surrounding whitespace. The address is otherwise untouched.
  addr="$(printf '%s' "${addr}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "${addr}" ] || continue

  echo "::group::${addr}"

  # Paranoia: re-assert the target really is what we think it is, immediately
  # before acting on it. Cheap, and the failure mode it guards against
  # (removing the wrong object) is unrecoverable.
  case "${addr}" in
    *"${RESOURCE}"*) : ;;
    *)
      echo "  [SKIP] address does not name ${RESOURCE} — refusing to touch it."
      echo "::endgroup::"
      continue
      ;;
  esac

  echo "  Rehearsing removal (-dry-run, changes nothing):"
  if ! terraform state rm -dry-run "${addr}"; then
    echo "  [SKIP] dry-run failed for this address — not removing it."
    echo "         Provision will still fail on the blocked destroy; that is"
    echo "         preferable to guessing at a state mutation."
    echo "::endgroup::"
    continue
  fi

  echo "  Dry-run succeeded. Removing for real:"
  terraform state rm "${addr}"
  removed=$((removed + 1))

  echo "::endgroup::"
done <<< "${deposed_addrs}"

echo
if [ "${removed}" -eq 0 ]; then
  echo "[WARN] deposed object(s) were found but none could be removed."
  echo "       provision will likely fail again on the blocked destroy."
  exit 0
fi

echo "[OK] removed ${removed} deposed object(s) from state."
echo "     terraform will no longer attempt the blocked in-apply destroy, so"
echo "     provision can complete, configure can flip the ALB listeners onto"
echo "     the current certificate, and verify's pruner retires the old one"
echo "     once ACM reports it detached."
