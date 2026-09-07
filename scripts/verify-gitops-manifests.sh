#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps manifest guard — runs in the `security` stage, BEFORE any AWS
# resource is touched.
#
# WHY THIS EXISTS
#   The root App-of-Apps reconciles gitops/apps/children/*.yaml FROM GIT. Any
#   value injected into a live Application at bootstrap time is therefore
#   reverted on root's next sync, and the Application is left with whatever git
#   actually contains. When git contained an unresolved placeholder, the result
#   was:
#
#     status: "Failed to load target state: ... repository not found"
#
#   with the workload silently never created — a failure that only surfaced
#   minutes later, in Argo CD, long after CI had gone green.
#
#   These checks make that class of mistake fail in ~2 seconds instead.
#
# SCOPE: only the Application manifests under gitops/apps/ are inspected, and
# only their actual VALUES. Scripts and prose elsewhere under gitops/
# legitimately mention placeholder names while explaining this bug, and a guard
# that trips over its own documentation is a broken guard.
# ---------------------------------------------------------------------------
set -uo pipefail

FAILURES=0
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)) || true; }
pass() { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

APPS_DIR="gitops/apps"
ROOT_APP="${APPS_DIR}/root-app.yaml"
CHILDREN_DIR="${APPS_DIR}/children"
SHOPFAST_VALUES="gitops/applications/shopfast/values.yaml"
MONITORING="${CHILDREN_DIR}/monitoring.yaml"

echo "=== GitOps manifest verification ==="

[ -f "${ROOT_APP}" ] || fail "missing ${ROOT_APP}"

# 1+2. Every Application's repoURL must be a real, resolvable URL. This single
#      check subsumes "no placeholders": a placeholder is simply not a URL.
for f in "${ROOT_APP}" "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  # Strip comments, then read the value of the first real repoURL key.
  url="$(grep -E '^[[:space:]]*repoURL:' "$f" \
         | head -n1 \
         | sed -E 's/^[[:space:]]*repoURL:[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//')"

  if [ -z "${url}" ]; then
    fail "${name}: no repoURL found"
    continue
  fi

  case "${url}" in
    https://*|http://*|oci://*|git@*)
      pass "${name}: repoURL resolves (${url})"
      ;;
    *)
      fail "${name}: repoURL is not a URL: '${url}' — the root app applies this value verbatim, so it must be committed in full"
      ;;
  esac
done

# 3. Child Applications must not carry apply-time helm parameters. Anything the
#    chart needs belongs in a values file git owns, or root will fight whoever
#    injects it.
for f in "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if grep -qE '^[[:space:]]+parameters:' "$f"; then
    fail "${name}: declares helm parameters; put environment-specific values in a committed values file instead"
  else
    pass "${name}: no apply-time helm parameters"
  fi
done

# 4. The bootstrap script must not rewrite the App-of-Apps manifests. Only an
#    actual sed COMMAND counts — comments explaining why this is forbidden do
#    not. Match a sed invocation at a command position that targets gitops/apps.
BOOTSTRAP="gitops/bootstrap/bootstrap.sh"
if [ -f "${BOOTSTRAP}" ]; then
  if grep -nE '^[[:space:]]*[^#]*(^|[|;&[:space:]])sed[[:space:]][^|;&]*gitops/apps' "${BOOTSTRAP}" >/dev/null 2>&1; then
    grep -nE '^[[:space:]]*[^#]*(^|[|;&[:space:]])sed[[:space:]][^|;&]*gitops/apps' "${BOOTSTRAP}" || true
    fail "bootstrap.sh rewrites gitops/apps manifests — root reverts such edits; commit the real values instead"
  else
    pass "bootstrap.sh does not rewrite the App-of-Apps manifests"
  fi
fi

