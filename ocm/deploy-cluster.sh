#!/usr/bin/env bash
# deploy-cluster.sh — Deploy greenhouse from scratch on a Kubernetes cluster.
#
# Suitable for both internet-connected and air-gapped environments.
# Flux and kro are extracted from the on-site OCM registry — no internet access required.
#
# RUN FROM THE REPO ROOT:
#   cd /path/to/greenhouse
#   ./ocm/deploy-cluster.sh
#
# REQUIRED environment variables:
#   KUBECONFIG              Path to the target cluster kubeconfig
#   ON_SITE_REGISTRY        Base OCI registry URL
#                           Connected:   ghcr.io/cloudoperators
#                           Air-gapped:  keppel.eu-de-1.cloud.sap/myspace
#   REGISTRY_USER           Username for the on-site registry
#   REGISTRY_TOKEN          Password / token for the on-site registry
#   GREENHOUSE_VALUES_YAML  Path to greenhouse-values.yaml (Helm values file)
#
# OPTIONAL environment variables:
#   COMPONENT_VERSION          Semver constraint (default: >=0.23.0)
#   POSTGRES_REGISTRY          Registry prefix for postgres images
#                              (default: ${ON_SITE_REGISTRY}/sapcc)
#   FLUX_VERSION               Must match version in the prereqs OCM bundle (default: 2.15.0)
#   KRO_VERSION                Must match version in the prereqs OCM bundle (default: 0.9.4)
#   PREREQS_BUNDLE_REGISTRY    Where the prerequisites OCM bundle was pushed.
#                              ghcr.io (default): ${ON_SITE_REGISTRY}/greenhouse-prerequisites
#                              Single registry (e.g. Keppel): set to ${ON_SITE_REGISTRY}
#   GH_BUNDLE_REGISTRY         Where the greenhouse OCM bundle was pushed.
#                              ghcr.io (default): ${ON_SITE_REGISTRY}/greenhouse
#                              Single registry (e.g. Keppel): set to ${ON_SITE_REGISTRY}
#
# TOOLS REQUIRED (must be on PATH):
#   kubectl, helm, ocm (v0.48+), jq

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
COMPONENT_VERSION="${COMPONENT_VERSION:->=0.23.0}"
FLUX_VERSION="${FLUX_VERSION:-2.15.0}"
KRO_VERSION="${KRO_VERSION:-0.9.4}"

