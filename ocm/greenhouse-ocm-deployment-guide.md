# Greenhouse OCM + Flux Deployment Guide

Deploy Greenhouse on a Kubernetes cluster using OCM (Open Component Model) as the artifact distribution layer and Flux as the GitOps engine. A kro ResourceGraphDefinition (`GreenhouseStack`) ties the components together via a single parameterized CR instance.

---

## Architecture

```
ghcr.io (OCM registry)
    └─ greenhouse-bundle CTF
           ├─ cert-manager chart
           ├─ ocm-controller chart
           ├─ kro chart
           ├─ greenhouse chart
           └─ kro-rgd (plain YAML — ResourceGraphDefinition)
                        │
               OCM controller pulls → OCM internal registry (ocm-system)
                        │
               Snapshots → Resource CRs
                        │
               Deployer (OCM) ──► applies kro-rgd YAML directly to cluster
                        │
                     kro processes RGD ──► GreenhouseStack CRD
                        │
               kubectl apply instance.yaml
                        │
               kro creates OCIRepositories + HelmReleases:
                 cert-manager / ocm-controller / greenhouse
```

---

## Prerequisites

| Tool | Min version | Install |
|---|---|---|
| `kubectl` | 1.28+ | |
| `helm` | 3.14+ | |
| `flux` CLI | 2.x | |
| `ocm` CLI | 0.48+ | |
| GitHub PAT | `read:packages` for pull, `write:packages` to push | |

Set before running anything:

```bash
export GITHUB_TOKEN=ghp_...          # GitHub PAT
export KUBECONFIG=/path/to/kubeconfig
```

All `make` commands run from the `greenhouse/ocm/` directory.

---

## Step 1 — Prepare the OCM Bundle

> Skip if the bundle is already pushed to `ghcr.io/sofiyadesaisap/greenhouse-ocm`.

```bash
cd greenhouse/ocm

# 1a. Package the greenhouse Helm chart (resolves file:// deps + OCI)
make -f Makefile.ocm package

# 1b. Fetch ocm-controller chart (v-prefix OCI tag requires manual pull)
make -f Makefile.ocm fetch-prereqs

# 1c. Build the OCM CTF archive
# kro-rgd is a plain YAML file (deploy/kro-rgd.yaml) — no helm packaging needed.
make -f Makefile.ocm build

# 1d. Verify the archive contains all components
make -f Makefile.ocm verify
```

**Screenshot placeholder — `make verify` output:**
<img width="758" height="431" alt="image" src="https://github.com/user-attachments/assets/371631b1-48eb-4fc7-ba25-d55b3247bfe5" />


```bash
# 1e. Push to ghcr.io
make -f Makefile.ocm push GITHUB_TOKEN=$GITHUB_TOKEN
```

**Screenshot placeholder — successful push:**
```
[SCREENSHOT: make push output showing all components transferred to ghcr.io]
```

---

## Step 2 — Prepare `greenhouse-values.yaml`

Copy the example and edit for your environment:

```bash
cp deploy/greenhouse-values-example.yaml greenhouse-values.yaml
```

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
  registry: ghcr.io
  monitoring:
    enabled: false
  dex:
    backend: kubernetes   # NOT postgres (needs pguser secret) and NOT memory (invalid)

idproxy:
  enabled: false
corsProxy:
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

---

## Step 3 — Bootstrap the Cluster

Run each step once on a fresh cluster. Individual targets are idempotent — safe to re-run if something fails mid-way.

### 3a. Bootstrap Flux

```bash
make -f Makefile.ocm bootstrap-flux
```

> Skips reinstall if Flux is already running. Only installs from scratch.

**Screenshot placeholder:**
```
[SCREENSHOT: make bootstrap-flux output showing flux install completing and rollout status]
```

### 3b. Install kro

```bash
make -f Makefile.ocm install-kro
```

### 3c. Grant helm-controller RBAC

Required for Flux to install CRDs and ClusterRoles:

```bash
make -f Makefile.ocm grant-helm-rbac
```

### 3d. Install prometheus-operator CRDs

The greenhouse chart hardcodes `PrometheusRule` regardless of monitoring settings:

```bash
make -f Makefile.ocm install-prometheus-crds
```

