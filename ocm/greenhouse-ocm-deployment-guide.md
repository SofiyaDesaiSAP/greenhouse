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
        ├─ core (greenhouse chart + images)
        ├─ prerequisites/cert-manager      (access.type: ociArtifact)
        ├─ prerequisites/ocm-controller    (access.type: ociArtifact)
        ├─ prerequisites/flux
        └─ prerequisites/kro

ocm transfer --copy-resources CTF → ghcr.io/sofiyadesaisap/greenhouse-rbsc (RBSC)
   └─ cert-manager  → rbsc/cloudoperators/greenhouse-extensions/charts/cert-manager
      ocm-controller → rbsc/open-component-model/helm/ocm-controller
      greenhouse image → rbsc/cloudoperators/greenhouse

Cluster:
  Flux + kro (direct Helm, once)
  │
  ├─ GreenhouseBootstrap RGD ──► OCIRepository/cert-manager-bootstrap (RBSC)
  │                               OCIRepository/ocm-controller-bootstrap (RBSC)
  │                               HelmRelease/cert-manager → cert-manager ns
  │                               HelmRelease/ocm-controller → ocm-system ns
  │                                        OCM controller now running
  │
  └─ GreenhouseStack RGD ──► kro expands GreenhouseStack CR into 4-resource graph:
                               1. ComponentVersion → fetches bundle from RBSC
                               2. Resource          → extracts greenhouse-chart → Snapshot
                               3. FluxDeployer      → reads Snapshot URL → creates OCIRepository
                               4. HelmRelease       → pulls chart from OCIRepository → helm install
                                    ↑ no manual snapshot paths — the chain is fully automatic
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


### Step 3 — Push CTF to GHCR (central registry)

```bash
GITHUB_TOKEN=$(gh auth token) ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/sofiyadesaisap/greenhouse
```

**`--copy-resources` rewrites component descriptors** to point to the new registry location.
This must happen before signing — signing the local CTF first and then transferring would
invalidate the signature because the descriptors change during transfer.

Verify all 6 components landed:

```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.23.0" \
  --recursive 2>&1 | tee ocm-verify-ghcr-output.txt
```

<img width="1100" height="143" alt="image" src="https://github.com/user-attachments/assets/69a063bf-0858-444c-ba73-ee4fb6b8bbc0" />

### Step 4 — Sign the bundle in GHCR (keyless / Sigstore)

Sign **in GHCR** — not the local CTF — so the signature covers the final post-transfer state:

```bash
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo oci://ghcr.io/sofiyadesaisap/greenhouse \
  github.com/cloudoperators/greenhouse:0.23.0
```

Browser opens for OIDC login. One signature transitively covers every chart, image, and
sub-component in the bundle.

<img width="1748" height="579" alt="image" src="https://github.com/user-attachments/assets/91ccc43f-e554-4391-833a-eeaf6029d216" />

<img width="411" height="335" alt="image" src="https://github.com/user-attachments/assets/8f601a2b-2b02-4a6b-9779-74743ec076a6" />

<img width="1745" height="188" alt="image" src="https://github.com/user-attachments/assets/97361f5a-406f-4f56-8a55-6d937df8992f" />


### Step 5 — Verify signature, then transfer to RBSC (on-site / air-gap registry)

```bash
# Integrity gate: verify before crossing the air-gap boundary
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://ghcr.io/sofiyadesaisap/greenhouse \
  github.com/cloudoperators/greenhouse:0.23.0
```

<img width="1345" height="425" alt="image" src="https://github.com/user-attachments/assets/e006c716-63ac-4982-a2df-a84d21bceee6" />


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

<img width="800" height="439" alt="Screenshot 2026-10-12 at 18 08 55" src="https://github.com/user-attachments/assets/eda5b93f-682b-41fc-9f26-05a594b93ce3" />

Verify 6 components in RBSC:

```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc//github.com/cloudoperators/greenhouse:0.23.0" \
  --recursive
```

Expected output — 6 components, all showing the transferred version:

