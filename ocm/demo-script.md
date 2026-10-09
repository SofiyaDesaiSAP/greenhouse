# Demo Script: Air-Gated Greenhouse Deployment — OCM + Flux + kro

> **Execution context key**
>
> | Label | Meaning |
> |---|---|
> | `[LOCAL]` | Runs on your laptop/workstation — needs `ocm`, `docker`, `helm`, `flux`, `kubectl` |
> | `[CLUSTER]` | Runs against the target k8s cluster via `kubectl` |

---

## Narrative

> "We have an OCM bundle in GHCR — that's the delivery artifact. It contains the Greenhouse
> Helm chart, container images, and all prerequisites (cert-manager, OCM controller, kro).
> The bundle is **signed keyless with Sigstore** — one signature over the component descriptor
> that transitively covers every chart and image content digest, with no key pair to manage.
> With one `ocm transfer` command we move the entire bundle — charts AND container image blobs —
> to the on-site registry; the signature travels inside the descriptor and is **verified at the
> air-gap boundary before anything crosses**. The cluster has no network path to external
> registries. We then apply a single CR — `GreenhouseStack` — and kro expands it into all
> deployment resources. cert-manager, the OCM controller, and Greenhouse itself all pull from the
> local registry. Zero runtime dependency on external infrastructure."

> **Signing scope at a glance:** the OCM signature is the integrity gate for the *bundle*
> (verified at the boundary and again in-cluster via `ComponentVersion READY=True`). It does
> **not** reach pod admission — that is a separate, optional decision (see Part 6). Full
> rationale and the open decisions: `keyless-signing-discussion.md`.

---

## PART 0 — Pre-Demo Setup *(done once before demo)*

> All Part 0 steps run on your **local machine**. They are done ahead of time and do not need
> to be re-run per demo unless chart versions or image tags change.

**`[LOCAL]`** — Change into the greenhouse OCM directory. All make commands run from here.
```bash
cd /Users/i779118/projects/sci-k8s-cluster/greenhouse/ocm
```

**`[LOCAL]`** — Get a GitHub PAT with `write:packages` scope. OCM needs this to push to GHCR.
```bash
export GITHUB_TOKEN=$(gh auth token --hostname github.com)
export GITHUB_USER=sofiyadesaisap
```

---

### Step 1 — Resolve Greenhouse Chart's Local Subchart Dependencies

**Why this step?** The greenhouse Helm chart references `idproxy`, `cors-proxy`, `manager`,
`authz`, and `dashboard` as `file://` subcharts. OCM cannot resolve these itself — Helm must
pre-populate `charts/greenhouse/charts/` before OCM packages the chart directory.
This is a one-time step per checkout; safe to re-run.

**`[LOCAL]`** — Run from the repo root (one directory up from `ocm/`):
```bash
helm dependency update ../charts/greenhouse
```

---

### Step 2 — Build the Multi-Component CTF Archive

**Why `ocm add componentversions --addenv`?** OCM's native variable substitution reads env vars
via `--addenv`, expanding `${GREENHOUSE_VERSION}` etc. in the component descriptor directly —
no external `envsubst` step required.

The build fetches cert-manager, kro, and OCM controller charts directly from their source
OCI registries. The greenhouse chart is packaged from the local directory. The dashboard
image digest and greenhouse image tag are recorded as OCM resources so `--copy-resources`
copies their blobs during the transfer step.

**`[LOCAL]`** — Build the CTF archive:
```bash
make -f Makefile.ocm build
```

The CTF directory (`greenhouse-bundle.ctf/`) now contains the local OCI layout with 6 components:
`greenhouse` (umbrella), `core`, `prerequisites/cert-manager`, `prerequisites/flux`,
`prerequisites/kro`, `prerequisites/ocm-controller`.

---

### Step 2b — Sign the Bundle (Keyless / Sigstore)

**Why this step?** One keyless signature over the OCM component descriptor transitively covers
**every** chart, image, and sub-component *content digest* in the bundle. There is no key pair to
create or store — `ocm sign --keyless` opens a browser, you log in to your OIDC provider, and
Sigstore issues a ~10-minute certificate. The resulting signature (Fulcio cert + Rekor proof,
one self-contained bundle) is **embedded inside the component descriptor** and travels with the
bundle through every `ocm transfer`. Full rationale and the architecture decisions behind this:
`keyless-signing-discussion.md`.

