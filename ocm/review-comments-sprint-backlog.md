# Review Comments — Greenhouse OCM Deployment Guide
## Sprint Backlog

Reviewer feedback received on:
https://github.com/SofiyaDesaiSAP/greenhouse/blob/main/ocm/greenhouse-ocm-deployment-guide.md

---

## 1. Remove RBSC and SAP-specific references

**Comment:**
> No need of mentioning RBSC in github.com as it is only SAP specific. We only need to document open source steps. We are neonephos — put SAP logic in there we are screwed.

**What needs to change:**
- Replace all `ghcr.io/sofiyadesaisap/greenhouse-rbsc` references with `<your-on-site-registry>` placeholder
- Replace `GITHUB_USER=sofiyadesaisap` and `GITHUB_TOKEN` hardcodes with generic `REGISTRY_USER` / `REGISTRY_TOKEN`
- Remove the GitHub API package-delete loop (SAP/GHCR specific) — replace with a generic note about deleting stale packages via your registry's UI/API
- Replace "RBSC" terminology throughout with "on-site registry" or "target registry"
- Add a note at the top: substitute `<your-on-site-registry>` with any OCI registry the cluster can reach

**Files affected:**
- `ocm/greenhouse-ocm-deployment-guide.md` — ~20 occurrences throughout architecture, steps, troubleshooting, upgrading
- `ocm/deploy/instance.yaml` — `imageRegistry` field
- `ocm/pre-demo-reading.md`

---

## 2. Two separate OCM components (greenhouse vs prerequisites)

**Comment:**
> I'd like a clean separation between the prerequisites and the Greenhouse installation itself. For the open-source world I'd prefer the OCM component to cover only the Greenhouse stack. Keep the requirements as a clearly listed set of prerequisites (documented, not bundled). Offer an extended OCM bundle that ships the prerequisites as an explicit, opt-in add-on.
> Thus I would also opt for two OCM components: one for greenhouse (product, open-source) and one for greenhouse-prerequisites.

**What needs to change:**
- Guide Part 0 Step 2: replace `component-constructor.yaml` with `greenhouse-component.yaml` as the default open-source build; document `greenhouse-prerequisites-component.yaml` as opt-in
- Guide architecture section: show two separate component trees, not one umbrella bundle
- Guide prerequisites section: list cert-manager/Flux/kro/OCM controller as documented prerequisites, not bundled defaults
- Acceptance criteria: update from "prerequisites bundled" to "prerequisites as opt-in artifact"

**Files affected:**
- `ocm/greenhouse-ocm-deployment-guide.md`
- `ocm/pre-demo-reading.md`

**Note:** `greenhouse-component.yaml` and `greenhouse-prerequisites-component.yaml` already exist. Guide just needs to reference them instead of `component-constructor.yaml`.

---

## 3. Per-component enable/disable flags in bootstrap

**Comment:**
> Have you thought about scenarios where OCM and Flux is already present in cluster? In that scenario we only bring in kro + greenhouse.
> `enableCertManager: true/false`, `enableKro: true/false`, `enableFlux: true/false` etc.
> Benefit: use same artifact everywhere and not provide multiple OCM bundles.

**What needs to change:**
- `deploy/bootstrap-rgd.yaml`: add `enableFlux` and `enableKro` boolean schema fields with suspend CEL expressions (mirrors existing `enableCertManager`/`enableOcmController` pattern)
- `deploy/bootstrap-instance.yaml`: add `enableFlux: false` and `enableKro: false` (pre-installed scenario default)
- Guide Part 1 Step 6: document all enable flags and the "pre-installed components" scenario

**Note:** `enableFlux` and `enableKro` are already implemented in `bootstrap-rgd.yaml` and `bootstrap-instance.yaml`. Guide documentation is still missing.

---

## 4. Remove `--overwrite` from `ocm transfer ctf` commands

**Comment:**
> You should not provide `--overwrite` — that is wrong, it is mutating artifacts.

**What needs to change:**
- Remove `--overwrite` flag from all three `ocm transfer ctf` commands in the guide (push to central registry, transfer greenhouse to on-site, transfer prerequisites to on-site)
- Add explanatory note: OCM artifacts are content-addressed and immutable — `--overwrite` would mutate existing artifacts and break the signature chain
- `push-ocm-bundle.yaml` GitHub Action: remove `--overwrite` from the transfer step

**Files affected:**
- `ocm/greenhouse-ocm-deployment-guide.md` (3 occurrences)
- `.github/workflows/push-ocm-bundle.yaml`

---

## 5. GitHub Actions workflow — automate the OCM bundle flow

**Comment:**
> Needed a GitHub Actions workflow to automate the flow.

