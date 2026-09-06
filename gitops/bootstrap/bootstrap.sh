#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cluster bootstrap — runs in the CI `configure` stage.
#
# Installs the minimum needed for GitOps to take over, then gets out of the way:
#   1. AWS Load Balancer Controller  (so Ingress -> real public ALB)
#   2. Argo CD                       (self-managed, HTTPS ingress, authenticated)
#   3. Root App-of-Apps              (from then on, git is the source of truth)
#
# Everything else — Argo Rollouts, monitoring, dashboards, ShopFast — is created
# by Argo CD from gitops/apps/children/. This script never installs them directly.
#
# CREDENTIAL HANDLING: no credential value is ever assigned to a shell variable,
# written to a file inside the repo, or echoed. Values move from the CI
# environment straight into stdin of the tool that consumes them.
#
# Idempotent: safe to re-run on every deploy.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

: "${AWS_REGION:?AWS_REGION must be set}"
: "${ARGOCD_HOSTNAME:?ARGOCD_HOSTNAME must be set}"
: "${ARGOCD_ADMIN_PASSWORD:?ARGOCD_ADMIN_PASSWORD must be set}"
: "${GITOPS_REPO_URL:?GITOPS_REPO_URL must be set}"
: "${CERT_ARN:?CERT_ARN must be set}"

ARGOCD_CHART_VERSION="7.7.11"
ALB_CHART_VERSION="1.10.1"

# ---------------------------------------------------------------------------
# Preconditions — verify, never assume.
# ---------------------------------------------------------------------------
log "Verifying cluster connectivity"
kubectl version -o yaml >/dev/null || die "cannot reach the Kubernetes API server"
kubectl get nodes -o wide

READY_NODES="$(kubectl get nodes --no-headers -o custom-columns=S:.status.conditions[-1].type 2>/dev/null | grep -c '^Ready$' || true)"
[ "${READY_NODES}" -gt 0 ] || die "no Ready nodes — the node group has not joined the cluster"
log "${READY_NODES} node(s) Ready"

# ---------------------------------------------------------------------------
# 1. AWS Load Balancer Controller
# ---------------------------------------------------------------------------
log "Resolving infrastructure values from terraform state"
pushd infra >/dev/null
ALB_ROLE_ARN="$(terraform output -raw alb_controller_role_arn)"
VPC_ID="$(terraform output -raw vpc_id)"
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
popd >/dev/null
[ -n "${ALB_ROLE_ARN}" ] || die "alb_controller_role_arn output is empty"
[ -n "${CLUSTER_NAME}" ] || die "eks_cluster_name output is empty"

log "Installing AWS Load Balancer Controller (${ALB_CHART_VERSION}) on ${CLUSTER_NAME}"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null