### 3e. Install OCM controller

cert-manager is installed first as a dependency, then the OCM controller:

```bash
make -f Makefile.ocm install-ocm-controller GITHUB_TOKEN=$GITHUB_TOKEN
```

> **Note:** `--set tlsCert.generateTlsCert=true` is required — the chart default is `false`. Without it, the OCM registry TLS secret is never created and pods stay in `ContainerCreating`.

**Screenshot placeholder:**
```
[SCREENSHOT: make install-ocm-controller completing — cert-manager pods + ocm-controller pods Running + "TLS secret exists."]
```

---

## Step 4 — Create Namespace and Secrets

```bash
make -f Makefile.ocm create-greenhouse-ns

# Registry pull credentials for ghcr.io
make -f Makefile.ocm create-registry-secret GITHUB_TOKEN=$GITHUB_TOKEN

# Copy OCM TLS cert from ocm-system → greenhouse namespace
# (Flux OCIRepositories in greenhouse need it to pull from the OCM internal registry)
make -f Makefile.ocm copy-tls-secret

# Upload greenhouse-values.yaml as a K8s secret
make -f Makefile.ocm create-values-secret
```

---

## Step 5 — Apply OCM Manifests

```bash
make -f Makefile.ocm deploy-apply
```

This creates:
- `ComponentVersion` greenhouse — points OCM controller at the bundle in ghcr.io
- `Resource` CRs — one per chart + one for the kro RGD, trigger OCM to sync each artifact into the internal registry as a `Snapshot`
- `Deployer` greenhouse-stack — applies the kro RGD YAML directly to the cluster (no Flux HelmRelease for this step)

**Screenshot placeholder:**
```
[SCREENSHOT: make deploy-apply output — namespace/componentversion/deployer/resource lines all showing "created" or "configured"]
```

Watch OCM + Flux objects become ready (~2–3 min):

```bash
make -f Makefile.ocm deploy-status
```

**Screenshot placeholder:**
```
[SCREENSHOT: make deploy-status — ComponentVersion Ready, all Resources Ready, Deployer exists, greenhouse-stack-rgd Snapshot Ready]
```

---

## Step 6 — Deploy the GreenhouseStack Instance

Wait for kro to process the RGD and create the `GreenhouseStack` CRD, then apply the instance:

```bash
make -f Makefile.ocm deploy-instance
```

The instance references the OCM Snapshot paths. To get the current paths from a live cluster:

```bash
make -f Makefile.ocm snapshot-urls
```

kro then creates OCIRepositories and HelmReleases for:
- `cert-manager` → installs in `cert-manager` namespace
- `ocm-controller` → installs in `ocm-system` namespace (depends on cert-manager)
- `greenhouse` → installs in `greenhouse` namespace (depends on cert-manager + ocm-controller)

Watch the HelmReleases reconcile:

```bash
make -f Makefile.ocm deploy-watch
```

**Screenshot placeholder:**
```
[SCREENSHOT: make deploy-watch — cert-manager True, ocm-controller True, greenhouse True in order]
```

---

## Step 7 — Verify

```bash
make -f Makefile.ocm deploy-status
```

**Screenshot placeholder — final full status:**
```
[SCREENSHOT: make deploy-status final state]
```

Expected final state:

```
ComponentVersion:  greenhouse   Ready=True   0.16.1
Resources:         all 5        Ready=True
Deployer:          greenhouse-stack  (applies kro RGD)
HelmReleases:      cert-manager, ocm-controller, greenhouse  all Ready=True
GreenhouseStack:   greenhouse   ACTIVE  Ready=True
Pods (greenhouse): controller-manager x3, cors-proxy x2, webhook x2 — all Running
Pods (cert-manager): cert-manager, cainjector, webhook — Running
Pods (ocm-system):   ocm-controller, registry — Running
Pods (kro-system):   kro — Running
Pods (flux-system):  helm-controller, source-controller, kustomize-controller, notification-controller — Running
```

**Screenshot placeholder:**
```
[SCREENSHOT: kubectl get pods -n greenhouse showing all Running]
```

```bash
# Check GreenhouseStack instance
kubectl get greenhousestack -n greenhouse
```

