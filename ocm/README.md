# Bundling Greenhouse as an OCM Artifact and Pushing to GHCR

## The Story

You are a platform engineer. Your job is to ship the entire **Greenhouse platform** — its
application chart, all dependencies (cert-manager, flux, kro, the OCM controller) — as a
**single, versioned, self-contained artifact** that can be pulled and deployed on any
Kubernetes cluster without anyone manually hunting down charts or YAML files.

The tool that does this is **OCM — the Open Component Model**.

> For deploying the bundle onto a cluster after it is pushed, see
> [greenhouse-ocm-deployment-guide.md](greenhouse-ocm-deployment-guide.md).

---

## Chapter 1: What is OCM and Why Should You Care?

Think of OCM like a shipping container for software. Just as a shipping container can hold
many different goods (boxes, liquids, machinery), an OCM **component** can hold many
different software artifacts (Helm charts, container images, YAML manifests).

Three ideas you need to hold in your head:

### 1. Component

A component is a named, versioned unit of software. Like a package on npm or a Maven
artifact — but for platform software. It has a name that looks like a Go module path:

```
github.com/cloudoperators/greenhouse                        ← the whole product
github.com/cloudoperators/greenhouse/core                   ← just the greenhouse app
github.com/cloudoperators/greenhouse/prerequisites/cert-manager
```

### 2. Resource

Each component contains resources — the actual files. A resource can be:

- A **Helm chart** (`type: helmChart`)
- A **container image** (`type: ociImage`)
- A **YAML file or directory** (`type: blob`)

### 3. CTF — Common Transport Format

Before pushing to a registry, OCM assembles everything locally into a **CTF directory**
(`greenhouse-bundle.ctf/`). Think of it as the packed shipping container sitting on the
dock before it goes onto the ship. The "ship" is GHCR.

```
Your machine                              GHCR
──────────────────────────────────        ──────────────────────────────────────
component-constructor.yaml (recipe)       ghcr.io/<your-org>/greenhouse/
        │                                 component-descriptors/
        ▼                                 ├── github.com/cloudoperators/greenhouse:0.16.1
ocm add componentversions                 ├── .../greenhouse/core:0.16.1
        │                                 ├── .../prerequisites/cert-manager:1.20.1
        ▼                                 ├── .../prerequisites/flux:2.15.0
greenhouse-bundle.ctf/ ──── push ──────►  ├── .../prerequisites/kro:0.9.4
                                          └── .../prerequisites/ocm-controller:0.33.0
```

---

## Chapter 2: What Exactly Are We Bundling?

One top-level component that references everything else:

```
github.com/cloudoperators/greenhouse:0.16.1               ← top-level (references all below)
│
├── github.com/cloudoperators/greenhouse/core:0.16.1
│     ├── resource: greenhouse-chart     (Helm chart — packaged from charts/greenhouse/)
│     ├── resource: greenhouse-image     (OCI image ref: ghcr.io/cloudoperators/greenhouse:v0.16.1)
│     └── resource: kro-rgd             (YAML — the kro ResourceGraphDefinition)
│
├── github.com/cloudoperators/greenhouse/prerequisites/cert-manager:1.20.1
│     └── resource: cert-manager-chart  (Helm chart — fetched from ghcr.io/cloudoperators/greenhouse-extensions/charts)
│
├── github.com/cloudoperators/greenhouse/prerequisites/flux:2.15.0
│     └── resource: flux-install        (official install.yaml from github.com/fluxcd/flux2 releases,
│                                        downloaded and embedded at push time via --copy-resources)
│
├── github.com/cloudoperators/greenhouse/prerequisites/kro:0.9.4
│     └── resource: kro-chart           (Helm chart — fetched from registry.k8s.io/kro/charts)
│
└── github.com/cloudoperators/greenhouse/prerequisites/ocm-controller:0.33.0
      └── resource: ocm-controller-chart (Helm chart — fetched from ghcr.io/open-component-model/helm)
```

The recipe for all of this lives in one file: [`component-constructor.yaml`](component-constructor.yaml).

---

## Chapter 3: Prerequisites

### OCM CLI

```bash
# Needs v0.48.0+
ocm version
```

Install if missing:

```bash
OCM_VERSION="v0.48.0"
curl -fsSL "https://github.com/open-component-model/ocm/releases/download/${OCM_VERSION}/ocm-${OCM_VERSION#v}-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/').tar.gz" \
  -o /tmp/ocm.tar.gz
tar xzf /tmp/ocm.tar.gz -C /tmp/
sudo mv /tmp/ocm /usr/local/bin/
```

### Helm CLI (for one-time dependency resolution)

```bash
helm version  # any v3+
```

### GitHub PAT with `write:packages` scope