kubectl create serviceaccount aws-load-balancer-controller \
  -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system "eks.amazonaws.com/role-arn=${ALB_ROLE_ARN}" --overwrite

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${ALB_CHART_VERSION}" \
  --set "clusterName=${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "region=${AWS_REGION}" \
  --set "vpcId=${VPC_ID}" \
  --wait --timeout 10m

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m

# ---------------------------------------------------------------------------
# 2. Argo CD
# ---------------------------------------------------------------------------
log "Installing Argo CD (${ARGOCD_CHART_VERSION})"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

# Render chart values (hostname + certificate ARN) into a temp file OUTSIDE the
# repo. This file contains no credentials.
VALUES_FILE="$(mktemp)"
HASH_FILE="$(mktemp)"
RENDER_DIR="$(mktemp -d)"
chmod 600 "${HASH_FILE}"
cleanup() { rm -f "${VALUES_FILE}" "${HASH_FILE}"; rm -rf "${RENDER_DIR}"; }
trap cleanup EXIT

sed -e "s|__ARGOCD_HOSTNAME__|${ARGOCD_HOSTNAME}|g" \
    -e "s|__CERT_ARN__|${CERT_ARN}|g" \
    gitops/bootstrap/argocd-values.yaml > "${VALUES_FILE}"

# Argo CD stores the admin credential as a bcrypt hash. The hash is derived from
# the CI environment variable and written only to a 0600 temp file, which helm
# reads via a values file. The plaintext is never stored, logged, or committed.
log "Deriving the Argo CD admin credential hash"
python3 -m pip install --quiet --disable-pip-version-check bcrypt >/dev/null 2>&1 || \
  die "could not install the bcrypt module required to derive the credential hash"

python3 - "${HASH_FILE}" <<'PY'
import os, sys, bcrypt, json
digest = bcrypt.hashpw(os.environ["ARGOCD_ADMIN_PASSWORD"].encode(),
                       bcrypt.gensalt(rounds=10)).decode()
# Written as a helm values overlay so the value never appears on a command line
# (argv is world-readable via /proc on a shared runner).
with open(sys.argv[1], "w") as fh:
    json.dump({"configs": {"secret": {"argocdServerAdminPassword": digest}}}, fh)
PY

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --values "${HASH_FILE}" \
  --wait --timeout 15m

kubectl -n argocd rollout status deploy/argocd-server --timeout=10m

# ---------------------------------------------------------------------------
# 3. Grafana admin credentials (generated in-cluster, never in git)
# ---------------------------------------------------------------------------
log "Ensuring Grafana admin credentials secret"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n monitoring get secret grafana-admin-credentials >/dev/null 2>&1; then
  log "grafana-admin-credentials already exists — leaving it untouched"
else
  # Generated and piped straight into kubectl; never bound to a shell variable.
  kubectl -n monitoring create secret generic grafana-admin-credentials \
    --from-literal=admin-user=admin \
    --from-file=admin-password=<(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  log "Created grafana-admin-credentials (retrieve it with the command in the README)"
fi

# ---------------------------------------------------------------------------
# 4. Inject runtime values into the GitOps manifests, then hand over
# ---------------------------------------------------------------------------
# The committed manifests carry PLACEHOLDER_REPO_URL and an empty certificateArn
# so no environment-specific value is hardcoded in git. Both are resolved here,
# at apply time, from terraform state and CI env.
log "Rendering GitOps manifests with the resolved repo URL"
for f in gitops/apps/root-app.yaml gitops/apps/children/*.yaml; do
  sed "s|PLACEHOLDER_REPO_URL|${GITOPS_REPO_URL}|g" "$f" > "${RENDER_DIR}/$(basename "$f")"
done

# The ShopFast Application needs the ACM cert ARN for its ingress. Passed as a
# Helm parameter on the Application so the value stays out of the repo.
python3 - "${RENDER_DIR}/shopfast.yaml" "${CERT_ARN}" <<'PY'
import sys, yaml
path, cert = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = yaml.safe_load(fh)
helm = doc["spec"]["source"].setdefault("helm", {})
params = [p for p in helm.get("parameters", []) if p.get("name") != "ingress.certificateArn"]
params.append({"name": "ingress.certificateArn", "value": cert})
helm["parameters"] = params
with open(path, "w") as fh:
    yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
print(f"injected ingress.certificateArn into {path}")
PY

log "Applying child Applications"
for f in "${RENDER_DIR}"/*.yaml; do
  [ "$(basename "$f")" = "root-app.yaml" ] && continue
  kubectl apply -n argocd -f "$f"
done

log "Applying the root App-of-Apps (git becomes the source of truth)"
kubectl apply -n argocd -f "${RENDER_DIR}/root-app.yaml"

log "Waiting for the root application to register"
for _ in $(seq 1 30); do
  kubectl -n argocd get application root >/dev/null 2>&1 && break
  sleep 5
done

kubectl -n argocd get applications -o wide || true

log "Bootstrap complete — Argo CD now reconciles the cluster from git"
