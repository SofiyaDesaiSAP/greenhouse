# Greenhouse OCM + Flux Deployment Guide

Deploy Greenhouse on a Kubernetes cluster using OCM (Open Component Model) as the artifact
distribution layer and Flux as the deployment engine. A kro `GreenhouseBootstrap` RGD
installs prerequisites from the RBSC; a `GreenhouseStack` RGD installs greenhouse itself via
OCM Snapshots.

---

## Architecture

```
CTF archive (local)
   └─ umbrella component: github.com/cloudoperators/greenhouse:0.23.0
        ├─ core (greenhouse chart + image)
        ├─ prerequisites/cert-manager      (access.type: ociArtifact)
        ├─ prerequisites/ocm-controller    (access.type: ociArtifact)
        ├─ prerequisites/flux
        ├─ prerequisites/kro
        └─ kro-rgd (GreenhouseStack ResourceGraphDefinition)

ocm transfer --copy-resources CTF → ghcr.io/sofiyadesaisap/greenhouse-rbsc (RBSC)
   └─ path-preservation: cert-manager lands at rbsc/cloudoperators/greenhouse-extensions/charts/cert-manager
      ocm-controller lands at rbsc/open-component-model/helm/ocm-controller

Cluster bootstrap:
  Flux + kro (direct Helm, once)
       └─ GreenhouseBootstrap RGD → cert-manager + ocm-controller OCIRepositories → HelmReleases
              └─ OCM controller running → reconciles ComponentVersion → Snapshots
                     └─ GreenhouseStack RGD → greenhouse OCIRepository → HelmRelease
```

---

## Prerequisites

| Tool | Min version |
|---|---|
| `kubectl` | 1.28+ |
| `helm` | 3.14+ |
| `flux` CLI | 2.x |
| `ocm` CLI | 0.48+ |
| GitHub PAT | `write:packages` to push, `read:packages` to pull |

**Session setup — run once at the start:**

```bash
cd /path/to/greenhouse/ocm

export GITHUB_TOKEN=$(gh auth token --hostname github.com)
export GITHUB_USER=sofiyadesaisap
export KUBECONFIG=/path/to/cluster-kubeconfig.yaml
```

---

## Part 0 — Build and Distribute the OCM Bundle *(before demo / before deploy)*

### Step 1 — Resolve helm chart dependencies

```bash
helm dependency update ../charts/greenhouse
```

### Step 2 — Build the multi-component CTF archive

Before building, verify `GREENHOUSE_VERSION` matches the chart's `version:` field:

```bash
grep "^version:" ../charts/greenhouse/Chart.yaml
# must match GREENHOUSE_VERSION below — Flux validates these match at deploy time
```

```bash
rm -rf greenhouse-bundle.ctf

ocm add componentversions \
  --addenv \
  --file greenhouse-bundle.ctf \
  --create \
  component-constructor.yaml \
  GREENHOUSE_VERSION=0.23.0 \
  "GREENHOUSE_IMAGE_REF=ghcr.io/cloudoperators/greenhouse:v0.16.1" \
  "DASHBOARD_IMAGE_REF=ghcr.io/cloudoperators/juno-app-greenhouse@sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631" \
  CERT_MANAGER_VERSION=1.20.1 \
  FLUX_VERSION=2.15.0 \
  KRO_VERSION=0.9.4 \
  OCM_CONTROLLER_VERSION=0.33.0
```

<img width="991" height="719" alt="Screenshot 2026-10-12 at 16 44 47" src="https://github.com/user-attachments/assets/3132b50d-87ef-4c55-92f3-2e060d948807" />


### Step 3 — Sign the bundle (keyless / Sigstore)

```bash
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse:0.23.0
```
<img width="1748" height="579" alt="image" src="https://github.com/user-attachments/assets/91ccc43f-e554-4391-833a-eeaf6029d216" />

Browser opens for OIDC login. One signature covers the entire bundle transitively.

**Screenshot placeholder — sign output showing `Verification succeeded` + identity:**

<img width="411" height="335" alt="image" src="https://github.com/user-attachments/assets/8f601a2b-2b02-4a6b-9779-74743ec076a6" />

<img width="1745" height="188" alt="image" src="https://github.com/user-attachments/assets/97361f5a-406f-4f56-8a55-6d937df8992f" />


### Step 4 — Push CTF to GHCR (central registry)

