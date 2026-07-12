#!/bin/bash
# ── Phase 6: Integration Test Prerequisites ────────────────────────────────────
# Applies the RBAC needed for the integration runner service account and links
# the regcred pull secret to the default SA so test pods can pull images.

# ── Configuration ─────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Integration Test Prerequisites — Configuration"
echo "══════════════════════════════════════════════════════════════"
echo ""
read -rp "  Tenant namespace [default-tenant]: " NS_INPUT
NS="${NS_INPUT:-default-tenant}"
echo "  ✔  Using namespace: $NS"
echo ""

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Integration Test Prerequisites                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Prerequisite 1: Apply RBAC for konflux-integration-runner ─────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Prerequisite 1: Apply RBAC for konflux-integration-runner"
echo "──────────────────────────────────────────────────────────────"
# WHY THIS IS NEEDED:
# The integration test pipeline (testrepo-integration.yaml) creates a Kubernetes
# Job in the tenant namespace to run the built container image, then reads its logs.
# By default the konflux-integration-runner service account only has narrow
# permissions and cannot create, delete, or list batch/jobs or pod logs in
# the tenant namespace. Without this RBAC the test PipelineRun fails immediately:
#
#   Error from server (Forbidden): jobs.batch "test-hello" is forbidden:
#   User "system:serviceaccount:default-tenant:konflux-integration-runner"
#   cannot delete resource "jobs" in API group "batch" in the namespace "default-tenant"
#
# Apply this once before creating the IntegrationTestScenario:
echo "  Applying integration-runner-rbac.yaml ..."
if oc apply -f integration-runner-rbac.yaml; then
  echo "  ✔  RBAC applied"
else
  echo "  ✘  RBAC apply failed — check that integration-runner-rbac.yaml exists in this directory"
fi

echo ""
echo "  Verifying Role was created..."
# Verify the Role and RoleBinding were created
if oc get role default-tenant-pod-viewer-job-creator -n "$NS" &>/dev/null; then
  echo "  ✔  Role 'default-tenant-pod-viewer-job-creator' found"
else
  echo "  ✘  Role 'default-tenant-pod-viewer-job-creator' not found"
fi

echo ""
echo "  Verifying RoleBinding was created..."
if oc get rolebinding default-tenant-pod-viewer-job-creator-binding -n "$NS" &>/dev/null; then
  echo "  ✔  RoleBinding 'default-tenant-pod-viewer-job-creator-binding' found"
else
  echo "  ✘  RoleBinding 'default-tenant-pod-viewer-job-creator-binding' not found"
fi

# ── Prerequisite 2: Link regcred pull secret to the default service account ───
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Prerequisite 2: Link regcred pull secret to default SA"
echo "──────────────────────────────────────────────────────────────"
# WHY THIS IS NEEDED:
# The Kubernetes Job created by the test pipeline runs as the "default" service
# account in default-tenant. The regcred secret (your quay.io push/pull credentials
# created in Phase 4) must be explicitly linked to this SA or the Job pod will
# fail to pull the testrepo image with an image pull error:
#
#   Failed to pull image "quay.io/...": ...unauthorized: access to the requested
#   resource is not authorized

# Link regcred to the default service account in your tenant namespace
echo "  Linking regcred to default service account in $NS..."
if oc secrets link default regcred --for=pull -n "$NS"; then
  echo "  ✔  regcred linked to default SA"
else
  echo "  ✘  Failed to link regcred — check that the secret exists in $NS"
fi

echo ""
echo "  Verifying the link was applied (output must include 'regcred')..."
# Verify the link was applied — output must include {"name": "regcred"}
oc get sa default -n "$NS" \
  -o jsonpath='{.imagePullSecrets}' | python3 -m json.tool

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 07-release-planning/prerequisites.sh"
echo "        Apply the EC policy, ReleasePlan, and trigger a release."
echo ""