Required to push to GHCR. Create one at:
**GitHub → Settings → Developer settings → Personal access tokens → Generate new token**

Scopes needed: ✅ `write:packages` ✅ `read:packages`

---

## Chapter 4: One-Time Setup — Resolve Greenhouse Chart Dependencies

The greenhouse Helm chart has local `file://` subcharts (idproxy, cors-proxy, manager, etc.)
that live only in this repository. OCM cannot resolve these itself — run this once on a
fresh clone, or whenever subchart versions change:

```bash
helm dependency update charts/greenhouse
```

This populates `charts/greenhouse/charts/` with the subchart tarballs. Everything else
(cert-manager, kro, ocm-controller) is fetched directly by OCM from their source
registries — no `helm pull` needed.

---

## Chapter 5: Set Your Variables

Set these once in your shell — every command below uses them:

```bash
export GREENHOUSE_VERSION=0.16.1
export GREENHOUSE_IMAGE_REF=ghcr.io/cloudoperators/greenhouse:v0.16.1
export CERT_MANAGER_VERSION=1.20.1
export FLUX_VERSION=2.15.0
export KRO_VERSION=0.9.4
export OCM_CONTROLLER_VERSION=0.33.0
export GITHUB_TOKEN=<your-pat>
```

Move into the OCM working directory — all commands run from here:

```bash
cd ocm/
```

---

## Chapter 6: Build the Bundle (CTF)

One command reads `component-constructor.yaml` and produces `greenhouse-bundle.ctf/`.
OCM handles all fetching and packaging internally:

| Resource | Source |
|---|---|
| cert-manager chart | fetched from `oci://ghcr.io/cloudoperators/greenhouse-extensions/charts` |
| kro chart | fetched from `oci://registry.k8s.io/kro/charts` |
| ocm-controller chart | fetched from `oci://ghcr.io/open-component-model/helm` |
| greenhouse chart | packaged from local `../charts/greenhouse/` directory |
| flux install manifests | downloaded from `github.com/fluxcd/flux2` releases at push time |
| kro-rgd YAML | embedded from `deploy/kro-rgd.yaml` |

```bash
rm -rf greenhouse-bundle.ctf

ocm add componentversions \
  --addenv \
  --file greenhouse-bundle.ctf \
  --create \
  component-constructor.yaml \
  GREENHOUSE_VERSION=$GREENHOUSE_VERSION \
  "GREENHOUSE_IMAGE_REF=$GREENHOUSE_IMAGE_REF" \
  CERT_MANAGER_VERSION=$CERT_MANAGER_VERSION \
  FLUX_VERSION=$FLUX_VERSION \
  KRO_VERSION=$KRO_VERSION \
  OCM_CONTROLLER_VERSION=$OCM_CONTROLLER_VERSION
```

**Flag reference:**

| Flag | Meaning |
|---|---|
| `--addenv` | enables `${VAR}` substitution from your shell environment |
| `--file greenhouse-bundle.ctf` | output CTF directory |
| `--create` | create the CTF from scratch (fails if it already exists — use `rm -rf` first) |

After this you will have `greenhouse-bundle.ctf/` containing an `artifact-index.json` and
a `blobs/` directory with all packaged content.

---

## Chapter 7: Verify the Local Bundle

Before pushing, confirm all 6 components are present:

```bash
ocm get componentversion --repo directory::./greenhouse-bundle.ctf
```

Expected output:

```
COMPONENT                                                           VERSION   PROVIDER
github.com/cloudoperators/greenhouse                                0.16.1    cloudoperators
github.com/cloudoperators/greenhouse/core                           0.16.1    cloudoperators
github.com/cloudoperators/greenhouse/prerequisites/cert-manager     1.20.1    cloudoperators
github.com/cloudoperators/greenhouse/prerequisites/flux             2.15.0    cloudoperators
github.com/cloudoperators/greenhouse/prerequisites/kro              0.9.4     cloudoperators
github.com/cloudoperators/greenhouse/prerequisites/ocm-controller   0.33.0    cloudoperators
```

Inspect the resources inside a specific component:

```bash
# Summary view
ocm get resources \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/core:$GREENHOUSE_VERSION

# Full detail
ocm get resources \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse/core:$GREENHOUSE_VERSION \
  -o yaml
```

---

## Chapter 8: Push to GHCR

Ship the CTF to GitHub Container Registry. The `--copy-resources` flag is critical — it
tells OCM to resolve every resource reference and embed the actual blob content into GHCR,
producing a fully self-contained bundle.

```bash
GITHUB_TOKEN=$GITHUB_TOKEN ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/<your-github-username>/greenhouse
```

> **Note:** GHCR requires the username/org to be **all lowercase** in the path.
> `SofiyaDesaiSAP` → `sofiyadesaisap`.

