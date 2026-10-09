# Keyless Signing for OCM + Flux + Greenhouse — Discussion Brief

> **Purpose:** A self-contained write-up of the investigation into keyless (Sigstore) signing for
> the air-gapped Greenhouse OCM bundle, for review with the technical architect **before**
> implementing. Nothing in this proposal has been committed or run end-to-end yet.
>
> **Audience:** technical architect + whoever owns the OCM/Flux delivery pipeline.
>
> **Status:** proposal / for discussion. Companion files already drafted in the repo are listed
> at the end under "Artifacts already drafted."
>
> **Date of investigation:** 2026-10-07, revised 2026-10-08. **Verified against:** OCM CLI v0.48.0.
>
> **Revision note (2026-10-08):** This brief has been reconciled with a second, deeper
> investigation (`ocm-kyverno-signing-discussion.md`) that examined exactly *where* the OCM
> signature lives and whether Kyverno can verify it at admission. That analysis **corrects a
> material error** in the first draft: Kyverno `verifyImages` **cannot** verify the OCM-embedded
> signature — the two operate on different objects. See the new **§4a, §6, and §8**, and the
> correction notice on the drafted Kyverno artifact in the final table. Read §4a before anything
> else; it changes what "Domain B" can actually be.

---

## 1. The question we set out to answer

> *How can keyless (OIDC) signatures be implemented in the OCM + Flux Greenhouse model, so that
> Docker images, Helm charts, and everything else are signed as OCI artifacts and verified by
> Gatekeeper or Kyverno?*

Source material reviewed:
- OCM project: <https://github.com/open-component-model/open-component-model>
- OCM signing concepts: <https://ocm.software/docs/concepts/signing-and-verification/>
- GitLab CI signing examples (cosign keyless with OIDC id_tokens): <https://docs.gitlab.com/ci/yaml/signing_examples/>
- Octopus "Securing containers with OIDC": <https://octopus.com/blog/securing-containers-oidc>
- Flux source-controller cosign verification: <https://fluxcd.io/flux/components/source/ocirepositories/>
- Kyverno image verification (cosign keyless)

Our existing delivery model (from `demo-script.md`): an OCM bundle in GHCR containing the
Greenhouse Helm chart, container images, and all prerequisites (cert-manager, Flux, kro, OCM
controller). One `ocm transfer` moves the whole bundle — charts **and** image blobs — to an
on-site "RBSC" registry inside a datacenter with **no network path to external registries**. A
single `GreenhouseStack` CR is then expanded by kro into Flux `OCIRepository` + `HelmRelease`
objects. The headline promise is **"zero runtime dependency on external infrastructure."**

**Important context correction made during the discussion:** this flow is run **by hand with
`ocm` commands from a workstation**, *not* from a CI pipeline. That single fact reshaped the
whole design (see §7). The `.github/workflows/push-ocm-bundle.yaml` in the repo exists but is
**not** the path in use for this work, and we reverted an earlier attempt to wire signing into
it.

### Headline conclusion (read this first)

1. **Signing the OCM component (`ocm sign --keyless`) is the right, sufficient integrity gate.**
   One signature transitively covers every chart and image *content digest*; verify it once at the
   air-gap boundary (`ocm verify`) and the whole bundle is attested. This part is solid and worth
   implementing.
2. **The OCM signature does NOT reach pod admission.** It lives embedded in the component
   descriptor, is consumed by the OCM controller upstream, and **never travels on the image**.
   Therefore **Kyverno `verifyImages` cannot verify it** (§4a, §6). This corrects the first draft.
3. **Pod-admission enforcement is a separate, explicit decision** with three real options —
   digest allowlist (Option 1, best air-gap fit), per-image cosign + Kyverno (Option 2, blocked by
   image ownership), or registry-only (Option 3). It is **not** a free byproduct of OCM signing.
   This is the main thing to decide with the architect (§6, decision C).
