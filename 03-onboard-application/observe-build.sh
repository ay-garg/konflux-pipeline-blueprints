#!/bin/bash
# ── Phase 3: Observe the first component build ─────────────────────────────────
# Verifies the Component CR was accepted by Build Service, waits for the Repository
# CR, watches the PR pipeline, then extracts the final image URL and digest.

NS="default-tenant"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Build Observation — First Component Build            ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Derive GitHub username and repo name from the Component's git URL ──────────
# This avoids hardcoding YOUR-USERNAME throughout the script.
COMP_GIT_URL=$(oc get component testrepo -n "$NS" \
  -o jsonpath='{.spec.source.git.url}' 2>/dev/null)
if [ -n "$COMP_GIT_URL" ]; then
  # Strip protocol + host, then remove optional .git suffix — pure bash, cross-platform
  _path="${COMP_GIT_URL#https://github.com/}"
  _path="${_path%.git}"
  GITHUB_USERNAME="${_path%%/*}"
  GITHUB_REPO="${_path#*/}"
  echo "  Detected GitHub repo : https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}"
else
  GITHUB_USERNAME="YOUR-USERNAME"
  GITHUB_REPO="testrepo"
  echo "  ⚠  Could not read Component git URL — using placeholder values."
fi

# ── Step 1: Verify the Component was accepted by the Build Service ─────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Verify Component annotation (Build Service status)"
echo "──────────────────────────────────────────────────────────────"
# The Build Service records its reconciliation result in the annotation
# build.appstudio.openshift.io/status (not in status.conditions).
# A successful reconciliation shows: {"pac":{"state":"enabled",...}}
echo "  Fetching build.appstudio.openshift.io/status annotation from Component 'testrepo'..."
ANNOTATION=$(oc get component testrepo -n "$NS" \
  -o jsonpath='{.metadata.annotations.build\.appstudio\.openshift\.io/status}' \
  2>/dev/null)
if [ -n "$ANNOTATION" ]; then
  echo "$ANNOTATION" | python3 -m json.tool
else
  echo "  –  Annotation not yet set — Build Service may still be reconciling."
  echo "     Wait a few seconds and re-check with:"
  echo "     oc get component testrepo -n $NS -o jsonpath='{.metadata.annotations.build\\.appstudio\\.openshift\\.io/status}'"
fi

# ── Step 2: Wait for the Repository CR ────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Verify the Repository CR was auto-created"
echo "──────────────────────────────────────────────────────────────"
# The Build Service creates the pipelinesascode.tekton.dev/v1alpha1 Repository
# object automatically — you do NOT need to create it manually.
echo "  Listing Repository CRs in namespace '$NS'..."
oc get repository -n "$NS"

# The NAME column from the command above is what you pass to describe.
# It typically matches the Component name but use the exact value shown.
REPO_NAME=$(oc get repository -n "$NS" -o jsonpath='{.items[0].metadata.name}')
echo "  Repository name: $REPO_NAME"
oc describe repository "$REPO_NAME" -n "$NS"

# ── Step 3: Find the auto-generated PR in your GitHub fork ────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 3: Wait for auto-generated PR — check GitHub"
echo "──────────────────────────────────────────────────────────────"
# Shortly after the Component CR was applied, the Build Service (via PaC)
# opened a PR on your fork adding a .tekton/ directory with two pipeline files:
#   .tekton/testrepo-pull-request.yaml  → runs on every PR opened/updated
#   .tekton/testrepo-push.yaml          → runs on every merge to main
#
# Go to your fork on GitHub and look for this open PR.
# It will be titled something like: "Add Konflux CI pipelines"
# URL: https://github.com/YOUR-USERNAME/testrepo/pulls
#
# IMPORTANT: Make sure the PR base is set to YOUR fork's main branch,
# not the upstream konflux-ci/testrepo. GitHub sometimes defaults to the
# upstream — change it before merging.
echo "  The Build Service (via PaC) has opened a PR on your fork adding .tekton/ pipelines."
echo ""
echo "  Go to:  https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}/pulls"
echo "  Title:  'Add Konflux CI pipelines'"
echo ""
echo "  IMPORTANT: confirm the PR base branch is YOUR fork's main, not upstream."

