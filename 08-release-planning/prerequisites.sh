#!/bin/bash
# ── 08-release-planning: Prerequisites and release watch ─────────────────────
# Applies the Enterprise Contract policy, ReleasePlan, and ReleasePlanAdmission
# to the cluster. Auto-release is enabled — once a push build completes and the
# Integration Service marks the Snapshot as passing, the Release Service creates
# a Release CR and triggers the release pipeline automatically.

# ── Configuration ─────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Release Planning Prerequisites — Configuration"
echo "══════════════════════════════════════════════════════════════"
echo ""
read -rp "  Tenant namespace [default-tenant]: " NS_INPUT
NAMESPACE="${NS_INPUT:-default-tenant}"
echo "  ✔  Using namespace: $NAMESPACE"

echo ""
echo "  GitHub username — used to replace YOUR-USERNAME in release-plan-admission.yaml."
echo "  This must be the owner of the testrepo fork referenced in the git resolver url."
echo ""
read -rp "  GitHub username (e.g. jsmith): " GITHUB_USERNAME
if [ -z "$GITHUB_USERNAME" ]; then
  echo "  ✘  GitHub username is required — the git resolver cannot fetch the release"
  echo "     pipeline without a valid repository URL."
  exit 1
fi
echo "  ✔  Using GitHub username: $GITHUB_USERNAME"

echo ""
echo "  Replacing YOUR-USERNAME with '$GITHUB_USERNAME' in release-plan-admission.yaml ..."
# Use perl for cross-platform compatibility (works on Linux and macOS)
perl -pi -e "s/YOUR-USERNAME/$GITHUB_USERNAME/g" release-plan-admission.yaml
echo "  ✔  Placeholder replaced"

echo ""
echo "  ── Configuration summary ─────────────────────────────────"
echo "  Namespace      : $NAMESPACE"
echo "  GitHub username: $GITHUB_USERNAME"
echo "  ──────────────────────────────────────────────────────────"
echo ""

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Release Planning Prerequisites & Commands            ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Create EnterpriseContractPolicy from the cluster default ──────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Create EnterpriseContractPolicy from cluster default"
echo "──────────────────────────────────────────────────────────────"
echo "  Copying enterprise-contract-service/default → $NAMESPACE/testrepo-ec-policy ..."
echo "  (strips server-managed fields and renames the object)"
echo ""

if ! command -v jq &>/dev/null; then
  echo "  ERROR: 'jq' is required for this step."
  echo "  Install: brew install jq  (macOS) | sudo apt install jq  (Linux)"
  exit 1
fi

if oc get enterprisecontractpolicy default -n enterprise-contract-service &>/dev/null; then
  oc get enterprisecontractpolicy default \
    -n enterprise-contract-service \
    -o json \
    | jq 'del(.metadata.resourceVersion,
              .metadata.uid,
              .metadata.creationTimestamp,
              .metadata.generation,
              .metadata.ownerReferences,
              .metadata.labels,
              .metadata.managedFields,
              .status)
          | .metadata.name = "testrepo-ec-policy"
          | .metadata.namespace = "'"$NAMESPACE"'"' \
    | oc apply -f -

  echo ""
  if oc get enterprisecontractpolicy testrepo-ec-policy -n "$NAMESPACE" &>/dev/null; then
    echo "  ✔  testrepo-ec-policy created in $NAMESPACE"
  else
    echo "  ✘  testrepo-ec-policy not found after apply — check oc apply output above"
    exit 1
  fi
else
  echo "  WARNING: enterprisecontractpolicy/default not found in enterprise-contract-service."
  echo "  This namespace may not exist on your cluster or EC may not be installed."
  echo "  Check with: oc get enterprisecontractpolicy -A"
  exit 1
fi

# ── Step 2: Apply ReleasePlan and ReleasePlanAdmission ─────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Apply ReleasePlan and ReleasePlanAdmission"
echo "──────────────────────────────────────────────────────────────"
echo "  Applying release-plan.yaml ..."
# Apply the ReleasePlan and ReleasePlanAdmission — both in default-tenant
if oc apply -f release-plan.yaml -n $NAMESPACE; then
  echo "  ✔  ReleasePlan applied (auto-release: true)"
else
  echo "  ✘  ReleasePlan apply failed"
fi

echo ""
echo "  Applying release-plan-admission.yaml ..."
if oc apply -f release-plan-admission.yaml -n $NAMESPACE; then
  echo "  ✔  ReleasePlanAdmission applied"
else
  echo "  ✘  ReleasePlanAdmission apply failed"
fi

echo ""
echo "  Verifying they are matched..."
# Verify they are matched
oc get releaseplan -n $NAMESPACE
oc get releaseplanadmission -n $NAMESPACE

# ── Step 3: Commit the release pipeline and wait ──────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 3: Commit the release pipeline to your testrepo fork"
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  The cluster-side CRs are now applied. Because auto-release is"
echo "  enabled on the ReleasePlan, the Release Service will automatically"
echo "  create a Release CR once:"
echo "    1. A push build completes successfully"
echo "    2. Integration tests pass (AppStudioTestSucceeded=True)"
echo "    3. The Snapshot is within the releaseGracePeriodDays window"
echo ""
echo "  Before the automatic release can run, the release pipeline file"
echo "  must exist in your testrepo fork at path: release/release-pipeline.yaml"
echo ""
echo "  Refer to Step 5 of the README (08-release-planning/README.md)"
echo "  for the exact git commands to copy and commit the file."
echo ""
read -rp "  Press Enter once you have committed release/release-pipeline.yaml to your testrepo fork... " _PAUSE

# ── Step 4: Watch release status ──────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 4: Watch for the automatic Release and pipeline"
echo "──────────────────────────────────────────────────────────────"
echo "  Watching for Release CRs (auto-created by the Release Service)..."
echo "  Push a commit to main in your testrepo fork to trigger a build"
echo "  if no passing Snapshot exists yet."
echo ""
# Watch the Release status
oc get release -n $NAMESPACE -w

echo ""
RELEASE_NAME=$(oc get release -n $NAMESPACE \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

if [ -z "$RELEASE_NAME" ]; then
  echo "  No Release CR found yet. Push a commit to main to trigger a build,"
  echo "  then re-run: oc get release -n $NAMESPACE -w"
else
  echo "  Latest Release: $RELEASE_NAME"
  oc describe release "$RELEASE_NAME" -n $NAMESPACE

  echo ""
  echo "  Release PipelineRuns:"
  tkn pipelinerun list -n $NAMESPACE

  echo ""
  echo "  Following release pipeline logs..."
  tkn pipelinerun logs --last -f -n $NAMESPACE

  echo ""
  echo "  Full Release status conditions:"
  oc get release "$RELEASE_NAME" -n $NAMESPACE \
    -o jsonpath='{.status.conditions}' | python3 -m json.tool
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 09-enterprise-contract-slsa/commands.sh"
echo "        Validate images with the Enterprise Contract CLI."
echo ""