# Two separate bundle registries (ghcr.io uses distinct repos per bundle;
# a single on-site registry like Keppel stores both under the same base URL).
PREREQS_BUNDLE_REGISTRY="${PREREQS_BUNDLE_REGISTRY:-${ON_SITE_REGISTRY}/greenhouse-prerequisites}"
GH_BUNDLE_REGISTRY="${GH_BUNDLE_REGISTRY:-${ON_SITE_REGISTRY}/greenhouse}"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
step() { echo -e "\n${BOLD}── $*${RESET}"; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
die()  { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────
step "Validating prerequisites"

for var in KUBECONFIG ON_SITE_REGISTRY REGISTRY_USER REGISTRY_TOKEN GREENHOUSE_VALUES_YAML; do
  [[ -n "${!var:-}" ]] || die "Required env var \$${var} is not set"
done

[[ -f "${GREENHOUSE_VALUES_YAML}" ]] || die "GREENHOUSE_VALUES_YAML file not found: ${GREENHOUSE_VALUES_YAML}"
[[ -d "ocm/deploy" ]]                || die "Run this script from the repo root (ocm/deploy/ not found)"

for tool in kubectl helm ocm jq; do
  command -v "${tool}" >/dev/null 2>&1 || die "Required tool '${tool}' not found on PATH"
done

POSTGRES_REGISTRY="${POSTGRES_REGISTRY:-${ON_SITE_REGISTRY}/sapcc}"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

ok "All checks passed"
echo "  ON_SITE_REGISTRY          = ${ON_SITE_REGISTRY}"
echo "  PREREQS_BUNDLE_REGISTRY   = ${PREREQS_BUNDLE_REGISTRY}"
echo "  GH_BUNDLE_REGISTRY        = ${GH_BUNDLE_REGISTRY}"
echo "  KUBECONFIG                = ${KUBECONFIG}"
echo "  VALUES                    = ${GREENHOUSE_VALUES_YAML}"

# ── Step 1: Verify cluster connectivity ───────────────────────────────────────
step "Step 1 — Verifying cluster connectivity"
kubectl cluster-info
ok "Cluster reachable"

# ── Step 2: Install Flux from on-site OCM registry ────────────────────────────
step "Step 2 — Installing Flux ${FLUX_VERSION} from on-site registry"

if kubectl get deployment helm-controller -n flux-system >/dev/null 2>&1; then
  ok "Flux already installed — skipping"
else
  echo "Downloading flux-install manifest from OCM registry..."
  OCM_REGISTRY_CREDS="${REGISTRY_USER}:${REGISTRY_TOKEN}" \
  ocm download resources \
    --repo "oci://${PREREQS_BUNDLE_REGISTRY}" \
    "github.com/cloudoperators/greenhouse/prerequisites/flux:${FLUX_VERSION}" \
    flux-install \
    -O "${TMP}/flux-install.yaml"

  kubectl apply -f "${TMP}/flux-install.yaml"
  kubectl rollout status deploy/source-controller -n flux-system --timeout=120s
  kubectl rollout status deploy/helm-controller   -n flux-system --timeout=120s
  ok "Flux installed"
fi

# ── Step 3: Grant helm-controller cluster-admin RBAC ─────────────────────────
step "Step 3 — Granting helm-controller cluster-admin RBAC"
kubectl create clusterrolebinding helm-controller-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:helm-controller \
  --dry-run=client -o yaml | kubectl apply -f -
ok "RBAC configured"

# ── Step 4: Install kro from on-site OCM registry ─────────────────────────────
step "Step 4 — Installing kro ${KRO_VERSION} from on-site registry"

if kubectl get deployment kro-controller-manager -n kro-system >/dev/null 2>&1; then
  ok "kro already installed — skipping"
else
  echo "Downloading kro chart from OCM registry..."
  OCM_REGISTRY_CREDS="${REGISTRY_USER}:${REGISTRY_TOKEN}" \
  ocm download resources \
    --repo "oci://${PREREQS_BUNDLE_REGISTRY}" \
    "github.com/cloudoperators/greenhouse/prerequisites/kro:${KRO_VERSION}" \
    kro-chart \
    -O "${TMP}/kro-chart.tgz"

  helm upgrade --install kro "${TMP}/kro-chart.tgz" \
    --namespace kro-system \
    --create-namespace \
    --wait --timeout 5m
  ok "kro installed"
fi

# ── Step 5: Namespace and registry secret ─────────────────────────────────────
step "Step 5 — Creating greenhouse namespace and registry secret"

kubectl create namespace greenhouse --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry greenhouse-ocm-registry-creds \
  --namespace greenhouse \
  --docker-server="${ON_SITE_REGISTRY%%/*}" \
  --docker-username="${REGISTRY_USER}" \
  --docker-password="${REGISTRY_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

ok "Namespace and registry secret ready"

# ── Step 6: Apply kro RGDs ────────────────────────────────────────────────────
step "Step 6 — Applying kro ResourceGraphDefinitions"
kubectl apply -k ocm/deploy/

echo "Waiting for GreenhouseBootstrap and GreenhouseStack CRDs..."
kubectl wait --for=condition=Established \
  crd/greenhousebootstraps.kro.run \
  crd/greenhousestacks.kro.run \
  --timeout=120s
ok "RGDs applied, CRDs registered"

# ── Step 7: Bootstrap prerequisites (cert-manager + OCM controller) ───────────
step "Step 7 — Applying GreenhouseBootstrap instance"

sed "s|<your-on-site-registry>|${PREREQS_BUNDLE_REGISTRY}|g" \
  ocm/deploy/bootstrap-instance.yaml | kubectl apply -f -

echo "Triggering immediate OCIRepository reconciliation..."
sleep 15
kubectl annotate ocirepository --all -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite 2>/dev/null || true

echo "Waiting for cert-manager HelmRelease (up to 5m)..."
kubectl wait helmrelease/cert-manager \
  --namespace greenhouse \
  --for=condition=Ready \
  --timeout=300s
ok "cert-manager ready"

echo "Waiting for OCM controller HelmRelease (up to 5m)..."
kubectl wait helmrelease/ocm-k8s-toolkit \
  --namespace greenhouse \
  --for=condition=Ready \
  --timeout=300s
ok "OCM controller ready"

# ── Step 8: Flux extension stubs ──────────────────────────────────────────────
step "Step 8 — Applying Flux extension stub CRDs"
# greenhouse controller-manager watches ArtifactGenerator.source.extensions.fluxcd.io.
# Without this stub CRD the controller enters CrashLoopBackOff on startup.
kubectl apply -f ocm/prereqs/flux-extension-stubs.yaml
ok "Flux extension stubs applied"

# ── Step 9: Greenhouse values secret ──────────────────────────────────────────
step "Step 9 — Creating greenhouse values secret"
kubectl create secret generic greenhouse-values \
  --namespace greenhouse \
  --from-file=values.yaml="${GREENHOUSE_VALUES_YAML}" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "Values secret created"

# ── Step 10: Deploy greenhouse stack ──────────────────────────────────────────
step "Step 10 — Applying GreenhouseStack instance"

# Read image digests from the on-site registry so instance.yaml is always in sync
# with what was actually transferred. Wrong digests cause NotFound pull errors.
# Mirrors what `make -f ocm/Makefile.ocm patch-instance` does.
step "  Reading image digests from on-site registry"
GH_VERSION=$(OCM_REGISTRY_CREDS="${REGISTRY_USER}:${REGISTRY_TOKEN}" \
  ocm get componentversion \
    --repo "oci://${GH_BUNDLE_REGISTRY}" \
    "github.com/cloudoperators/greenhouse" \
    -o json 2>/dev/null \
  | jq -r '[.items[].component.version] | sort | last' 2>/dev/null || echo "")

if [[ -n "${GH_VERSION}" ]]; then
  DIGESTS_JSON=$(OCM_REGISTRY_CREDS="${REGISTRY_USER}:${REGISTRY_TOKEN}" \
    ocm get resources \
      "oci://${GH_BUNDLE_REGISTRY}//github.com/cloudoperators/greenhouse/core:${GH_VERSION}" \
      -o json 2>/dev/null || echo "")
  GH_DIGEST=$(echo "${DIGESTS_JSON}" | jq -r \
    '.items[].element | select(.name=="greenhouse-image") | "sha256:" + .digest.value' \
    2>/dev/null || echo "")
  DB_DIGEST=$(echo "${DIGESTS_JSON}" | jq -r \
    '.items[].element | select(.name=="dashboard-image") | "sha256:" + .digest.value' \
    2>/dev/null || echo "")

  if [[ -n "${GH_DIGEST}" && -n "${DB_DIGEST}" ]]; then
    ok "  greenhouse-image: ${GH_DIGEST}"
    ok "  dashboard-image:  ${DB_DIGEST}"
    INSTANCE_PATCH_GH="s|greenhouseImageDigest:.*|greenhouseImageDigest: \"${GH_DIGEST}\"|"
    INSTANCE_PATCH_DB="s|dashboardImageDigest:.*|dashboardImageDigest:  \"${DB_DIGEST}\"|"
  else
    echo "  WARNING: could not read digests from on-site registry — using pinned values in instance.yaml"
    INSTANCE_PATCH_GH=""; INSTANCE_PATCH_DB=""
  fi
else
  echo "  WARNING: could not determine greenhouse version from on-site registry — using pinned values"
  INSTANCE_PATCH_GH=""; INSTANCE_PATCH_DB=""
fi

sed \
  -e "s|<your-on-site-registry>/<postgres-path-prefix>|${POSTGRES_REGISTRY}|g" \
  -e "s|<your-on-site-registry>|${GH_BUNDLE_REGISTRY}|g" \
  ${INSTANCE_PATCH_GH:+-e "${INSTANCE_PATCH_GH}"} \
  ${INSTANCE_PATCH_DB:+-e "${INSTANCE_PATCH_DB}"} \
  ocm/deploy/instance.yaml | kubectl apply -f -

# Wait for kro to expand the GreenhouseStack into the HelmRelease chain.
echo "Waiting for HelmRelease/greenhouse to be created by kro..."
until kubectl get helmrelease greenhouse -n greenhouse >/dev/null 2>&1; do
  echo "  waiting for HelmRelease/greenhouse..."
  sleep 10
done
ok "HelmRelease/greenhouse created"

# Patch imagePullSecrets on all ServiceAccounts.
# The greenhouse chart does not propagate global.imagePullSecrets to all subcharts.
# Without this, pods start in ImagePullBackOff on the first install attempt.
step "Patching imagePullSecrets on all ServiceAccounts"

# Delete stale webhook configs from any prior failed install.
# They intercept SA patch requests and reject them with "service not found".
kubectl delete validatingwebhookconfiguration \
  greenhouse-validating-webhook-configuration --ignore-not-found 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration \
  greenhouse-mutating-webhook-configuration --ignore-not-found 2>/dev/null || true

for sa in $(kubectl get serviceaccount -n greenhouse \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl patch serviceaccount "${sa}" -n greenhouse --type=merge \
    -p '{"imagePullSecrets":[{"name":"greenhouse-ocm-registry-creds"}]}' \
    >/dev/null 2>&1 || true
done
kubectl rollout restart deployment -n greenhouse 2>/dev/null || true
ok "imagePullSecrets patched"

# ── Step 11: Wait for greenhouse ──────────────────────────────────────────────
step "Step 11 — Waiting for greenhouse HelmRelease (up to 10m)"
kubectl wait helmrelease/greenhouse \
  --namespace greenhouse \
  --for=condition=Ready \
  --timeout=600s
ok "greenhouse HelmRelease ready"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verify"
echo ""
echo "=== HelmReleases ==="
kubectl get helmrelease -n greenhouse

echo ""
echo "=== Pods (greenhouse) ==="
kubectl get pods -n greenhouse

echo ""
echo "=== GreenhouseStack ==="
kubectl get greenhousestack greenhouse -n greenhouse 2>/dev/null \
  || echo "(GreenhouseStack not found — kro status may still be reconciling)"

echo ""
ok "Deploy complete."
