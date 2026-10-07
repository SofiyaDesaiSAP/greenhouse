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
> **Date of investigation:** 2026-10-07. **Verified against:** OCM CLI v0.48.0.

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

## 4. The central architectural insight — verification splits into TWO domains

This is the most important finding and it is **specific to the OCM-controller + Flux topology**
(it is not in any of the public docs). The runtime data flow forks:

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
  RBSC and are **not** repackaged, so cosign image signatures survive to runtime and can be
  enforced at pod admission by **Kyverno `verifyImages`**.

### Why Flux `spec.verify` cannot be the gate (common misconception)

The Flux docs show `OCIRepository.spec.verify: cosign` + `matchOIDCIdentity`, and it is tempting
to put that on the kro-generated `OCIRepository` objects. **It would always fail.** By the time
Flux pulls, the chart is a freshly-minted **unsigned Snapshot** created by the OCM controller —
a different OCI object with a different digest and no signature. Flux never sees the original
signed chart. **Chart integrity must therefore be attested at the OCM layer (Domain A), not the
Flux layer.** If we ever change the design so Flux pulls charts *directly* from RBSC (no Snapshot
indirection), *then* `spec.verify` becomes the right tool — we've left a commented marker in
`kro-rgd.yaml` showing exactly where it would go.

> **Takeaway for the architect:** For *this* topology, the OCM component signature (Domain A) is
> both necessary and nearly sufficient. Kyverno image verification (Domain B) is optional
> defense-in-depth, and is currently blocked by image ownership (§6).

---

## 5. OCM signing specifics (verified against CLI v0.48.0)

What the installed `ocm` binary actually supports (not just docs):

- **Signature algorithms** (`--algorithm`): `RSASSA-PKCS1-V1_5` (default), `RSASSA-PSS`,
  `rsa-signingservice`, `rsapss-signingservice`, **`sigstore`**, **`sigstore-v2`**.
