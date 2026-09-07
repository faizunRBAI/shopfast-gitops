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
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

APPS_DIR="gitops/apps"
ROOT_APP="${APPS_DIR}/root-app.yaml"
CHILDREN_DIR="${APPS_DIR}/children"
SHOPFAST_VALUES="gitops/applications/shopfast/values.yaml"
# The Grafana ARN moved OUT of the Application manifest and into the monitoring
# stack's $values file when monitoring became multi-source (2026-09-07).
MONITORING_VALUES="gitops/monitoring/values.yaml"
MONITORING="${CHILDREN_DIR}/monitoring.yaml"

echo "=== GitOps manifest verification ==="

[ -f "${ROOT_APP}" ] || fail "missing ${ROOT_APP}"

# 1+2. Every Application's repoURL must be a real, resolvable URL. This single
#      check subsumes "no placeholders": a placeholder is simply not a URL.
#
#      MULTI-SOURCE NOTE: an Application may declare several sources, and a
#      chart source's repoURL is a Helm repository while the $values source's
#      is this git repo. Both are URLs, so checking EVERY repoURL in the file
#      is both correct and stricter than checking only the first.
for f in "${ROOT_APP}" "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  # Strip comments first so a URL mentioned in prose is never graded.
  body="$(sed -E 's/#.*$//' "$f")"

  urls="$(printf '%s\n' "${body}" \
          | grep -E '^[[:space:]]*-?[[:space:]]*repoURL:' \
          | sed -E 's/^[[:space:]]*-?[[:space:]]*repoURL:[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//')"

  if [ -z "${urls}" ]; then
    fail "${name}: no repoURL found"
    continue
  fi

  bad=0
  while IFS= read -r url; do
    [ -n "${url}" ] || continue
    case "${url}" in
      https://*|http://*|oci://*|git@*) ;;
      *)
        fail "${name}: repoURL is not a URL: '${url}' — the root app applies this value verbatim, so it must be committed in full"
        bad=1
        ;;
    esac
  done <<EOF
${urls}
EOF

  if [ "${bad}" -eq 0 ]; then
    count="$(printf '%s\n' "${urls}" | grep -c .)"
    pass "${name}: ${count} repoURL(s) resolve"
  fi
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
#      - gitops/monitoring/values.yaml             (grafana ingress annotation)
#    If they disagree, one hostname is pointing at a certificate that is being
#    retired, and its HTTPS listener breaks on the next reconcile. CI rewrites
#    both in the same commit (scripts/gitops-commit.sh); this check proves it.
#
#    PATH MOVED 2026-09-07: the Grafana copy used to live inside
#    gitops/apps/children/monitoring.yaml. It now lives in the multi-source
#    $values file. If this check ever reads an empty ARN from a file that
#    plainly contains one, suspect this path first.
extract_arn() {
  grep -oE 'arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-f0-9-]+' "$1" \
    | head -n1
}

if [ -f "${SHOPFAST_VALUES}" ] && [ -f "${MONITORING_VALUES}" ]; then
  app_arn="$(extract_arn "${SHOPFAST_VALUES}")"
  graf_arn="$(extract_arn "${MONITORING_VALUES}")"

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

# 5b. The Grafana ARN must not be left behind in the Application manifest after
#     the multi-source refactor. A stale copy there is not read by anything, so
#     it cannot break a sync — but it WILL be found by a future engineer, who
#     will reasonably believe it is live and edit the wrong file.
if [ -f "${MONITORING}" ]; then
  if [ -n "$(sed -E 's/#.*$//' "${MONITORING}" | grep -oE 'arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-f0-9-]+' | head -n1)" ]; then
    fail "monitoring.yaml still carries a certificate ARN in the Application manifest; after the multi-source refactor the live copy is ${MONITORING_VALUES} — remove the orphan so there is one obvious place to edit"
  else
    pass "monitoring.yaml carries no orphaned certificate ARN"
  fi
fi

# 6. Grafana is deliberately internet-facing, so anonymous access must stay off.
#    A chart upgrade or a careless edit that flips this exposes every dashboard
#    and the metrics datasource to the public internet with no login at all.
#
#    Follows the values file, same as check 5.
for f in "${MONITORING}" "${MONITORING_VALUES}"; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if grep -qE '^[[:space:]]*ingress:' "$f"; then
    if grep -A2 -E '^[[:space:]]*auth\.anonymous:' "$f" \
         | grep -qE '^[[:space:]-]*enabled:[[:space:]]*true'; then
      fail "${name}: Grafana is publicly exposed AND auth.anonymous is enabled — this publishes every dashboard without a login"
    else
      pass "${name}: Grafana anonymous access disabled"
    fi
  fi