```bash
GITHUB_TOKEN=$GITHUB_TOKEN ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/sofiyadesaisap/greenhouse
```

Verify all 6 components landed:

```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.23.0" \
  --recursive
```

ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.23.0" \
  --recursive

<img width="1100" height="143" alt="image" src="https://github.com/user-attachments/assets/69a063bf-0858-444c-ba73-ee4fb6b8bbc0" />

### Step 5 — Verify signature, then transfer to RBSC (on-site / air-gap registry)

```bash
# Integrity gate: verify before crossing the air-gap boundary
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://ghcr.io/sofiyadesaisap/greenhouse \
  github.com/cloudoperators/greenhouse:0.23.0
```

**Screenshot placeholder — `Verification succeeded` output:**

If rebuilding after a change to `component-constructor.yaml`, delete stale RBSC packages
for cert-manager and ocm-controller first (OCM skips re-transfer of "already present"
components by content digest — see Troubleshooting):

```bash
for pkg in \
  "greenhouse-rbsc/github.com/cloudoperators/greenhouse/prerequisites/cert-manager/cert-manager" \
  "greenhouse-rbsc/component-descriptors/github.com/cloudoperators/greenhouse/prerequisites/cert-manager" \
  "greenhouse-rbsc/github.com/cloudoperators/greenhouse/prerequisites/ocm-controller/ocm-controller" \
  "greenhouse-rbsc/component-descriptors/github.com/cloudoperators/greenhouse/prerequisites/ocm-controller"; do
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$pkg")
  result=$(gh api --method DELETE "/user/packages/container/${encoded}" 2>&1)
  [[ -z "$result" ]] && echo "✓ deleted: $pkg" || echo "✗ not found (ok): $pkg"
done
```

Transfer from CTF directly to RBSC (not through GHCR, which may have stale descriptors):

```bash
GITHUB_TOKEN=$(gh auth token) ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc
```

**Screenshot placeholder — transfer output showing cert-manager + ocm-controller at correct paths:**

Verify 6 components in RBSC:

```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc//github.com/cloudoperators/greenhouse:0.23.0" \
  --recursive
```

---

## Part 1 — Cluster Bootstrap

> Flux and kro are the only direct Helm installs. Everything else goes through kro.

### Step 1 — Install Flux

```bash
flux install

kubectl rollout status deploy/source-controller -n flux-system --timeout=120s
kubectl rollout status deploy/helm-controller   -n flux-system --timeout=120s
```

**Screenshot placeholder — Flux rollout status output:**

### Step 2 — Install kro

```bash
helm upgrade --install kro \
  oci://registry.k8s.io/kro/charts/kro \
  --namespace kro-system \
  --create-namespace \
  --version 0.9.4 \
  --wait --timeout 5m
```

### Step 3 — Grant helm-controller RBAC

```bash
kubectl create clusterrolebinding helm-controller-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:helm-controller \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 4 — Create namespace and registry secret

The registry secret is needed for both the bootstrap OCIRepositories (cert-manager, OCM
controller pulling from RBSC) and the OCM controller (pulling the bundle from RBSC).

```bash
kubectl create namespace greenhouse --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry greenhouse-ocm-registry-creds \
  --namespace greenhouse \
  --docker-server=ghcr.io \
  --docker-username=$GITHUB_USER \
  --docker-password=$GITHUB_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 5 — Apply kro RGDs

```bash
kubectl apply -k deploy/
```

This creates: namespace (idempotent), `GreenhouseStack` RGD, `GreenhouseBootstrap` RGD.
kro processes both RGDs immediately and registers their CRDs.

`componentversion.yaml` and `resources.yaml` are intentionally excluded — their CRDs
(`ComponentVersion`, `Resource`) don't exist until the OCM controller is running.

**Screenshot placeholder — `kubectl apply -k deploy/` output:**

### Step 6 — Apply the bootstrap instance

Wait for the `GreenhouseBootstrap` CRD:

```bash
kubectl get crd greenhousebootstraps.kro.run
```

Apply:

```bash
kubectl apply -f deploy/bootstrap-instance.yaml
```

kro expands this into:

```
OCIRepository/prometheus-crds-bootstrap  → oci://ghcr.io/prometheus-community/...  (public OCI — exception)
OCIRepository/cert-manager-bootstrap     → oci://<rbscRegistry>/cloudoperators/greenhouse-extensions/charts/cert-manager
OCIRepository/ocm-controller-bootstrap   → oci://<rbscRegistry>/open-component-model/helm/ocm-controller

HelmRelease/prometheus-crds   → monitoring ns
HelmRelease/cert-manager      → cert-manager ns   (parallel with prometheus-crds)
HelmRelease/ocm-controller    → ocm-system ns     (dependsOn: cert-manager)
```

