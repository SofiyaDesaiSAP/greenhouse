# Pre-Demo Reading: Bundle Greenhouse Core as an OCM Artifact

> **User Story:** As a greenhouse operator, installation of greenhouse should be done via OCM so
> that it can be securely delivered in a sovereign cloud / air-gapped environment.
>
> **This document explains every command you will run and why, so you can narrate confidently.**

---

## The Big Picture — What You Are About to Prove

The three acceptance criteria map directly to three moments in the demo:

| Acceptance Criteria | Where it is proved | Key command |
|---|---|---|
| greenhouse chart as OCM artifact | Part 0 — build step | `ocm add componentversions` |
| prerequisites are part of the artifact | Part 0 — same build | 6-component CTF bundle |
| core components installable via OCM | Part 4 — deploy step | `GreenhouseStack` CR |

The mental model: OCM is the **packaging and transport layer**. You build one bundle that
contains the greenhouse Helm chart AND all its prerequisites. You sign it, transfer it to the
on-site registry, and then the cluster installs everything from that registry alone — the
only commands you run against the cluster are `kubectl apply`. Two ResourceGraphDefinitions
drive the full lifecycle: one bootstraps the cluster (cert-manager + OCM controller), the
other installs greenhouse itself.

**Session setup — run once at the start:**

```bash
cd /Users/i779118/projects/sci-k8s-cluster/greenhouse/ocm

export GITHUB_TOKEN=$(gh auth token --hostname github.com)
export GITHUB_USER=sofiyadesaisap
export KUBECONFIG=/path/to/cluster-kubeconfig.yaml
```

---

## Technology Primer

> Read this section first if any of these tools are new to you.

### OCM — Open Component Model

