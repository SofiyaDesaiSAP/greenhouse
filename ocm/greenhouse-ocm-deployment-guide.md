# Greenhouse OCM + Flux Deployment Guide

Deploy Greenhouse on a Kubernetes cluster using OCM (Open Component Model) as the artifact
distribution layer and Flux as the deployment engine. A kro `GreenhouseBootstrap` RGD
installs prerequisites; a `GreenhouseStack` RGD installs Greenhouse itself via the OCM
controller.

---

## Air-gate deployment model

Greenhouse uses OCM to bundle all charts and images into transferable artifacts. After a
one-time transfer to your on-site registry, the cluster runs fully autonomously — no runtime
dependency on any external registry. To upgrade, temporarily open access to pull a new OCM
bundle, transfer it in, then close access again.

---

## Architecture

```
Two OCM bundles (built once per release):

  greenhouse-bundle.ctf              ← default, product only
  └─ github.com/cloudoperators/greenhouse:0.23.0
       └─ core  (greenhouse-chart, greenhouse-image, dashboard-image, kro-rgd)

  greenhouse-prereqs-bundle.ctf      ← opt-in, skip if tools already installed
  └─ github.com/cloudoperators/greenhouse-prerequisites:0.21.0
       ├─ prerequisites/cert-manager
       ├─ prerequisites/ocm-controller  (open-component-model/kubernetes/controller/chart)
       ├─ prerequisites/flux
       └─ prerequisites/kro

ocm transfer --copy-resources → <on-site-registry>  (one-time per release)
   └─ greenhouse-chart → <on-site>/github.com/cloudoperators/greenhouse/core/greenhouse
      cert-manager     → <on-site>/cloudoperators/greenhouse-extensions/charts/cert-manager
      ocm-controller   → <on-site>/open-component-model/kubernetes/controller/chart

Cluster (air-gapped at runtime — all pulls from on-site registry):
  Flux + kro (direct Helm, once)
  │
  ├─ GreenhouseBootstrap RGD ──► OCIRepository/cert-manager-bootstrap  → <on-site>
  │                               OCIRepository/ocm-controller-bootstrap → <on-site>
  │                               HelmRelease/cert-manager      → cert-manager ns
  │                               HelmRelease/ocm-k8s-toolkit   → ocm-k8s-toolkit-system ns
  │                                        New OCM controller (open-component-model) running
  │
  └─ GreenhouseStack RGD ──► kro expands GreenhouseStack CR into 5-resource graph:
                               1. Repository    → points to <on-site-registry>
                               2. Component     → fetches github.com/cloudoperators/greenhouse
                               3. Resource      → extracts greenhouse-chart, exposes OCI URL
                               4. OCIRepository → pulls chart from <on-site-registry>
                               5. HelmRelease   → installs from OCIRepository
                                    ↑ all image.repository values point to <on-site-registry>
                                    ↑ zero runtime dependency on external registries
```

---

## Prerequisites

| Tool | Min version |
|---|---|
| `kubectl` | 1.28+ |
| `helm` | 3.14+ |
| `flux` CLI | 2.x |
| `ocm` CLI | 0.48+ |
| OCI registry | Any registry your cluster can reach (central + on-site) |

**Session setup — run once at the start:**

```bash
cd /path/to/greenhouse/ocm

# Central registry — where your signed OCM bundles live
export CENTRAL_REGISTRY=<your-central-registry>         # e.g. ghcr.io/cloudoperators
# On-site registry — the OCI registry your cluster can reach (air-gap target)
export ON_SITE_REGISTRY=<your-on-site-registry>         # e.g. registry.example.internal
export REGISTRY_USER=<your-registry-user>
export REGISTRY_TOKEN=<your-registry-token>
export KUBECONFIG=/path/to/cluster-kubeconfig.yaml
```

---

## Part 0 — Build and Distribute the OCM Bundle *(before demo / before deploy)*

### Step 1 — Resolve helm chart dependencies

```bash
helm dependency update ../charts/greenhouse
```

### Step 2 — Build the OCM CTF archives

Read the chart version and app image version from `Chart.yaml`:

```bash
export GREENHOUSE_VERSION=$(grep "^version:" ../charts/greenhouse/Chart.yaml | awk '{print $2}')
export APP_IMAGE_VERSION=$(grep "^appVersion:" ../charts/greenhouse/Chart.yaml | awk '{print $2}')
echo "Chart: $GREENHOUSE_VERSION  App image: $APP_IMAGE_VERSION"
```

**Default build — greenhouse product bundle only:**

