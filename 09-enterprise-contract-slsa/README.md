# 09 — Enterprise Contract & SLSA

This step explores the Enterprise Contract (EC) CLI and SLSA supply-chain security features built into Konflux. The `ec validate image` command evaluates a built image against an `EnterpriseContractPolicy`: it verifies the cosign signature from Tekton Chains, checks the SLSA provenance attestation, and evaluates Rego policy rules against that attestation. This is the same validation the Release Service runs automatically before allowing a release. Running EC against an upstream image (for example `docker.io/library/alpine:latest`) demonstrates a failing case — it is unsigned and carries no Tekton attestation. The `commands.sh` script walks through installation, cluster policy discovery, public key extraction, and both passing and failing validation examples.

## Prerequisites

- At least one successful push build with a signed image (complete `05-bundle-pipeline/` or `06-pipeline-as-code/`)
- `testrepo-ec-policy` created in `default-tenant` (done in `08-release-planning/` Step 2)
- `oc` CLI logged in with access to `default-tenant`
- Internet access to download the `ec` CLI binary and fetch policy bundles

## Environment Variables

| Variable | Set By | Description | Example |
|---|---|---|---|
| `NS` | Set manually | Tenant namespace | `default-tenant` |
| `IMAGE_URL` | **Must set manually** | Full image URL from a previous push PipelineRun `IMAGE_URL` result | `quay.io/jsmith/testrepo` |
| `IMAGE_DIGEST` | **Must set manually** | Image digest from a previous push PipelineRun `IMAGE_DIGEST` result | `sha256:abc123...` |

The latest PipelineRun is the **release pipeline run** (from item 19), which does not expose `IMAGE_URL`/`IMAGE_DIGEST` as Tekton results — those belong to the build pipeline. Instead, read the image reference from the `post-release-actions` task log, which prints `"Released image : <ref>"` explicitly:

```bash
NS="default-tenant"

# Get the latest PipelineRun (the release pipeline run)
PR=$(oc get pipelinerun -n $NS \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')
echo "Last PipelineRun: $PR"

# Grep the released image reference from the post-release-actions task log
IMAGE_REF=$(tkn pipelinerun logs "$PR" -n $NS 2>/dev/null | \
  grep "Released image" | \
  awk '{print $NF}' | \
  tail -1)
echo "Image reference : $IMAGE_REF"

# Split into URL and digest (format: quay.io/org/repo@sha256:...)
IMAGE_URL="${IMAGE_REF%@*}"
IMAGE_DIGEST="${IMAGE_REF#*@}"

echo "IMAGE_URL=$IMAGE_URL"
echo "IMAGE_DIGEST=$IMAGE_DIGEST"
```

## Files in This Directory

| File | Description |
|---|---|
| `commands.sh` | Install the `ec` CLI; list EC policies in the cluster; extract the Chains public key; run `ec validate image` against a Konflux-built image and against an unsigned upstream image |

## Step-by-step Usage

### Step 1 — Install the ec CLI

```bash
# Apple Silicon (macOS arm64)
curl -sLO https://github.com/conforma/cli/releases/latest/download/ec_darwin_arm64
chmod 755 ec_darwin_arm64 && sudo mv ec_darwin_arm64 /usr/local/bin/ec

# Intel Mac (macOS amd64)
curl -sLO https://github.com/conforma/cli/releases/latest/download/ec_darwin_amd64
chmod 755 ec_darwin_amd64 && sudo mv ec_darwin_amd64 /usr/local/bin/ec

# Linux amd64
curl -sLO https://github.com/conforma/cli/releases/latest/download/ec_linux_amd64
chmod 755 ec_linux_amd64 && sudo mv ec_linux_amd64 /usr/local/bin/ec

ec version
```

### Step 2 — List EC policies in the cluster

```bash
# List all EnterpriseContractPolicy CRs across all namespaces
oc get enterprisecontractpolicy -A

# Describe the policy created in `08-release-planning/`
oc describe enterprisecontractpolicy testrepo-ec-policy -n default-tenant
```

### Step 3 — Extract the Chains public key

On OCP, Tekton Chains stores the signing key in `openshift-pipelines` as the `public-key` secret (NOT `tekton-chains`, which is the upstream default namespace).

```bash
oc get secret public-key -n openshift-pipelines \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/chains-public-key.pub

echo "Public key saved to /tmp/chains-public-key.pub"
cat /tmp/chains-public-key.pub
```

### Step 4 — Set image reference variables

```bash
NS="default-tenant"

PR=$(oc get pipelinerun -n $NS \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

IMAGE_REF=$(tkn pipelinerun logs "$PR" -n $NS 2>/dev/null | \
  grep "Released image" | \
  awk '{print $NF}' | \
  tail -1)

IMAGE_URL="${IMAGE_REF%@*}"
IMAGE_DIGEST="${IMAGE_REF#*@}"

echo "Validating: ${IMAGE_URL}@${IMAGE_DIGEST}"
```

### Step 5 — Export the EC policy to a local YAML file

Some `ec` CLI versions cannot parse `k8s://` policy references directly. Export the policy CR to a file first:

```bash
oc get enterprisecontractpolicy testrepo-ec-policy -n default-tenant -o yaml \
  > /tmp/testrepo-ec-policy.yaml
echo "Policy exported to /tmp/testrepo-ec-policy.yaml"
```

### Step 6 — Validate a Konflux-built image (text output)

```bash
ec validate image \
  --image "${IMAGE_URL}@${IMAGE_DIGEST}" \
  --policy /tmp/testrepo-ec-policy.yaml \
  --public-key /tmp/chains-public-key.pub \
  --ignore-rekor \
  --output text
```

`--ignore-rekor` skips the public Sigstore Rekor transparency log — required on self-hosted Konflux where signatures are written by the cluster's internal Tekton Chains key, not published to public Rekor.

### Step 7 — Full JSON output and result summary

```bash
ec validate image \
  --image "${IMAGE_URL}@${IMAGE_DIGEST}" \
  --policy /tmp/testrepo-ec-policy.yaml \
  --public-key /tmp/chains-public-key.pub \
  --ignore-rekor \
  --output json > /tmp/ec-result.json

# Overall result and counts
jq '{result: .components[0].success,
     violations: (.components[0].violations | length),
     warnings:   (.components[0].warnings   | length),
     successes:  (.components[0].successes  | length)}' /tmp/ec-result.json

# List violations with their rule code and reason
jq -r '.components[0].violations[] | "VIOLATION \(.metadata.code): \(.msg)"' \
  /tmp/ec-result.json
```

### Step 8 — Verify the cosign image signature

> **Do not use `2>&1`** — cosign writes status/progress messages to stderr and the JSON payload to stdout. Redirecting stderr into stdout corrupts the JSON stream and causes `Expecting value: line 1 column 1 (char 0)`.

```bash
cosign verify \
  --key /tmp/chains-public-key.pub \
  --insecure-ignore-tlog \
  "${IMAGE_URL}@${IMAGE_DIGEST}" | jq .
```

### Step 9 — Inspect the SLSA provenance attestation

Tekton Chains generates an in-toto SLSA v0.2 attestation for every build. The `cosign verify-attestation` command fetches and verifies it, then `jq` decodes the base64 payload and extracts the key fields.

```bash
cosign verify-attestation \
  --key /tmp/chains-public-key.pub \
  --insecure-ignore-tlog \
  --type slsaprovenance \
  "${IMAGE_URL}@${IMAGE_DIGEST}" \
  | jq -r '.payload | @base64d | fromjson | {
      predicateType,
      builder: .predicate.builder.id,
      buildType: .predicate.buildType,
      commit: .predicate.materials[0].digest.sha1,
      repo: .predicate.materials[0].uri,
      startedOn: .predicate.metadata.buildStartedOn,
      finishedOn: .predicate.metadata.buildFinishedOn
    }'
```

### Step 10 — Test a non-compliant image (expected to fail)

```bash
ec validate image \
  --image "docker.io/library/alpine:latest" \
  --policy /tmp/testrepo-ec-policy.yaml \
  --public-key /tmp/chains-public-key.pub \
  --ignore-rekor \
  --output text || true
# Expected: FAILURE — unsigned image, no Tekton attestation
```

### Step 11 — Understand EC output fields

| Field | Meaning |
|---|---|
| `violations` | Rules that FAILED — block release |
| `warnings` | Rules that passed with advisory concerns |
| `successes` | Rules that passed cleanly |
| `result: SUCCESS` | Image passed all enforced rules |
| `result: FAILURE` | Image failed one or more enforced rules |

Or run the full script — it auto-detects IMAGE and DIGEST from the latest PipelineRun and falls back to interactive prompts if they cannot be read:

```bash
bash commands.sh
```

## What to Expect

- `ec validate image` against a Konflux-built image returns a JSON or text report with `result: SUCCESS` when:
  - The cosign signature is valid against the cluster public key
  - A SLSA provenance attestation is present and properly signed
  - Any enabled policy rules pass
- Running the same command against `docker.io/library/alpine:latest` returns `result: FAILURE` with a violation indicating "No attestations found".
- The release pipeline in `08-release-planning/release/release-pipeline.yaml` runs `ec validate image` as Task 2 against `enterprise-contract-service/default` using the `quay.io/conforma/cli` image directly. The `TEST_OUTPUT` result (`SUCCESS`, `WARNING`, or `FAILURE`) is written to the PipelineRun results and visible in the task logs. With `STRICT=false` (the default) the pipeline continues past violations rather than blocking the release.

## Troubleshooting

**`ec validate image` fails with "no valid signatures found"**
Tekton Chains may not have finished signing. Wait 1–2 minutes after the PipelineRun completed and retry. Check Chains logs:
```bash
oc logs -n openshift-pipelines -l app=tekton-chains-controller --tail=50
```

**`signing-secrets` not found in `openshift-pipelines`**
On some OCP versions the secret may be named differently or Chains may not have created it yet:
```bash
oc get secrets -n openshift-pipelines | grep -i sign
```

**`ec` CLI fails to download policy from GitHub**
You may be behind a proxy or firewall. Use the `k8s://` policy reference (pointing to the cluster CR) instead of the `github.com/enterprise-contract/ec-policies//...` URL.

## Next Step

`10-multi-arch-builds/` — Build manifest-list images for multiple CPU architectures in parallel.