done

# 7. Replace=true IS ONLY A DEFECT ON A CHART THAT PROVISIONS STORAGE.
#
#    Replace=true makes Argo CD use `kubectl replace`: it posts the WHOLE object
#    as the chart renders it and discards server-side field ownership. On a
#    chart that provisions a PersistentVolumeClaim that is fatal and permanent —
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
#    BUT Replace=true is ALSO the documented, correct workaround for installing
#    large CRDs: a CRD manifest routinely exceeds the 262144-byte
#    kubectl.kubernetes.io/last-applied-configuration annotation limit that
#    client-side apply depends on. `argo-rollouts` (installCRDs: true) provisions
#    NO PersistentVolumeClaim — verified live, `kubectl -n argo-rollouts get pvc`
#    returns nothing — so Replace=true there is safe and intentional.
#
#    A BLANKET BAN WAS THE BUG (2026-09-07): the first run of this check failed
#    the build on argo-rollouts, a chart the failure mode cannot apply to. A
#    guard that fires on a condition that cannot cause harm trains people to
#    ignore it. So the check is now CONDITIONAL: Replace=true is a failure only
#    on an Application whose chart declares persistence/PVC storage.
#
#    A genuinely immutable object that must be replaced is scoped with the
#    per-resource annotation `argocd.argoproj.io/sync-options: Replace=true`,
#    never with an Application-wide syncOption.
#
#    SELECTOR NOTE: this must match the VALUE, not the prose. monitoring.yaml
#    documents this bug at length and names Replace=true many times in comments.
#    So: strip comments first, then require the syncOptions LIST-ITEM form.
#
#    MULTI-SOURCE NOTE: the storage declaration may now live in the $values file
#    rather than in the Application. For monitoring, look at both.
for f in "${ROOT_APP}" "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  body="$(sed -E 's/#.*$//' "$f")"

  if ! printf '%s' "${body}" | grep -qE '^[[:space:]]*-[[:space:]]*Replace=true[[:space:]]*$'; then
    pass "${name}: no Application-wide Replace=true"
    continue
  fi

  # Replace=true IS set. Does this chart provision storage? Look for the values
  # keys that request a PVC: `persistence.enabled: true`, or a `storage:` block
  # declaring a volume request. Search the Application AND, when it points at a
  # committed values file, that file too.
  storage_body="${body}"
  if [ "${f}" = "${MONITORING}" ] && [ -f "${MONITORING_VALUES}" ]; then
    storage_body="${body}
$(sed -E 's/#.*$//' "${MONITORING_VALUES}")"
  fi

  if printf '%s' "${storage_body}" | grep -qE '^[[:space:]]*persistence:[[:space:]]*$' \
     || printf '%s' "${storage_body}" | grep -qE '^[[:space:]]*storage:[[:space:]]*$' \
     || printf '%s' "${storage_body}" | grep -qE '^[[:space:]]*(storageClass|storageClassName|volumeClaimTemplate):' ; then
    fail "${name}: sets Application-wide Replace=true AND provisions persistent storage — a Bound PVC's spec is immutable, so every sync will be rejected forever. Use ServerSideApply, or scope Replace to one resource with the argocd.argoproj.io/sync-options annotation"
  else
    pass "${name}: Replace=true present but chart provisions no PVC (CRD-install case — safe)"
  fi
done