# ── Step 4: Watch PipelineRun appear ──────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 4: Watch PipelineRun (pull-request pipeline)"
echo "──────────────────────────────────────────────────────────────"
# ── Step 4: Wait for the pull-request PipelineRun to complete ──
# Opening the auto-generated PR is itself a pull_request event. PaC
# immediately triggers the pull-request pipeline (.tekton/testrepo-pull-request.yaml)
# against the PR branch. This is a lighter build (no image push, no signing)
# that verifies the component builds successfully before the PR is merged.
#
# Watch for the pull-request PipelineRun to appear (may take 10-30 seconds
# after the PR is opened on GitHub):
echo "  Watching for PipelineRuns (look for one containing 'pull-request' or 'on-pull-request')..."
oc get pipelinerun -n "$NS" -w
# Look for a PipelineRun whose name contains "pull-request" or "on-pull-request"

echo ""
echo "  Following pipeline logs..."
# Follow its logs:
tkn pipelinerun logs --last -f -n "$NS"

# Wait until the PipelineRun shows Succeeded before proceeding:
echo ""
echo "  PipelineRun status (STATUS must be 'Succeeded' before merging the PR):"
oc get pipelinerun -n "$NS" \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[0].reason,STARTED:.metadata.creationTimestamp"
# STATUS must be "Succeeded" — do NOT merge the PR until all tasks pass

# The GitHub PR will also show a green check from PaC once the pipeline passes.
# Only proceed to Step 5 when you see the check mark on the PR.

# ── Step 5: Merge PR, watch push pipeline, extract image results ───────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 5: Merge PR — push pipeline — extract image results"
echo "──────────────────────────────────────────────────────────────"
# ── Step 5: Approve and merge the PR ───────────────────────────
# Once the pull-request PipelineRun has Succeeded and the GitHub check is green,
# review the generated .tekton/ pipeline files, then merge the PR.
#
# Go to: https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}/pulls
#   → Open the auto-generated PR
#   → Confirm all checks pass (green ✓ from PaC)
#   → Click "Merge pull request" → "Confirm merge"
#
# DO NOT merge if the pull-request PipelineRun is still running or has failed —
# the pipeline files may have an issue that needs to be resolved first.
echo "  After the pull-request pipeline shows Succeeded, merge the PR on GitHub."
echo "  DO NOT merge if the PipelineRun is still running or has failed."

# ── Step 6: After merging the PR — the push pipeline triggers ──
# Merging the PR is a push event to main. PaC delivers the webhook to the
# cluster and creates a NEW PipelineRun for the push pipeline automatically.
# This is the FULL build pipeline (clone → build → scan → sign → push image).
# Watch for it to appear (may take 10-30 seconds after the merge):
echo ""
echo "  Watching for push PipelineRun (look for one containing 'push' or 'on-push')..."
oc get pipelinerun -n "$NS" -w
# Look for a second PipelineRun whose name contains "push" or "on-push"

# ── Step 7: Follow the push build logs ─────────────────────────
echo ""
echo "  Following push pipeline logs..."
tkn pipelinerun logs --last -f -n "$NS"

# ── Step 8: Verify the build results ───────────────────────────
# After the push pipeline succeeds the Integration Service creates a Snapshot
echo ""
echo "  Checking Snapshots created by Integration Service..."
oc get snapshot -n "$NS"

# Extract the built image URL and digest from the PipelineRun results
PR_NAME=$(oc get pipelinerun -n "$NS" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

IMAGE_URL=$(oc get pipelinerun "$PR_NAME" -n "$NS" \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
IMAGE_DIGEST=$(oc get pipelinerun "$PR_NAME" -n "$NS" \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

echo ""
echo "  ──────────────────────────────────────────────────────────"
echo "  Built image reference:"
echo "    IMAGE_URL:    $IMAGE_URL"
echo "    IMAGE_DIGEST: $IMAGE_DIGEST"
echo "    Full ref:     ${IMAGE_URL}@${IMAGE_DIGEST}"
echo "  ──────────────────────────────────────────────────────────"
echo ""

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 04-build-pipeline-internals/inspect-pipeline.sh"
echo "        Inspect build artifacts, verify image signature, and download the SBOM."
echo ""