Trigger immediate reconciliation (don't wait for the 10m interval):

```bash
kubectl annotate ocirepository cert-manager-bootstrap -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate ocirepository ocm-controller-bootstrap -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

Watch the bootstrap:

```bash
kubectl get helmreleases -n greenhouse -w
```

Expected order: `prometheus-crds` + `cert-manager` Ready (parallel), then `ocm-controller` Ready.

**Screenshot placeholder — all three bootstrap HelmReleases Ready:**

### Step 7 — Apply Flux extension stub CRDs

```bash
kubectl apply -f prereqs/flux-extension-stubs.yaml
```

Greenhouse controller-manager watches `ArtifactGenerator.source.extensions.fluxcd.io`.
Without this stub CRD it enters `CrashLoopBackOff` on startup.

### Step 8 — Copy the OCM TLS certificate

Wait for the OCM controller to generate the TLS secret:

```bash
kubectl get secret ocm-registry-tls-certs -n ocm-system
```

Copy it to the greenhouse namespace:

```bash
kubectl get secret ocm-registry-tls-certs -n ocm-system -o json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['metadata'] = {'name': d['metadata']['name'], 'namespace': 'greenhouse'}
print(json.dumps(d))
" \
  | kubectl apply -f -
```

---

## Part 2 — Remaining Secrets

Namespace and registry secret were created in Part 1. Only the values secret remains.

### Prepare `greenhouse-values.yaml`

Minimal working config (no ingress, no OIDC, no postgres):

```yaml
global:
  dnsDomain: greenhouse.example.com
  imagePullSecrets:
    - name: greenhouse-ocm-registry-creds
  oidc:
    enabled: false
  ingress:
    enabled: false
  postgresql:
    enabled: false
  registry: ghcr.io
  monitoring:
    enabled: false
  dex:
    backend: kubernetes   # NOT postgres (needs pguser secret) and NOT memory (invalid)

idproxy:
  enabled: false
# NOTE: the correct key is proxy.enabled, NOT corsProxy.enabled
# Using corsProxy: enabled: false is silently ignored — cors-proxy will still deploy
proxy:
  enabled: false
authz:
  enabled: false
controllerManager:
  enabled: true
  replicaCount: 1
  monitoring:
    enabled: false

postgresqlng:
  enabled: false
dashboard:
  enabled: false
```

Create the secret:

```bash
kubectl create secret generic greenhouse-values \
  --namespace greenhouse \
  --from-file=values.yaml=greenhouse-values.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Part 3 — Deploy *(the demo moment)*

### Step 1 — Apply OCM CRs

The OCM controller CRDs are now registered:

```bash
kubectl apply -f deploy/componentversion.yaml
kubectl apply -f deploy/resources.yaml
```

**Screenshot placeholder — `kubectl apply` output:**

### Step 2 — Watch OCM resolve the bundle

```bash
kubectl get componentversion,resource -n greenhouse
```

Wait for `ComponentVersion` `READY=True` and all 5 `Resource` objects `READY=True`.

**Screenshot placeholder — all resources Ready:**

### Step 3 — Get Snapshot paths

```bash
kubectl get snapshot -n greenhouse \
  -o custom-columns='RESOURCE:.metadata.ownerReferences[0].name,REPO:.status.repositoryURL,TAG:.status.tag'
```

Output:

```
RESOURCE               REPO                      TAG
cert-manager-chart     sha-15031618658884295978   1.20.1
kro-chart              sha-<hash>                 0.9.4
ocm-controller-chart   sha-3868847230746277828    0.33.0
greenhouse-chart       sha-12147715848810698429   0.23.0
greenhouse-stack-rgd   sha-<hash>                 0.23.0
```

The `sha-NNNN` values are cluster-specific and change between deploys.

**Screenshot placeholder — snapshot output:**

### Step 4 — Update `deploy/instance.yaml`

Fill in the snapshot paths from above:

```yaml
spec:
  registryHost: "registry.ocm-system.svc.cluster.local:5000"
  imageRegistry: "ghcr.io/sofiyadesaisap/greenhouse-rbsc"

  certManagerSnapshotPath: "sha-15031618658884295978"
  certManagerVersion: "1.20.1"

  ocmControllerSnapshotPath: "sha-3868847230746277828"
  ocmControllerVersion: "0.33.0"

  greenhouseSnapshotPath: "sha-12147715848810698429"
  greenhouseVersion: "0.23.0"

  greenhouseImageDigest: "sha256:0c0cac95a1dafbb9a22d64aaf3cc425e990f2eb9b7863b3e53749e2878472b13"
  dashboardImageDigest: "sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631"

  tlsSecretName: "ocm-registry-tls-certs"
  valuesSecretName: "greenhouse-values"
```

### Step 5 — Patch ServiceAccounts with imagePullSecrets

The `manager` subchart has no `imagePullSecrets` template — `global.imagePullSecrets` in
values does not propagate to it. Pods will hit `401 Unauthorized` without this patch.

Delete any stale webhook configurations from a previous failed install first (a stale
webhook intercepts SA patches and rejects them with "service not found"):

```bash
kubectl delete validatingwebhookconfiguration greenhouse-validating-webhook-configuration --ignore-not-found
kubectl delete mutatingwebhookconfiguration greenhouse-mutating-webhook-configuration --ignore-not-found
```

Patch all ServiceAccounts in the namespace:

```bash
for sa in $(kubectl get serviceaccount -n greenhouse -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch serviceaccount "$sa" -n greenhouse --type=merge \
    -p '{"imagePullSecrets":[{"name":"greenhouse-ocm-registry-creds"}]}'
done
```

Re-run this patch after any Helm upgrade that recreates ServiceAccounts.

### Step 6 — Apply the GreenhouseStack instance

Wait for the `GreenhouseStack` CRD (kro created it when it processed `kro-rgd.yaml`):

```bash
kubectl get crd greenhousestacks.kro.run
```

Apply:

```bash
kubectl apply -f deploy/instance.yaml
```

kro expands this into OCIRepositories + HelmReleases that install in order:
cert-manager → ocm-controller → greenhouse (all pulling from OCM Snapshots).

Watch:

```bash
kubectl get helmreleases -n greenhouse -w
```

**Screenshot placeholder — greenhouse HelmRelease `Helm install succeeded`:**

---

## Part 4 — Verify

### Full status check

```bash
kubectl get componentversion,resource,greenhousestack,helmrelease -n greenhouse
kubectl get pods -n greenhouse
kubectl get pods -n cert-manager
kubectl get pods -n ocm-system
kubectl get pods -n kro-system
kubectl get pods -n flux-system
```

Expected final state:

```
ComponentVersion:  greenhouse        Ready=True   0.23.0
Resources:         all 5             Ready=True
GreenhouseStack:   greenhouse        ACTIVE
HelmReleases:      cert-manager      Ready=True
                   ocm-controller    Ready=True
                   greenhouse        Ready=True
Pods (greenhouse): controller-manager ×3, cors-proxy ×2, webhook ×2  — Running
Pods (cert-manager): controller, cainjector, webhook                  — Running
Pods (ocm-system):   ocm-controller, registry                         — Running
Pods (kro-system):   kro                                              — Running
Pods (flux-system):  helm, source, kustomize, notification            — Running
```

**Screenshot placeholder — full status output:**

### Prove zero external registry dependency

```bash
kubectl get pods -n greenhouse \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

Every line must start with `ghcr.io/sofiyadesaisap/greenhouse-rbsc/`.

**Screenshot placeholder — all images from RBSC:**

---

## Acceptance Criteria — Final Checklist

| Criterion | Evidence |
|---|---|
| ✅ greenhouse chart as OCM artifact | `ocm get componentversions --recursive` shows 6 components in GHCR and RBSC |
| ✅ prerequisites are part of the artifact | Same bundle contains cert-manager, Flux, kro, OCM controller as separate component versions |
| ✅ core components installable via OCM | `GreenhouseStack ACTIVE`, all HelmReleases `Ready=True`, pods Running — all images from RBSC |

---

## Troubleshooting

### cert-manager / ocm-controller HelmRelease stuck: MANIFEST_UNKNOWN

OCM compares component versions by content digest only. If these components were previously
transferred with `input.type: helm` (old approach), their descriptors are "already present"
even after switching to `access.type: ociArtifact` — OCM skips them and chart blobs never
land at the bootstrap OCIRepository paths.

**Fix:** Delete the stale RBSC packages (see Part 0 Step 5 delete loop), then re-run the
CTF → RBSC transfer and annotate the OCIRepositories to force immediate reconciliation.

---

### `ImagePullBackOff` on greenhouse pods: 401 Unauthorized from RBSC

**Cause:** ServiceAccounts in the greenhouse namespace have no `imagePullSecrets`. The
`manager` subchart does not support `global.imagePullSecrets` propagation.

**Fix:** Delete stale webhook configs, then run the SA patch loop (Part 3 Step 5).

---

### SA patch rejected: "service greenhouse-webhook-service not found"

**Cause:** A prior failed Helm install left `greenhouse-validating-webhook-configuration`
and `greenhouse-mutating-webhook-configuration` in the cluster. The webhook intercepts SA
patches and rejects them because the webhook service was never created.

**Fix:**
```bash
kubectl delete validatingwebhookconfiguration greenhouse-validating-webhook-configuration --ignore-not-found
kubectl delete mutatingwebhookconfiguration greenhouse-mutating-webhook-configuration --ignore-not-found
```

Then re-run the SA patch loop.

---

### `HelmRelease RetriesExceeded`

Flux stops retrying after 1 failed attempt. The `reconcile.fluxcd.io/requestedAt` annotation
does not reset the retry counter in this state.

**Fix:** Suspend → delete Helm release state → resume:

```bash
kubectl patch helmrelease greenhouse -n greenhouse --type merge -p '{"spec":{"suspend":true}}'
kubectl delete secret -n greenhouse -l name=greenhouse-greenhouse,owner=helm
kubectl patch helmrelease greenhouse -n greenhouse --type merge -p '{"spec":{"suspend":false}}'
```

---

### `cors-proxy` deploys despite disabling it in values

**Cause:** The Chart.yaml condition key is `proxy.enabled`, not `corsProxy.enabled`. Using
`corsProxy: enabled: false` is silently ignored.

**Fix:** Use `proxy: enabled: false` in `greenhouse-values.yaml`, recreate the values
secret, and reset the HelmRelease (see RetriesExceeded fix above).

---

### `ComponentVersion READY=False`

Re-run the CTF → RBSC transfer and verify the registry secret is present in the
`greenhouse` namespace.

---

### `CrashLoopBackOff: ArtifactGenerator CRD not found`

Flux extension stubs not applied. Run:

```bash
kubectl apply -f prereqs/flux-extension-stubs.yaml
```

---

### kro `GreenhouseStack` or `GreenhouseBootstrap` status shows ERROR/False

kro's CEL status expressions may cache a stale failure state. The HelmReleases are the
source of truth — check `kubectl get helmreleases -n greenhouse`. If all are Ready, the
kro status typically self-resolves on the next reconciliation cycle (~1m).

---

### kro RGD stays `Inactive`: type mismatch `__type_schema.*`

kro v0.9.x uses **SimpleSchema**. The old `{type: string}` object format causes kro to
fail type inference.

**Fix:** Schema fields must use inline type strings:
```yaml
# WRONG
spec:
  fieldName:
    type: string

# CORRECT
spec:
  fieldName: "string"
```

---

### OCM controller pods: `MountVolume.SetUp failed: secret "ocm-registry-tls-certs" not found`

The bootstrap HelmRelease must include `values.tlsCert.generateTlsCert: true`. The chart
default is `false` — without it, cert-manager never creates the TLS secret.

This is already set in `bootstrap-rgd.yaml`. If installing the OCM controller manually:
```bash
helm upgrade --install ocm-controller ... --set tlsCert.generateTlsCert=true
```

---

## Upgrading

1. Bump version variables, rebuild CTF, re-sign, push to GHCR, delete stale RBSC packages if needed, transfer to RBSC (Part 0)
2. On the cluster, annotate the OCM `ComponentVersion` to force reconciliation:
   ```bash
   kubectl annotate componentversion greenhouse -n greenhouse \
     reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
   ```
3. Wait for new Snapshots to appear, get updated paths with:
   ```bash
   kubectl get snapshot -n greenhouse \
     -o custom-columns='RESOURCE:.metadata.ownerReferences[0].name,REPO:.status.repositoryURL,TAG:.status.tag'
   ```
4. Update `deploy/instance.yaml` with new snapshot paths and version, re-apply:
   ```bash
   kubectl apply -f deploy/instance.yaml
   ```