> **What the signature does and does not cover** (confirmed — see discussion brief §4a/§5):
> - ✅ It binds the **content digest** of every chart and image (`resources[].digest`), so a
>   swapped blob is detected at verify time. The local CTF already carries these digests (the
>   greenhouse/dashboard `ociImage` digests resolve at build time), so signing here is correct.
> - ✅ It is **transfer-safe** — the signed digest excludes storage location (`access`,
>   `repositoryContexts`), so GHCR → RBSC does not invalidate it.
> - ❌ It is **not** a cosign `.sig` on the images and **does not reach pod admission**. Kyverno
>   `verifyImages` cannot see it. Admission enforcement is a separate, optional decision — see the
>   new **Part 6 (optional)** below and discussion brief §6.

**`[LOCAL]`** — Sign the top-level component recursively. A browser window opens for login.
```bash
make -f Makefile.ocm sign-sigstore
```

> Override the signing identity to match your provider, e.g.
> `make -f Makefile.ocm sign-sigstore SIG_OIDC_ISSUER=https://github.com/login/oauth`.
> The identity you log in with (your email + provider) is what you pin at verify time.

> **Not yet proven:** the interactive `--keyless` round-trip (browser sign + offline verify) has
> not been run end-to-end in this environment. **Validate it once before relying on the demo.**
> (Discussion brief, risk #1.)

---

### Step 3 — Verify the Local Archive

**`[LOCAL]`** — Confirm all 6 components are present before pushing:
```bash
make -f Makefile.ocm verify
```

Expected:
```
COMPONENT                                                           VERSION
github.com/cloudoperators/greenhouse                                0.16.1
github.com/cloudoperators/greenhouse/core                           0.16.1
github.com/cloudoperators/greenhouse/prerequisites/cert-manager     1.20.1
github.com/cloudoperators/greenhouse/prerequisites/flux             2.15.0
github.com/cloudoperators/greenhouse/prerequisites/kro              0.9.4
github.com/cloudoperators/greenhouse/prerequisites/ocm-controller   0.33.0
```

---

### Step 4 — Push the CTF to GHCR (Central / Source Registry)

**Why `--copy-resources`?** Without this flag OCM pushes only component descriptors (tiny
metadata JSON) and leaves chart tarballs and image blobs as unresolved external references.
With `--copy-resources`, OCM fetches every referenced artifact from its source registry
(ghcr.io, registry.k8s.io, etc.) and embeds the actual blobs into GHCR — producing a
fully self-contained bundle.

**`[LOCAL]`** — Log in to GHCR and push. `GITHUB_TOKEN` must be set (see above).
```bash
make -f Makefile.ocm push GITHUB_TOKEN=$GITHUB_TOKEN
```

**`[LOCAL]`** — Verify the top-level component resolves in GHCR:
```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.16.1" \
  --recursive
```

Expected: 6 rows — `greenhouse`, `core`, `prerequisites/cert-manager`, `prerequisites/flux`,
`prerequisites/kro`, `prerequisites/ocm-controller`.

---

## PART 1 — On-Site Transfer *(shown live in demo)*

> **Context:** In production the "on-site RBSC" is a disconnected registry inside the customer
> datacenter. Here we simulate it as a separate GHCR repo (`greenhouse-rbsc`). The `ocm
> transfer` command is what runs at the air-gap boundary — it is the *only* step that needs
> outbound internet access. After it completes, the cluster never contacts `ghcr.io/cloudoperators`
> or any other external registry again.

**`[LOCAL]`** — Refresh the GitHub token for this session.
```bash
export GITHUB_TOKEN=$(gh auth token --hostname github.com)
```

**`[LOCAL]`** — **The signature gate.** Verify the keyless signature on the central-GHCR bundle
*before* crossing the air gap. If a chart or image was tampered with anywhere in the bundle, the
component digest no longer matches and this fails — so the bad bundle never reaches the on-site
registry. Add `OCM_VERIFY_LOCAL=1` to force fully-offline verification using only the embedded
Sigstore bundle (no network egress).
```bash
make -f Makefile.ocm verify-sigstore OCM_REGISTRY=ghcr.io/sofiyadesaisap/greenhouse
```
Expected: `Verification succeeded` for signature `greenhouse-release`, confirming the identity
(your email) and issuer (your OIDC provider). Only then proceed to the transfer below.

**`[LOCAL]`** — Transfer the full bundle from the central GHCR to the simulated on-site
registry. This is the air-gap crossing step — it moves charts AND container image blobs.
- `--copy-resources`: copies image blobs, not just manifest references
- `--recursive`: follows component references (core + all prerequisites)
- After this completes, the cluster never needs to reach `ghcr.io/sofiyadesaisap/greenhouse`
```bash
ocm transfer componentversion \
  --copy-resources \
  --recursive \
  --overwrite \
  "oci://ghcr.io/sofiyadesaisap/greenhouse//github.com/cloudoperators/greenhouse:0.16.1" \
  oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc
```

> **Path preservation:** OCM strips the source registry host and preserves the original path
> structure under the target. Images declared as
> `ghcr.io/cloudoperators/greenhouse:v0.16.1` end up at
> `ghcr.io/sofiyadesaisap/greenhouse-rbsc/cloudoperators/greenhouse:v0.16.1`.
> This is why `imageRegistry: "ghcr.io/sofiyadesaisap/greenhouse-rbsc"` in the GreenhouseStack
> CR gives the correct prefix for all pod image pulls.

**`[LOCAL]`** — Verify: all 6 components appear in the on-site registry.
```bash
ocm get componentversions \
  "oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc//github.com/cloudoperators/greenhouse:0.16.1" \
  --recursive
```

---

## PART 2 — Cluster Bootstrap *(one-time per cluster)*

> All remaining parts run against the **target cluster**. Set your kubeconfig first.

**`[LOCAL]`** — Point kubectl at the target cluster.
```bash
export KUBECONFIG=/path/to/new-cluster-kubeconfig.yaml
```

---

### Flux Controllers

**`[LOCAL]`** — Install Flux. Flux's `helm-controller` watches `OCIRepository` and
`HelmRelease` CRs created by kro (via the GreenhouseStack CR expansion) and performs
the actual Helm installs. Skips reinstall if Flux is already running.
```bash
make -f Makefile.ocm bootstrap-flux
```

---

### kro (Kubernetes Resource Orchestrator)

**`[LOCAL]`** — Install kro. kro processes the `GreenhouseStack` ResourceGraphDefinition
and expands a single `GreenhouseStack` CR into all `OCIRepository` and `HelmRelease` CRs —
so the operator applies one object instead of N Flux resources.
kro must be running before the RGD can be processed.
```bash
make -f Makefile.ocm install-kro
```

---

### RBAC for helm-controller

**`[CLUSTER]`** — Grant `helm-controller` cluster-admin so it can install CRDs and
`ClusterRole`s. Required for cert-manager, OCM controller, and kro installs via Flux
HelmRelease.
```bash
make -f Makefile.ocm grant-helm-rbac
```

---

### Prometheus-operator CRDs

**`[CLUSTER]`** — Install prometheus-operator CRDs. The greenhouse chart hardcodes
`PrometheusRule` resources regardless of whether monitoring is enabled. Without the CRD,
the HelmRelease install fails.
```bash
make -f Makefile.ocm install-prometheus-crds
```

---

### cert-manager + OCM Controller

**`[LOCAL]`** — Install cert-manager first (OCM controller depends on it), then the OCM
controller. The OCM controller fetches the signed bundle from the on-site registry, extracts
Helm charts as OCI Snapshots, and hands them to Flux via OCIRepository.

> **Critical flag:** `--set tlsCert.generateTlsCert=true` is mandatory. Without it, the
> `ocm-registry-tls-certs` Secret is never created and all FluxDeployer / OCIRepository
> pulls from the OCM internal registry fail with a TLS error.
```bash
make -f Makefile.ocm install-ocm-controller
```

---

### Flux Extension Stub CRDs

**`[CLUSTER]`** — Greenhouse v0.16.1+ controller-manager watches `ArtifactGenerator` from
`source.extensions.fluxcd.io` — an API group not included in `flux install`. Without this
stub, the greenhouse controller-manager enters `CrashLoopBackOff` at startup.
```bash
make -f Makefile.ocm install-flux-extension-stubs
```

---

## PART 3 — Secrets *(one-time per cluster)*

**`[LOCAL]`** — Get a fresh GitHub token (used as the registry password for GHCR pulls from
inside the cluster — both for the OCM bundle and for container images).
```bash
export GITHUB_TOKEN=$(gh auth token --hostname github.com)
```

**`[CLUSTER]`** — Create the `greenhouse` namespace.
```bash
make -f Makefile.ocm create-greenhouse-ns
```

**`[CLUSTER]`** — Create the registry pull secret. The OCM controller uses this to fetch the
bundle from the RBSC (simulated GHCR) registry. The `ComponentVersion` CR references this
secret via `secretRef`.
```bash
make -f Makefile.ocm create-registry-secret GITHUB_TOKEN=$GITHUB_TOKEN
```

**`[CLUSTER]`** — Copy the OCM registry TLS certificate from `ocm-system` → `greenhouse`. The
kro-generated `OCIRepository` objects have a `certSecretRef` pointing to this secret. Without
it, Flux cannot pull chart artifacts from the OCM internal registry at
`registry.ocm-system.svc.cluster.local:5000`.
```bash
make -f Makefile.ocm copy-tls-secret
```

**`[LOCAL]`** — Create and upload the Greenhouse Helm values secret. Copy the example and
edit for your environment (at minimum set `global.dnsDomain` and OIDC config).
```bash
cp deploy/greenhouse-values-example.yaml greenhouse-values.yaml
# edit greenhouse-values.yaml for your environment
make -f Makefile.ocm create-values-secret
```

---

## PART 4 — Deploy *(THE DEMO MOMENT)*

> Before applying OCM manifests, update the ComponentVersion to point at the RBSC registry
> so OCM fetches the bundle from the on-site location — not the central GHCR.

**`[LOCAL]`** — Edit `deploy/componentversion.yaml` and update the repository URL:
```yaml
spec:
  repository:
    url: ghcr.io/sofiyadesaisap/greenhouse-rbsc   # ← was: ghcr.io/sofiyadesaisap/greenhouse
```

---

**`[CLUSTER]`** — Apply all OCM manifests via kustomize. This creates:
- `Namespace` — greenhouse
- `ComponentVersion` greenhouse — OCM controller fetches the bundle from the RBSC
- `Resource` CRs — one per chart (cert-manager, kro, ocm-controller, greenhouse, kro-rgd);
  each triggers OCM to extract the chart blob as a Snapshot in the internal registry
- `ResourceGraphDefinition` greenhouse-stack — kro processes this and creates the
  `GreenhouseStack` CRD
```bash
make -f Makefile.ocm deploy-apply
```

**`[CLUSTER]`** — Watch OCM resolve all components from the RBSC. `READY=True` on
`ComponentVersion` means the bundle was fetched. `READY=True` on each `Resource` means the
chart blob was extracted as a local Snapshot.
```bash
kubectl get componentversions,resources -n greenhouse
```

**`[CLUSTER]`** — Once all Resources are Ready, get the Snapshot paths that OCM assigned.
These paths are needed in the `GreenhouseStack` instance.
```bash
make -f Makefile.ocm snapshot-urls
```

Expected output (paths will differ per cluster — use the actual values):
```
RESOURCE               REPO                                           TAG
cert-manager-chart     sha-15457104823554620187                       1.16.1
kro-chart              sha-<hash>                                     0.9.4
ocm-controller-chart   sha-3868847230746277828                        0.33.0
greenhouse-chart       sha-6660783123634428906                        0.16.1
greenhouse-stack-rgd   sha-<hash>                                     0.16.1
```

**`[LOCAL]`** — Update `deploy/instance.yaml` with the snapshot paths from above and set
`imageRegistry` to the RBSC URL. After OCM transfer, container images land at
`ghcr.io/sofiyadesaisap/greenhouse-rbsc/cloudoperators/greenhouse:v0.16.1` — the
`imageRegistry` prefix is all kro needs to construct the correct `image.repository` for
every subchart.
```yaml
spec:
  registryHost: "registry.ocm-system.svc.cluster.local:5000"
  imageRegistry: "ghcr.io/sofiyadesaisap/greenhouse-rbsc"  # ← RBSC, not central GHCR

  certManagerSnapshotPath: "sha-<from snapshot-urls>"
  certManagerVersion: "1.20.1"

  ocmControllerSnapshotPath: "sha-<from snapshot-urls>"
  ocmControllerVersion: "0.33.0"

  greenhouseSnapshotPath: "sha-<from snapshot-urls>"
  greenhouseVersion: "0.16.1"

  tlsSecretName: "ocm-registry-tls-certs"
  valuesSecretName: "greenhouse-values"
```

**`[CLUSTER]`** — Apply the `GreenhouseStack` instance. This is the single CR that triggers
kro to create all `OCIRepository` and `HelmRelease` objects. `kubectl api-resources | grep
GreenhouseStack` must return a result before this step (kro must have processed the RGD).
```bash
make -f Makefile.ocm deploy-instance
```

**`[CLUSTER]`** — Watch kro expand the `GreenhouseStack` CR into OCIRepositories and
HelmReleases.
```bash
kubectl get greenhousestack -n greenhouse -w
```

**`[CLUSTER]`** — Watch OCIRepositories become ready. Each points to a Snapshot in the OCM
internal registry. Flux's `source-controller` pulls the chart artifact and makes it available
to `helm-controller`.
```bash
kubectl get ocirepository -n greenhouse
```

**`[CLUSTER]`** — Watch Flux deploy HelmReleases in dependency order:
cert-manager → ocm-controller → greenhouse.
```bash
kubectl get helmreleases -n greenhouse -w
```

> `deploy/instance.yaml` has `imageRegistry: "ghcr.io/sofiyadesaisap/greenhouse-rbsc"` —
> all container images (greenhouse controller-manager, idproxy, cors-proxy, authz, dashboard,
> postgresql) are served from there. No external registry is ever contacted.

---

## PART 5 — Verify

**`[CLUSTER]`** — Check all OCM, Flux, and pod status in one shot.
```bash
make -f Makefile.ocm deploy-status
```

Expected final state:
```
ComponentVersion:  greenhouse          Ready=True   0.16.1
Resources:         all 5               Ready=True
GreenhouseStack:   greenhouse          ACTIVE
HelmReleases:      cert-manager        Ready=True
                   ocm-controller      Ready=True
                   greenhouse          Ready=True
Pods (greenhouse): controller-manager x3, cors-proxy x2, webhook x2 — Running
Pods (cert-manager): controller, cainjector, webhook                 — Running
Pods (ocm-system):   ocm-controller, registry                        — Running
Pods (kro-system):   kro                                             — Running
Pods (flux-system):  helm, source, kustomize, notification           — Running
```

**`[CLUSTER]`** — Verify every container image in the `greenhouse` namespace comes from the
RBSC only. No image should reference `ghcr.io/cloudoperators` directly — only the RBSC path.
```bash
kubectl get pods -n greenhouse \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

Every line should start with `ghcr.io/sofiyadesaisap/greenhouse-rbsc/`.

**`[CLUSTER]`** — Check the GreenhouseStack instance status. `ACTIVE` means kro successfully
expanded the CR and all managed resources are reconciled.
```bash
kubectl get greenhousestack -n greenhouse
```

---

## PART 6 — Pod-Admission Enforcement: OCM Digest Allowlist (Option 1)

> **How this relates to the OCM signature.** The signature from Step 2b is verified upstream — at
> the air-gap boundary (Part 1) and in-cluster by the OCM controller (`ComponentVersion
> READY=True`). It lives **inside the component descriptor** and is **gone by the time a Pod is
> admitted** — it never travels on the image. So **Kyverno `verifyImages` cannot verify the OCM
> signature** (reasoning: `keyless-signing-discussion.md` §4a). Instead, this Part enforces the
> *outcome* of that verification: **a Pod may only run an image whose content digest is one the
> OCM signature covered.** No signature is re-checked at admission; no sigstore infra on the
> pod-creation path. (This is the chosen approach; Options 2 and 3 are summarized at the end.)

This has three moving parts, already wired into the repo:
1. **Pods run by digest** — `deploy/kro-rgd.yaml` sets `image.digest` for
   manager/idproxy/cors-proxy/authz/dashboard, so each renders `repository@sha256:…`.
2. **Allowlist = the signed digests** — `make gen-image-allowlist` extracts them from the signed
   bundle into a ConfigMap.
3. **Kyverno validates** — a plain `validate` rule (NOT `verifyImages`) denies any pod image whose
   digest is not in the allowlist. postgres (sapcc, tag-pinned, not OCM-signed) is exempted.

### Step 6.1 — Pin the pod image digests *(done at Part 4 time, listed here for the full picture)*

**`[LOCAL]`** — Read the signed image digests from the bundle and put them in `deploy/instance.yaml`.
```bash
make -f Makefile.ocm print-image-digests
```
Set `greenhouseImageDigest` (shared by manager/idproxy/cors-proxy/authz) and `dashboardImageDigest`
in `deploy/instance.yaml` from the output. These flow through `kro-rgd.yaml` into each subchart's
`image.digest`, so every greenhouse pod runs `…@sha256:…`.

> **Verify once:** OCM's recorded digest should equal the registry manifest digest the kubelet
> pulls. Confirm with `crane digest <rbsc-image>:<tag>` (or `cosign triangulate`) and compare to
> `print-image-digests`. For multi-arch images confirm the index digest matches. (Risk to validate
> before Enforce mode.)

### Step 6.2 — Generate the allowlist from the signed bundle

**`[LOCAL]`** — Generate the ConfigMap from the verified bundle. Point `ALLOWLIST_SRC` at the RBSC
bundle after transfer, or use the local CTF default pre-demo.
```bash
make -f Makefile.ocm gen-image-allowlist \
  ALLOWLIST_SRC='oci://ghcr.io/sofiyadesaisap/greenhouse-rbsc//github.com/cloudoperators/greenhouse:0.16.1'
```
This writes `prereqs/image-digest-allowlist.yaml` (ConfigMap `ocm-signed-image-digests`). Only
`ociImage` resources are included — that is what pods actually run.

### Step 6.3 — Install Kyverno and apply the policy (Audit first)

**`[CLUSTER]`** — Installs Kyverno, applies the allowlist ConfigMap, then the policy. The policy
ships in **Audit** mode so you can observe before blocking.
```bash
make -f Makefile.ocm install-kyverno
```

**`[CLUSTER]`** — Observe what Audit would block before enforcing.
```bash
kubectl get policyreport -A | grep ocm-digest-allowlist || true
kubectl describe clusterpolicy ocm-digest-allowlist
```

**`[CLUSTER]`** — When clean, flip to Enforce: set `validationFailureAction: Enforce` in
`prereqs/kyverno-digest-allowlist.yaml` and re-apply.
```bash
kubectl apply -f prereqs/kyverno-digest-allowlist.yaml
```

> **On every version bump** (see Upgrade Flow step 9): re-run `make gen-image-allowlist` and
> re-apply the ConfigMap, or new legitimate image digests will be denied.

### Not chosen (for reference)

- **Option 2 — per-image cosign + Kyverno `verifyImages`:** true image signatures Kyverno verifies
  natively, but **blocked** — our images are upstream `ghcr.io/cloudoperators/...` which we cannot
  sign without re-hosting; also needs mirrored sigstore roots in-cluster. (Brief §6 Option 2.)
- **Option 3 — registry/provenance only:** require images from the RBSC registry + digest-pinned,
  no allowlist. Simpler, not tied to the signed set. (Brief §6 Option 3.)

---

## Quick Troubleshooting Reference

| Symptom | Where to look | Fix |
|---|---|---|
| `ComponentVersion READY=False` | `kubectl describe componentversion greenhouse -n greenhouse` | Part 1 transfer may have failed — re-run `ocm transfer` |
| `OCIRepository: secret 'greenhouse/ocm-registry-tls-certs' not found` | Flux source-controller events | Re-run `make copy-tls-secret` from Part 3 |
| `HelmRelease stuck in 'install/upgrade'` past timeout | `kubectl describe helmrelease -n greenhouse` | `make flux-fix APP=<name>` or `make deploy-reconcile` |
| `GreenhouseStack` CRD not found after `deploy-apply` | `kubectl get resourcegraphdefinition` | kro may not have processed the RGD yet — wait 30s, check `kubectl get pods -n kro-system` |
| Pods in `CrashLoopBackOff`: `ArtifactGenerator` CRD not found | greenhouse controller-manager logs | Re-run `make install-flux-extension-stubs` |
| cert-manager install fails: CRD ownership conflict | HelmRelease events | Delete orphaned CRDs — see deployment guide Troubleshooting section |
| `ImagePullBackOff` on greenhouse pods | `kubectl describe pod -n greenhouse` | Verify `imageRegistry` in `instance.yaml` matches actual RBSC path; re-run `make create-registry-secret` |
| Snapshot paths in `instance.yaml` mismatch | `make snapshot-urls` | Re-run `make snapshot-urls`, update `instance.yaml`, re-apply `make deploy-instance` |
| OCM controller pods `ContainerCreating`: `ocm-registry-tls-certs` not found | OCM controller pod events | `tlsCert.generateTlsCert=true` was not set — reinstall: `make install-ocm-controller` |
| `ocm sign` fails: no browser / cannot open OIDC login | terminal output of `make sign-sigstore` | Run on a workstation with a browser; or configure a device-flow / headless OIDC token. Keyless requires an interactive login (brief §2) |
| `ocm verify` fails: `signature verification failed` / identity mismatch | `make verify-sigstore` output | The signer identity (your email/provider) must match what the verifier expects; confirm you signed with the same OIDC identity |
| `ocm verify --local` fails offline: trust root missing | verify output in air-gapped env | The Fulcio/Rekor trusted-root file must be distributed into the environment once, out of band (brief §3) |
| Kyverno `ocm-digest-allowlist` denies a greenhouse pod | `kubectl describe clusterpolicy ocm-digest-allowlist`; policyreports | Pod image digest not in allowlist. Re-run `make gen-image-allowlist` from the current signed bundle + re-apply the ConfigMap; confirm `instance.yaml` digests match `print-image-digests` |
| Kyverno denies ALL pods incl. postgres | policyreport messages | Allowlist ConfigMap empty/missing, or postgres not matching the `/sapcc/` exemption. Check `kubectl get cm ocm-signed-image-digests -n kyverno` and the image path |
| Pod still runs by `:tag` not `@sha256` | `kubectl get pod -o jsonpath=...image` | `image.digest` not set — confirm `greenhouseImageDigest`/`dashboardImageDigest` in `instance.yaml` and that kro re-expanded the GreenhouseStack |

---

## Upgrade Flow

When a new Greenhouse version is released:

1. Update `GREENHOUSE_VERSION` and `GREENHOUSE_IMAGE_REF` in `Makefile.ocm`
2. Update `DASHBOARD_IMAGE_REF` if the dashboard image changed
3. Re-run Part 0 (build), then **re-sign** the new bundle (Step 2b — a new version needs a fresh
   signature; the old signature covers only the old digests), then push to central GHCR
4. Re-run Part 1 — **re-verify the signature** (`make verify-sigstore`) before transfer, then
   transfer to RBSC
5. Force OCM to re-pull:
   ```bash
   make -f Makefile.ocm deploy-reconcile-ocm
   ```
6. Get new snapshot paths:
   ```bash
   make -f Makefile.ocm snapshot-urls
   ```
7. Update `deploy/instance.yaml` with new snapshot paths + new `greenhouseVersion`
8. Re-apply the instance:
   ```bash
   make -f Makefile.ocm deploy-instance
   ```
9. **If Part 6 Option 1 (digest allowlist) is in use:** regenerate the allowlist from the new
   bundle and re-apply the admission policy — otherwise the new (legitimate) image digests are
   blocked. (Discussion brief, risk #7.)