# 5. ONE CERTIFICATE, MANY CONSUMERS.
#    argocd, shopfast and grafana are served by a single ACM certificate. Adding
#    a SAN REPLACES that certificate and mints a new ARN, so every committed
#    copy must move together. Two files carry it in git:
#      - gitops/applications/shopfast/values.yaml  (ingress.certificateArn)
#      - gitops/apps/children/monitoring.yaml      (grafana ingress annotation)
#    If they disagree, one hostname is pointing at a certificate that is being
#    retired, and its HTTPS listener breaks on the next reconcile. CI rewrites
#    both in the same commit (scripts/gitops-commit.sh); this check proves it.
extract_arn() {
  grep -oE 'arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-f0-9-]+' "$1" \
    | head -n1
}

if [ -f "${SHOPFAST_VALUES}" ] && [ -f "${MONITORING}" ]; then
  app_arn="$(extract_arn "${SHOPFAST_VALUES}")"
  graf_arn="$(extract_arn "${MONITORING}")"

  if [ -z "${app_arn}" ] || [ -z "${graf_arn}" ]; then
    # Before the first successful build_push there is no ARN to compare. That
    # is a legitimate bootstrap state, not a defect.
    pass "certificate ARN not yet committed in both files (pre-bootstrap state)"
  elif [ "${app_arn}" = "${graf_arn}" ]; then
    pass "shopfast and grafana reference the same certificate ARN"
  else
    fail "certificate ARN mismatch — shopfast='${app_arn}' grafana='${graf_arn}'; one hostname will lose HTTPS. Both are rewritten together by scripts/gitops-commit.sh"
  fi
fi

# 6. Grafana is deliberately internet-facing, so anonymous access must stay off.
#    A chart upgrade or a careless edit that flips this exposes every dashboard
#    and the metrics datasource to the public internet with no login at all.
if [ -f "${MONITORING}" ]; then
  if grep -qE '^[[:space:]]*ingress:' "${MONITORING}"; then
    if grep -A2 -E '^[[:space:]]*auth\.anonymous:' "${MONITORING}" \
         | grep -qE '^[[:space:]-]*enabled:[[:space:]]*true'; then
      fail "monitoring.yaml: Grafana is publicly exposed AND auth.anonymous is enabled — this publishes every dashboard without a login"
    else
      pass "monitoring.yaml: Grafana anonymous access disabled"
    fi
  fi
fi

# 7. NO APPLICATION-WIDE Replace=true.
#    Replace=true makes Argo CD use `kubectl replace`: it posts the WHOLE object
#    as the chart renders it and discards server-side field ownership. Any chart
#    that provisions a PersistentVolumeClaim is then permanently unsyncable —
#    the rendered PVC omits volumeName/storageClassName, the binding controller
#    has written both, and the API server rejects the mutation:
#
#      PersistentVolumeClaim "vm-grafana" is invalid: spec: Forbidden:
#      spec is immutable after creation except resources.requests ...
#
#    Observed 2026-09-07 on the `monitoring` Application: 5 retries, ~25 min,
#    failed on every sync. Nothing was broken in the cluster, which is exactly
#    what made it dangerous — the app simply stopped being able to deliver any
#    future change (including the certificate ARN written by set-grafana-cert.py).
#
#    A genuinely immutable object that must be replaced is scoped with the
#    per-resource annotation `argocd.argoproj.io/sync-options: Replace=true`,
#    never with an Application-wide syncOption.
#
#    SELECTOR NOTE: this must match the VALUE, not the prose. monitoring.yaml
#    documents this bug at length and names Replace=true many times in comments.
#    So: strip comments first, then require the syncOptions LIST-ITEM form.
for f in "${ROOT_APP}" "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if sed -E 's/#.*$//' "$f" | grep -qE '^[[:space:]]*-[[:space:]]*Replace=true[[:space:]]*$'; then
    fail "${name}: sets Application-wide Replace=true — this breaks any chart with a PersistentVolumeClaim (spec is immutable once Bound). Use ServerSideApply, or scope Replace to one resource with the argocd.argoproj.io/sync-options annotation"
  else
    pass "${name}: no Application-wide Replace=true"
  fi
done

echo
if [ "${FAILURES}" -gt 0 ]; then
  printf '\033[1;31mGitOps manifest verification FAILED (%s problem(s)).\033[0m\n' "${FAILURES}"
  exit 1
fi

printf '\033[1;32mGitOps manifests verified.\033[0m\n'