```
COMPONENT                                                               VERSION   PROVIDER
github.com/cloudoperators/greenhouse                                    0.23.0    ...
github.com/cloudoperators/greenhouse/core                               0.23.0    ...
github.com/cloudoperators/greenhouse/prerequisites/cert-manager         0.23.0    ...
github.com/cloudoperators/greenhouse/prerequisites/flux                 0.23.0    ...
github.com/cloudoperators/greenhouse/prerequisites/kro                  0.23.0    ...
github.com/cloudoperators/greenhouse/prerequisites/ocm-controller       0.23.0    ...
```

<!-- SCREENSHOT: terminal output of `ocm get componentversions --recursive` against RBSC showing all 6 components -->

---

## Part 1 — Cluster Bootstrap

> Flux and kro are the only direct Helm installs. Everything else goes through kro.

### Step 1 — Install Flux

```bash
flux install

kubectl rollout status deploy/source-controller -n flux-system --timeout=120s
kubectl rollout status deploy/helm-controller   -n flux-system --timeout=120s
```

<img width="725" height="63" alt="image" src="https://github.com/user-attachments/assets/3bdd9425-5ea1-4f89-b23e-21f24402f835" />

### Step 2 — Install kro

```bash
helm upgrade --install kro \
  oci://registry.k8s.io/kro/charts/kro \
  --namespace kro-system \
  --create-namespace \
  --version 0.9.4 \
  --wait --timeout 5m
```

Expected output:

```
Release "kro" does not exist. Installing it now.
...
STATUS: deployed
```

<!-- SCREENSHOT: terminal showing kro helm install success and `kubectl get pods -n kro-system` with kro pod Running -->

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

Expected output:

```
namespace/greenhouse configured
secret/greenhouse-ocm-registry-creds configured
```

<!-- SCREENSHOT: terminal showing namespace + secret created/configured -->

### Step 5 — Apply kro RGDs

```bash
kubectl apply -k deploy/
```

This creates: namespace (idempotent), `GreenhouseStack` RGD, `GreenhouseBootstrap` RGD.
kro processes both RGDs immediately and registers their CRDs.

`componentversion.yaml` and `resources.yaml` are intentionally excluded — their CRDs
(`ComponentVersion`, `Resource`) don't exist until the OCM controller is running.

<img width="431" height="61" alt="image" src="https://github.com/user-attachments/assets/07a8d69b-8c19-4b43-b935-0bb0aace2c82" />


### Step 6 — Apply the bootstrap instance

Wait for the `GreenhouseBootstrap` CRD:

```bash
kubectl get crd greenhousebootstraps.kro.run
```

Apply:

```bash
kubectl apply -f deploy/bootstrap-instance.yaml
```

<img width="509" height="74" alt="image" src="https://github.com/user-attachments/assets/fb0083fb-131d-43e3-a448-1c7f75dd1e5d" />


kro expands this into:

```
OCIRepository/prometheus-crds-bootstrap  → oci://ghcr.io/prometheus-community/...  (public OCI — exception)
OCIRepository/cert-manager-bootstrap     → oci://<rbscRegistry>/cloudoperators/greenhouse-extensions/charts/cert-manager
OCIRepository/ocm-controller-bootstrap   → oci://<rbscRegistry>/open-component-model/helm/ocm-controller

HelmRelease/prometheus-crds   → monitoring ns
HelmRelease/cert-manager      → cert-manager ns   (parallel with prometheus-crds)
HelmRelease/ocm-controller    → ocm-system ns     (dependsOn: cert-manager)
```

> **Skipping prerequisites that already exist**: if cert-manager, OCM controller, or prometheus-crds
> are already installed in the cluster, set the corresponding flag to `false` in
> `deploy/bootstrap-instance.yaml` before applying:
> `installCertManager: false`, `installOcmController: false`, `installPrometheusCrds: false`.
> Any component set to `false` will have its OCIRepository and HelmRelease created but immediately
> suspended — Flux will not attempt an install.

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

<img width="1151" height="74" alt="image" src="https://github.com/user-attachments/assets/315e5631-ca78-4f05-b48b-738d80ddcc3b" />


