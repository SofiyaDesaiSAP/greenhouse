# pipeline.yaml.erb — Detailed Explanation

This is a **Concourse CI** pipeline definition, templated with **ERB (Embedded Ruby)**. It gets rendered into a final YAML before being applied to Concourse.

---

## ERB Structure & Task Injection

```erb
<% Dir.glob(File.join(File.dirname(__FILE__), "/tasks/*.yaml"))... %>
```

At render time, every `.yaml` file in the local `tasks/` directory is read and injected as a **YAML anchor** into the top of the rendered pipeline. This is how `*kustomize-diff` and `*kustomize-apply` get defined — they come from `tasks/kustomize-diff.yaml` and `tasks/kustomize-apply.yaml` and are referenced later via `<<: *kustomize-diff`.

---

## Target Clusters

Three clusters are defined as a Ruby array, controlling the generated jobs:

| Cluster | Region | Trigger | Gates (must pass before running) | Role |
|---|---|---|---|---|
| `greenhouse-qa` | eu-nl-1 | auto | none | QA / canary |
| `greenhouse-playground` | eu-nl-1 | manual | `greenhouse-qa-deploy` | Staging |
| `greenhouse-p-eu-de-1` | eu-de-1 | manual | `greenhouse-playground-deploy` | Production |

`organization: false` on qa and playground means the **ccloud jobs are skipped** for them (guarded by `next if cluster[:organization] == false`).

---

## Resource Types

| Name | Image | Purpose |
|---|---|---|
| `git-proxy` | `keppel.eu-de-1.cloud.sap/ccloud/concourse-git-resource-proxy` | SAP-internal git proxy/caching layer wrapping standard git resource |
| `release` | `keppel.eu-de-1.cloud.sap/ccloud/concourse-release-resource:v2` | SAP-internal resource for tracking release versions |

---

## Resources

These are the **watched inputs** that trigger pipeline runs:

| Resource | Type | Source Repo / Registry | What it watches |
|---|---|---|---|
| `greenhouse-ghcr-image` | docker-image | `ghcr.io/cloudoperators/greenhouse:main` | New image pushes, checked every 1h |
| `greenhouse-charts.git` | git | `github.com/cloudoperators/greenhouse`, branch `main` | `charts/**` — used for QA only |
| `greenhouse-charts-release.git` | git | same repo, branch `helm-chart-0.23.0` | `charts/**` — used for playground & prod |
| `greenhouse-org-charts.git` | git-proxy | `github.com/sapcc/helm-charts`, branch `master` | `system/greenhouse-organization/**` |
| `greenhouse-ccloud-charts.git` | git | same `sapcc/helm-charts` | `system/greenhouse-ccloud/**` |
| `secrets-script.git` | git-proxy | `github.wdf.sap.corp:cc/secrets.git` (private) | `ci/greenhouse/*`, `ci/shared/*` — CI task scripts |
| `secrets.git` | git-proxy | same private secrets repo | `*/values/globals.yaml`, per-cluster value files |

**Key insight:** `secrets.git` holds Helm values (not just credentials). `secrets-script.git` holds the actual task YAML scripts used by helm-diff, helm-upgrade, and replicate-images tasks.

---

## Pipeline Groups

- **`build`** — greenhouse core: diff + deploy for each cluster
- **`greenhouse-organization`** — org-level Helm chart: diff + deploy for each cluster
- **`ccloud`** — CCloud org chart: diff + deploy, **production only** (`greenhouse-p-eu-de-1`)

---

## Jobs in Detail

### 1. `readme` (informational only)

- **Task:** `describe-this-pipeline`
- **Image:** `alpine:latest`
- **What it does:** Runs `/bin/echo` to print the URL of the CI definition. A human-readable no-op documenting where the pipeline lives.
- **Prerequisites:** None. Not triggered by anything.
- No chart involved.

---

### 2. `{cluster}-diff` — Preview what will change

**Purpose:** Dry-run before any real deployment. Shows what Helm/kustomize would change without applying anything.

#### Step 1 — Gather inputs (parallel)

- `get: secrets.git` — triggers the job when value files change
- `get: secrets-script.git` — CI task script files
- **For `greenhouse-qa` only:**
  - `get: greenhouse-charts.git` — from `main` branch, `charts/**`
  - `get: greenhouse-ghcr-image` — grabs the latest docker image
  - `load_var: greenhouse-digest` ← reads the image digest file into a pipeline variable so the exact SHA can be pinned in Helm `--set` args
- **For playground/prod:**
  - `get: greenhouse-charts-release.git` — from `helm-chart-0.23.0` release branch, must pass the upstream gate cluster's deploy job

#### Step 2 — Vault authentication

- `get-vault-token` — runs `secrets.git/ci/shared/task-get-vault-jwt.yaml`
  Gets a short-lived JWT from HashiCorp Vault using `VAULT_ROLE_ID` / `VAULT_SECRET_ID`
- `load_var: vault-jwt` — loads the JWT for use by kubelogon (Kubernetes auth)

#### Step 3 — Diff (parallel)

**Sub-task A: `kustomize-diff`**
- Config loaded from `*kustomize-diff` anchor (from local `tasks/kustomize-diff.yaml`)
- Input mapped: `source.git` → `greenhouse-charts.git` or `greenhouse-charts-release.git`
- **Chart path:** `charts/manager/crds`
- **What it does:** Shows what CRD changes would be applied via `kubectl diff` / kustomize
- Key params: `CONTEXT` (cluster name), `NAMESPACE: greenhouse`, `REGION`, `KUBELOGON_TOKEN` (vault JWT)

