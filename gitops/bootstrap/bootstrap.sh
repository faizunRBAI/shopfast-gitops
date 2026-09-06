#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cluster bootstrap — runs in the CI `configure` stage.
#
# Installs the minimum needed for GitOps to take over, then gets out of the way:
#   1. AWS Load Balancer Controller  (so Ingress -> real public ALB)
#   2. Default StorageClass          (so PVCs bind to the EBS CSI driver)
#   3. Argo CD                       (self-managed, HTTPS ingress, authenticated)
#   4. Root App-of-Apps              (from then on, git is the source of truth)
#
# Everything else — Argo Rollouts, monitoring, dashboards, ShopFast — is created
# by Argo CD from gitops/apps/children/. This script never installs them directly.
#
# SINGLE WRITER RULE — the hard lesson of this project
#   This script must NEVER modify a field of an Application that the root
#   App-of-Apps also reconciles from git. Root renders the children from the
#   repository, so anything injected into the live object here is reverted on
#   root's next sync, leaving the Application with whatever git actually says.
#   When git held an unresolved placeholder, every child reported
#   "repository not found" and no workload was ever created.
#
#   So the manifests under gitops/apps/ carry their REAL values, committed.
#   Nothing is substituted at apply time; this script only applies them.
#   scripts/verify-gitops-manifests.sh enforces that in the security stage.
#
#   Environment-specific values for the ShopFast chart (image tag, ACM
#   certificate ARN) live in gitops/applications/shopfast/values.yaml, written
#   by CI in the build_push stage and committed — the one place both root and
#   child read from.
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
# 2. Default StorageClass
# ---------------------------------------------------------------------------
# EKS's built-in gp2 class is not marked default, so a PVC that does not name a
# storageClassName binds to nothing and its pod stays Pending forever with
# "unbound immediate PersistentVolumeClaims". Grafana and VictoriaMetrics both
# request storage without naming a class. This must be applied BEFORE Argo CD
# syncs the monitoring stack.
log "Applying the default gp3 StorageClass (EBS CSI)"
kubectl apply -f gitops/bootstrap/storageclass.yaml

# Exactly one class may be default. If the legacy gp2 class is also marked
# default, Kubernetes picks arbitrarily between them.
if [ "$(kubectl get storageclass gp2 \
          -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' \
          2>/dev/null)" = "true" ]; then
  kubectl annotate storageclass gp2 \
    storageclass.kubernetes.io/is-default-class=false --overwrite
  log "Cleared the default flag on the legacy gp2 StorageClass"
fi

DEFAULT_SC="$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
log "Default StorageClass: ${DEFAULT_SC:-NONE}"
[ -n "${DEFAULT_SC}" ] || die "no default StorageClass — PVCs will never bind"

# ---------------------------------------------------------------------------
# 3. Argo CD
# ---------------------------------------------------------------------------
log "Installing Argo CD (${ARGOCD_CHART_VERSION})"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

# Render chart values (hostname + certificate ARN) into a temp file OUTSIDE the
# repo. This file contains no credentials.
#
# Substituting here is correct for Argo CD's OWN ingress: this script is the
# single writer for the argocd helm release, and no Application reconciles it.
# That is NOT true of the child Applications.
VALUES_FILE="$(mktemp)"
HASH_FILE="$(mktemp)"
chmod 600 "${HASH_FILE}"
cleanup() { rm -f "${VALUES_FILE}" "${HASH_FILE}"; }
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
# 4. Grafana admin credentials (generated in-cluster, never in git)
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
# 5. Hand over to GitOps
# ---------------------------------------------------------------------------
# The ShopFast chart reads its image tag and certificate ARN from the values
# file CI commits. Check it is populated so a missing HTTPS listener is
# explained here rather than discovered later on the load balancer.
SHOPFAST_VALUES="gitops/applications/shopfast/values.yaml"
if grep -Eq '^[[:space:]]+certificateArn:[[:space:]]*"arn:aws:acm:' "${SHOPFAST_VALUES}"; then
  log "ShopFast values carry the certificate ARN from git"
else
  warn "certificateArn is not set in ${SHOPFAST_VALUES}."
  warn "The ShopFast ingress will come up without an HTTPS listener until the"
  warn "build_push stage commits the ARN. This is expected on a first bootstrap."
fi

log "Applying child Applications"
for f in gitops/apps/children/*.yaml; do
  kubectl apply -n argocd -f "$f"
done

log "Applying the root App-of-Apps (git becomes the source of truth)"
kubectl apply -n argocd -f gitops/apps/root-app.yaml

log "Waiting for the root application to register"
for _ in $(seq 1 30); do
  kubectl -n argocd get application root >/dev/null 2>&1 && break
  sleep 5
done

# An Application created by an EARLIER bootstrap may still carry the helm
# parameters that older revision injected at apply time. Git no longer contains
# them, so strip them once; from here on nothing re-adds them.
log "Clearing legacy apply-time helm parameters from the shopfast Application"
if kubectl -n argocd get application shopfast \
     -o jsonpath='{.spec.source.helm.parameters}' 2>/dev/null | grep -q 'certificateArn'; then
  kubectl -n argocd patch application shopfast --type=json \
    -p '[{"op":"remove","path":"/spec/source/helm/parameters"}]' && \
    log "Removed the legacy helm parameters"
else
  log "No legacy helm parameters present"
fi

kubectl -n argocd get applications -o wide || true

log "Bootstrap complete — Argo CD now reconciles the cluster from git"