# 8. EVERY VMServiceScrape MUST HAVE A SERVICE TO SELECT.
#
#    A VMServiceScrape selects SERVICES and scrapes their endpoints. If no
#    Service carries the matched labels, the scrape resolves to zero targets.
#    It does NOT error, it does NOT go unhealthy, and Argo reports it Synced —
#    it simply never produces a sample. The dashboard panel is empty and
#    everyone reads that as "quiet", not "unmonitored". This is the worst kind
#    of observability bug because the monitoring of the monitoring is what is
#    broken.
#
#    Verified 2026-09-07: neither Argo CD nor Argo Rollouts ships a metrics
#    Service. The application-controller has no Service AT ALL — only a bare
#    containerPort 8082. So a scrape written without its Service is not a
#    hypothetical mistake here; it is the default outcome.
#
#    CHECK: for every VMServiceScrape defined under gitops/, require a Service
#    in the SAME file (they are authored as a pair, deliberately). Charts that
#    generate their own scrape+service are out of scope — this only inspects
#    committed manifests.
SCRAPE_FILES="$(grep -rlE '^kind:[[:space:]]*VMServiceScrape' gitops 2>/dev/null || true)"
if [ -z "${SCRAPE_FILES}" ]; then
  pass "no committed VMServiceScrape manifests to check"
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    name="${f#gitops/}"
    body="$(sed -E 's/#.*$//' "$f")"
    n_scrape="$(printf '%s\n' "${body}" | grep -cE '^kind:[[:space:]]*VMServiceScrape')"
    n_svc="$(printf '%s\n' "${body}" | grep -cE '^kind:[[:space:]]*Service[[:space:]]*$')"
    if [ "${n_svc}" -lt "${n_scrape}" ]; then
      fail "${name}: ${n_scrape} VMServiceScrape(s) but only ${n_svc} Service(s) — a scrape with no matching Service silently collects nothing. Define the Service alongside it"
    else
      pass "${name}: ${n_scrape} scrape(s) paired with ${n_svc} Service(s)"
    fi
  done <<EOF
${SCRAPE_FILES}
EOF
fi

# 9. THE LABEL-SYNC IMAGE MUST HAVE A SHELL AND A PINNED VERSION.
#
#    The CronJob's command is a bash script that branches on which workload kind
#    exists. A distroless image has no shell: the container exits 127 instantly,
#    and because a CronJob retries every minute the breakage looks like log
#    noise rather than a failure.
#
#    WHAT IS A HARD FAILURE
#      - distroless (no shell)
#      - `latest` or no tag at all (unpinned; the job runs 1440 times a day, so
#        a tag that moves under you is a large blast radius)
#
#    WHAT IS ONLY A WARNING
#      A digest pin is stricter and preferable, but requiring it here would be
#      a guard that fails the build on a perfectly correct manifest — and the
#      digest cannot be resolved offline. Attempt 24's lesson: a guard that
#      fires where no harm can occur trains people to ignore it. So an explicit
#      version tag PASSES with a nudge toward the digest.
#
#    CONDITIONAL: only runs when the CronJob exists.
LABEL_SYNC="gitops/label-sync/cronjob.yaml"
if [ -f "${LABEL_SYNC}" ]; then
  ls_body="$(sed -E 's/#.*$//' "${LABEL_SYNC}")"
  ls_image="$(printf '%s\n' "${ls_body}" \
              | grep -E '^[[:space:]]*image:' \
              | head -n1 \
              | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//')"

  if [ -z "${ls_image}" ]; then
    fail "label-sync/cronjob.yaml: no image declared"
  else
    case "${ls_image}" in
      *distroless*|gcr.io/distroless/*)
        fail "label-sync/cronjob.yaml: image '${ls_image}' is distroless — the job runs a bash script and would exit 127 every minute"
        ;;
      *@sha256:*)
        pass "label-sync/cronjob.yaml: image pinned by digest (${ls_image%%@*})"
        ;;
      *:latest)
        fail "label-sync/cronjob.yaml: image '${ls_image}' uses the 'latest' tag — pin an explicit version"
        ;;
      *:*)
        pass "label-sync/cronjob.yaml: image pinned to an explicit tag (${ls_image})"
        warn "label-sync/cronjob.yaml: consider a digest pin — resolve with 'crane digest ${ls_image}'"
        ;;
      *)
        fail "label-sync/cronjob.yaml: image '${ls_image}' has no tag — it would resolve to 'latest'"
        ;;
    esac
  fi

  # The job's script is bash-specific (it uses ${VAR##*:} parameter expansion
  # and [[-free but bash-shaped constructs). If the command ever switches to
  # /bin/sh on an image whose sh is dash, those expansions still work — but the
  # combination is worth stating explicitly rather than discovering at 03:00.
  if printf '%s\n' "${ls_body}" | grep -qE '^[[:space:]]*-[[:space:]]*/bin/bash[[:space:]]*$'; then
    pass "label-sync/cronjob.yaml: invokes /bin/bash explicitly"
  else
    warn "label-sync/cronjob.yaml: does not invoke /bin/bash explicitly — confirm the image's shell supports the script"
  fi
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  printf '\033[1;31mGitOps manifest verification FAILED (%s problem(s)).\033[0m\n' "${FAILURES}"
  exit 1
fi

printf '\033[1;32mGitOps manifests verified.\033[0m\n'
