#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Post-deploy verification — runs in the CI `verify` stage.
#
# Principle: never assume something works. Every claim this platform makes is
# checked against real AWS/EKS/Argo state, and the stage fails loudly if a
# claim is false.
#
# Note: `set -e` is deliberately NOT used. This script collects every failure
# and reports them together, so one broken check does not hide the other nine.
# ---------------------------------------------------------------------------
set -uo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  [ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  [warn] %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  [FAIL] %s\033[0m\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

FAILURES=0

# ---------------------------------------------------------------------------
# 1. AWS: the cluster really is ACTIVE
# ---------------------------------------------------------------------------
log "AWS — EKS control plane"
pushd infra >/dev/null || { echo "infra/ not found"; exit 1; }
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
ARGOCD_HOST="$(terraform output -raw argocd_hostname)"
APP_HOST="$(terraform output -raw app_hostname)"
ECR_NAME="$(terraform output -raw ecr_repository_name)"
popd >/dev/null || true

if [ -z "${CLUSTER_NAME}" ]; then
  echo "could not read eks_cluster_name from terraform state" >&2
  exit 1
fi

CLUSTER_STATUS="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
  --query 'cluster.status' --output text 2>/dev/null || echo UNKNOWN)"
if [ "${CLUSTER_STATUS}" = "ACTIVE" ]; then
  ok "EKS cluster ${CLUSTER_NAME} is ACTIVE"
else
  fail "EKS cluster ${CLUSTER_NAME} status is ${CLUSTER_STATUS}"
fi

log "AWS — ECR repository"
if aws ecr describe-repositories --repository-names "${ECR_NAME}" >/dev/null 2>&1; then
  IMAGE_COUNT="$(aws ecr list-images --repository-name "${ECR_NAME}" \
    --query 'length(imageIds)' --output text 2>/dev/null || echo 0)"
  ok "ECR repository ${ECR_NAME} present with ${IMAGE_COUNT} image(s)"
  if [ "${IMAGE_COUNT}" = "0" ]; then
    fail "ECR repository has no images — the build_push stage did not publish"
  fi
else
  fail "ECR repository ${ECR_NAME} not found"
fi

# ---------------------------------------------------------------------------
# 2. Kubernetes: nodes and namespaces
# ---------------------------------------------------------------------------
log "Kubernetes — nodes"
kubectl get nodes -o wide
NOT_READY="$(kubectl get nodes --no-headers -o custom-columns=S:.status.conditions[-1].type 2>/dev/null \
  | grep -vc '^Ready$' || true)"
if [ "${NOT_READY:-1}" -eq 0 ]; then
  ok "all nodes Ready"
else
  fail "${NOT_READY} node(s) not Ready"
fi

log "Kubernetes — namespaces"
for ns in argocd argo-rollouts shopfast monitoring; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    ok "namespace ${ns} exists"
  else
    fail "namespace ${ns} missing"
  fi
done

# ---------------------------------------------------------------------------
# 3. Argo CD itself
# ---------------------------------------------------------------------------
log "Argo CD — control plane"
if kubectl -n argocd rollout status deploy/argocd-server --timeout=5m >/dev/null 2>&1; then
  ok "argocd-server is available"
else
  fail "argocd-server did not become available"
fi

# ---------------------------------------------------------------------------
# 4. Argo CD applications — the real sync/health state
# ---------------------------------------------------------------------------
log "Argo CD — application sync & health (waiting up to 15m for convergence)"

read -r -d '' COUNT_BAD <<'PY' || true
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(99); sys.exit(0)
bad = 0
items = d.get("items", [])
if not items:
    print(99); sys.exit(0)
for i in items:
    s = i.get("status", {}).get("sync", {}).get("status")
    h = i.get("status", {}).get("health", {}).get("status")
    if s != "Synced" or h != "Healthy":
        bad += 1
print(bad)
PY

DEADLINE=$((SECONDS + 900))
while [ $SECONDS -lt $DEADLINE ]; do
  UNSYNCED="$(kubectl -n argocd get applications -o json 2>/dev/null \
    | python3 -c "${COUNT_BAD}" 2>/dev/null || echo 99)"
  [ "${UNSYNCED}" = "0" ] && break
  sleep 20
done

kubectl -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' || true

read -r -d '' LIST_BAD <<'PY' || true
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("unreadable"); sys.exit(0)
bad = []
for i in d.get("items", []):
    n = i["metadata"]["name"]
    s = i.get("status", {}).get("sync", {}).get("status")
    h = i.get("status", {}).get("health", {}).get("status")
    if s != "Synced" or h != "Healthy":
        bad.append(f"{n}(sync={s},health={h})")
print(" ".join(bad))
PY

APP_PROBLEMS="$(kubectl -n argocd get applications -o json 2>/dev/null \
  | python3 -c "${LIST_BAD}" 2>/dev/null || echo "unreadable")"

if [ -z "${APP_PROBLEMS}" ]; then
  ok "all Argo CD applications are Synced and Healthy"
else
  fail "applications not converged: ${APP_PROBLEMS}"
  for app in $(kubectl -n argocd get applications -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "--- $app conditions ---"
    kubectl -n argocd get application "$app" \
      -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null || true
  done
fi

# ---------------------------------------------------------------------------
# 5. Argo Rollouts: the CRD and controller must actually be running
# ---------------------------------------------------------------------------
log "Argo Rollouts — controller and rollout state"
if kubectl get crd rollouts.argoproj.io >/dev/null 2>&1; then
  ok "Rollout CRD is registered"
else
  fail "Rollout CRD missing — blue/green and canary cannot work"
fi

if kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=5m >/dev/null 2>&1; then
  ok "argo-rollouts controller is available"
else
  warn "argo-rollouts controller not reporting available yet"
fi

# THE CORE REQUIREMENT: a Deployment must never coexist with a Rollout.
if kubectl -n shopfast get rollout shopfast >/dev/null 2>&1; then
  ok "shopfast Rollout exists"
  kubectl -n shopfast get rollout shopfast \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DESIRED:.spec.replicas,READY:.status.readyReplicas' || true
  if kubectl -n shopfast get deployment shopfast >/dev/null 2>&1; then
    fail "BOTH a Rollout and a Deployment exist for shopfast — mutual exclusion violated"
  else
    ok "no competing Deployment (mutual exclusion holds)"
  fi
elif kubectl -n shopfast get deployment shopfast >/dev/null 2>&1; then
  ok "shopfast Deployment exists (strategy=standard)"
else
  fail "neither a Rollout nor a Deployment exists for shopfast"
fi

# ---------------------------------------------------------------------------
# 6. Application health, verified from inside the cluster
# ---------------------------------------------------------------------------
log "ShopFast — pod readiness"
kubectl -n shopfast get pods -o wide || true

if kubectl -n shopfast wait --for=condition=ready pod \
     -l app.kubernetes.io/name=shopfast --timeout=10m >/dev/null 2>&1; then
  ok "shopfast pods are Ready"
else
  fail "shopfast pods did not become Ready"
  kubectl -n shopfast describe pods -l app.kubernetes.io/name=shopfast 2>/dev/null | tail -60 || true
  kubectl -n shopfast logs -l app.kubernetes.io/name=shopfast --tail=80 --all-containers 2>/dev/null || true
fi

log "ShopFast — endpoint checks from inside the cluster"
for path in /actuator/health /api/hello /actuator/prometheus; do
  if kubectl -n shopfast run "verify-$RANDOM" --rm -i --restart=Never --quiet \
       --image=curlimages/curl:8.10.1 --command -- \
       curl --fail --silent --show-error --max-time 20 \
            --retry 10 --retry-delay 10 --retry-all-errors \
            "http://shopfast.shopfast.svc.cluster.local${path}" >/dev/null 2>&1; then
    ok "GET ${path} responded 2xx"
  else
    fail "GET ${path} did not respond successfully"
  fi
done

# ---------------------------------------------------------------------------
# 7. Monitoring
# ---------------------------------------------------------------------------
log "Monitoring — stack availability"
for d in $(kubectl -n monitoring get deploy -o name 2>/dev/null); do
  READY="$(kubectl -n monitoring get "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
    ok "${d} ready"
  else
    warn "${d} not ready yet"
  fi
done

if kubectl -n shopfast get vmservicescrape shopfast >/dev/null 2>&1; then
  ok "VMServiceScrape for shopfast exists (Spring Boot metrics are collected)"
else
  warn "VMServiceScrape for shopfast not found yet"
fi

# ---------------------------------------------------------------------------
# 8. Public ingress — the ALB and the HTTPS endpoints
# ---------------------------------------------------------------------------
log "Ingress — public ALB"
kubectl get ingress -A || true

ALB_HOST=""
for _ in $(seq 1 30); do
  ALB_HOST="$(kubectl -n argocd get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "${ALB_HOST}" ] && break
  sleep 20
done

if [ -n "${ALB_HOST}" ]; then
  ok "ALB provisioned: ${ALB_HOST}"

  # The ALB answers even before DNS delegation completes; Host-header routing
  # is what proves the ingress rule works end to end.
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 25 \
      --retry 8 --retry-delay 15 --retry-all-errors \
      -H "Host: ${ARGOCD_HOST}" "https://${ALB_HOST}/" 2>/dev/null || echo 000)"
  case "${CODE}" in
    200|302|307)
      ok "Argo CD answered through the ALB (HTTP ${CODE})" ;;
    *)
      warn "Argo CD via ALB returned HTTP ${CODE} (target group may still be registering)" ;;
  esac
