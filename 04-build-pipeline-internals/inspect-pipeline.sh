#!/bin/bash
# ── Phase 4: Inspect the build pipeline results ────────────────────────────────
# Extracts build results, verifies the cosign image signature and SLSA provenance
# attestation from Tekton Chains, and downloads the SBOM attached to the image.

# Set NAMESPACE to your tenant namespace.
# Options (in order of precedence):
#   1. Export it before running:  export NAMESPACE="your-actual-namespace"
#   2. Replace "default-tenant" below with your namespace name
#   3. Leave as-is — the script will use "default-tenant"
NAMESPACE="${NAMESPACE:-default-tenant}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Build Pipeline Inspection                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Get the last PipelineRun name ─────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Get last PipelineRun name"
echo "──────────────────────────────────────────────────────────────"
echo "  Watching build pipeline tasks in real time (Ctrl+C when done)..."
# ── Watch build pipeline tasks in real time ────────────────────
tkn pipelinerun logs --last -f -n $NAMESPACE

echo ""
echo "  Describing last PipelineRun (all task results)..."
# ── Describe the PipelineRun — see all task results ────────────
tkn pipelinerun describe --last -n $NAMESPACE

echo ""
echo "  Fetching last PipelineRun name..."
# ── Extract the IMAGE_DIGEST result from the PipelineRun ───────
PR_NAME=$(oc get pipelinerun -n $NAMESPACE \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "  ✔  Last PipelineRun: $PR_NAME"

# ── Step 2: Extract IMAGE_URL and IMAGE_DIGEST ────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Extract IMAGE_URL and IMAGE_DIGEST"
echo "──────────────────────────────────────────────────────────────"
IMAGE_URL=$(oc get pipelinerun $PR_NAME -n $NAMESPACE \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')

IMAGE_DIGEST=$(oc get pipelinerun $PR_NAME -n $NAMESPACE \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

echo ""
echo "  ──────────────────────────────────────────────────────────"
echo "  IMAGE_URL:    $IMAGE_URL"
echo "  IMAGE_DIGEST: $IMAGE_DIGEST"
echo "  ──────────────────────────────────────────────────────────"
echo ""

# ── Step 3: Extract cosign public key ─────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 3: Extract cosign public key from Tekton Chains"
echo "──────────────────────────────────────────────────────────────"
# ── Verify the image signature from Tekton Chains ───────────────
# You need the public key from the Chains signing secret
echo "  Extracting cosign.pub from signing-secrets in openshift-pipelines..."
oc get secret signing-secrets -n openshift-pipelines \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign.pub
echo "  ✔  Key saved to /tmp/cosign.pub"

# WHY --insecure-ignore-tlog IS REQUIRED HERE:
#
# Tekton Chains signs images using the cluster's own keypair stored in
# signing-secrets. On a self-hosted Konflux installation the signatures are
# recorded in the cluster's internal Rekor instance (or no transparency log
# at all), NOT in the public Sigstore Rekor at rekor.sigstore.dev.
#
# By default cosign verify tries to look up the signature in rekor.sigstore.dev
# to confirm the transparency log entry — this will always fail for cluster-
# signed images because no entry was ever written there.
#
# --insecure-ignore-tlog tells cosign to verify only the cryptographic
# signature against the public key and skip the Rekor lookup entirely.
# This is the correct approach for self-hosted Konflux; the "insecure" label
# is a cosign convention meaning "no transparency log required", not that
# the signature itself is weaker.
#
# Additional note: if you are behind a corporate or ISP proxy (e.g. Airtel)
# that performs TLS inspection, the Rekor request would also fail with an
# x509 certificate error even if the endpoint were correct. The flag bypasses
# that network issue as well.

# ── Pre-flight: verify ~/.docker/config.json exists ──────────────────────────
# Steps 4, 5, and 6 use cosign to pull image metadata (signature, attestation,
# SBOM) from the OCI registry. cosign reads registry credentials from
# ~/.docker/config.json — the same file written by `docker login` or
# `podman login`. If this file is missing or does not contain credentials for
# the registry where the image was pushed, cosign will fail with an auth error.
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Pre-flight: checking ~/.docker/config.json"
echo "──────────────────────────────────────────────────────────────"
DOCKER_CONFIG_FILE="${HOME}/.docker/config.json"
if [ ! -f "$DOCKER_CONFIG_FILE" ]; then
  echo ""
  echo "  ✘  ~/.docker/config.json not found."
  echo ""
  echo "  Steps 4 (cosign verify), 5 (cosign verify-attestation), and"
  echo "  6 (SBOM download) all require registry credentials to pull"
  echo "  image manifests and attached OCI artifacts from the registry."
  echo ""
  echo "  To resolve, log in to the registry where your image was pushed:"
  echo ""
  echo "    For Quay.io:"
  echo "      docker login quay.io"
  echo "      # or:"
  echo "      podman login quay.io"
  echo ""
  echo "    For Docker Hub:"
  echo "      docker login"
  echo ""
  echo "  Both commands write credentials to ~/.docker/config.json."
  echo "  After logging in, re-run this script."
  echo ""
  exit 1
fi
echo "  ✔  ~/.docker/config.json found — registry credentials available"

# ── Step 4: cosign verify ─────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 4: Verify image signature (cosign verify)"
echo "──────────────────────────────────────────────────────────────"
echo "  Running cosign verify against ${IMAGE_URL}@${IMAGE_DIGEST} ..."
if cosign verify \
  --key /tmp/cosign.pub \
  --insecure-ignore-tlog \
  "${IMAGE_URL}@${IMAGE_DIGEST}"; then
  echo "  ✔  Image signature verified"
else
  echo "  ✘  Image signature verification failed"
fi

# ── Step 5: cosign verify-attestation ─────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 5: Verify SLSA provenance attestation"
echo "──────────────────────────────────────────────────────────────"
# ── Verify the SLSA provenance attestation ─────────────────────
# Same reasoning applies: the attestation was recorded by Tekton Chains
# against the cluster's internal Rekor, not the public one. --insecure-ignore-tlog
# skips the transparency log lookup and verifies the attestation signature only.
echo "  Running cosign verify-attestation (SLSA provenance) ..."
if cosign verify-attestation \
  --key /tmp/cosign.pub \
  --insecure-ignore-tlog \
  --type slsaprovenance \
  "${IMAGE_URL}@${IMAGE_DIGEST}" | jq '.payload | @base64d | fromjson'; then
  echo "  ✔  SLSA attestation verified"
else
  echo "  ✘  SLSA attestation verification failed"
fi

# ── Step 6: SBOM download section ─────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 6: Download and inspect SBOM"
echo "──────────────────────────────────────────────────────────────"
# ── Inspect the SBOM attached to the image ─────────────────────
# Install cosign if needed
brew install cosign   # macOS
# go install github.com/sigstore/cosign/v2/cmd/cosign@latest

# NOTE: cosign uses ~/.docker/config.json to authenticate to the registry when
# pulling the image manifest and attached artifacts (SBOM, attestations).
# Ensure this file exists with valid credentials for the registry where the image
# was pushed. If missing or stale, cosign will fail with an auth error.
#   docker login quay.io          # for quay.io
#   podman login quay.io          # alternative; writes to the same config path
# The file must contain an entry for the registry host used in $IMAGE_URL.

# ── Download the SBOM generated by the Konflux build pipeline ─────────────────
#
# Konflux always uploads the SBOM via `cosign attach sbom` (the upload-sbom
# pipeline step). This is the deprecated API in cosign 2.x but is still fully
# functional — use Option A below, which works with all Konflux installations.
#
# Additionally, when keyless signing (Fulcio + Rekor) is configured on the
# cluster, the pipeline also stores the SBOM as a proper cosign attestation via
# `cosign attest --type spdxjson`. Use Option B to retrieve it in that case.
# You can tell keyless signing is active if you see Rekor/Fulcio URLs in the
# cluster-config ConfigMap: oc get cm cluster-config -n konflux-info -o yaml
#
echo "  Option A — cosign attach sbom path (works on all Konflux clusters):"
# Option A — cosign attach sbom path (works on all Konflux clusters):
cosign download sbom "${IMAGE_URL}@${IMAGE_DIGEST}" | python3 -m json.tool | head -60

echo ""
echo "  Option B — cosign attest path (only when keyless signing is enabled):"
# Option B — cosign attest path (only when keyless signing is enabled):
# predicateType will be https://spdx.dev/Document (spdxjson) or a CycloneDX URL.
cosign download attestation "${IMAGE_URL}@${IMAGE_DIGEST}" \
  | jq -r 'select(.payload != null) | .payload | @base64d | fromjson
            | select(
                .predicateType == "https://spdx.dev/Document" or
                (.predicateType | startswith("https://cyclonedx.org") or startswith("https://spdx.dev"))
              ) | .predicate' \
  | head -60

# ── Debugging a failed task ────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Debugging a failed task"
echo "──────────────────────────────────────────────────────────────"
# ── Debugging a failed task ────────────────────────────────────
# Find which TaskRun failed
echo "  Listing TaskRuns for PipelineRun '$PR_NAME' sorted by completion time..."
oc get taskruns -n $NAMESPACE \
  --selector=tekton.dev/pipelineRun=$PR_NAME \
  '--sort-by=.status.conditions[-1].lastTransitionTime'

# Get logs of the specific failed TaskRun
echo ""
echo "  Identifying failed TaskRun..."
FAILED_TR=$(oc get taskruns -n $NAMESPACE \
  --selector=tekton.dev/pipelineRun=$PR_NAME \
  -o jsonpath='{.items[?(@.status.conditions[0].reason=="Failed")].metadata.name}')

echo "  Fetching logs for failed TaskRun: $FAILED_TR ..."
tkn taskrun logs $FAILED_TR -n $NAMESPACE

# If the TaskRun pod is stuck in Pending:
echo ""
echo "  Describing pod for stuck TaskRun (if stuck in Pending)..."
oc describe pod -n $NAMESPACE \
  --selector=tekton.dev/taskRun=$FAILED_TR

# Check Tekton Chains controller logs (if signing failed)
# On OCP, Tekton Chains runs inside openshift-pipelines (not a separate tekton-chains namespace)
echo ""
echo "  Tekton Chains controller logs (useful if signing failed)..."
oc logs -n openshift-pipelines \
  -l app=tekton-chains-controller --tail=50

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 05-pipeline-as-code/commands.sh"
echo "        Customize and inspect Pipeline as Code configuration."
echo ""