[OCM](https://ocm.software) is an open standard for describing, packaging, signing, and
transporting software artifacts in a vendor-neutral, registry-agnostic way. Think of it as
a "bill of materials + shipping container" for cloud-native software.

Key concepts:
- **Component version** — a versioned, named artifact (e.g. `github.com/cloudoperators/greenhouse:0.16.1`) that contains resources (Helm charts, container images, raw YAML) and can reference other component versions
- **Component descriptor** — the metadata file inside a component version that lists all resources with their content digests and references to sub-components
- **CTF (Common Transport Format)** — an OCI layout directory on disk; OCM's local bundle format before pushing to a registry
- **Signature** — one keyless Sigstore signature over the component descriptor transitively covers every chart, image, and sub-component in the bundle

In this demo OCM is used to: build a multi-component bundle, sign it once, transfer it across the air gap, and let the OCM controller reconcile it on-cluster.

[OCM docs](https://ocm.software/docs/) · [OCM CLI reference](https://ocm.software/docs/reference/ocm-cli/)

---

### component-constructor.yaml

`component-constructor.yaml` is the OCM build manifest — the recipe file that `ocm add componentversions` reads to assemble the bundle. It defines:

- What each component version is named and versioned
- Where each resource comes from (local directory, OCI chart URL, plain YAML file)
- Which sub-components the umbrella component references

Variable placeholders like `${GREENHOUSE_VERSION}` are expanded by the `--addenv` flag at build time, so versions are injected from the environment rather than hardcoded in the file. The `component-constructor.yaml` in this repo lives at `ocm/component-constructor.yaml`.

---

### kro — Kubernetes Resource Orchestrator

[kro](https://kro.run) is a Kubernetes controller that lets you define **composite custom resources**. You write a `ResourceGraphDefinition` (RGD) once; kro registers a new CRD from it. An operator then applies a single CR of that custom kind — kro expands it into all the underlying Kubernetes objects the RGD templates.

Why it matters here: instead of a human applying 6+ Flux CRs by hand (one `OCIRepository` + one `HelmRelease` per component, with the right `dependsOn` and values), the operator applies one `GreenhouseStack` CR and kro handles the expansion.

[kro docs](https://kro.run/docs/) · [kro GitHub](https://github.com/kro-run/kro)

---

### ResourceGraphDefinition (RGD)

An RGD is the CRD-schema + resource-template pairing that kro processes. It has two sections:

- **`spec.schema`** — defines the new custom kind (name, API version, spec fields, status fields). Status fields are CEL expressions that project from managed resource conditions back to the CR.
- **`spec.resources`** — a list of Kubernetes resource templates with `${schema.spec.*}` variable references. kro applies these in dependency order when a CR instance is created.

This demo uses two RGDs:

| RGD file | Custom kind | What it provisions |
|---|---|---|
| `deploy/bootstrap-rgd.yaml` | `GreenhouseBootstrap` | prometheus-operator CRDs, cert-manager, OCM controller |
| `deploy/kro-rgd.yaml` | `GreenhouseStack` | cert-manager, OCM controller, greenhouse (all from OCM Snapshots) |

---

### Flux

[Flux](https://fluxcd.io) is a GitOps toolkit for Kubernetes. In this demo it acts purely as the **Helm deployment engine** — kro creates `OCIRepository` and `HelmRelease` CRs, and Flux's `source-controller` + `helm-controller` watch those CRs and run the actual Helm installs. Flux is not doing GitOps here; it is used as the standard Helm-over-OCI operator that ships with most clusters.

[Flux docs](https://fluxcd.io/flux/)

---

### Sigstore / Keyless Signing

[Sigstore](https://www.sigstore.dev) is an open-source supply-chain security project. **Keyless signing** means no long-lived private key: you log in with your OIDC identity (Google, GitHub, Microsoft), Sigstore's Fulcio CA issues a short-lived certificate tied to your email, and the resulting signature + Rekor transparency log proof is embedded in the OCM component descriptor. Anyone can verify the signature offline using only the public Sigstore trust root.

[Sigstore docs](https://docs.sigstore.dev) · [Fulcio](https://docs.sigstore.dev/certificate_authority/overview/) · [Rekor](https://docs.sigstore.dev/logging/overview/)

---

## PART 0 — Building the OCM Bundle *(done before demo)*

> This is the "greenhouse chart as OCM artifact" proof. These steps happen on your laptop before
> the demo starts. You won't run them live, but you need to explain what they produced.

### What the build produces

The `ocm add componentversions` command reads `component-constructor.yaml` and outputs a
`greenhouse-bundle.ctf/` directory — a CTF archive (see Technology Primer). It contains
6 component versions:

- The **greenhouse Helm chart** (packaged from the local `charts/greenhouse/` directory)
- **cert-manager** chart (fetched directly from its source OCI registry)
- **kro** chart (fetched directly from `registry.k8s.io`)
- **OCM controller** chart (fetched from `ghcr.io/open-component-model`)
- **Flux** chart (fetched from its source)
- A **kro-rgd** YAML resource (the ResourceGraphDefinition that defines the `GreenhouseStack` CRD)

All 6 become separate **component versions** inside the bundle, linked by an umbrella
`greenhouse` component. The umbrella's component descriptor references all 5 sub-components,
so `ocm transfer --recursive` moves all 6 in one shot.

**Talking point for the audience:** "The greenhouse chart — with all its subcharts baked in —
and every prerequisite are now a single versioned artifact. There is one thing to sign, one
thing to transfer, one thing to verify."

---

### Step 1 — Resolve Greenhouse Chart's Subchart Dependencies

```bash
helm dependency update ../charts/greenhouse
```

**Why this step exists:** The greenhouse Helm chart has 5 subcharts (`manager`, `idproxy`,
`cors-proxy`, `authz`, `dashboard`) declared as `file://` references in `Chart.yaml`. This
means they live as sibling directories in the repo, not in a Helm repository. When OCM packages
the `charts/greenhouse/` directory it does a straight directory copy — it does not know how to
resolve `file://` subchart references itself. `helm dependency update` does that resolution:
it copies the subchart directories into `charts/greenhouse/charts/` so OCM finds a
fully self-contained chart directory to package.

**Run once** per checkout, or whenever a subchart is added or changed.

---

### Step 2 — Build the Multi-Component CTF Archive

```bash
rm -rf greenhouse-bundle.ctf

ocm add componentversions \
  --addenv \
  --file greenhouse-bundle.ctf \
  --create \
  component-constructor.yaml \
  GREENHOUSE_VERSION=0.16.1 \
  "GREENHOUSE_IMAGE_REF=ghcr.io/cloudoperators/greenhouse:v0.16.1" \
  "DASHBOARD_IMAGE_REF=ghcr.io/cloudoperators/juno-app-greenhouse@sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631" \
  CERT_MANAGER_VERSION=1.20.1 \
  FLUX_VERSION=2.15.0 \
  KRO_VERSION=0.9.4 \
  OCM_CONTROLLER_VERSION=0.33.0
```

**What `--addenv` does:** OCM reads env vars at build time. The `component-constructor.yaml`
file has `${GREENHOUSE_VERSION}` placeholders — `--addenv` expands them directly, with no
external `envsubst` needed. See the Technology Primer for what `component-constructor.yaml` is.

**What gets produced:** A `greenhouse-bundle.ctf/` directory — an OCI layout containing 6
component versions. The umbrella component `github.com/cloudoperators/greenhouse:0.16.1`
references all 5 others via component references. When you later do `ocm transfer --recursive`,
OCM follows those references and moves all 6 together.

---

### Step 2b — Sign the Bundle (Keyless / Sigstore)

```bash
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse:0.16.1
```

**What keyless signing means:** See the Technology Primer (Sigstore section). In short: no
key pair, browser OIDC login, Fulcio issues a short-lived certificate, the resulting Sigstore
bundle is embedded in the OCM component descriptor.

**What the signature covers:** OCM computes a digest over the component descriptor content —
this descriptor contains the content digest of every chart, every image, and every
sub-component. So one signature transitively covers the entire bundle. If any single blob is
tampered with, the content digest changes, and the verify step fails.

**What the signature does NOT cover:** Pod admission. Kyverno `verifyImages` cannot see this
signature — it lives in the OCM descriptor, not on the container image. For this PoC the OCM
signature is the boundary integrity gate.

**Talking point:** "One signature, no key management, transitive coverage of the entire bundle.
The signed digest excludes storage location so it survives the transfer to the on-site registry
without invalidation."

---

### Step 3 — Verify the Local Archive Before Pushing

```bash
ocm get componentversion \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse:0.16.1

ocm get componentversion \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/core:0.16.1

ocm get componentversion \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/prerequisites/cert-manager:1.20.1

ocm get componentversion \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/prerequisites/flux:2.15.0

ocm get componentversion \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/prerequisites/kro:0.9.4

ocm get componentversion \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/prerequisites/ocm-controller:0.33.0
```

Expected: all 6 rows appear without error.

---

### Step 4 — Push the CTF to GHCR (Central Registry)

```bash
GITHUB_TOKEN=$GITHUB_TOKEN ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/sofiyadesaisap/greenhouse
```

**Critical flag — `--copy-resources`:** Without this, OCM pushes only the component
descriptors (small JSON metadata) and leaves all chart tarballs and image blobs as unresolved
external references. With `--copy-resources`, OCM fetches every referenced artifact and embeds
the actual blobs into GHCR — making the bundle truly self-contained for air-gapped use.

**Verify it landed in GHCR:**

```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.16.1" \
  --recursive
```

Expected: 6 rows. The `//` separator is OCM syntax — everything left of `//` is the registry,
everything right is the component path.

---

### Step 5 — If `component-constructor.yaml` was changed (rebuild + re-sign + re-transfer)

Any change to `component-constructor.yaml` (e.g. switching `input.type: helm` to
`access.type: ociArtifact`, bumping a version, adding a resource) requires a full rebuild
of the CTF bundle, a new signature, and re-transfer to both GHCR and RBSC.

```bash
# 1. Rebuild the CTF from scratch
rm -rf greenhouse-bundle.ctf
ocm add componentversions \
  --addenv \
  --file greenhouse-bundle.ctf \
  --create \
  component-constructor.yaml \
  GREENHOUSE_VERSION=0.16.1 \
  "GREENHOUSE_IMAGE_REF=ghcr.io/cloudoperators/greenhouse:v0.16.1" \
  "DASHBOARD_IMAGE_REF=ghcr.io/cloudoperators/juno-app-greenhouse@sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631" \
  CERT_MANAGER_VERSION=1.20.1 \
  FLUX_VERSION=2.15.0 \
  KRO_VERSION=0.9.4 \
  OCM_CONTROLLER_VERSION=0.33.0

# 2. Re-sign the new CTF (browser opens for OIDC login)
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse:0.16.1

# 3. Re-push to GHCR (central registry)
GITHUB_TOKEN=$GITHUB_TOKEN ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/sofiyadesaisap/greenhouse

# 4. Verify the signature on GHCR before transferring to RBSC
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://ghcr.io/sofiyadesaisap/greenhouse \
  github.com/cloudoperators/greenhouse:0.16.1

# 5. Re-transfer to RBSC
ocm transfer componentversion \
  --copy-resources \
  --recursive \
  --overwrite \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.16.1" \
  oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc
```

After the RBSC is updated, the OCM controller on-cluster will reconcile the
`ComponentVersion` CR and re-extract updated Snapshots automatically (on the next poll
interval, or trigger immediately with `kubectl annotate componentversion greenhouse \
reconcile.ocm.software/requestedAt="$(date +%s)" -n greenhouse`).

---

## PART 1 — Air-Gap Transfer *(shown live in the demo)*

> This is the sovereign cloud / air-gap story. One command moves the entire bundle — charts
> AND container image blobs — from the central registry to the simulated on-site registry.
> This is the only step that requires outbound internet access.

### The Signature Gate — Verify Before Crossing

```bash
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://ghcr.io/sofiyadesaisap/greenhouse \
  github.com/cloudoperators/greenhouse:0.16.1
```

**Why you run this BEFORE the transfer:** This is the integrity gate at the air-gap boundary.
The command re-computes the content digests of every chart and image in the bundle and checks
them against the signed descriptor. If anyone tampered with a chart tarball or swapped an image
after signing, this step fails — and the bundle never reaches the on-site registry.

Expected output: `Verification succeeded` — identity shows your email, issuer shows your OIDC
provider. Only if you see this do you proceed.

---

### Transfer to the On-Site Registry

```bash
ocm transfer componentversion \
  --copy-resources \
  --recursive \
  --overwrite \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.16.1" \
  oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc
```

**`--recursive`:** Follows component references and transfers all 6 components.

**`--copy-resources`:** Copies image blobs, not just manifest references.

**Path preservation:** OCM strips the source registry host and keeps the original path. An
image declared as `ghcr.io/cloudoperators/greenhouse:v0.16.1` ends up at
`ghcr.io/sofiyadesaisap/greenhouse-rbsc/cloudoperators/greenhouse:v0.16.1`. A chart declared
as `ghcr.io/open-component-model/helm/ocm-controller` ends up at
`ghcr.io/sofiyadesaisap/greenhouse-rbsc/open-component-model/helm/ocm-controller`. This
predictable path is exactly what the bootstrap RGD uses to pull charts from the RBSC.

**Talking point:** "After this command completes, the cluster has no network path to any
external registry. Everything — bootstrap charts, greenhouse charts, container images — is
in `greenhouse-rbsc`."

**Verify:**

```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc//github.com/cloudoperators/greenhouse:0.16.1" \
  --recursive
```

Same 6 rows, now in the RBSC (on-site) registry.

---

## PART 2 — Cluster Bootstrap

> The cluster needs Flux and kro before any ResourceGraphDefinition can run. These two are
> the only direct Helm installs in the entire demo — everything else goes through kro.

### Step 1 — Install Flux (irreducible minimum)

```bash
flux install

kubectl rollout status deploy/source-controller -n flux-system --timeout=120s
kubectl rollout status deploy/helm-controller   -n flux-system --timeout=120s
```

**Why Flux is needed:** kro expands ResourceGraphDefinitions into Flux `OCIRepository` and
`HelmRelease` objects. Flux's `helm-controller` is what actually runs the Helm installs.
OCM = delivery and orchestration layer; Flux = deployment executor.

---

### Step 2 — Install kro (irreducible minimum)

```bash
helm upgrade --install kro \
  oci://registry.k8s.io/kro/charts/kro \
  --namespace kro-system \
  --create-namespace \
  --version 0.9.4 \
  --wait --timeout 5m
```

**Why kro is needed:** kro processes `ResourceGraphDefinition` objects and creates a custom
CRD (`GreenhouseBootstrap`, `GreenhouseStack`). The operator then applies a single CR — kro
expands it into all the `OCIRepository` and `HelmRelease` objects needed. Without kro, you
would need to create those Flux objects by hand.

**Talking point:** "These are the only two direct Helm commands in this demo. Everything else
— cert-manager, the OCM controller, and greenhouse itself — is installed by kro expanding a CR
into Flux resources."

---

### Step 3 — Grant RBAC to helm-controller

```bash
kubectl create clusterrolebinding helm-controller-cluster-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=flux-system:helm-controller \
  --dry-run=client -o yaml | kubectl apply -f -
```

Gives `helm-controller` cluster-admin so it can install CRDs and `ClusterRole`s. Required for
cert-manager, OCM controller, and kro installs via HelmRelease.

---

### Step 4 — Create the greenhouse namespace and registry secret

The namespace must exist before OCM and bootstrap manifests can be applied. The registry
secret is needed for **both the bootstrap** (cert-manager and OCM controller OCIRepositories
pull from the private RBSC) and the **main deploy** (OCM controller pulls the bundle from RBSC),
so create it now.

```bash
kubectl create namespace greenhouse --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry greenhouse-ocm-registry-creds \
  --namespace greenhouse \
  --docker-server=ghcr.io \
  --docker-username=$GITHUB_USER \
  --docker-password=$GITHUB_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

### Step 5 — Apply bootstrap manifests (kro RGDs only)

```bash
kubectl apply -k deploy/
```

This applies:
- `namespace.yaml` — greenhouse namespace (idempotent)
- `kro-rgd.yaml` — `GreenhouseStack` RGD (kro processes immediately, creates `GreenhouseStack` CRD)
- `bootstrap-rgd.yaml` — `GreenhouseBootstrap` RGD (kro processes immediately, creates `GreenhouseBootstrap` CRD)

**Why `componentversion.yaml` and `resources.yaml` are NOT here:** Those are OCM CRs
(`ComponentVersion`, `Resource`) whose CRDs are registered by the OCM controller — which
doesn't exist yet. Applying them now would fail with `no matches for kind`. They are applied
separately in Part 4 after the bootstrap completes and the OCM controller is running.

---

### Step 6 — Apply the bootstrap instance

Wait for kro to create the `GreenhouseBootstrap` CRD:

```bash
kubectl get crd greenhousebootstraps.kro.run
```

Then apply the instance:

```bash
kubectl apply -f deploy/bootstrap-instance.yaml
```

**What kro expands this into:**

```
OCIRepository/prometheus-crds-bootstrap  → oci://ghcr.io/prometheus-community/charts/...   (public OCI — exception)
OCIRepository/cert-manager-bootstrap     → oci://<rbscRegistry>/cloudoperators/greenhouse-extensions/charts/cert-manager
OCIRepository/ocm-controller-bootstrap   → oci://<rbscRegistry>/open-component-model/helm/ocm-controller

HelmRelease/prometheus-crds  → installs prometheus-operator CRDs   (monitoring ns)
HelmRelease/cert-manager     → installs cert-manager               (cert-manager ns)  ← parallel with prometheus-crds
HelmRelease/ocm-controller   → installs OCM controller             (ocm-system ns)    ← dependsOn: cert-manager
```

**Why cert-manager and OCM controller pull from the RBSC:** In `component-constructor.yaml`,
these charts use `access.type: ociArtifact`. When `ocm transfer --copy-resources` runs, OCM
applies its path-preservation rule: it strips the source registry host and copies the chart
blob to the RBSC at the same path. So `ghcr.io/cloudoperators/greenhouse-extensions/charts/cert-manager`
becomes `<rbscRegistry>/cloudoperators/greenhouse-extensions/charts/cert-manager` — the exact
URL the bootstrap OCIRepository targets. Flux can consume this directly without the OCM
controller as intermediary, which solves the chicken-and-egg problem.

**Why prometheus-operator-crds is the one exception:** It is not part of the OCM bundle —
greenhouse unconditionally creates `PrometheusRule` resources, but prometheus-crds was
intentionally left as a cluster-level dependency rather than bundled. It always pulls from
public OCI. This is documented explicitly and does not affect air-gap compliance for the
core components.

**Content integrity:** The OCM bundle signature (`ocm sign`) records content digests for cert-manager
and the OCM controller chart in the signed component descriptor. `ocm verify` confirms those
digests before the transfer runs, so the bootstrap charts are still covered by the supply-chain
integrity boundary.

**After the RBSC transfer completes, trigger immediate reconciliation** (don't wait for the
10m interval to expire):

```bash
kubectl annotate ocirepository cert-manager-bootstrap -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate ocirepository ocm-controller-bootstrap -n greenhouse \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

**Watch the bootstrap unfold:**

```bash
kubectl get helmreleases -n greenhouse -w
```

Expected order: `prometheus-crds` + `cert-manager` Ready (in parallel), then `ocm-controller`
Ready. Once `ocm-controller` is Ready, the OCM controller pod starts in `ocm-system` and
begins reconciling the ComponentVersion and Resource CRs applied in Step 5.

---

### Step 7 — Apply Flux extension stub CRDs

```bash
kubectl apply -f prereqs/flux-extension-stubs.yaml
```

Greenhouse v0.16.1+ controller-manager watches `ArtifactGenerator` from
`source.extensions.fluxcd.io`. Without this stub CRD, the greenhouse controller-manager
enters `CrashLoopBackOff` on startup because Kubernetes rejects its watch on an unknown API.

---

### Step 8 — Copy the OCM TLS certificate

Wait for the OCM controller to generate its internal registry TLS certificate:

```bash
kubectl get secret ocm-registry-tls-certs -n ocm-system
```

Then copy it to the greenhouse namespace (kro-generated `OCIRepository` objects for the main
greenhouse deploy reference this secret via `certSecretRef`):

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

**Why this is needed:** The OCM controller's internal registry at
`registry.ocm-system.svc.cluster.local:5000` uses a self-signed TLS cert. The
`OCIRepository` objects that kro creates in the main greenhouse deploy (Part 4) pull chart
Snapshots from that internal registry and verify the cert against this secret. Without the
copy, all those pulls fail with a TLS error.

---

## PART 3 — Remaining Secrets *(one-time per cluster)*

The namespace and registry secret were already created in Part 2. Only two secrets remain.

### Create the Greenhouse Helm values secret

```bash
cp deploy/greenhouse-values-example.yaml greenhouse-values.yaml
# edit greenhouse-values.yaml — at minimum set global.dnsDomain and OIDC config

kubectl create secret generic greenhouse-values \
  --namespace greenhouse \
  --from-file=values.yaml=greenhouse-values.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

The greenhouse Helm chart needs environment-specific values (domain, OIDC issuer, etc.).
Stored as a secret so they are not committed to the repo. The `GreenhouseStack` CR references
it by name via `spec.valuesSecretName`.

---

## PART 4 — Deploy *(THE DEMO MOMENT)*

> This is where you prove Acceptance Criteria 3: "greenhouse core components should be
> installable via OCM." Apply the OCM CRs now that the OCM controller is running, then
> the main kro RGD takes over.

### Step 1 — Apply the OCM CRs

The OCM controller CRDs (`ComponentVersion`, `Resource`) are now registered. Apply the files
that were excluded from the kustomization:

```bash
kubectl apply -f deploy/componentversion.yaml
kubectl apply -f deploy/resources.yaml
```

### Step 2 — Watch OCM resolve the bundle

### Step 2 — Watch OCM resolve the bundle

```bash
kubectl get componentversions,resources -n greenhouse
```

Wait until `ComponentVersion` shows `READY=True` (bundle fetched from RBSC) and all 5
`Resource` objects show `READY=True` (chart blobs extracted as Snapshots).

### Get the Snapshot paths

```bash
kubectl get snapshot -n greenhouse \
  -o custom-columns='RESOURCE:.metadata.ownerReferences[0].name,REPO:.status.repositoryURL,TAG:.status.tag'
```

Output looks like:

```
RESOURCE               REPO                      TAG
cert-manager-chart     sha-15457104823554620187   1.20.1
kro-chart              sha-<hash>                 0.9.4
ocm-controller-chart   sha-3868847230746277828    0.33.0
greenhouse-chart       sha-6660783123634428906    0.16.1
greenhouse-stack-rgd   sha-<hash>                 0.16.1
```

**Why you need these:** kro generates `OCIRepository` objects with URLs like
`oci://registry.ocm-system.svc.cluster.local:5000/<sha-hash>`. The `sha-NNNN` paths are
assigned by the OCM controller at extraction time and are cluster-specific. You put them
into `deploy/instance.yaml` before applying the `GreenhouseStack` instance.

---

### Update `deploy/instance.yaml`

```yaml
spec:
  registryHost: "registry.ocm-system.svc.cluster.local:5000"
  imageRegistry: "ghcr.io/sofiyadesaisap/greenhouse-rbsc"

  certManagerSnapshotPath: "sha-15457104823554620187"
  certManagerVersion: "1.20.1"

  ocmControllerSnapshotPath: "sha-3868847230746277828"
  ocmControllerVersion: "0.33.0"

  greenhouseSnapshotPath: "sha-6660783123634428906"
  greenhouseVersion: "0.16.1"

  greenhouseImageDigest: "sha256:0c0cac95a1dafbb9a22d64aaf3cc425e990f2eb9b7863b3e53749e2878472b13"
  dashboardImageDigest: "sha256:ae366951d37198d05d6b3d5859dec8181530d380ea7b9a8a8cfc5a8f07937631"

  tlsSecretName: "ocm-registry-tls-certs"
  valuesSecretName: "greenhouse-values"
```

**`registryHost`:** The OCM controller's internal registry. All main `OCIRepository` objects
pull chart Snapshots from here.

**`imageRegistry`:** The RBSC prefix. kro injects this into every subchart's `image.repository`
so pods pull images from the RBSC.

**`*SnapshotPath`:** The `sha-NNNN` values from above — path inside the OCM internal registry
where the OCM controller deposited each chart tarball.

**`greenhouseImageDigest`:** All four core components (`manager`, `idproxy`, `cors-proxy`,
`authz`) share the same binary image. Setting `image.digest` means pods run as
`repository@sha256:...` instead of `repository:tag`.

---

### Apply the GreenhouseStack instance

Wait for the `GreenhouseStack` CRD (kro created it when it processed `kro-rgd.yaml`):

```bash
kubectl get crd greenhousestacks.kro.run
```

Then apply:

```bash
kubectl apply -f deploy/instance.yaml
```

**What kro expands this into:**

```
OCIRepository/cert-manager    → oci://registry.../sha-15457...  tag:1.20.1
OCIRepository/ocm-controller  → oci://registry.../sha-38688...  tag:0.33.0
OCIRepository/greenhouse      → oci://registry.../sha-66607...  tag:0.16.1

HelmRelease/cert-manager      → chartRef: OCIRepository/cert-manager
HelmRelease/ocm-controller    → chartRef: OCIRepository/ocm-controller  dependsOn: cert-manager
HelmRelease/greenhouse        → chartRef: OCIRepository/greenhouse       dependsOn: cert-manager, ocm-controller
```

These OCIRepositories pull from the OCM internal registry (Snapshots), not from RBSC directly.
Flux installs in dependency order: **cert-manager → ocm-controller → greenhouse**.

**Watch it unfold:**

```bash
# Watch kro expand the CR
kubectl get greenhousestack -n greenhouse -w

# Watch OCIRepositories become ready
kubectl get ocirepository -n greenhouse

# Watch HelmReleases install in order
kubectl get helmreleases -n greenhouse -w
```

---

## PART 5 — Verify

### Full status check

```bash
kubectl get componentversion   -n greenhouse
kubectl get resource           -n greenhouse
kubectl get greenhousestack    -n greenhouse
kubectl get helmrelease        -n greenhouse
kubectl get pods               -n greenhouse
kubectl get pods               -n cert-manager
kubectl get pods               -n ocm-system
kubectl get pods               -n kro-system
kubectl get pods               -n flux-system
```

Expected final state:

```
ComponentVersion:  greenhouse        Ready=True   0.16.1
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

---

### Prove zero external registry dependency

```bash
kubectl get pods -n greenhouse \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

**Every line must start with `ghcr.io/sofiyadesaisap/greenhouse-rbsc/`.**

This is the air-gap proof. No pod is pulling from `ghcr.io/cloudoperators` or any other
external registry. Everything comes from the RBSC populated by the one-time `ocm transfer`.

---

## Acceptance Criteria — Final Checklist

| Criterion | Evidence |
|---|---|
| ✅ greenhouse chart as OCM artifact | `ocm get componentversions --recursive` shows `greenhouse` + `core` in GHCR and RBSC |
| ✅ prerequisites are part of the artifact | Same bundle contains cert-manager, Flux, kro, OCM controller as separate component versions |
| ✅ core components installable via OCM | `GreenhouseStack ACTIVE`, all HelmReleases `Ready=True`, pods Running — all images from RBSC |

---

## Quick Troubleshooting Reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `GreenhouseBootstrap CRD not found` | kro hasn't processed bootstrap-rgd.yaml yet | Wait 30s; check `kubectl get pods -n kro-system` |
| `cert-manager / ocm-controller HelmRelease` stuck | OCIRepository pull failing from RBSC | Check registry secret is in `greenhouse` ns; verify RBSC paths in `bootstrap-instance.yaml` |
| `ComponentVersion READY=False` | Transfer failed or registry secret wrong | Re-run `ocm transfer`; re-create registry secret |
| `OCIRepository: secret not found` (main deploy) | TLS cert not copied to greenhouse ns | Re-run the TLS copy command (Part 2 Step 8) |
| `HelmRelease stuck past timeout` | Helm state corrupted | Delete the HelmRelease + its helm secret, restart `helm-controller`, re-apply `kubectl apply -k deploy/` |
| `GreenhouseStack CRD not found` | kro hasn't processed kro-rgd.yaml yet | Wait 30s; `kubectl get resourcegraphdefinition -n greenhouse` |
| `CrashLoopBackOff: ArtifactGenerator CRD` | Flux extension stubs not applied | `kubectl apply -f prereqs/flux-extension-stubs.yaml` |
| `ImagePullBackOff` | `imageRegistry` wrong in `instance.yaml` | Verify it matches the RBSC path exactly; re-apply `kubectl apply -f deploy/instance.yaml` |
