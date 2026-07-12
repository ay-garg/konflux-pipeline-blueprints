#!/bin/bash
# ── 09-enterprise-contract-slsa: Verification commands ───────────────────────
# Validates built images against Enterprise Contract policies and verifies
# cosign signatures and SLSA provenance attestations from Tekton Chains.
#
# Prerequisites:
#   - cosign v2.x installed
#   - jq installed
#   - oc logged in
#   - At least one successful build PipelineRun in default-tenant
#
# Usage: bash commands.sh

set -e

NS="${NAMESPACE:-default-tenant}"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  09 — Enterprise Contract & SLSA Verification"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Install the ec CLI ────────────────────────────────────────────────
echo "── Step 1: Install the ec CLI (skip if already installed) ──────────────"
echo ""
if command -v ec &>/dev/null; then
  echo "  ec already installed: $(ec version 2>/dev/null | head -1)"
else
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  if [ "$OS" = "Darwin" ]; then
    case "$ARCH" in
      arm64)  EC_FILE="ec_darwin_arm64" ;;
      x86_64) EC_FILE="ec_darwin_amd64" ;;
      *)      EC_FILE="ec_darwin_amd64" ;;
    esac
  else
    case "$ARCH" in
      x86_64)  EC_FILE="ec_linux_amd64" ;;
      aarch64) EC_FILE="ec_linux_arm64" ;;
      *)       EC_FILE="ec_linux_amd64" ;;
    esac
  fi

  EC_URL="https://github.com/conforma/cli/releases/latest/download/${EC_FILE}"
  echo "  Downloading: $EC_URL"
  curl -sLO "$EC_URL"
  chmod 755 "$EC_FILE"
  sudo mv "$EC_FILE" /usr/local/bin/ec
  echo "  ✓ ec installed to /usr/local/bin/ec"
fi
ec version
echo ""

# ── Step 2: Resolve IMAGE and DIGEST from the latest release PipelineRun ──────
echo "── Step 2: Resolve image reference from latest release PipelineRun ──────"
echo ""
echo "  The latest PipelineRun is the release pipeline run (from 08-release-planning/)."
echo "  It does not expose IMAGE_URL/IMAGE_DIGEST as Tekton results — those belong to"
echo "  the build pipeline. Instead, grep the released image ref from the"
echo "  post-release-actions task log which prints 'Released image : <ref>'."
echo ""

PR=$(oc get pipelinerun -n "$NS" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

if [ -z "$PR" ]; then
  echo "  No PipelineRun found. Enter image details manually:"
  read -rp "  IMAGE (full ref, e.g. quay.io/yourorg/testrepo@sha256:...): " IMAGE_REF
  IMAGE="${IMAGE_REF%@*}"
  DIGEST="${IMAGE_REF#*@}"
else
  echo "  Latest PipelineRun: $PR"

  IMAGE_REF=$(tkn pipelinerun logs "$PR" -n "$NS" 2>/dev/null | \
    grep "Released image" | \
    awk '{print $NF}' | \
    tail -1 || true)

  if [ -z "$IMAGE_REF" ]; then
    echo ""
    echo "  Could not find 'Released image' in PipelineRun logs."
    echo "  The release run may still be in progress, or the post-release-actions"
    echo "  task may not have completed yet."
    echo ""
    read -rp "  Enter full image ref (quay.io/yourorg/testrepo@sha256:...): " IMAGE_REF
  fi

  IMAGE="${IMAGE_REF%@*}"
  DIGEST="${IMAGE_REF#*@}"
fi

echo ""
echo "  Image : $IMAGE"
echo "  Digest: $DIGEST"
echo ""

# ── Step 3: Extract cosign public key ─────────────────────────────────────────
echo "── Step 3: Extract cosign public key from Tekton Chains ─────────────────"
echo ""
echo "  On OCP, Tekton Chains stores the signing key in openshift-pipelines"
echo "  as the 'public-key' secret (NOT tekton-chains, the upstream default)."
echo ""

# Try public-key first (OCP/Konflux default), fall back to signing-secrets
if oc get secret public-key -n openshift-pipelines &>/dev/null; then
  oc get secret public-key -n openshift-pipelines \
    -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/chains-public-key.pub
  echo "  ✓ Key extracted from openshift-pipelines/public-key → /tmp/chains-public-key.pub"
elif oc get secret signing-secrets -n openshift-pipelines &>/dev/null; then
  oc get secret signing-secrets -n openshift-pipelines \
    -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/chains-public-key.pub
  echo "  ✓ Key extracted from openshift-pipelines/signing-secrets → /tmp/chains-public-key.pub"
else
  echo "  ERROR: Could not find public-key or signing-secrets in openshift-pipelines."
  echo "  Check with: oc get secrets -n openshift-pipelines | grep -E 'public|signing'"
  exit 1
fi

echo ""
cat /tmp/chains-public-key.pub
echo ""

# ── Step 4: List EC policies in the cluster ───────────────────────────────────
echo "── Step 4: List EnterpriseContractPolicy CRs ────────────────────────────"
echo ""
oc get enterprisecontractpolicy -A 2>/dev/null || \
  echo "  No EnterpriseContractPolicy CRs found (EC CRD may not be installed)."
echo ""

# ── Step 5: Export the EC policy to a local YAML file ─────────────────────────
echo "── Step 5: Export testrepo-ec-policy to local YAML ─────────────────────"
echo ""
echo "  Some ec CLI versions cannot parse k8s:// policy references. Exporting"
echo "  the policy CR to a file is the reliable approach."
echo ""

if oc get enterprisecontractpolicy testrepo-ec-policy -n "$NS" &>/dev/null; then
  oc get enterprisecontractpolicy testrepo-ec-policy -n "$NS" -o yaml \
    > /tmp/testrepo-ec-policy.yaml
  echo "  ✓ Policy exported to /tmp/testrepo-ec-policy.yaml"
else
  echo "  testrepo-ec-policy not found in $NS."
  echo "  Run 08-release-planning/prerequisites.sh Step 1 to create it."
  exit 1
fi
echo ""

# ── Step 6: ec validate image (text output) ───────────────────────────────────
echo "── Step 6: Validate image with Enterprise Contract (text) ───────────────"
echo ""
echo "  Running ec validate image against:"
echo "    ${IMAGE}@${DIGEST}"
echo ""
echo "  --ignore-rekor: required on self-hosted Konflux — images are signed by"
echo "  the cluster's internal Tekton Chains key, not recorded in public Rekor."
echo ""

ec validate image \
  --image "${IMAGE}@${DIGEST}" \
  --policy /tmp/testrepo-ec-policy.yaml \
  --public-key /tmp/chains-public-key.pub \
  --ignore-rekor \
  --output text 2>&1 || true

echo ""

# ── Step 7: ec validate image (full JSON + summary) ───────────────────────────
echo "── Step 7: Validate image — JSON output and result summary ──────────────"
echo ""

ec validate image \
  --image "${IMAGE}@${DIGEST}" \
  --policy /tmp/testrepo-ec-policy.yaml \
  --public-key /tmp/chains-public-key.pub \
  --ignore-rekor \
  --output json > /tmp/ec-result.json 2>&1 || true

echo "  Overall result:"
jq '{result: .components[0].success,
     violations: (.components[0].violations | length),
     warnings:   (.components[0].warnings   | length),
     successes:  (.components[0].successes  | length)}' \
  /tmp/ec-result.json 2>/dev/null || echo "  (no JSON result written)"

