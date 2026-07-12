#!/bin/bash
# ── 10-multi-arch-builds: Verify OCI Image Index ─────────────────────────────
# Confirms the built testrepo image is a proper multi-arch manifest list.
# Run this after the testrepo-multiarch-on-push PipelineRun completes.
#
# Usage (arguments):
#   bash verify-manifest.sh quay.io/YOUR-ORG/testrepo sha256:abc123...
#
# Usage (auto-detect from latest PipelineRun):
#   bash verify-manifest.sh
#
# Requirements: skopeo, python3, oc (only if arguments are not provided)

set -e

IMAGE="${1:-}"
DIGEST="${2:-}"
NS="${NAMESPACE:-default-tenant}"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  10 — Multi-Arch Manifest Verification"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── Resolve IMAGE and DIGEST if not provided ──────────────────────────────────
if [ -z "$IMAGE" ] || [ -z "$DIGEST" ]; then
  echo "No arguments provided. Looking up the latest PipelineRun in: $NS"
  echo ""

  if ! command -v oc &>/dev/null; then
    echo "ERROR: 'oc' not found. Pass IMAGE and DIGEST as arguments:"
    echo "  bash verify-manifest.sh quay.io/YOUR-ORG/testrepo sha256:..."
    exit 1
  fi

  PR=$(oc get pipelinerun -n "$NS" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

  if [ -z "$PR" ]; then
    echo "ERROR: No PipelineRun found in namespace $NS."
    echo "  Run: oc get pipelinerun -n $NS"
    exit 1
  fi

  echo "Latest PipelineRun: $PR"

  IMAGE=$(oc get pipelinerun "$PR" -n "$NS" \
    -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}' 2>/dev/null || true)
  DIGEST=$(oc get pipelinerun "$PR" -n "$NS" \
    -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}' 2>/dev/null || true)

  if [ -z "$IMAGE" ] || [ -z "$DIGEST" ]; then
    echo ""
    echo "ERROR: IMAGE_URL or IMAGE_DIGEST results not found on PipelineRun $PR."
    echo "  The run may still be in progress or may have failed."
    echo "  Run: oc describe pipelinerun $PR -n $NS"
    exit 1
  fi
fi

echo ""
echo "Image : $IMAGE"
echo "Digest: $DIGEST"
echo ""

# ── Section 1: Raw OCI manifest ───────────────────────────────────────────────
echo "── 1. Raw OCI Image Index manifest ─────────────────────────────────────"
echo "   mediaType must be: application/vnd.oci.image.index.v1+json"
echo ""
skopeo inspect --raw "docker://${IMAGE}@${DIGEST}" | python3 -m json.tool
echo ""

# ── Section 2: Platform list ──────────────────────────────────────────────────
echo "── 2. Platforms in the manifest list ───────────────────────────────────"
echo ""
skopeo inspect --raw "docker://${IMAGE}@${DIGEST}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
media = data.get('mediaType', 'unknown')
print(f'mediaType : {media}')
manifests = data.get('manifests', [])
print(f'platforms : {len(manifests)} found')
print()
for m in manifests:
    p = m.get('platform', {})
    arch = p.get('architecture', '?')
    variant = p.get('variant', '')
    os_ = p.get('os', '?')
    digest = m.get('digest', '?')
    label = f'{os_}/{arch}'
    if variant:
        label += f'/{variant}'
    print(f'  {label:<20} {digest[:48]}...')

if media != 'application/vnd.oci.image.index.v1+json':
    print()
    print('WARNING: mediaType is not an OCI Image Index.')
    print('         The multi-platform build may not have completed correctly.')
"
echo ""

# ── Section 3: Full inspect (resolves to host arch) ───────────────────────────
echo "── 3. Full skopeo inspect (resolves to current host architecture) ───────"
echo ""
skopeo inspect "docker://${IMAGE}@${DIGEST}" | python3 -m json.tool

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Verification complete."
echo "  If all 3 platforms are listed and mediaType is"
echo "  application/vnd.oci.image.index.v1+json — success."
echo "══════════════════════════════════════════════════════════════"