**Screenshot placeholder:**
```
[SCREENSHOT: kubectl get greenhousestack showing STATE=ACTIVE READY=True]
```

---

## Troubleshooting

### OCM controller pods stuck in `ContainerCreating`

**Symptom:** `MountVolume.SetUp failed for volume "certificates": secret "ocm-registry-tls-certs" not found`

**Cause:** `tlsCert.generateTlsCert` defaults to `false` in the OCM controller chart — cert-manager never receives a `Certificate` CR to create the secret.

**Fix:** The Makefile passes `--set tlsCert.generateTlsCert=true`. If installing manually, include:
```bash
helm upgrade --install ocm-controller ... --set tlsCert.generateTlsCert=true
```

---

### cert-manager install fails: CRD ownership conflict

**Symptom:**
```
Error: unable to continue with install: CustomResourceDefinition "certificaterequests.cert-manager.io"
exists ... annotation validation error: key "meta.helm.sh/release-name" must equal "cert-manager":
current value is "cert-manager-cert-manager"
```

**Cause:** Orphaned cert-manager CRDs from a previous partial install under a different release name.

**Fix:**
```bash
kubectl delete crd \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io
```

---

### kro RGD stays `Inactive`

**Symptom:**
```
type mismatch: expression "schema.spec.tlsSecretName" returns type "__type_schema.spec.tlsSecretName"
but expected "string"
```

**Cause:** kro v0.9.4 uses **SimpleSchema** for field type declarations. The old `{type: string}` object format causes kro to fail type inference, returning opaque `__type_schema.*` types that cannot be used in CEL expressions.

**Fix:** Schema fields must use inline type strings:
```yaml
# WRONG (kro v0.9.x)
spec:
  fieldName:
    type: string

# CORRECT (SimpleSchema)
spec:
  fieldName: "string"
```

Status fields must use CEL expressions projecting from resources:
```yaml
# WRONG
status:
  someField:
    type: string

# CORRECT
status:
  someField: "${resourceId.status.someField}"
```

---

### `flux install` fails: `timeout waiting for Namespace/flux-system status: NotFound`

**Cause:** `flux uninstall` was called and the namespace is still terminating, or there is a timing issue.

**Fix:** Wait 30s and retry `make bootstrap-flux`. The target now detects if Flux is already installed and skips the uninstall entirely.

> **Never call `make deploy-full` on a cluster where steps have already been partially applied.** It was designed for a completely fresh cluster. For incremental installs, call individual targets.

---

### Stuck HelmRelease

```bash
# Recover a stuck HelmRelease (replace cert-manager with the stuck release name)
make -f Makefile.ocm flux-fix APP=cert-manager
```

---

### Force re-pull from ghcr.io after pushing a new bundle

```bash
# Force OCM to reconcile ComponentVersion + all Resource CRs
make -f Makefile.ocm deploy-reconcile-ocm

# Then watch for Snapshots to update
make -f Makefile.ocm deploy-status
```

> **Note:** OCM caches by tag. If you push the same version tag with new chart content, OCM will serve the cached version. Bump `GREENHOUSE_VERSION` to guarantee a cache-miss, or delete the relevant Snapshot to force a re-pull.

---

## Upgrading

1. Update version variables in `Makefile.ocm`
2. `make package build push GITHUB_TOKEN=$GITHUB_TOKEN`
3. `make deploy-reconcile-ocm` — OCM pulls the new bundle and updates Snapshots
4. Update `deploy/instance.yaml` snapshot paths with `make snapshot-urls`
5. `kubectl apply -f deploy/instance.yaml`

---

## Known Issues

| Issue | Workaround |
|---|---|
| Two cert-manager installs after `deploy-full` on a cluster where cert-manager was already manually installed | The bootstrap target (`install-cert-manager`) installs under release name `cert-manager`; the GreenhouseStack instance installs under `cert-manager-cert-manager`. Both are functional but redundant. Remove the manually-installed one with `helm uninstall cert-manager -n cert-manager`. |
| kro `GreenhouseStack` status fields not reflecting HelmRelease conditions | The status CEL expressions use `conditions[0]` which may not always be the `Ready` condition — cosmetic only, does not affect deployment. |