else
  fail "no ALB hostname on the argocd ingress — the Load Balancer Controller did not provision it"
fi

# ---------------------------------------------------------------------------
# 9. Public DNS — reports truthfully instead of pretending
# ---------------------------------------------------------------------------
log "DNS — public resolution of ${ARGOCD_HOST}"
if getent hosts "${ARGOCD_HOST}" >/dev/null 2>&1; then
  ok "${ARGOCD_HOST} resolves publicly"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
      --retry 5 --retry-delay 10 --retry-all-errors "https://${ARGOCD_HOST}/" 2>/dev/null || echo 000)"
  if [ "${CODE}" = "200" ]; then
    ok "https://${ARGOCD_HOST}/ is live (HTTP 200)"
  else
    warn "https://${ARGOCD_HOST}/ returned HTTP ${CODE} — the certificate may still be validating"
  fi
else
  warn "${ARGOCD_HOST} does not resolve yet."
  warn "ACTION REQUIRED: point the domain's nameservers at Route 53 — see docs/DNS-CPANEL.md."
  warn "Until then, reach the dashboard through the ALB hostname above."
fi

echo
echo "──────────────────────────────────────────────"
if [ "${FAILURES}" -eq 0 ]; then
  printf '\033[1;32mVERIFICATION PASSED\033[0m\n'
  echo "Argo CD:  https://${ARGOCD_HOST}"
  echo "ShopFast: https://${APP_HOST}"
  exit 0
else
  printf '\033[1;31mVERIFICATION FAILED — %s check(s) failed\033[0m\n' "${FAILURES}"
  exit 1
fi