4. **The drafted `kyverno-verify-images.yaml` is misleading and must not ship as-is** — it implies
   it verifies the OCM signature; it does not. Repurpose to Option 1 or delete (risk #2).

---

## 2. What "keyless" actually means (the concept)

"Keyless" is a misnomer — there *is* a private key, it just lives ~10 minutes and is thrown
away. The trust anchor shifts from *"I possess a long-lived private key"* to *"an OIDC identity
provider vouched for who I am at signing time, and a transparency log recorded it."*

The flow (Sigstore: cosign/ocm + Fulcio + Rekor + TUF):

```
signer runs the sign command
  → OIDC provider issues an id_token (a JWT) for the signer's identity
  → the signing tool generates an ephemeral keypair
  → Fulcio (a CA) validates the JWT and issues a ~10-minute X.509 certificate
       that binds the ephemeral PUBLIC key to the JWT identity (identity lands in the cert SAN)
  → the tool signs the artifact DIGEST with the ephemeral PRIVATE key
  → {signature, Fulcio cert, Rekor inclusion proof} are recorded; Rekor is an
       append-only transparency log that also provides a trusted timestamp
  → the ephemeral private key is discarded
```

**Verification needs no key.** It needs two facts:
- **who** signed — the certificate identity (SAN).
- **which issuer** vouched — the OIDC issuer.

Those two map 1:1 onto every verifier in this stack:
| Verifier | "who" field | "which issuer" field |
|---|---|---|
| `ocm verify --keyless` | `--issuer` / identity | OIDC issuer |
| Flux `matchOIDCIdentity` | `subject` | `issuer` |
| Kyverno `keyless` attestor | `subject` | `issuer` |

### Interactive (laptop) vs pipeline identity — this matters

Because we sign **by hand**, there is **no CI token**. `ocm sign --keyless` opens a **browser**;
the signer logs into an OIDC provider; the signing identity is therefore the **signer's email +
the OIDC provider**, not a pipeline URL.

| OIDC provider | issuer to pin at verify | identity (subject) to pin |
|---|---|---|
| Google | `https://accounts.google.com` | `person@sap.com` |
| GitHub (interactive) | `https://github.com/login/oauth` | GitHub email / noreply address |
| Microsoft / Entra | `https://login.microsoftonline.com` | the user's UPN |

> **Architect decision point A:** *Which OIDC provider do we standardise on for signing, and
> whose identity (a named person? a shared service identity? a group)?* This determines what gets
> pinned in every verifier. A per-person identity is simplest to start but couples trust to an
> individual; a dedicated signing identity is cleaner long-term. See §9.

---

## 3. The air-gap problem, and why Sigstore still works offline

Public keyless **verification** normally reaches the network at verify time:
- `rekor.sigstore.dev` — to confirm the transparency-log inclusion proof,
- the Sigstore **TUF root** — to fetch current Fulcio/Rekor public keys.

That directly conflicts with "zero runtime dependency on external infrastructure" for anything
verifying **inside** the cluster. The resolution, confirmed by the OCM concepts doc:

1. **The OCM signature is a self-contained Sigstore bundle** — *"the signature bytes, the Fulcio
   certificate, and the Rekor inclusion proof, all in one self-contained blob"* — embedded in the
   component descriptor. No Rekor call is needed to verify, because the proof is already attached.

2. **`ocm transfer` preserves the signature.** Signatures are part of the descriptor, and the
   signed digest **excludes the `access` field** (where a resource is stored). So moving GHCR →
   RBSC does not invalidate anything. *Sign once, verify anywhere.*

3. **Offline verification needs only a local trusted-root file** (the Fulcio/Rekor public keys),
   distributed into the air gap **once, out of band**. With that present, `ocm verify cv
   --keyless --local` runs *"entirely offline: no callback to any Sigstore service, no TUF
   refresh, no network egress whatsoever."*

**Chosen trust model (from the discussion):** *offline bundles, no cluster network egress.* The
primary verification happens **at the air-gap boundary on the connected transfer host** (where
public Sigstore is reachable). Optional in-cluster verification is possible but requires
mirroring the trusted root.

> **Architect decision point B:** *Is verifying at the transfer boundary sufficient, or do we
> also want in-cluster re-verification (OCM controller and/or Kyverno) — which obliges us to
> mirror and maintain a Sigstore trusted root inside the datacenter?* The boundary check alone is
> a strong story; in-cluster adds defense-in-depth at operational cost. See §9.

---

## 4. The architecture splits in two — and only one half is straightforward

This is a key topology finding (not in the public docs): the runtime data flow forks into the
**bundle** path (where the OCM signature works cleanly) and the **pod** path (where it does
**not** reach — see §4a). The fork:

```
                        ┌──────────────── DOMAIN A: the bundle ─────────────────┐
   sign the OCM     ──► ocm transfer (air-gap)  ──► OCM controller pulls bundle,
   component version     │  `ocm verify` here       EXTRACTS each chart and re-pushes
   (one sig covers all)  │  = the primary gate      it as a NEW Snapshot in the
                         ▼                           in-cluster registry (:5000)
                    RBSC registry                              │
                                                               ▼ (Snapshot is a NEW OCI object,
                                        Flux OCIRepository pulls   new digest, signature NOT
                                        the Snapshot ──────────┘   carried over)
                         │
                         │  ┌──────────── DOMAIN B: the pods ─────────────────┐
                         └─►│ kubelet pulls IMAGES directly from RBSC ──► Kyverno
                            │ (images are NOT repackaged — signature survives) verifyImages
                            └───────────────────────────────────────────────────┘
```

- **Domain A — the bundle.** Sign the whole OCM component version. Its normalised digest
  **transitively covers every resource digest** (every chart, every image reference) and every
  nested component reference. **One signature attests the entire bundle.** Verify it with `ocm
  verify` at the transfer boundary. **This is the primary gate.**

- **Domain B — the running pods.** Container **images** are pulled by the kubelet *directly* from
  RBSC and are **not** repackaged. **BUT** — and this is the correction below — the OCM signature
  does **not** travel on the image, so a pod-admission controller has nothing to check *unless we
  separately sign each image with cosign*. See **§4a**.

### Why Flux `spec.verify` cannot be the gate (common misconception)

The Flux docs show `OCIRepository.spec.verify: cosign` + `matchOIDCIdentity`, and it is tempting
to put that on the kro-generated `OCIRepository` objects. **It would always fail.** By the time
Flux pulls, the chart is a freshly-minted **unsigned Snapshot** created by the OCM controller —
a different OCI object with a different digest and no signature. Flux never sees the original
signed chart. **Chart integrity must therefore be attested at the OCM layer (Domain A), not the
Flux layer.** If we ever change the design so Flux pulls charts *directly* from RBSC (no Snapshot
indirection), *then* `spec.verify` becomes the right tool — we've left a commented marker in
`kro-rgd.yaml` showing exactly where it would go.

---

## 4a. CORRECTION — the OCM signature and pod admission do NOT connect out of the box

> This section supersedes the optimistic reading of "Domain B" in the first draft. It is the
> single most important correction from the second investigation.

**Where the OCM signature actually lives.** It is an **embedded field** inside the component
descriptor — a `signatures:` array *within* the descriptor blob — **not** a separate OCI layer,
and **not** a cosign-style `.sig` referrer artifact. (Media type of the embedded sigstore bundle:
`application/vnd.ocm.signature.sigstore.bundle+protobuf.v0.3+json`.) OCM does it this way on
purpose: the signature then survives every `ocm transfer` automatically, and verification is a
single fetch. The price is that it is **invisible to anything that speaks the cosign/referrer
model.**

**What OCM signs is not an OCI manifest digest.** `ocm sign` hashes a *normalised* form of the
descriptor (`jsonNormalisation`) that **includes** `resources[].digest` and
`componentReferences[].digest` but **excludes** `access` and `repositoryContexts`. (That
exclusion is exactly why transfer across the air gap keeps the signature valid — only *content*
is signed, not *location*.) Cosign, by contrast, verifies over the **raw OCI manifest digest**.
Different bytes, different hash.

**The consequence — the trust gap:**

```
OCM signature verified HERE                          Admission runs HERE
         │                                                   │
ComponentVersion ──► Resource ──► Flux HelmRelease ──► Pod (image@sha256:…)
  (sig checked by OCM controller)                     (NO signature on the image)
```

At pod-admission time, the admission controller sees only `spec.containers[].image`. The OCM
signature is **gone** — it lived in the descriptor, was consumed by the OCM controller four steps
upstream, and never travels with the image. The image carries no cosign referrer (OCM creates
none). **So Kyverno `verifyImages` has nothing cryptographic to inspect on the image.**

**Why Kyverno `verifyImages` cannot verify the OCM signature (two-layer mismatch):**
1. **Wrong location** — Kyverno looks for a cosign *referrer* (`sha256-….sig` / OCI 1.1 referrer
   with a `subject`). The OCM signature is an embedded YAML field; Kyverno has no code path to
   fetch an OCM descriptor, parse it, and read `signatures[].signature.value`.
2. **Wrong thing signed** — even pointed at the descriptor's own OCI manifest, Kyverno would hash
   the raw manifest, not OCM's normalised descriptor hash. It would be verifying the wrong bytes.

> **Takeaway for the architect (revised):** For *this* topology the OCM component signature
> (Domain A) is the real, sufficient integrity gate, verified at the transfer boundary. **Pod-
> admission image verification is a SEPARATE, non-trivial decision** — it is *not* a free
> byproduct of the OCM signature, and the Kyverno policy drafted earlier does not do what its
> name implies. The options are in §6.

---

## 5. OCM signing specifics (verified against CLI v0.48.0)

What the installed `ocm` binary actually supports (not just docs):

- **Signature algorithms** (`--algorithm`): `RSASSA-PKCS1-V1_5` (default), `RSASSA-PSS`,
  `rsa-signingservice`, `rsapss-signingservice`, **`sigstore`**, **`sigstore-v2`**.
- **Keyless flag:** `--keyless` (on both `sign` and `verify`).
- **Offline verify:** `--local` / `-L` ("verification based on information found in component
  versions, only") — the air-gapped path, using the embedded bundle.
- **Transitive signing:** `--recursive` signs each sub-component individually AND the root
  signature already covers them via embedded digests. The second investigation used `--recursive`
  explicitly; recommended so each sub-component is independently verifiable.
- Also present: `--tsa` / `--tsa-url` (RFC-3161 timestamp authority), `--issuer`, `--signature`
  (signature *name* — a component may hold several, e.g. build-sig + release-sig).

**What the signature covers (confirmed facts):**
- `resources[].digest` (image/chart **content** hash via `genericBlobDigest/v1`, SHA-256) → the
  image and chart *content* is bound to the signature. Swapping an image blob (same tag, different
  content) is **detected** — re-pulled content hashes differently and verification fails.
- `componentReferences[].digest` under `--recursive` → verifying the umbrella transitively
  guarantees all sub-components and their images/charts.
- **Excluded:** `access`, `repositoryContexts` (storage location) → transfer-safe.
- **Sequencing requirement:** digests must be **precomputed before signing**. `--copy-resources`
  ensures real blobs exist so digests resolve; *then* sign. `ComponentVersion READY=True` in the
  cluster asserts the OCM controller re-normalised the descriptor, recomputed every resource
  digest from registry content, and confirmed it matches the signed digest.
- **Scope caveat:** the guarantee is integrity *from sign-time onward* + across transfers. If an
  image were malicious *before* signing, the signature faithfully vouches for the bad content. It
  is **not** a provenance or malware check of the original source.

**Proposed commands (what we'd run):**

Sign (laptop, browser login, after building the CTF):
```bash
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse:0.16.1
```

Verify (transfer boundary — the gate; add `--local` to force fully offline):
```bash
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://ghcr.io/<owner>/greenhouse \
  github.com/cloudoperators/greenhouse:0.16.1
```

> **Caveat / to-confirm:** we have *not* been able to run the interactive `--keyless` round-trip
> in this investigation (it requires a browser login). The flag *shapes* are binary-verified; the
> live signing + offline-verify round-trip is still to be validated by whoever runs the demo.
> **This is the single most important thing to prove out before committing to the approach.**

---

## 6. Pod-admission enforcement — the real options (THIS is the decision)

Given §4a (OCM signature ≠ anything an admission controller can read on an image), there are
**three** distinct ways to enforce something at pod admission. They are not variations of one
idea — they defend different things at different cost.

### Case A vs Case B — do not conflate the two "sigstore" signatures

| | What was signed | Where it lives | Can Kyverno `verifyImages` check it? |
|---|---|---|---|
| **Case A** | each **image**, via `cosign sign --keyless` | cosign `.sig` **referrer** on the image | **Yes, natively** (keyless attestor, pin issuer+subject) |
| **Case B** | the **OCM component**, via `ocm sign --algorithm sigstore --keyless` | embedded field in the **descriptor** | **No** — needs a custom verifier (§8) |

Our current demo does **Case B only**. Kyverno cannot see that signature. To get native Kyverno
image verification we would additionally need Case A — i.e. separately cosign-sign each image.

### Option 1 — OCM digest allowlist (bridges OCM → admission, NO cosign, NO sigstore infra at admission) ✅ CHOSEN & IMPLEMENTED

Extract the signed, already-verified image digests from the descriptor
(`ocm get resources --recursive -o json`), load them into a policy that **rejects any pod whose
image digest is not in that allowlist** (and requires digest-pinned images). OCM verified the
signature once at the boundary; admission enforces the *outcome* — "only images that came through
a verified OCM bundle may run." No per-image signing, no sigstore trust roots on the pod-creation
path. This is the lightest, most robust, most air-gap-friendly option.

**Implemented as (2026-10-08):**
- **Pods run by digest** — `deploy/kro-rgd.yaml` sets `image.digest` for
  manager/idproxy/cors-proxy/authz/dashboard (the four binary subcharts share one image → one
  digest). New RGD schema fields `greenhouseImageDigest` / `dashboardImageDigest`, filled in
  `deploy/instance.yaml`. Each subchart's `_helpers.tpl` renders `repository@digest` when set.
- **Allowlist from the signed bundle** — `make gen-image-allowlist` runs
  `ocm get resources ... -o json | jq (select type==ociImage)` and emits ConfigMap
  `ocm-signed-image-digests` (ns kyverno). `make print-image-digests` shows the values for
  `instance.yaml`.
- **Kyverno `validate` policy** — `prereqs/kyverno-digest-allowlist.yaml` (a `validate` foreach,
  NOT `verifyImages`): deny if an image is not `@sha256`-pinned or its digest ∉ allowlist. Ships
  in **Audit**; flip to Enforce when clean. `make install-kyverno` installs Kyverno + ConfigMap +
  policy.
- **postgres exception** — the sapcc postgres image is tag-pinned, has no digest knob, and is NOT
  an OCM resource. The policy exempts images whose path contains `/sapcc/`. It is not covered by
  the OCM signature.

### Option 2 — per-image cosign (Case A) + Kyverno `verifyImages`

Separately `cosign sign` each image and verify cryptographically at admission. True image-level
attestation, but it is a **parallel trust chain to OCM**, it is **blocked by image ownership**
(our images are upstream `ghcr.io/cloudoperators/...`, which we cannot push signatures to — we'd
have to **re-host** them under a registry we control and sign those copies), and keyless + air-gap
means the verifier still needs mirrored sigstore trust roots.

### Option 3 — registry/provenance only (no signatures at admission)

Policy simply requires images from the expected RBSC registry + digest-pinned. Simplest, not
cryptographic. A reasonable baseline if Option 1 is more than the demo needs.

> **Architect decision point C (revised):** *What are we defending against at admission that the
> OCM controller's verification doesn't already cover?*
> - "A pod shouldn't run an image that didn't come through a verified OCM bundle" → **Option 1**
>   (digest-membership check). You do **not** need to re-verify a signature at admission.
> - "Re-verify the sigstore signature cryptographically at admission, independent of the OCM
>   controller" → **Option 2 (Case A)** or a **custom OCM-aware verifier (§8)**. Heavier.
> - "Just keep rogue registries out" → **Option 3**.
> See §10 — this is the question to settle before writing any more policy YAML.

---

## 7. Why the laptop/hand-run reality changed the design

The first draft of this proposal assumed a GitHub Actions pipeline (because the repo has one and
the GitLab doc we were pointed at is pipeline-centric). That was wrong for how this is actually
operated. Corrections made:

| Pipeline assumption (wrong) | Laptop reality (correct) |
|---|---|
| CI mints an OIDC token via `id_tokens: {aud: sigstore}` | Browser login; `ocm sign --keyless` drives the OIDC flow interactively |
| Identity = workflow URL (`…/push-ocm-bundle.yaml@refs/heads/main`) | Identity = signer's email + OIDC provider |
| Signing wired into `.github/workflows/push-ocm-bundle.yaml` | Signing is a `make` target run by hand; workflow left untouched |
| Verifier pins the workflow subject | Verifier pins the person/provider |

The workflow file was **reverted** to its original state. All signing lives in `make` targets
and in `demo-script.md` where the operator actually works.

> Note: if we ever choose **Option 2/Case A** image signing *and* pin a pipeline identity, the
> verifier subject would become a workflow URL again. For the hand-run demo it stays the signer's
> email + provider.

---

## 8. If we insist on re-verifying the OCM signature at admission (Case B) — the custom-verifier route

This is included for completeness; it is the **heaviest** option and almost certainly *not* what
the demo needs. Kyverno cannot verify the OCM signature itself, so the pattern is: Kyverno calls
out (via `context.apiCall`) to a service that **does** understand OCM and answers yes/no.

```
Pod admission (image: registry/.../greenhouse@sha256:abc)
   │
   ▼  Kyverno policy — context.apiCall POST /verify
OCM verifier service  ◄── verifies the descriptor's embedded sigstore signature
   │                       (re-normalise, recompute digest, verify Fulcio+Rekor, CHECK identity)
   ▼  { "verified": true, "component": "...", "matchedDigest": "sha256:abc" }
Kyverno deny rule:  verified != true  → block
```

**Hard realities of this route (from the second investigation):**
- **There is NO off-the-shelf `ocm-verifier` service.** Any `service.url` in such a policy points
  at a component **we must build, deploy, give sigstore trust roots to, and keep highly
  available.** (An earlier draft elsewhere used a fake URL — it was invented, not real.)
- The verifier must: resolve image→digest, find the OCM descriptor whose `resources[].digest`
  matches, re-normalise + recompute + compare, verify the sigstore bundle (Fulcio chain + Rekor
  inclusion), **and crucially check the signer identity == expected issuer/subject** (otherwise
  *any* valid sigstore identity passes — near-worthless). Simplest correct impl: shell out to
  `ocm verify componentversions ...` plus an identity check, or link the OCM Go bindings.
- **Air-gap tax doesn't go away** — it moves into *your* service, which still needs mirrored
  Fulcio/Rekor trust roots to complete keyless verification offline.
- **It duplicates the OCM controller's work** — `ComponentVersion READY=True` already means OCM
  verified this signature once; re-verifying at admission drags sigstore infra onto the
  pod-creation critical path.
- **Fail-closed risk** — `failurePolicy: Fail` means every pod creation depends on the verifier
  being up. Must be HA and must exclude its own namespace, or it can wedge the cluster.

A full draft `ClusterPolicy` (apiCall skeleton) and the verifier endpoint contract are in
`ocm-kyverno-signing-discussion.md` §8 if we ever go this way.

---

## 8b. Gatekeeper vs Kyverno (for Option 2 / Case A only)

- **Kyverno** verifies cosign signatures **natively** (`verifyImages` with `attestors → keyless →
  {subject, issuer}`). Simpler, and the recommended choice *if* we do Case A image verification.
- **OPA / Gatekeeper** has **no native cosign verifier.** Using it means running the **Ratify**
  external-data provider as the actual verifier (`ExternalData` → Ratify → cosign). More moving
  parts.

Note: this comparison only matters for **Option 2 (Case A)**. For **Option 1** (digest allowlist),
*either* engine works and no cosign verifier is involved at all — it's a plain
digest-membership/validate rule.

---

## 9. Open decisions for the architect (consolidated)

| # | Decision | Options | Our lean |
|---|---|---|---|
| **A** | Signing identity | Named person / shared service identity / group; and which OIDC provider | A dedicated signing identity (not a personal account) for longevity; provider per org standard |
| **B** | Where to verify the OCM signature | Transfer boundary only / also in-cluster (OCM controller) | Boundary is the strong, low-cost gate; add in-cluster later if required |
| **C** | **Pod-admission enforcement** | **Option 1** digest allowlist / **Option 2** per-image cosign (Case A) / **Option 3** registry-only / **none** | ✅ **DECIDED: Option 1** — implemented (digest pinning in kro-rgd + generated allowlist + Kyverno validate policy, Audit mode) |
| **D** | Trusted-root distribution | Needed only if in-cluster OCM re-verify (B) OR Option 2/§8 verifier | Defer until B and C are decided |
| **E** | Timestamping | Use `--tsa` for validity beyond the ~10-min cert lifetime? | Consider for release artifacts; optional for the demo |
| **F** | Signature policy | Single release signature / multi-party (build + release) | Single to start; OCM supports multiple names later |
| **G** | Re-host upstream images? | Only required for Option 2/Case A | Only if C = Option 2 |

---

## 10. Proposed end-to-end flow (if approved)

Assuming **decision C = Option 1 (digest allowlist)**, the simplest coherent story:

```
[LAPTOP — online]
  make build            # ocm add componentversions → greenhouse-bundle.ctf
  make sign-sigstore    # ocm sign cv --keyless -S sigstore-v2 --recursive  (browser login)
  make push             # ocm transfer ctf → central GHCR         (signature preserved)

[LAPTOP / transfer host — the air-gap boundary, online]
  make verify-sigstore  # ocm verify cv --keyless  ← THE GATE. fail = stop, do not cross.
  (then the Part 1 `ocm transfer` to RBSC)
  # Option 1: extract verified digests → generate the admission allowlist here
  #   ocm get resources --recursive -o json  →  list of signed image digests

[CLUSTER — air-gapped]
  OCM controller pulls bundle → Snapshots → Flux installs charts (integrity attested at verify)
  (Option 1) admission policy: reject any pod whose image digest ∉ allowlist, require @sha256 pins
```

What this story does **not** include, by design: no cosign per-image signing, no sigstore trust
roots in the cluster, no custom verifier service. If decision C lands on Option 2 or §8 instead,
the flow gains the re-host+cosign-sign step and/or the verifier service and its trust-root
mirroring.

---

## 11. Risks / things explicitly NOT yet proven

1. **Interactive `--keyless` round-trip not executed** — flag shapes are binary-verified against
   v0.48.0, but the live browser-login sign + offline (`--local`) verify has not been run.
   **Prove this first.** (§5)
2. **The drafted Kyverno policy does not do what its name implies** — `prereqs/kyverno-verify-images.yaml`
   was written on the (incorrect) assumption that Kyverno can verify the signature. Per §4a/§6 it
   can only verify **Case A** (per-image cosign) signatures, which we do not currently produce.
   **Do not ship it as-is.** It must either be repurposed to Option 1 (digest allowlist — not a
   `verifyImages` rule at all) or deleted. (§6)
3. **Image signing blocked by upstream ownership** — Option 2/Case A is inert until images are
   re-hosted under a registry we control. (§6)
4. **In-cluster / verifier offline verification needs a maintained trusted root** — a mirrored
   Sigstore root is an operational artifact to refresh/manage if B includes in-cluster re-verify
   or if we build the §8 verifier. (§3, §8)
5. **`ocm transfer` + image referrers** — only relevant to Option 2: confirm cosign `.sig`
   referrers survive `ocm transfer --copy-resources` (may need an explicit re-attach at RBSC).
6. **`sigstore` vs `sigstore-v2`** — v0.48.0 offers both; confirm which the in-cluster OCM
   controller version can verify, if we do in-cluster re-verification.
7. **Option 1 allowlist freshness** — the digest allowlist must be regenerated on every bundle
   version bump, or new legitimate images get blocked. Needs an owner/automation step.

---

## Artifacts already drafted in the repo (for review, not yet committed)

| File | What it is | State |
|---|---|---|
| `ocm/keyless-signing-discussion.md` | **This brief** — the authoritative design doc | current |
| `ocm/demo-script.md` | Step 2b (sign), Part 1 verify gate, **Part 6 (Option 1 admission)** — all current | updated — keep |
| `ocm/Makefile.ocm` | `sign-sigstore`, `verify-sigstore`; **`print-image-digests`, `gen-image-allowlist`, `install-kyverno`** (Option 1); `sign-images`/`load-sigstore-root` (only if Option 2 later) | updated |
| `ocm/deploy/kro-rgd.yaml` | **Digest pinning** (`image.digest` for all greenhouse subcharts) + new schema fields; `spec.verify` omission comment | updated |
| `ocm/deploy/instance.yaml` | `greenhouseImageDigest` / `dashboardImageDigest` values | updated |
| `ocm/prereqs/kyverno-digest-allowlist.yaml` | **Option 1 Kyverno `validate` policy** — digest-membership + registry, postgres exempt, Audit mode. (Replaces the deleted misleading `verifyImages` file.) | New |
| `ocm/prereqs/image-digest-allowlist.yaml` | Generated ConfigMap of signed digests | **generated** by `make gen-image-allowlist` (not committed; produced from a fresh signed build) |
| `ocm/keyless-signing.md` | Earlier reference doc. **⚠ superseded by this brief**; still contains the pre-correction "Domain B" framing. | **revise or drop** |
| `.github/workflows/push-ocm-bundle.yaml` | **Reverted** — signing is NOT wired into CI (hand-run) | Unchanged |

> **Deleted:** `ocm/prereqs/kyverno-verify-images.yaml` — the misleading `verifyImages` policy that
> implied it verified the OCM signature. Replaced by the Option 1 `validate` policy above.

### Source documents this brief reconciles
- `ocm-kyverno-signing-discussion.md` (repo root) — the deeper second investigation into signature
  storage and Kyverno admission. **Authoritative on §4a, §6, §8.** Worth reading in full alongside
  this brief; its §8 has the complete `apiCall` policy skeleton and verifier endpoint contract.
- OCM concepts: <https://ocm.software/docs/concepts/signing-and-verification/>

> **Still to prove before Enforce mode / commit:** (1) the interactive `ocm sign --keyless`
> round-trip is unproven (risk #1); (2) confirm OCM's recorded image digest equals the registry
> manifest digest the kubelet pulls, especially for multi-arch (risk; see demo Part 6 Step 6.1);
> (3) rebuild the stale local CTF so the allowlist includes the dashboard image (risk #2/#7).
