#!/bin/bash
# ── 05-bundle-pipeline: Setup script ─────────────────────────────────────────
# Copies the bundle-based pipeline files into your testrepo fork's .tekton/
# directory, replaces placeholders, and pushes to trigger the first bundle run.
#
# Prerequisites:
#   - Your testrepo fork is cloned locally
#   - You have completed 04-build-pipeline-internals/
#   - Your quay.io credentials (regcred) are configured
#
# Usage: bash setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  05 — Bundle-Based Pipeline Setup"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "This script copies testrepo-push.yaml and testrepo-pull-request.yaml"
echo "into your testrepo fork, replacing the auto-generated inline pipeline."
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
  read -rp "Absolute path to your local testrepo fork clone: " REPO_PATH
done

echo ""
read -rp "Running on CRC arm64 (Silicon Mac)? Scan images are amd64-only there. [y/N]: " ON_CRC
ON_CRC="${ON_CRC:-n}"

# ── Determine skip-checks value ───────────────────────────────────────────────
if [[ "$ON_CRC" =~ ^[Yy]$ ]]; then
  SKIP_CHECKS="true"
  echo "  skip-checks will be set to 'true' (CRC arm64 mode)."
else
  SKIP_CHECKS="false"
  echo "  skip-checks will be set to 'false' (all checks enabled)."
fi

# ── Prepare destination ───────────────────────────────────────────────────────
TEKTON_DIR="$REPO_PATH/.tekton"
mkdir -p "$TEKTON_DIR"

echo ""
echo "── Copying pipeline files ───────────────────────────────────────────────"

for YAML_FILE in testrepo-push.yaml testrepo-pull-request.yaml; do
  SRC="$SCRIPT_DIR/.tekton/$YAML_FILE"
  DST="$TEKTON_DIR/$YAML_FILE"

  cp "$SRC" "$DST"

  # Replace placeholders (cross-platform: perl works on macOS and Linux)
  perl -pi -e "s/YOUR-USERNAME/$GITHUB_USERNAME/g" "$DST"
  perl -pi -e "s/YOUR-ORG/$QUAY_ORG/g" "$DST"

  # Set skip-checks value
  perl -pi -e "s/value: \"true\"  # skip-checks placeholder/value: \"$SKIP_CHECKS\"/g" "$DST"
  # Handle the literal "true" already in the file
  if [ "$SKIP_CHECKS" = "false" ]; then
    perl -pi -e 's/(- name: skip-checks\n\s+value: )"true"/$1"false"/' "$DST" 2>/dev/null || true
    # Simpler approach: replace the skip-checks value line
    perl -0pi -e 's/(- name: skip-checks\s*\n\s+value: )"true"/$1"false"/g' "$DST"
  fi

  echo "  ✓ $YAML_FILE → $DST"
done

# ── Remove the old auto-generated inline pipeline if present ──────────────────
echo ""
echo "── Checking for conflicting pipeline files ──────────────────────────────"
echo "  Both files use the same CEL trigger (event == push/pull_request &&"
echo "  target_branch == main). Keeping the old auto-generated file alongside"
echo "  these would fire two PipelineRuns on every event."
echo ""

# The auto-generated files typically use the same names; already replaced above.
# Check for any other push/PR yamls that might conflict.
CONFLICTS=$(find "$TEKTON_DIR" -name "*.yaml" ! -name "testrepo-push.yaml" ! -name "testrepo-pull-request.yaml" 2>/dev/null || true)
if [ -n "$CONFLICTS" ]; then
  echo "  Found other .tekton YAML files. Review these for CEL conflicts:"
  echo "$CONFLICTS" | while read -r f; do echo "    $f"; done
  echo ""
  read -rp "  Remove them? [y/N]: " REMOVE_EXTRA
  if [[ "$REMOVE_EXTRA" =~ ^[Yy]$ ]]; then
    echo "$CONFLICTS" | while read -r f; do
      rm -f "$f"
      echo "  Removed: $f"
    done
  fi
fi

# ── Commit and push ───────────────────────────────────────────────────────────
echo ""
echo "── Committing and pushing ───────────────────────────────────────────────"
read -rp "Commit and push now? [Y/n]: " DO_PUSH
DO_PUSH="${DO_PUSH:-y}"

if [[ "$DO_PUSH" =~ ^[Yy]$ ]]; then
  cd "$REPO_PATH"
  git add .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
  git commit -m "chore: switch to bundle-based pipeline (pipeline-docker-build-oci-ta)"
  git push origin main
  echo ""
  echo "  Pushed. PaC will detect the change and trigger testrepo-on-push."
  echo "  Watch progress:"
  echo ""
  echo "    oc get pipelinerun -n default-tenant -w"
  echo "    tkn pipelinerun logs --last -f -n default-tenant"
else
  echo ""
  echo "  Skipped push. Commit manually when ready:"
  echo "    cd $REPO_PATH"
  echo "    git add .tekton/"
  echo "    git commit -m 'chore: switch to bundle-based pipeline'"
  echo "    git push origin main"
fi

echo ""
echo "── Verify the PipelineRun ───────────────────────────────────────────────"
echo ""
echo "  After the push, run:"
echo ""
echo "    oc get pipelinerun -n default-tenant --sort-by=.metadata.creationTimestamp"
echo ""
echo "  Confirm the pipeline was resolved from the bundle:"
echo "    PR=\$(oc get pipelinerun -n default-tenant \\
  --sort-by=.metadata.creationTimestamp \\
  -o jsonpath='{.items[-1].metadata.name}')"
echo "    oc describe pipelinerun \$PR -n default-tenant | grep -A5 'Pipeline Ref'"
echo ""
echo "  Check which tasks were skipped (when skip-checks=true):"
echo "    oc get pipelinerun \$PR -n default-tenant \\
  -o jsonpath='{.status.skippedTasks[*].name}' | tr ' ' '\\n'"
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Done."
echo "══════════════════════════════════════════════════════════════"