- **Keyless flag:** `--keyless` (on both `sign` and `verify`).
- **Offline verify:** `--local` / `-L` ("verification based on information found in component
  versions, only") — the air-gapped path, using the embedded bundle.
- **Transitive signing:** `--recursive` optionally signs each sub-component individually; not
  required because the root signature already covers them via embedded digests.
- Also present: `--tsa` / `--tsa-url` (RFC-3161 timestamp authority), `--issuer`, `--signature`
  (signature *name* — a component may hold several, e.g. build-sig + release-sig).

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

## 6. Container image signing — real constraint

Images in the bundle are `ghcr.io/cloudoperators/greenhouse` and `…/juno-app-greenhouse` — the
**upstream** cloudoperators repositories, which **we cannot push cosign signatures to.** So:

- **Today:** image-signature enforcement via Kyverno is **not actionable** for these images. But
  it mostly doesn't matter, because the **OCM signature already covers the image digests**, so a
  swapped/tampered image fails `ocm verify` at the boundary anyway.
- **To make Domain B real:** we would need to **re-host** the greenhouse/dashboard images under a
  registry we control (plausibly as part of, or right after, the transfer to RBSC), sign *those*
  copies with cosign keyless, and point Kyverno at them.

> **Architect decision point C:** *Do we want pod-admission image verification at all, and if so,
> are we willing to re-host (and sign) the upstream images under our own registry?* If "no," we
> rely solely on Domain A and skip Kyverno. If "yes," we add a re-host+sign step to the transfer.

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

---

## 8. Gatekeeper vs Kyverno

- **Kyverno** verifies cosign signatures **natively** (`verifyImages` with `attestors → keyless →
  {subject, issuer}`). Simpler, and the recommended choice for this stack.
- **OPA / Gatekeeper** has **no native cosign verifier.** Using it means running the **Ratify**
  external-data provider as the actual verifier, with Gatekeeper only calling out to it
  (`ExternalData` → Ratify → cosign). More moving parts.

**Recommendation:** Kyverno, *if* we do pod-admission verification at all (see decision C). A
Gatekeeper+Ratify variant can be produced if there's an org mandate for Gatekeeper.

---

## 9. Open decisions for the architect (consolidated)

| # | Decision | Options | Our lean |
|---|---|---|---|
| **A** | Signing identity | Named person / shared service identity / group; and which OIDC provider | A dedicated signing identity (not a personal account) for longevity; provider per org standard |
| **B** | Where to verify | Transfer boundary only / also in-cluster (OCM controller + Kyverno) | Boundary is the strong, low-cost gate; add in-cluster later if required |
| **C** | Pod-admission image verification | Skip (rely on OCM sig) / re-host+sign images + Kyverno | Start without it; OCM signature already covers image digests |
| **D** | Trusted-root distribution | Only needed if B includes in-cluster | Defer until B is decided |
| **E** | Timestamping | Use `--tsa` for long-term signature validity beyond cert lifetime? | Consider for release artifacts; optional for the demo |
| **F** | Signature policy | Single release signature / multi-party (build + release) approval | Single to start; OCM supports multiple names later |

---

## 10. Proposed end-to-end flow (if approved)

```
[LAPTOP — online]
  make build            # ocm add componentversions → greenhouse-bundle.ctf
  make sign-sigstore    # ocm sign cv --keyless -S sigstore-v2   (browser login)
  make push             # ocm transfer ctf → central GHCR        (signature preserved)

[LAPTOP / transfer host — the air-gap boundary, online]
  make verify-sigstore  # ocm verify cv --keyless  ← THE GATE. fail = stop, do not cross.
  (then the Part 1 `ocm transfer` to RBSC)

[CLUSTER — air-gapped]
  (optional) make load-sigstore-root   # mount trusted root for in-cluster verify
  (optional) make install-kyverno      # enforce image sigs — ONLY for images we own/re-host
  OCM controller pulls bundle → Snapshots → Flux installs charts (integrity attested at verify)
```

---

## 11. Risks / things explicitly NOT yet proven

1. **Interactive `--keyless` round-trip not executed** — flag shapes are binary-verified against
   v0.48.0, but the live browser-login sign + offline verify has not been run. **Prove this
   first.** (§5)
2. **Image signing blocked by upstream ownership** — Domain B is inert until images are re-hosted
   under a registry we control. (§6)
3. **In-cluster offline verification needs a maintained trusted root** — a mirrored Sigstore root
   is an operational artifact that must be refreshed/managed if we go that route. (§3, decision B)
4. **`ocm transfer` + image referrers** — if we later enforce image signatures, confirm the
   cosign signature *referrers* survive `ocm transfer --copy-resources` (may need an explicit
   re-attach step at RBSC).
5. **`sigstore` vs `sigstore-v2`** — v0.48.0 offers both; we should confirm which the OCM
   controller version in-cluster can verify, if we do in-cluster verification.

---

## Artifacts already drafted in the repo (for review, not yet committed)

| File | What it is | State |
|---|---|---|
| `ocm/keyless-signing.md` | Full design/reference doc (laptop flow, two domains, offline model) | New, drafted |
| `ocm/Makefile.ocm` | Added targets: `sign-sigstore`, `verify-sigstore`, `sign-images`, `transfer-rbsc`, `install-kyverno`, `load-sigstore-root` + vars/help | Modified |
| `ocm/demo-script.md` | Added Step 2b (sign) and a verify gate in Part 1 | New in diff |
| `ocm/prereqs/kyverno-verify-images.yaml` | Keyless `verifyImages` ClusterPolicy (Audit mode), laptop identity | New, drafted |
| `ocm/deploy/kro-rgd.yaml` | Comment documenting why `spec.verify` is omitted + where it'd go | Modified |
| `.github/workflows/push-ocm-bundle.yaml` | **Reverted** to original — signing is NOT wired into CI | Unchanged |

> Nothing has been committed. The `make` targets parse and expand to the correct, binary-verified
> flags, but the interactive signing round-trip (risk #1) remains to be validated.