```bash
rm -rf greenhouse-bundle.ctf

ocm add componentversions \
  --addenv \
  --file greenhouse-bundle.ctf \
  --create \
  greenhouse-component.yaml \
  GREENHOUSE_VERSION=$GREENHOUSE_VERSION \
  "GREENHOUSE_IMAGE_REF=ghcr.io/cloudoperators/greenhouse:$APP_IMAGE_VERSION" \
  "DASHBOARD_IMAGE_REF=ghcr.io/cloudoperators/juno-app-greenhouse@sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631"
```

**Opt-in — prerequisites bundle** *(skip if cert-manager, Flux, kro, OCM controller are already installed):*

```bash
rm -rf greenhouse-prereqs-bundle.ctf

ocm add componentversions \
  --addenv \
  --file greenhouse-prereqs-bundle.ctf \
  --create \
  greenhouse-prerequisites-component.yaml \
  CERT_MANAGER_VERSION=1.20.1 \
  FLUX_VERSION=2.15.0 \
  KRO_VERSION=0.9.4 \
  OCM_CONTROLLER_VERSION=0.21.0
```

<img width="991" height="719" alt="Screenshot 2026-10-12 at 16 44 47" src="https://github.com/user-attachments/assets/3132b50d-87ef-4c55-92f3-2e060d948807" />


### Step 3 — Push CTF to central registry

```bash
# Do NOT use --overwrite — OCM artifacts are content-addressed and immutable.
# --overwrite mutates existing artifacts and breaks the signature chain.
# If re-pushing after a change, delete stale packages via your registry's UI/API first.
REGISTRY_TOKEN=$REGISTRY_TOKEN ocm transfer ctf \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://$CENTRAL_REGISTRY
```

**`--copy-resources` rewrites component descriptors** to point to the new registry location.
This must happen before signing — signing the local CTF first and then transferring would
invalidate the signature because the descriptors change during transfer.

Verify 2 components landed (greenhouse root + core):

```bash
ocm get componentversions \
  "oci://$CENTRAL_REGISTRY//github.com/cloudoperators/greenhouse:$GREENHOUSE_VERSION" \
  --recursive 2>&1 | tee ocm-verify-central-output.txt
```

<img width="1100" height="143" alt="image" src="https://github.com/user-attachments/assets/69a063bf-0858-444c-ba73-ee4fb6b8bbc0" />

### Step 4 — Sign the bundle in the central registry (keyless / Sigstore)

Sign **in the central registry** — not the local CTF — so the signature covers the final post-transfer state:

```bash
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo oci://$CENTRAL_REGISTRY \
  github.com/cloudoperators/greenhouse:$GREENHOUSE_VERSION
```

Browser opens for OIDC login. One signature transitively covers every chart, image, and
sub-component in the bundle.

<img width="1748" height="579" alt="image" src="https://github.com/user-attachments/assets/91ccc43f-e554-4391-833a-eeaf6029d216" />

<img width="411" height="335" alt="image" src="https://github.com/user-attachments/assets/8f601a2b-2b02-4a6b-9779-74743ec076a6" />

<img width="1745" height="188" alt="image" src="https://github.com/user-attachments/assets/97361f5a-406f-4f56-8a55-6d937df8992f" />


### Step 5 — Verify signature, then transfer to on-site registry

```bash
# Integrity gate: verify before crossing the air-gap boundary
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://$CENTRAL_REGISTRY \
  github.com/cloudoperators/greenhouse:$GREENHOUSE_VERSION
```

If rebuilding after a change, delete stale packages from your on-site registry via its UI or
API before re-running the transfer. OCM compares by content digest — it skips components that
are already present at the same digest, so stale entries must be removed manually first.

Transfer greenhouse bundle to the on-site registry:

```bash
REGISTRY_TOKEN=$REGISTRY_TOKEN ocm transfer ctf \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://$ON_SITE_REGISTRY
```

If you built the prerequisites bundle, transfer it too:

```bash
REGISTRY_TOKEN=$REGISTRY_TOKEN ocm transfer ctf \
  --copy-resources \
  greenhouse-prereqs-bundle.ctf \
  oci://$ON_SITE_REGISTRY
```

Verify the greenhouse bundle on the on-site registry (greenhouse root + core):

```bash
ocm get componentversions \
  "oci://$ON_SITE_REGISTRY//github.com/cloudoperators/greenhouse:$GREENHOUSE_VERSION" \
  --recursive
```

Expected output — 2 components:

```
REFERENCEPATH                               COMPONENT                                 VERSION PROVIDER
                                            github.com/cloudoperators/greenhouse      0.23.0  cloudoperators
github.com/cloudoperators/greenhouse:0.23.0 github.com/cloudoperators/greenhouse/core 0.23.0  cloudoperators
```

Verify the prerequisites bundle (if transferred):

```bash
ocm get componentversions \
  "oci://$ON_SITE_REGISTRY//github.com/cloudoperators/greenhouse-prerequisites:0.21.0" \
  --recursive
```

Expected output — 5 components:

```
REFERENCEPATH                                                     COMPONENT                                                         VERSION PROVIDER
                                                                  github.com/cloudoperators/greenhouse-prerequisites                0.21.0  cloudoperators
github.com/cloudoperators/greenhouse-prerequisites:0.21.0         github.com/cloudoperators/greenhouse/prerequisites/cert-manager   1.20.1  cloudoperators
github.com/cloudoperators/greenhouse-prerequisites:0.21.0         github.com/cloudoperators/greenhouse/prerequisites/flux           2.15.0  cloudoperators
github.com/cloudoperators/greenhouse-prerequisites:0.21.0         github.com/cloudoperators/greenhouse/prerequisites/kro            0.9.4   cloudoperators
github.com/cloudoperators/greenhouse-prerequisites:0.21.0         github.com/cloudoperators/greenhouse/prerequisites/ocm-controller 0.21.0  cloudoperators
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

<img width="454" height="46" alt="image" src="https://github.com/user-attachments/assets/4f69cc9a-e795-4df3-b50b-17e232665f52" />


### Step 3 — Grant helm-controller RBAC

```bash
kubectl create clusterrolebinding helm-controller-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:helm-controller \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 4 — Create namespace and registry secret

The registry secret authenticates OCIRepository and OCM Component pulls from the on-site registry.

```bash
kubectl create namespace greenhouse --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry greenhouse-ocm-registry-creds \
  --namespace greenhouse \
  --docker-server=<your-registry-server> \
  --docker-username=$REGISTRY_USER \
  --docker-password=$REGISTRY_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
```

Expected output:

```
namespace/greenhouse configured
secret/greenhouse-ocm-registry-creds configured
```

<img width="676" height="90" alt="image" src="https://github.com/user-attachments/assets/6a19b88a-962e-4b40-bc95-1454a51e5c3c" />


### Step 5 — Apply kro RGDs

```bash
kubectl apply -k deploy/
```

This creates: namespace (idempotent), `GreenhouseStack` RGD, `GreenhouseBootstrap` RGD.
kro processes both RGDs immediately and registers their CRDs.

`componentversion.yaml` and `resources.yaml` are intentionally excluded — they are stale
from the old OCM controller. The new OCM controller CRDs (`Repository`, `Component`,
`Resource`) are already registered by `ocm-k8s-toolkit`.

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
OCIRepository/cert-manager-bootstrap     → oci://<onSiteRegistry>/cloudoperators/greenhouse-extensions/charts/cert-manager
OCIRepository/ocm-controller-bootstrap   → oci://<onSiteRegistry>/open-component-model/kubernetes/controller/chart

HelmRelease/prometheus-crds    → monitoring ns
HelmRelease/cert-manager       → cert-manager ns           (parallel with prometheus-crds)
HelmRelease/ocm-k8s-toolkit    → ocm-k8s-toolkit-system ns (dependsOn: cert-manager)
```

> **Skip components that are already installed:** use the per-component flags in
> `deploy/bootstrap-instance.yaml` to prevent reinstalling what's already present:
>
> | Flag | Default | Set `false` when... |
> |---|---|---|
> | `installCertManager` | `true` | cert-manager already installed |
> | `installOcmController` | `true` | OCM controller already installed |
> | `installPrometheusCrds` | `true` | prometheus-operator-crds already installed |
> | `enableFlux` | `false` | Flux already installed *(most common)* |
> | `enableKro` | `false` | kro already installed *(most common)* |
>
> When a flag is `false`, the OCIRepository and HelmRelease are created but immediately
> suspended — Flux does not attempt an install.
>
> **Pre-installed scenario:** if your platform team already manages Flux and kro,
> `enableFlux: false` and `enableKro: false` are already the defaults in
> `deploy/bootstrap-instance.yaml`. The same bootstrap artifact works in every environment.

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


---

## Part 2 — Remaining Secrets

Namespace and registry secret were created in Part 1. Only the values secret remains.

### Prepare `greenhouse-values.yaml`

Minimal working config (no ingress, no OIDC, no postgres):

```yaml
global:
  dnsDomain: greenhouse.example.com
  oidc:
    enabled: false
  ingress:
    enabled: false
  postgresql:
    enabled: false
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