### Step 7 — Apply Flux extension stub CRDs

```bash
kubectl apply -f prereqs/flux-extension-stubs.yaml
```

Expected output:

```
customresourcedefinition.apiextensions.k8s.io/artifactgenerators.source.extensions.fluxcd.io created
```

<!-- SCREENSHOT: terminal showing CRD created -->

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

Expected output:

```
secret/ocm-registry-tls-certs configured
```

<!-- SCREENSHOT: terminal showing secret copied to greenhouse namespace -->

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

Expected output:

```
secret/greenhouse-values configured
```

<!-- SCREENSHOT: terminal showing secret created/configured -->

---

## Part 3 — Deploy *(the demo moment)*

### Step 1 — Update image digests in `deploy/instance.yaml`

The `greenhouseImageDigest` and `dashboardImageDigest` fields in `instance.yaml` must match
the image content digests stored in the OCM component at the version being deployed. After
every bundle rebuild + RBSC transfer, run:

```bash
make -f Makefile.ocm patch-instance GREENHOUSE_VERSION=0.23.0
```

Expected output:

```
Reading image digests from RBSC for github.com/cloudoperators/greenhouse/core:0.23.0...
  greenhouse-image: sha256:be2177349a8dbbd58bfb281c81d3181b298f042bd40ae77166e55e848c124afe
  dashboard-image:  sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631
deploy/instance.yaml updated. Apply with: make deploy-instance
```

<!-- SCREENSHOT: terminal output of `make patch-instance` showing digests read and instance.yaml patched -->

Current `deploy/instance.yaml`:

```yaml
spec:
  imageRegistry: "ghcr.io/sofiyadesaisap/greenhouse-rbsc"
  registrySecretName: "greenhouse-ocm-registry-creds"
  componentVersion: ">=0.23.0"
  greenhouseImageDigest: "sha256:be2177349a8dbbd58bfb281c81d3181b298f042bd40ae77166e55e848c124afe"
  dashboardImageDigest: "sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631"
  valuesSecretName: "greenhouse-values"
  enableCertManager: true
  enableOcmController: true
```

> **No snapshot paths.** The kro RGD's 4-resource graph (ComponentVersion → Resource →
> FluxDeployer → HelmRelease) navigates the OCM bundle automatically. The FluxDeployer
> reads `Resource.status.snapshotName`, looks up the Snapshot, and creates the OCIRepository
> with the correct `sha-...` OCI path. There is nothing to copy-paste from `kubectl get snapshot`.

### Step 2 — Apply the GreenhouseStack instance

Wait for the `GreenhouseStack` CRD (kro created it when it processed `kro-rgd.yaml`):

```bash
kubectl get crd greenhousestacks.kro.run
```

Apply:

```bash
kubectl apply -f deploy/instance.yaml
```

kro expands this into the 4-resource graph. Watch the chain become Ready:

```bash
kubectl get componentversion,resource,ocirepository,helmrelease -n greenhouse -w
```

Expected sequence:
1. `ComponentVersion/greenhouse` → Ready (fetched bundle from RBSC)
2. `Resource/greenhouse-chart` → Ready (extracted chart, created Snapshot)
3. FluxDeployer creates `OCIRepository/greenhouse` → Ready (sha-... URL resolved)
4. `HelmRelease/greenhouse` → starts install

Expected output (after chain stabilises):

```
NAME                                         READY   STATUS   AGE
componentversion.delivery.ocm.software/greenhouse   True    ...      2m

NAME                                     READY   STATUS   AGE
resource.delivery.ocm.software/greenhouse-chart   True    ...   90s

NAME                                 READY   URL                                                                AGE
ocirepository.source.toolkit.fluxcd.io/greenhouse   True   oci://registry.ocm-system.svc.cluster.local:5000/sha-...   60s

NAME                                        AGE   READY   STATUS
helmrelease.helm.toolkit.fluxcd.io/greenhouse   45s   False   Helm install in progress
```

<!-- SCREENSHOT: terminal showing all 4 resources in Ready state, then HelmRelease progressing -->