echo ""
echo "  Violations:"
jq -r '.components[0].violations[] | "  VIOLATION \(.metadata.code): \(.msg)"' \
  /tmp/ec-result.json 2>/dev/null || echo "  (none)"

echo ""
echo "  Warnings:"
jq -r '.components[0].warnings[] | "  WARNING \(.metadata.code): \(.msg)"' \
  /tmp/ec-result.json 2>/dev/null || echo "  (none)"

echo ""

# ── Step 8: cosign verify signature ───────────────────────────────────────────
echo "── Step 8: Verify image signature with cosign ───────────────────────────"
echo ""
echo "  Tekton Chains signs the image after the PipelineRun completes."
echo "  --insecure-ignore-tlog: skip public Rekor lookup (cluster-signed image)."
echo ""

# cosign writes status/progress to stderr and the JSON payload to stdout.
# Do NOT use 2>&1 here — mixing stderr into stdout corrupts the JSON stream
# and causes "Expecting value: line 1 column 1 (char 0)" from the JSON parser.
cosign verify \
  --key /tmp/chains-public-key.pub \
  --insecure-ignore-tlog \
  "${IMAGE}@${DIGEST}" | jq .

echo ""

# ── Step 9: cosign verify SLSA attestation ────────────────────────────────────
echo "── Step 9: Inspect the SLSA provenance attestation ─────────────────────"
echo ""
echo "  Tekton Chains generates an in-toto SLSA v0.2 attestation encoding every"
echo "  build input: git commit, task images, parameters. EC validates this."
echo ""

# Same rule: no 2>&1. cosign writes the base64-encoded in-toto envelope to
# stdout. jq decodes the payload field and extracts the key SLSA fields.
cosign verify-attestation \
  --key /tmp/chains-public-key.pub \
  --insecure-ignore-tlog \
  --type slsaprovenance \
  "${IMAGE}@${DIGEST}" \
  | jq -r '.payload | @base64d | fromjson | {
      predicateType,
      builder: .predicate.builder.id,
      buildType: .predicate.buildType,
      commit: .predicate.materials[0].digest.sha1,
      repo: .predicate.materials[0].uri,
      startedOn: .predicate.metadata.buildStartedOn,
      finishedOn: .predicate.metadata.buildFinishedOn
    }'

echo ""

# ── Step 10: Test a non-compliant image (expected: FAILURE) ───────────────────
echo "── Step 10: Test a non-compliant image (expected: FAILURE) ──────────────"
echo ""
echo "  docker.io/library/alpine:latest has no cosign signature and no SLSA"
echo "  attestation — EC always fails on this image."
echo ""

ec validate image \
  --image "docker.io/library/alpine:latest" \
  --policy /tmp/testrepo-ec-policy.yaml \
  --public-key /tmp/chains-public-key.pub \
  --ignore-rekor \
  --output text 2>&1 || echo "  (expected failure — alpine is not signed by Tekton Chains)"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Done. Next: 10-multi-arch-builds/"
echo "══════════════════════════════════════════════════════════════"