<img width="597" height="47" alt="image" src="https://github.com/user-attachments/assets/554bd477-b4a5-4ff8-a709-0c0987544608" />


---

## Part 3 — Deploy *(the demo moment)*

### Step 1 — Update image digests in `deploy/instance.yaml`

The `greenhouseImageDigest` and `dashboardImageDigest` fields in `instance.yaml` must match
the image content digests stored in the OCM component at the version being deployed. After
every bundle rebuild + on-site registry transfer, run:

```bash
make -f Makefile.ocm patch-instance GREENHOUSE_VERSION=$GREENHOUSE_VERSION
```

Expected output:

```
Reading image digests from on-site registry for github.com/cloudoperators/greenhouse/core:0.23.0...
  greenhouse-image: sha256:be2177349a8dbbd58bfb281c81d3181b298f042bd40ae77166e55e848c124afe
  dashboard-image:  sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631
deploy/instance.yaml updated. Apply with: make deploy-instance
```

Current `deploy/instance.yaml`:

```yaml
spec:
  onSiteRegistry: "<your-on-site-registry>"
  registrySecretName: "greenhouse-ocm-registry-creds"
  componentVersion: ">=0.23.0"
  greenhouseImageDigest: "sha256:be2177349a8dbbd58bfb281c81d3181b298f042bd40ae77166e55e848c124afe"
  dashboardImageDigest: "sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631"
  postgresImageRegistry: "<your-on-site-registry>/sapcc"
  valuesSecretName: "greenhouse-values"
  enableCertManager: true
  enableOcmController: true
```

> **No snapshot paths.** The kro RGD's 5-resource graph (Repository → Component → Resource →
> OCIRepository → HelmRelease) resolves the chart location automatically from
> `Resource.status.additional.oci`. There is nothing to copy-paste manually.

### Step 2 — Apply the GreenhouseStack instance

Wait for the `GreenhouseStack` CRD (kro created it when it processed `kro-rgd.yaml`):

```bash
kubectl get crd greenhousestacks.kro.run
```

Apply:

```bash
kubectl apply -f deploy/instance.yaml
```

kro expands this into the 5-resource graph. Watch the chain become Ready:

```bash
kubectl get repository,component,resource,ocirepository,helmrelease -n greenhouse -w
```

Expected sequence:
1. `Repository/greenhouse` → Ready (connected to on-site registry)
2. `Component/greenhouse` → Ready (resolved version from semver constraint)
3. `Resource/greenhouse-chart` → Ready (extracted chart, `status.additional.oci` populated)
4. `OCIRepository/greenhouse` → Ready (URL resolved from Resource status)
5. `HelmRelease/greenhouse` → starts install

Expected output (after chain stabilises):

```
NAME                                              READY   STATUS   AGE
repository.delivery.ocm.software/greenhouse       True    ...      2m

NAME                                              READY   STATUS   AGE
component.delivery.ocm.software/greenhouse        True    ...      90s

NAME                                              READY   STATUS   AGE
resource.delivery.ocm.software/greenhouse-chart   True    ...      60s

NAME                                              READY   URL                                                   AGE
ocirepository.source.toolkit.fluxcd.io/greenhouse True    oci://<on-site>/...greenhouse/core/greenhouse         45s

NAME                                              AGE   READY   STATUS
helmrelease.helm.toolkit.fluxcd.io/greenhouse     30s   False   Helm install in progress
```

<img width="1538" height="454" alt="image" src="https://github.com/user-attachments/assets/09e7027c-4f32-4d6a-aa51-f6c9c7ab9043" />


---

## Part 4 — Verify

### Full status check

```bash
# kro 5-resource graph + stack instance
kubectl get repository,component,resource,ocirepository,helmrelease,greenhousestack -n greenhouse

kubectl get pods -n greenhouse
kubectl get pods -n cert-manager
kubectl get pods -n ocm-k8s-toolkit-system
kubectl get pods -n kro-system
kubectl get pods -n flux-system
```

Expected final state:

```
Repository:        greenhouse        Ready=True
Component:         greenhouse        Ready=True
Resource:          greenhouse-chart  Ready=True
OCIRepository:     greenhouse        Ready=True
GreenhouseStack:   greenhouse        ACTIVE
HelmReleases:      cert-manager      Ready=True
                   ocm-k8s-toolkit   Ready=True
                   greenhouse        Ready=True
Pods (greenhouse):             controller-manager ×3, cors-proxy ×2, webhook ×2  — Running
Pods (cert-manager):           controller, cainjector, webhook                   — Running
Pods (ocm-k8s-toolkit-system): ocm-k8s-toolkit-controller-manager               — Running
Pods (kro-system):             kro                                               — Running
Pods (flux-system):            helm, source, kustomize, notification             — Running
```

<img width="1542" height="496" alt="image" src="https://github.com/user-attachments/assets/5343055b-e648-4cad-a740-8edd115f1369" />


<img width="673" height="229" alt="image" src="https://github.com/user-attachments/assets/9ca9e9d1-d51a-4d09-8d40-38ff6bf80006" />


### Prove zero external registry dependency

```bash
kubectl get pods -n greenhouse \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

Every line must start with your on-site registry prefix (`$ON_SITE_REGISTRY/`).
No line should reference `ghcr.io`, `docker.io`, or any external registry.

Expected output (all lines on-site-registry-prefixed):

```
<your-on-site-registry>/cloudoperators/greenhouse@sha256:be2177...
<your-on-site-registry>/cloudoperators/juno-app-greenhouse@sha256:ae36...
<your-on-site-registry>/<postgres-path>@sha256:...
```


---

## Acceptance Criteria — Final Checklist

| Criterion | Evidence |
|---|---|
| ✅ Greenhouse chart as OCM artifact | `ocm get componentversions --recursive` shows 2 components in greenhouse bundle (root + core) |
| ✅ Prerequisites as separate opt-in artifact | Prerequisites bundle shows 5 components (root + cert-manager, flux, kro, ocm-controller) |
| ✅ Core components installable via OCM | `GreenhouseStack ACTIVE`, all HelmReleases `Ready=True`, all pods Running |
| ✅ Air-gapped at runtime | All pod images prefixed with `$ON_SITE_REGISTRY` — no external registry dependency |

---

## Troubleshooting

### cert-manager / ocm-k8s-toolkit HelmRelease stuck: MANIFEST_UNKNOWN

OCM compares component versions by content digest only. If these components were previously
transferred with `input.type: helm` (old approach), their descriptors are "already present"
even after switching to `access.type: ociArtifact` — OCM skips them and chart blobs never
land at the bootstrap OCIRepository paths.

**Fix:** Delete the stale packages from your on-site registry (via its UI or API), then
re-run the CTF → on-site registry transfer and annotate the OCIRepositories to force
immediate reconciliation.

---

### `ImagePullBackOff` on greenhouse pods: wrong digest

**Cause:** The `greenhouseImageDigest` in `instance.yaml` references a content digest from a
different version than what was actually transferred to the on-site registry. The error is
`rpc error: code = NotFound` — the image exists in the registry but not at that specific digest.

**Fix:** Run `make -f Makefile.ocm patch-instance GREENHOUSE_VERSION=<version>` to read the
correct digest from the component descriptor and patch `instance.yaml` automatically.
Then re-apply `instance.yaml`.

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

If the install fails again for the same reason, check `kubectl get events -n greenhouse` for the root cause first.

---

### `cors-proxy` deploys despite disabling it in values

**Cause:** The Chart.yaml condition key is `proxy.enabled`, not `corsProxy.enabled`. Using
`corsProxy: enabled: false` is silently ignored.

**Fix:** Use `proxy: enabled: false` in `greenhouse-values.yaml`, recreate the values
secret, and reset the HelmRelease (see RetriesExceeded fix above).

---

### `Component` or `Resource` READY=False

Re-run the CTF → on-site registry transfer and verify the registry secret is present in the
`greenhouse` namespace.

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

---

## Upgrading

1. Bump version variables, rebuild CTF, re-sign, push to central registry, transfer to on-site registry (Part 0).
2. Update `deploy/instance.yaml` with the new digests:
   ```bash
   make -f Makefile.ocm patch-instance GREENHOUSE_VERSION=<new-version>
   ```
   This queries the on-site registry component descriptor directly — no manual snapshot inspection needed.
3. Re-apply the instance:
   ```bash
   kubectl apply -f deploy/instance.yaml
   ```
4. kro detects the changed `componentVersion` / digests and updates the OCM Component CR.
   The OCM controller fetches the new bundle; the Resource + OCIRepository + HelmRelease chain
   re-reconciles automatically. Watch:
   ```bash
   kubectl get component,resource,ocirepository,helmrelease -n greenhouse -w
   ```