### Step 3 — Unblock imagePullSecrets

The greenhouse chart does not support `global.imagePullSecrets` propagation. Pods will start
in `ImagePullBackOff` on the first install attempt. The fix is to patch ServiceAccounts after
the Helm install creates them.

> **Do this when you see the HelmRelease timeout or pods in `ImagePullBackOff`.**

```bash
# 1. Suspend the HelmRelease to prevent Flux from retrying and recreating webhook configs
kubectl patch helmrelease greenhouse -n greenhouse --type=merge -p '{"spec":{"suspend":true}}'

# 2. Delete webhook configs created by the failed install
#    (they intercept SA patches and reject them with "service not found")
kubectl delete validatingwebhookconfiguration greenhouse-validating-webhook-configuration --ignore-not-found
kubectl delete mutatingwebhookconfiguration greenhouse-mutating-webhook-configuration --ignore-not-found

# 3. Patch all ServiceAccounts — Kubernetes merges SA imagePullSecrets into new pods
for sa in $(kubectl get serviceaccount -n greenhouse -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch serviceaccount "$sa" -n greenhouse --type=merge \
    -p '{"imagePullSecrets":[{"name":"greenhouse-ocm-registry-creds"}]}'
done

# 4. Restart pods so they pick up the SA imagePullSecrets
kubectl rollout restart deployment -n greenhouse

# 5. Unsuspend and force reconcile
kubectl patch helmrelease greenhouse -n greenhouse --type=merge -p '{"spec":{"suspend":false}}'
kubectl annotate helmrelease greenhouse -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

Watch:

```bash
kubectl get helmrelease greenhouse -n greenhouse -w
kubectl get pods -n greenhouse -w
```

Expected final state:

```
NAME          AGE   READY   STATUS
greenhouse    5m    True    Helm upgrade succeeded for release greenhouse/greenhouse-greenhouse.v2 with chart greenhouse@0.23.0
```

```
NAME                                          READY   STATUS    RESTARTS   AGE
greenhouse-controller-manager-...            1/1     Running   0          3m
greenhouse-webhook-...                       1/1     Running   0          3m
greenhouse-cors-proxy-...                    1/1     Running   0          3m
```

<!-- SCREENSHOT: terminal showing HelmRelease Ready=True with "Helm upgrade succeeded" message and all greenhouse pods Running -->


---

## Part 4 — Verify

### Full status check

```bash
# kro 4-resource graph + stack instance
kubectl get componentversion,resource,fluxdeployer,ocirepository,helmrelease,greenhousestack -n greenhouse

kubectl get pods -n greenhouse
kubectl get pods -n cert-manager
kubectl get pods -n ocm-system
kubectl get pods -n kro-system
kubectl get pods -n flux-system
```

Expected final state:

```
ComponentVersion:  greenhouse        Ready=True   0.23.0
Resource:          greenhouse-chart  Ready=True
FluxDeployer:      greenhouse        Ready=True
OCIRepository:     greenhouse        Ready=True
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

<!-- SCREENSHOT: `kubectl get componentversion,resource,fluxdeployer,ocirepository,helmrelease,greenhousestack -n greenhouse` and `kubectl get pods -n greenhouse` all Ready/Running -->


### Prove zero external registry dependency