**Sub-task B: `helm-diff`**
- Task file: `secrets-script.git/ci/shared/task-helm-diff.yaml`
- Input mapped: `helm-charts.git` → `greenhouse-charts.git` or `greenhouse-charts-release.git`
- **Chart path:** `charts/greenhouse`
- **What it does:** Runs `helm diff upgrade` to show what would change in the `greenhouse` Helm release
- Values resolution via `VALUES: local:globals global:greenhouse local:<cluster-name>`:
  - `local:globals` → `secrets.git/<region>/values/globals.yaml`
  - `global:greenhouse` → `secrets.git/globals/values/greenhouse.yaml`
  - `local:<cluster-name>` → `secrets.git/<region>/values/<cluster-name>.yaml`
- **For QA only:** additional `--set` args pin each component's image to the loaded digest:
  - `idproxy.image.digest`
  - `cors-proxy.image.digest`
  - `manager.controllerManager.image.digest`
  - `authz.image.digest`

#### Step 4 — Image replication

- `replicate-changed-images` from `secrets-script.git/ci/shared/task-replicate-changed-images.yaml`
- **For non-production clusters:** runs twice — first for `eu-de-1` (anonymous pull only works there), then for the cluster's own region
- **For `greenhouse-p-eu-de-1`:** runs once for `eu-de-1` only
- **What it does:** Mirrors newly referenced container images to the regional Keppel registry before deployment

---

### 3. `{cluster}-deploy` — Actual deployment

**Purpose:** Apply CRDs with kustomize, then upgrade the Helm release.

**Prerequisites:** All inputs must have **passed** the corresponding `{cluster}-diff` job. Playground and prod have `trigger: false` — they require manual promotion.

#### Steps 1–2 — Same input gathering + vault auth as diff

For QA: `greenhouse-ghcr-image` is fetched with `skip_download: true` — only the metadata/digest file is needed, not the full image layers.

#### Step 3 — `kustomize-apply`

- Config from `*kustomize-apply` anchor (from `tasks/kustomize-apply.yaml`)
- **Chart path:** `charts/manager/crds`
- **What it does:** Applies CRD manifests to the cluster via `kubectl apply -k`

#### Step 4 — `helm-deploy`

- Task file: `secrets-script.git/ci/shared/task-helm-upgrade.yaml`
- **Chart path:** `charts/greenhouse`
- **What it does:** Runs `helm upgrade --install greenhouse charts/greenhouse` in namespace `greenhouse`
- Same values resolution, same digest `--set` args (QA only), same vault auth

---

### 4. `{cluster}-ccloud-diff` / `{cluster}-ccloud-deploy` — CCloud org chart (production only)

Only generated for `greenhouse-p-eu-de-1`. QA and playground are skipped via `organization: false`.

| Property | Value |
|---|---|
| Chart source | `greenhouse-ccloud-charts.git` → `github.com/sapcc/helm-charts`, path `system/greenhouse-ccloud` |
| Helm release | `ccloud` in namespace `ccloud` |
| Values | `local:globals local:<cluster>-ccloud` (no global greenhouse values) |
| Trigger | changes to `greenhouse-ccloud-charts.git` or `secrets.git` |
| Deploy trigger | `trigger: false` — manual only, must pass diff |

No image digest pinning. No kustomize step — Helm only.

---

### 5. `{cluster}-organization-diff` / `{cluster}-organization-deploy` — Greenhouse Org chart (all clusters)

**Purpose:** Deploy the `greenhouse-organization` Helm chart (SAP-internal org configuration).

| Property | Value |
|---|---|
| Chart source | `greenhouse-org-charts.git` → `github.com/sapcc/helm-charts`, path `system/greenhouse-organization` |
| Helm release | `greenhouse-organization` in namespace `greenhouse` |
| Values | `local:globals global:greenhouse local:<cluster>` |
| Gate for non-QA | must pass `greenhouse-qa-organization-deploy` first |

Promotion chain: `qa-organization-deploy` unlocks both `playground` and `p-eu-de-1` org jobs.

---

## Full Promotion Flow

```
Trigger: secrets.git / greenhouse-charts.git (main) / ghcr image
  └─► greenhouse-qa-diff
        └─► greenhouse-qa-deploy
              └─► greenhouse-playground-diff (manual)
                    └─► greenhouse-playground-deploy (manual)
                          └─► greenhouse-p-eu-de-1-diff (manual, release branch)
                                └─► greenhouse-p-eu-de-1-deploy (manual)

Trigger: greenhouse-org-charts.git / secrets.git
  └─► greenhouse-qa-organization-diff
        └─► greenhouse-qa-organization-deploy
              └─► greenhouse-playground-organization-diff (manual)
              └─► greenhouse-p-eu-de-1-organization-diff (manual)

Trigger: greenhouse-ccloud-charts.git / secrets.git (prod only)
  └─► greenhouse-p-eu-de-1-ccloud-diff
        └─► greenhouse-p-eu-de-1-ccloud-deploy (manual)
```

**QA always uses the `main` branch and a live image digest. Playground and prod use the pinned release branch (`helm-chart-0.23.0`) and require manual promotion through gates.**