**What needs to change:**
- Update `.github/workflows/push-ocm-bundle.yaml`:
  - Use `greenhouse-component.yaml` instead of `component-constructor.yaml`
  - Add second job for `greenhouse-prerequisites-component.yaml`
  - Remove `--overwrite` from transfer commands
  - Fix `GREENHOUSE_IMAGE_REF` — reads `appVersion` from `Chart.yaml` separately (app image `v0.18.0` ≠ chart version `0.23.0`)
  - Auto-detect `GREENHOUSE_VERSION` from `Chart.yaml` instead of hardcoding `0.16.1`
  - Add keyless Sigstore signing step + verify step
  - Add `id-token: write` permission (required for OIDC-based keyless signing)
  - Add `dashboard_image_ref` as workflow_dispatch input
  - Update trigger paths to watch new component YAML files

---

## 6. Remove Step 7 — Flux extension stub CRDs

**Comment:**
> What is this? Why do you need this?

**Root cause:**
Greenhouse's catalog controller watches `ArtifactGenerator.source.extensions.fluxcd.io` at startup. The Flux extension framework that defines this CRD is not shipped with `flux install`. Without the CRD the controller enters `CrashLoopBackOff`. The stub CRD is a workaround.

**What needs to change:**
- Remove Step 7 from the guide — a deployment guide should not document workarounds for the application it deploys
- Raise a separate issue in the greenhouse repo: the chart should either include the stub CRD conditionally, or the controller should not register the watch unless the feature is enabled in config

**Files affected:**
- `ocm/greenhouse-ocm-deployment-guide.md` — remove Step 7 and its troubleshooting entry (`CrashLoopBackOff: ArtifactGenerator CRD not found`)
- `ocm/prereqs/flux-extension-stubs.yaml` — can be removed once the upstream chart fix lands

---

## 7. Remove Step 3 (Part 3) — Unblock imagePullSecrets

**Comment:**
> Is it because GHCR was private because you pushed using your PAT?

**Root cause:**
Yes. The imagePullSecrets workaround exists because images were in a private registry (personal GHCR with PAT). In an open-source deployment using public `ghcr.io/cloudoperators/greenhouse` images, no imagePullSecrets are needed.

There is also a chart bug: `global.imagePullSecrets` is not propagated to all subcharts.

**What needs to change:**
- Remove Step 3 (SA patching loop) from Part 3 of the guide
- Remove the related troubleshooting entries (`SA patch rejected`, `ImagePullBackOff`)
- Raise a separate chart issue: `global.imagePullSecrets` should be properly templated in all subcharts so private registry deployments work via values, not post-install SA patching

**Files affected:**
- `ocm/greenhouse-ocm-deployment-guide.md` — remove Part 3 Step 3 and related troubleshooting entries

---

## 8. Remove Step 8 — Copy the OCM TLS certificate

**Comment:**
> Do we really need this? This is only needed if you are bringing in a local registry. Latest OCM controllers removed this dependency. Now they don't bundle local registry anymore.
> Reference: https://github.com/open-component-model/open-component-model/tree/main/bindings/go/kubernetes/controller/chart/templates

**Root cause:**
The old `ocm-controller` bundled an in-cluster OCI registry (`registry.ocm-system.svc.cluster.local:5000`) with a self-signed TLS cert. The new OCM controller (`open-component-model/open-component-model`) has no local registry — Snapshots and FluxDeployer are gone.

**What needs to change:**
- Remove Step 8 from the guide
- Remove `tlsCert.generateTlsCert: true` from `deploy/bootstrap-rgd.yaml` (ocm-controller HelmRelease values)
- Remove the `ocm-registry-tls-certs` troubleshooting entry from the guide
- **IMPORTANT — architecture impact:** The new controller has completely different CRDs. See Item 9.

**Files affected:**
- `ocm/greenhouse-ocm-deployment-guide.md`
- `ocm/deploy/bootstrap-rgd.yaml`

---

## 9. [ARCHITECTURAL] New OCM controller API — kro RGD needs redesign

**Context (raised during review of Item 8):**

The reviewer's link (`open-component-model/open-component-model`) points to a **new OCM controller** with a completely different API from the `ocm-controller` v0.33.0 currently used.

| | Old (`ocm-controller` v0.33.0) | New (`open-component-model`) |
|---|---|---|
| Fetch component | `ComponentVersion` | `Component` + `Repository` |
| Extract resource | `Resource` → creates `Snapshot` | `Resource` (no Snapshot, no local registry) |
| Deploy via Flux | `FluxDeployer` → `OCIRepository` | **Gone** — no FluxDeployer |
| Deploy mechanism | Flux `HelmRelease` via OCIRepository | `NamespacedDeployer` (applies a ResourceGraphDefinition) |
| Local registry | `registry.ocm-system.svc.cluster.local:5000` | **Gone** |

**Impact:**
The entire kro RGD chain (`ComponentVersion → Resource → FluxDeployer → HelmRelease`) is based on the old API and would not work with the new controller.

**Open question for reviewer:**
Are we targeting the new `open-component-model` controller? If yes, the kro RGD needs to be redesigned — `FluxDeployer` is gone, the component/resource CRD specs are different, and the local registry assumption in the OCIRepository URL is invalid.

**Action needed:**
Confirm target OCM controller version/repo before planning any of Items 1–8 that touch the RGD or deployment files.