**Flag reference:**

| Flag | Meaning |
|---|---|
| `--overwrite` | replace an existing version in the registry |
| `--copy-resources` | download and embed all externally-referenced blobs — **required** to push actual artifacts, not just metadata |

Without `--copy-resources`, OCM pushes only the component descriptors (small metadata JSON)
and leaves the chart blobs as unresolved external references. The bundle will appear in
GHCR but will be unusable at deploy time.

---

## Chapter 9: Verify the Push

```bash
# List all components in the registry
ocm get componentversion oci://ghcr.io/<your-github-username>/greenhouse

# Check the top-level component resolves
ocm get componentversion \
  "oci://ghcr.io/<your-github-username>/greenhouse//github.com/cloudoperators/greenhouse:$GREENHOUSE_VERSION"

# Check core resources are embedded (access type should be ociArtifact/localBlob, not wget)
ocm get resources \
  "oci://ghcr.io/<your-github-username>/greenhouse//github.com/cloudoperators/greenhouse/core:$GREENHOUSE_VERSION" \
  -o yaml
```

You can also browse the packages in the GitHub UI at:

```
https://github.com/<your-github-username>?tab=packages
```

---

## Complete Command Reference

```bash
# ── Setup ────────────────────────────────────────────────────────────────────

cd ocm/

export GREENHOUSE_VERSION=0.16.1
export GREENHOUSE_IMAGE_REF=ghcr.io/cloudoperators/greenhouse:v0.16.1
export CERT_MANAGER_VERSION=1.20.1
export FLUX_VERSION=2.15.0
export KRO_VERSION=0.9.4
export OCM_CONTROLLER_VERSION=0.33.0
export GITHUB_TOKEN=<your-pat>

# One-time: resolve greenhouse chart's local subcharts (run from repo root)
helm dependency update charts/greenhouse

# ── Build ────────────────────────────────────────────────────────────────────

rm -rf greenhouse-bundle.ctf

ocm add componentversions \
  --addenv \
  --file greenhouse-bundle.ctf \
  --create \
  component-constructor.yaml \
  GREENHOUSE_VERSION=$GREENHOUSE_VERSION \
  "GREENHOUSE_IMAGE_REF=$GREENHOUSE_IMAGE_REF" \
  CERT_MANAGER_VERSION=$CERT_MANAGER_VERSION \
  FLUX_VERSION=$FLUX_VERSION \
  KRO_VERSION=$KRO_VERSION \
  OCM_CONTROLLER_VERSION=$OCM_CONTROLLER_VERSION

# ── Verify locally ───────────────────────────────────────────────────────────

ocm get componentversion --repo directory::./greenhouse-bundle.ctf

# ── Push to GHCR ─────────────────────────────────────────────────────────────

GITHUB_TOKEN=$GITHUB_TOKEN ocm transfer ctf \
  --overwrite \
  --copy-resources \
  greenhouse-bundle.ctf \
  oci://ghcr.io/<your-github-username>/greenhouse

# ── Verify on GHCR ───────────────────────────────────────────────────────────

ocm get componentversion oci://ghcr.io/<your-github-username>/greenhouse
```

---

## About the Flux Component

The flux prerequisite uses the **official `fluxcd/flux2` install manifests** — the
compiled `install.yaml` published with each flux release at:

```
https://github.com/fluxcd/flux2/releases/download/v<VERSION>/install.yaml
```

This is the same content as `https://github.com/fluxcd/flux2/tree/main/install`,
pre-rendered into a single file.

In the OCM bundle the flux resource is stored as a `wget` access reference in the CTF.
The manifest is **not** downloaded during `ocm add componentversions` — it is fetched
and embedded as a self-contained OCI blob only during:

```bash
ocm transfer ctf --copy-resources ...
```

To upgrade the flux version, update `FLUX_VERSION` in your shell variables (and in
`Makefile.ocm`) and rebuild the bundle.

---

## About Package Sizes

The pushed packages are small (~64 KB for the greenhouse chart) because Helm charts
contain only YAML templates and values — not the application binaries. The actual
container images (controller-manager, idproxy, cors-proxy, authz) are **not copied**
into your registry. They are stored as external references pointing back to
`ghcr.io/cloudoperators/greenhouse:v0.16.1`. This is intentional: copying multi-hundred-MB
images is only needed for fully air-gapped deployments.

---

## GitHub Actions

The workflow at `.github/workflows/push-ocm-bundle.yaml` automates this process. It
triggers on pushes to `main` that touch `ocm/component-constructor.yaml`,
`ocm/deploy/kro-rgd.yaml`, or `ocm/Makefile.ocm`, and can also be triggered manually
via `workflow_dispatch` with a custom `greenhouse_version` input.
