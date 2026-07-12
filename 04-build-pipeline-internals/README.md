# 04 — Build Pipeline Internals

This step examines what happens inside a Konflux build pipeline run. The standard pipeline chains tasks in this order: `init` → `clone-repository` → `prefetch-dependencies` → `build-container` → `build-image-index` → scan tasks in parallel (deprecated-base-image-check, clamav-scan, sast-shell-check, sast-unicode-check, rpms-signature-scan, tpa-scan). After the PipelineRun completes, Tekton Chains signs the image and creates a SLSA provenance attestation. The `IMAGE_DIGEST` result from `build-image-index` is the handoff value that Chains, Integration Service, and Release Service all use to identify the exact image. The `--insecure-ignore-tlog` flag is required for `cosign` on self-hosted Konflux because Chains signs against the cluster's internal keypair, not the public Sigstore transparency log.

## Prerequisites

- At least one successful push PipelineRun has completed (complete `03-onboard-application/`)
- `cosign` CLI installed: `brew install cosign` (macOS) or `go install github.com/sigstore/cosign/v2/cmd/cosign@latest`
- `tkn` CLI installed
- Registry credentials in `~/.docker/config.json` for the registry where the image was pushed — run `docker login quay.io` or `podman login quay.io`

## Environment Variables

| Variable | Set By | Description | Example |
|---|---|---|---|
| `NAMESPACE` | Set manually at top of `inspect-pipeline.sh` | Your tenant namespace | `default-tenant` |
| `PR_NAME` | Auto-derived in script | Name of the latest PipelineRun from `oc get pipelinerun` | `testrepo-on-push-abc12` |
| `IMAGE_URL` | Auto-derived in script | Image URL from PipelineRun result `IMAGE_URL` | `quay.io/jsmith/testrepo` |
| `IMAGE_DIGEST` | Auto-derived in script | Image digest from PipelineRun result `IMAGE_DIGEST` | `sha256:abc123...` |

## Files in This Directory

| File | Description |
|---|---|
| `inspect-pipeline.sh` | Watch pipeline logs; extract IMAGE_URL/IMAGE_DIGEST; download SBOM (two options); verify cosign signature; verify SLSA attestation; debug failed TaskRuns |

## Step-by-step Usage

### Step 1 — Set your namespace and edit the script

Open `inspect-pipeline.sh` and set `NAMESPACE` at the top:

```bash
NAMESPACE="default-tenant"
```

### Step 2 — Watch pipeline logs and describe results

```bash
NS="default-tenant"

# Follow the latest PipelineRun in real time
tkn pipelinerun logs --last -f -n $NS

# Describe all task results after completion
tkn pipelinerun describe --last -n $NS
```

### Step 3 — Extract IMAGE_URL and IMAGE_DIGEST

```bash
NS="default-tenant"

PR_NAME=$(oc get pipelinerun -n $NS \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

IMAGE_URL=$(oc get pipelinerun $PR_NAME -n $NS \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')

IMAGE_DIGEST=$(oc get pipelinerun $PR_NAME -n $NS \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

echo "IMAGE_URL:    $IMAGE_URL"
echo "IMAGE_DIGEST: $IMAGE_DIGEST"
```

### Step 4 — Download the SBOM

Konflux uploads the SBOM via `cosign attach sbom` (the upload-sbom pipeline step). Use Option A — it works on all Konflux installations:

```bash
# Option A — cosign attach sbom path (works on all Konflux clusters)
cosign download sbom "${IMAGE_URL}@${IMAGE_DIGEST}" | python3 -m json.tool | head -60
```

Option B (only when keyless signing is enabled on the cluster):

```bash
# Option B — cosign attestation path (only when keyless signing with Fulcio/Rekor is enabled)
cosign download attestation "${IMAGE_URL}@${IMAGE_DIGEST}" \
  | jq -r 'select(.payload != null) | .payload | @base64d | fromjson
            | select(.predicateType == "https://spdx.dev/Document") | .predicate' \
  | head -60
```

### Step 5 — Get the Chains public key

```bash
# On OCP, Tekton Chains runs in openshift-pipelines (NOT a separate tekton-chains namespace)
oc get secret signing-secrets -n openshift-pipelines \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign.pub
cat /tmp/cosign.pub
```

### Step 6 — Verify the cosign image signature

```bash
cosign verify \
  --key /tmp/cosign.pub \
  --insecure-ignore-tlog \
  "${IMAGE_URL}@${IMAGE_DIGEST}"
```

`--insecure-ignore-tlog` is required because Tekton Chains signs using the cluster's internal keypair, not the public Sigstore Rekor transparency log. Without this flag, cosign attempts to look up the signature at `rekor.sigstore.dev` and always fails for self-hosted Konflux.

### Step 7 — Verify the SLSA provenance attestation

```bash
cosign verify-attestation \
  --key /tmp/cosign.pub \
  --insecure-ignore-tlog \
  --type slsaprovenance \
  "${IMAGE_URL}@${IMAGE_DIGEST}" | jq '.payload | @base64d | fromjson'
```

### Step 8 — (If needed) Debug a failed TaskRun

```bash
NS="default-tenant"

# List all TaskRuns for the PipelineRun, sorted by completion time
oc get taskruns -n $NS \
  --selector=tekton.dev/pipelineRun=$PR_NAME \
  '--sort-by=.status.conditions[-1].lastTransitionTime'

# Find the failed TaskRun
FAILED_TR=$(oc get taskruns -n $NS \
  --selector=tekton.dev/pipelineRun=$PR_NAME \
  -o jsonpath='{.items[?(@.status.conditions[0].reason=="Failed")].metadata.name}')

# Get its logs
tkn taskrun logs $FAILED_TR -n $NS

# If the TaskRun pod is stuck in Pending
oc describe pod -n $NS --selector=tekton.dev/taskRun=$FAILED_TR
```

Or run the full script:

```bash
bash inspect-pipeline.sh
```

## What to Expect

- `cosign verify` exits with `Verified OK` and prints a JSON payload with the image digest.
- `cosign verify-attestation --type slsaprovenance` returns a JSON object with the full SLSA build provenance including `buildType`, `builder.id`, and all inputs/outputs.
- `cosign download sbom` prints the SPDX SBOM in JSON format — look for `packages`, `relationships`, and `spdxVersion` fields.
- Tekton Chains controller logs (in `openshift-pipelines`) show `Signing TaskRun ... Signed!` entries after each PipelineRun completes.

## Troubleshooting

**`cosign verify` fails with "no valid signatures found"**
Tekton Chains may not have finished signing yet. Wait 30–60 seconds after the PipelineRun shows `Succeeded`, then retry. Check Chains controller logs:
```bash
oc logs -n openshift-pipelines -l app=tekton-chains-controller --tail=50
```

**`cosign download sbom` fails with authentication error**
Your `~/.docker/config.json` is missing or stale for the registry. Run `docker login quay.io` or `podman login quay.io` and retry.

**`cosign verify-attestation` returns "no attestations found"**
This is normal if Chains only signed the image and did not store a separate attestation (depends on the Chains configuration). Use `cosign download attestation` instead.

**Tekton Chains controller namespace**
On OCP, Tekton Chains runs inside `openshift-pipelines` — there is no separate `tekton-chains` namespace. Always use `-n openshift-pipelines` when looking for the Chains controller pods or `signing-secrets`.

## Next Step

`05-pipeline-as-code/` — Customize the pipeline with your own tasks using Pipeline-as-Code.
