#!/bin/bash
# ── 10-multi-arch-builds: Setup script ───────────────────────────────────────
# Replaces the single-arch push pipeline with the multi-platform bundle,
# replaces placeholders, and commits to your testrepo fork.
#
# Prerequisites:
#   - Completed 08-release-planning/ (release pipeline is in your fork)
#   - Multi-Platform Controller installed on your cluster (not available on CRC)
#   - Local testrepo fork clone
#
# Usage: bash setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  10 — Multi-Architecture Build Setup"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "This script replaces .tekton/testrepo-push.yaml in your testrepo"
echo "fork with the multi-platform pipeline. Both files share the same"
echo "CEL trigger — the old file MUST be removed to avoid duplicate runs."
echo ""

# ── CRC warning ───────────────────────────────────────────────────────────────
echo "⚠  IMPORTANT: This pipeline requires the Multi-Platform Controller."
echo "   On CRC (OpenShift Local) the controller is not installed and build"
echo "   pods will hang indefinitely. Use 05-bundle-pipeline/ for CRC."
echo ""
read -rp "Is the Multi-Platform Controller installed on your cluster? [y/N]: " HAS_MPC
if [[ ! "$HAS_MPC" =~ ^[Yy]$ ]]; then
  echo ""
  echo "Multi-Platform Controller is not available. Options:"
  echo "  1. Use 05-bundle-pipeline/ for single-arch builds on CRC"
  echo "  2. Use hosted Konflux (console.redhat.com/application-pipeline)"
  echo "  3. Install the controller — see README.md for the architecture doc"
  echo ""
  read -rp "Continue anyway? [y/N]: " CONTINUE_ANYWAY
  if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
    echo "Exiting."
    exit 0
  fi
fi

echo ""

# ── Collect required values ───────────────────────────────────────────────────
read -rp "GitHub username (owner of your testrepo fork): " GITHUB_USERNAME
while [ -z "$GITHUB_USERNAME" ]; do
  echo "  GitHub username cannot be empty."
  read -rp "GitHub username: " GITHUB_USERNAME
done

read -rp "Quay.io org or username (where the image is pushed): " QUAY_ORG
while [ -z "$QUAY_ORG" ]; do
  echo "  Quay.io org cannot be empty."
  read -rp "Quay.io org or username: " QUAY_ORG
done

read -rp "Absolute path to your local testrepo fork clone: " REPO_PATH
while [ ! -d "$REPO_PATH/.git" ]; do
  echo "  Directory not found or is not a git repository: $REPO_PATH"
  read -rp "Absolute path: " REPO_PATH
done

# ── Verify release pipeline is present ───────────────────────────────────────
echo ""
if [ ! -f "$REPO_PATH/release/release-pipeline.yaml" ]; then
  echo "WARNING: release/release-pipeline.yaml not found in your fork."
  echo "  The release pipeline is committed in 08-release-planning/."
  echo "  Without it, the auto-release step will fail when triggered."
  echo ""
  read -rp "  Continue anyway? [y/N]: " SKIP_RELEASE_CHECK
  if [[ ! "$SKIP_RELEASE_CHECK" =~ ^[Yy]$ ]]; then
    echo "  Complete 08-release-planning/ first, then re-run this script."
    exit 1
  fi
else
  echo "✓ release/release-pipeline.yaml found."
fi

# ── Copy and configure the multi-arch pipeline ────────────────────────────────
echo ""
echo "── Installing multiarch-push.yaml ───────────────────────────────────────"

TEKTON_DIR="$REPO_PATH/.tekton"
mkdir -p "$TEKTON_DIR"

DST="$TEKTON_DIR/multiarch-push.yaml"
cp "$SCRIPT_DIR/.tekton/multiarch-push.yaml" "$DST"

perl -pi -e "s/YOUR-USERNAME/$GITHUB_USERNAME/g" "$DST"
perl -pi -e "s/YOUR-ORG/$QUAY_ORG/g" "$DST"

echo "  ✓ multiarch-push.yaml written to $DST"

# ── Remove the single-arch push pipeline ─────────────────────────────────────
echo ""
echo "── Removing single-arch push pipeline ───────────────────────────────────"
echo "  Both files use the same CEL expression (event == push && target_branch == main)."
echo "  Keeping the old file would trigger two PipelineRuns on every push."
echo ""

OLD_PUSH="$TEKTON_DIR/testrepo-push.yaml"
if [ -f "$OLD_PUSH" ]; then
  read -rp "  Remove $OLD_PUSH? [Y/n]: " REMOVE_OLD
  REMOVE_OLD="${REMOVE_OLD:-y}"
  if [[ "$REMOVE_OLD" =~ ^[Yy]$ ]]; then
    cd "$REPO_PATH"
    git rm --cached ".tekton/testrepo-push.yaml" 2>/dev/null || true
    rm -f "$OLD_PUSH"
    echo "  ✓ testrepo-push.yaml removed."
  fi
else
  echo "  testrepo-push.yaml not found — nothing to remove."
fi

# ── Commit and push ───────────────────────────────────────────────────────────
echo ""
echo "── Committing and pushing ───────────────────────────────────────────────"
read -rp "Commit and push now? [Y/n]: " DO_PUSH
DO_PUSH="${DO_PUSH:-y}"

if [[ "$DO_PUSH" =~ ^[Yy]$ ]]; then
  cd "$REPO_PATH"
  git add .tekton/multiarch-push.yaml
  git commit -m "feat: replace single-arch pipeline with multi-arch (amd64, arm64, s390x)"
  git push origin main
  echo ""
  echo "  Pushed. PaC will trigger testrepo-multiarch-on-push."
  echo ""
  echo "  Watch three build-images TaskRuns appear simultaneously:"
  echo "    oc get taskruns -n default-tenant -w | grep build-images"
else
  echo ""
  echo "  Skipped push. Commit manually:"
  echo "    cd $REPO_PATH"
  echo "    git add .tekton/multiarch-push.yaml"
  echo "    git commit -m 'feat: multi-arch pipeline'"
  echo "    git push origin main"
fi

echo ""
echo "── Next steps ───────────────────────────────────────────────────────────"
echo ""
echo "  1. Wait for the PipelineRun to complete"
echo "  2. Run: bash verify-manifest.sh"
echo "     (auto-detects IMAGE_URL and IMAGE_DIGEST from the latest PipelineRun)"
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Done."
echo "══════════════════════════════════════════════════════════════"
