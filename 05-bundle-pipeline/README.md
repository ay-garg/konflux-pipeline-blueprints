# 05 — Bundle-Based Build Pipelines

Replace the verbose auto-generated inline `pipelineSpec` with a single pinned OCI bundle reference. The `pipeline-docker-build-oci-ta` bundle is a complete `Pipeline` resource — all standard Konflux tasks are included, nothing is dropped.

## What This Directory Covers

- What a Tekton pipeline bundle is and how it differs from an inline `pipelineSpec`
- Using `pipelineRef` with the bundles resolver to reference a pipeline by OCI digest
- Why pinning by digest (not `:latest`) matters for reproducibility and supply-chain security
- The `skip-checks` parameter — when it is needed and what it skips
- The Tekton constraint: custom tasks cannot be appended to a `pipelineRef` pipeline

## Prerequisites

| Requirement | Details |
|---|---|
| Completed `04-build-pipeline-internals/` | Component is onboarded; at least one PipelineRun has succeeded |
| `oc` logged in | `oc whoami` returns your user |
| Local testrepo fork clone | `git clone https://github.com/YOUR-USERNAME/testrepo` |

## What the Bundle Contains

The `pipeline-docker-build-oci-ta` bundle includes every task in the auto-generated inline pipeline:

| Stage | Tasks |
|---|---|
| Sequential (build) | `init` → `clone-repository` → `prefetch-dependencies` → `build-container` → `build-image-index` |
| Parallel (post-build checks) | `clamav-scan`, `sast-shell-check`, `sast-unicode-check`, `deprecated-base-image-check`, `rpms-signature-scan`, `apply-tags`, `push-dockerfile` |

All check tasks are gated by the `skip-checks` parameter. Setting it to `"true"` skips the entire parallel fan-out; the build, clone, and index tasks always run.

## Bundle vs Inline `pipelineSpec`

| Aspect | Bundle (`pipelineRef`) | Inline (`pipelineSpec`) |
|---|---|---|
| File size | ~55 lines | ~230+ lines |
| Task visibility | Hidden inside bundle | Fully readable |
| Custom tasks | ❌ Not possible | ✅ Supported |
| Reproducibility | Pinned by digest | Each task bundle must be pinned individually |
| Upgrades | Update one digest line | Renovate/Mintmaker updates each task digest |
| Best for | Standard builds, minimal YAML | Custom steps, individual task control |

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Interactive script — copies and configures both pipeline files into your fork |
| `.tekton/testrepo-push.yaml` | Bundle-based push pipeline (triggers on merge to main) |
| `.tekton/testrepo-pull-request.yaml` | Bundle-based PR pipeline (triggers on pull request) |

## Placeholders

Replace these in both `.tekton/` files before applying (or let `setup.sh` do it):

| Placeholder | Replace With |
|---|---|
| `YOUR-USERNAME` | Your GitHub username (owner of the testrepo fork) |
| `YOUR-ORG` | Your quay.io username or organization |

## Steps

### Option A — Automated (recommended)

```bash
bash setup.sh
```

The script will:
1. Prompt for your GitHub username, Quay.io org, and repo path
2. Ask if you are on CRC arm64 and set `skip-checks` accordingly
3. Copy both `.tekton/` files into your fork and replace all placeholders
4. Offer to commit and push immediately

### Option B — Manual

```bash
# 1. Copy files into your fork
cp .tekton/testrepo-push.yaml         /path/to/your/testrepo/.tekton/
cp .tekton/testrepo-pull-request.yaml /path/to/your/testrepo/.tekton/

# 2. Replace placeholders (cross-platform)
cd /path/to/your/testrepo
perl -pi -e 's/YOUR-USERNAME/your-github-username/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
perl -pi -e 's/YOUR-ORG/your-quay-org/g'             .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml

# 3. If on CRC arm64 — enable skip-checks (scan images are amd64-only)
perl -0pi -e 's/(- name: skip-checks\s*\n\s+value: )"true"/$1"true"/g' .tekton/testrepo-push.yaml
# Remove the param block entirely on a full amd64 cluster (all checks will run)

# 4. Commit and push
git add .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
git commit -m "chore: switch to bundle-based pipeline (pipeline-docker-build-oci-ta)"
git push origin main
```

## skip-checks Parameter

The `skip-checks` parameter is built into the Konflux bundle. When set to `"true"`, all post-build scan tasks are skipped via their internal `when` conditions. The build itself is unaffected.

**When to use `skip-checks: "true"`:**
- Running on CRC (OpenShift Local) on a Silicon Mac — the scan task images are built amd64-only and cannot be pulled on an arm64 node. The pod fails with: `no image found in manifest list for architecture "arm64"`
- During rapid iteration where scan feedback is not needed

**Remove `skip-checks` or set to `"false"` when:**
- Running on a full amd64 OpenShift cluster
- Running on the hosted Konflux service (`console.redhat.com/application-pipeline`)
- Running a production pipeline where compliance scans must pass

## Verify the PipelineRun

```bash
NS="default-tenant"

# Watch the run start
oc get pipelinerun -n $NS -w

# Get the latest run name
PR=$(oc get pipelinerun -n $NS \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

# Confirm the pipeline was resolved from the bundle (not an inline spec)
oc describe pipelinerun "$PR" -n $NS | grep -A5 "Pipeline Ref"

# Follow logs
tkn pipelinerun logs "$PR" -n $NS -f

# Check which tasks were skipped (when skip-checks=true)
oc get pipelinerun "$PR" -n $NS \
  -o jsonpath='{.status.skippedTasks[*].name}' | tr ' ' '\n'

# Confirm IMAGE_URL and IMAGE_DIGEST results are populated
oc get pipelinerun "$PR" -n $NS \
  -o jsonpath='{.status.results}' | python3 -m json.tool
```

## Adding Custom Tasks

`pipelineRef` does not support appending tasks — this is a hard Tekton constraint. The referenced pipeline is fetched as-is from the OCI bundle; there is no field in the `PipelineRun` spec that adds tasks to it.

To add a custom `print-build-summary` step, use the inline `pipelineSpec` approach in **`06-pipeline-as-code/`** instead. That directory keeps the full task list explicit and adds the custom task after `build-image-index`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `MANIFEST_UNKNOWN: manifest unknown` | Bundle tag `:latest` does not exist | The digest in the YAML is pinned — verify the `sha256:` value is present and correct |
| `secret "multi-platform-ssh-…" not found` | Wrong bundle — multi-platform bundle requires the Multi-Platform Controller | Ensure you are using `pipeline-docker-build-oci-ta`, not `pipeline-docker-build-multi-platform-oci-ta` |
| `no image found in manifest list for architecture "arm64"` | Running on CRC arm64; scan images are amd64-only | Set `skip-checks: "true"` in both pipeline files |
| Two PipelineRuns fire on every push | Old inline pipeline file still present in `.tekton/` | Remove or rename the old file; both pipelines share the same CEL trigger |
| `serviceAccountName: build-pipeline-testrepo not found` | Service account not yet created | It is auto-created by Build Service when the Component is onboarded — re-trigger by pushing after onboarding completes |
