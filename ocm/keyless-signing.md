# Keyless Signing & Verification — OCM + Flux + Greenhouse

> Companion to `demo-script.md`. That doc delivers an *air-gapped* bundle by hand with `ocm`
> commands. This doc adds **supply-chain trust** to that same hand-run flow: the OCM bundle is
> signed with a short-lived OIDC identity (Sigstore keyless, **no key pair to manage**), and
> verified **offline** inside the air gap — the cluster never calls `fulcio.sigstore.dev` or
> `rekor.sigstore.dev`.
>
> **No CI pipeline is involved.** You run `ocm sign` from your laptop; a browser opens, you log
> in, Sigstore issues a ~10-minute certificate, and the signature (with its proof) is embedded
> in the component descriptor. This matches OCM's documented sigstore flow:
> <https://ocm.software/docs/concepts/signing-and-verification/>

Verified against the installed CLI: **OCM v0.48.0** (`ocm sign cv --keyless -S sigstore-v2`).

---

## TL;DR

| Artifact | Signed how (laptop) | Signature travels as | Verified where | Tool |
|---|---|---|---|---|
| The whole **OCM component version** (transitively covers every chart + image + sub-component digest) | `ocm sign cv --keyless -S sigstore-v2` → browser login | Sigstore bundle embedded in the component descriptor | at the air-gap transfer boundary, offline | **`ocm verify cv --keyless -L`** |
| Container **images** (greenhouse, dashboard, postgres) | `cosign sign` (keyless) — only for images **you own/re-host** | OCI referrer next to the image | kubelet admission, in-cluster, offline | **Kyverno** `verifyImages` |
| Helm **charts** pulled by Flux | — (covered by the OCM signature above) | — | **NOT at the Flux layer** — [see §5](#5-why-flux-specverify-cannot-be-the-gate) | — |

The OCM component signature is the **primary gate** and it alone is enough for a strong
integrity story: one `ocm verify` at the air-gap boundary attests the entire bundle. Kyverno is
optional defense-in-depth for the running images.

---

## 1. What "keyless" means, and why it fits a laptop workflow

There is still a private key — it lives ~10 minutes and is discarded. The trust anchor is *"an
OIDC provider vouched for this identity at signing time, and a transparency log recorded it"*
rather than *"I hold a long-lived secret key."*

Interactive (laptop) flow — exactly what you'll run:

```
you run: ocm sign cv --keyless -S sigstore-v2 ...
  → a browser opens to the OIDC provider (Google / GitHub / Microsoft)
  → you log in; the provider issues an id_token for your identity (e.g. you@sap.com)
  → ocm generates an ephemeral keypair
  → Fulcio validates the id_token, issues a ~10-min X.509 cert binding the
       ephemeral public key to your identity (your email goes in the cert SAN)
  → ocm signs the normalized component-descriptor digest with the ephemeral private key
  → {signature, Fulcio cert, Rekor inclusion proof} are bundled together and written
       into the component descriptor's `signatures:` array
  → ephemeral private key discarded
```

The signing **identity** is therefore *your email + the OIDC issuer* — not a pipeline URL. That
is what you pin at verify time.

| OIDC provider | `issuer` you verify against | `identity` you verify against |
|---|---|---|
| Google | `https://accounts.google.com` | `you@sap.com` |
| GitHub (interactive) | `https://github.com/login/oauth` | `you@users.noreply.github.com` or your GH email |
| Microsoft/Entra | `https://login.microsoftonline.com` | your UPN |

Both the Makefile (`SIG_IDENTITY`, `SIG_OIDC_ISSUER`) and the Kyverno policy pin these — swap
the values for whichever provider you log in with.

---

## 2. Why this is air-gap-safe (the key property)

Per the OCM concepts doc, the signature stored in the descriptor is a **self-contained Sigstore
bundle**: *"the signature bytes, the Fulcio certificate, and the Rekor inclusion proof, all in
one self-contained blob."* Two consequences that make the air gap work cleanly:

1. **`ocm transfer` preserves it.** Signatures are part of the component descriptor, and the
   signed digest excludes the `access` field (where a resource is stored), so moving the bundle
   from GHCR → RBSC does **not** invalidate the signature. Sign once, verify anywhere.

2. **Offline verification needs only a local trusted-root file.** Because the Rekor proof and
   Fulcio cert are already embedded, the verifier only needs the Fulcio/Rekor **public keys** to
   check them. Distribute that trusted-root file into the air gap **once, out of band**; then
   `ocm verify cv --keyless -L` runs *"entirely offline: no callback to any Sigstore service, no
   TUF refresh, no network egress whatsoever."* The `-L/--local` flag means "verify using only
   the information found in the component version" — exactly the embedded bundle.

> For a demo where even mirroring a trust root is too much: verify **on the connected transfer
> host** (step 6 below) where public Sigstore is reachable, and skip in-cluster verification.
> The bundle that crosses the gap is already proven at that point.

---

## 3. Domain A — sign & verify the OCM component version (the primary gate)

A single OCM signature whose normalized digest **transitively covers every resource** (every
chart, every `ociImage` reference) and every nested `componentReference`. Verify the root and
you've verified the whole tree.

### Sign (on your laptop, after `make build`, before `make push`)

```bash
# Browser opens for OIDC login. -S selects the sigstore handler; --keyless = no key files.
ocm sign componentversions \
  --keyless \
  --signature greenhouse-release \
  --algorithm sigstore-v2 \
  --repo directory::./greenhouse-bundle.ctf \
  github.com/cloudoperators/greenhouse:0.16.1
```

- `--signature greenhouse-release` — the signature *name* (a component may carry several; e.g.
  a build sig and a release sig).
- `--algorithm sigstore-v2` — the newer sigstore handler in v0.48.0 (`sigstore` is the v1).
- `--recursive` — add it if you want every sub-component individually signed too; not required,
  since the root signature already covers them transitively via embedded digests.

### Verify at the air-gap boundary (`make verify-sigstore` — THE gate)

```bash
# Run on the connected transfer host BEFORE `ocm transfer` to RBSC.
# Add -L to force fully-offline/local verification (uses the embedded bundle only).
ocm verify componentversions \
  --keyless \
  --signature greenhouse-release \
  --repo oci://ghcr.io/sofiyadesaisap/greenhouse \
  github.com/cloudoperators/greenhouse:0.16.1
```

A tampered chart or image **anywhere** in the bundle changes a resource digest, which changes
the component digest, which fails this one check. If it passes, the bundle is safe to cross the
air gap.

### Optional: verify again inside the cluster

The OCM controller (`delivery.ocm.software` `ComponentVersion`) can be configured to require a
valid signature before it resolves a bundle. That needs the trusted-root file mounted into
`ocm-system` (see `make load-sigstore-root`). This is the belt-and-suspenders option; the
transfer-boundary check (step 6) is the one that matters most.

---

## 4. Domain B — verify container images at admission (Kyverno, optional)

The kubelet pulls the greenhouse/dashboard/postgres **images** *directly* from RBSC — they are
**not** repackaged by the OCM controller (only Helm charts become Snapshots), so cosign image
signatures survive the whole journey and can be enforced at pod admission.

`prereqs/kyverno-verify-images.yaml` enforces this. Air-gap specifics: `rekor.ignoreTlog: true`
(the proof is embedded) + the mirrored trusted root loaded via `make load-sigstore-root`.

> **Ownership caveat (important for your bundle).** The images are
> `ghcr.io/cloudoperators/greenhouse` and `…/juno-app-greenhouse` — the **upstream** cloudoperators
> repos, which you cannot push cosign signatures to. So image signing is only meaningful if you
> **re-host** those images under a registry you control (e.g. during/after transfer to RBSC) and
> sign *those*. Until then, rely on **Domain A** (the OCM signature already covers the image
> *digests*, so a swapped image still fails `ocm verify`). Kyverno image-signature enforcement is
> a later add-on for when you own the image copies.

Gatekeeper note: OPA/Gatekeeper has **no native cosign verifier** — it needs the Ratify
external-data provider to do the actual verification. Kyverno verifies cosign natively, so for
this stack Kyverno is the simpler, correct choice. Ask if you want the Gatekeeper+Ratify variant.

---

## 5. Why Flux `spec.verify` cannot be the gate

The Flux docs (`OCIRepository.spec.verify: cosign` + `matchOIDCIdentity`) are correct *when Flux
pulls the signed artifact directly*. Your topology breaks that assumption:

```
signed bundle in RBSC ──► OCM controller pulls & EXTRACTS each chart ──► re-pushes it as a
                                                                          *new* Snapshot in
                                                                   registry.ocm-system:5000
                                                                          │  (new digest,
                                            Flux OCIRepository pulls ◄─────┘   signature NOT
                                            the Snapshot                       carried over)
```

Flux never sees the original signed chart — it sees the OCM controller's freshly-minted,
**unsigned** Snapshot. Putting `spec.verify` on the kro-generated `OCIRepository` objects would
**always fail** ("no signature found"), not add security. Chart integrity is instead attested by
the OCM signature in §3, which is computed *before* extraction and covers the chart digests
transitively. A commented block in `deploy/kro-rgd.yaml` marks exactly where `spec.verify` would
go *if* you ever switch to Flux pulling charts directly from RBSC.

---

## 6. End-to-end flow (hand-run, mapped to make targets)

```
[LAPTOP — has internet]
  make build            # ocm add componentversions → greenhouse-bundle.ctf
  make sign-sigstore    # ocm sign cv --keyless -S sigstore-v2   (browser login)
  make push             # ocm transfer ctf → central GHCR        (signature preserved)

[LAPTOP / transfer host — the air-gap boundary]
  make verify-sigstore  # ocm verify cv --keyless  ← THE GATE. fail = stop, don't cross.
  (then the Part 1 `ocm transfer` to RBSC from demo-script.md)

[CLUSTER — air-gapped]
  (optional) make load-sigstore-root   # mount trusted root for in-cluster verify
  (optional) make install-kyverno      # enforce image sigs — only for images you own/re-host
  OCM controller pulls bundle → Snapshots → Flux installs charts (integrity attested at verify)
```

---

## 7. Make targets added

| Target | Does |
|---|---|
| `make -f Makefile.ocm sign-sigstore` | `ocm sign cv --keyless -S sigstore-v2` on the local CTF (browser login) |
| `make -f Makefile.ocm verify-sigstore` | `ocm verify cv --keyless` — run before transfer; the air-gap gate |
| `make -f Makefile.ocm sign-images` | `cosign sign` greenhouse+dashboard images — **only after you re-host them** |
| `make -f Makefile.ocm install-kyverno` | install Kyverno + apply `prereqs/kyverno-verify-images.yaml` |
| `make -f Makefile.ocm load-sigstore-root` | load a mirrored trusted root for offline in-cluster verify |

Full definitions in `Makefile.ocm`.