```bash
kubectl get pods -n greenhouse \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

Every line must start with `ghcr.io/sofiyadesaisap/greenhouse-rbsc/`.

Expected output (all lines RBSC-prefixed):

```
ghcr.io/sofiyadesaisap/greenhouse-rbsc/cloudoperators/greenhouse@sha256:be2177349a8d...
ghcr.io/sofiyadesaisap/greenhouse-rbsc/cloudoperators/juno-app-greenhouse@sha256:ae36...
ghcr.io/sofiyadesaisap/greenhouse-rbsc/sapcc/postgres@sha256:...
```

<!-- SCREENSHOT: terminal output showing all pod images prefixed with `ghcr.io/sofiyadesaisap/greenhouse-rbsc/` — no external registries -->

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

### `ImagePullBackOff` on greenhouse pods: 401 / NotFound from RBSC

**Cause A — wrong image digest:** The `greenhouseImageDigest` in `instance.yaml` references
a content digest from a different version than what was actually transferred to RBSC. The
error is `rpc error: code = NotFound` (not a 401) — the image exists in the registry but
not at that specific digest.

**Fix:** Run `make -f Makefile.ocm patch-instance GREENHOUSE_VERSION=<version>` to read the
correct digest from the RBSC component descriptor and patch `instance.yaml` automatically.
Then re-apply `instance.yaml`.

**Cause B — missing imagePullSecrets on pods:** The greenhouse chart does not propagate
`global.imagePullSecrets` to all subcharts. Pods pull without credentials.

**Fix:** Follow Part 3 Step 3 (suspend HR → delete webhooks → patch SAs → restart → unsuspend).

---

### SA patch rejected: "service greenhouse-webhook-service not found"

**Cause:** A prior failed Helm install left `greenhouse-validating-webhook-configuration`
and `greenhouse-mutating-webhook-configuration` in the cluster. The webhook intercepts SA
patches and rejects them because the webhook service was never created.

Every Helm retry (whether from a new `kubectl apply` or an unsuspended HelmRelease) recreates
these webhook configs. Suspend the HelmRelease first, then delete webhooks, then patch SAs.

**Fix:**
```bash
kubectl patch helmrelease greenhouse -n greenhouse --type=merge -p '{"spec":{"suspend":true}}'
kubectl delete validatingwebhookconfiguration greenhouse-validating-webhook-configuration --ignore-not-found
kubectl delete mutatingwebhookconfiguration greenhouse-mutating-webhook-configuration --ignore-not-found
# ... patch SAs, restart deployments ...
kubectl patch helmrelease greenhouse -n greenhouse --type=merge -p '{"spec":{"suspend":false}}'
```

See Part 3 Step 3 for the full sequence.

---

### `HelmRelease RetriesExceeded` / `Stalled`

Flux stops retrying after 1 failed attempt. Annotating with `reconcile.fluxcd.io/requestedAt`
does NOT reset the retry counter when the release is in `Stalled` state — it returns
`terminal error: exceeded maximum retries`.

**Fix:** Suspend → unsuspend cycle (forces a fresh install, not a resume):

```bash
kubectl patch helmrelease greenhouse -n greenhouse --type merge -p '{"spec":{"suspend":true}}'
sleep 5
kubectl patch helmrelease greenhouse -n greenhouse --type merge -p '{"spec":{"suspend":false}}'
kubectl annotate helmrelease greenhouse -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

If the install fails again for the same reason (e.g., webhook blocks SA creation):
follow Part 3 Step 3 first, then unsuspend.

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

1. Bump version variables, rebuild CTF, re-sign, push to GHCR, delete stale RBSC packages if needed, transfer to RBSC (Part 0).
2. Update `deploy/instance.yaml` with the new digests:
   ```bash
   make -f Makefile.ocm patch-instance GREENHOUSE_VERSION=<new-version>
   ```
   This queries the RBSC component descriptor directly — no manual Snapshot inspection needed.
3. Re-apply the instance:
   ```bash
   kubectl apply -f deploy/instance.yaml
   ```
4. kro detects the changed `componentVersion` / digests and updates the ComponentVersion CR.
   The OCM controller fetches the new bundle; the Resource + FluxDeployer + HelmRelease chain
   re-reconciles automatically. Watch:
   ```bash
   kubectl get componentversion,helmrelease -n greenhouse -w
   ```
5. If the upgrade includes new ServiceAccounts (new subcharts), re-run the SA imagePullSecrets patch:
   ```bash
   for sa in $(kubectl get serviceaccount -n greenhouse -o jsonpath='{.items[*].metadata.name}'); do
     kubectl patch serviceaccount "$sa" -n greenhouse --type=merge \
       -p '{"imagePullSecrets":[{"name":"greenhouse-ocm-registry-creds"}]}'
   done
   ```
