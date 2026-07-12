#!/bin/bash
# ── Phase 2: Configure registry credentials for the tenant namespace ──────────
# Creates the regcred push secret and labels it so Build Service automatically
# mounts it onto every component build ServiceAccount.
# Ref: https://konflux-ci.dev/docs/installation/registry-configuration/
#
# SEQUENCING:
#   Part A (NOW — before Phase 5): verify tenant namespace + create regcred secret
#   Part B (AFTER Phase 5):        patch regcred onto the Component ServiceAccount
#                                  (the SA doesn't exist until Build Service reconciles
#                                   the Component CR, so Part B must come after)

# ── Configuration ─────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Registry Credentials Setup — Configuration"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  You need a Docker config JSON file with credentials for your OCI registry."
echo "  For Quay.io: Account Settings → CLI Password → Generate Encrypted Password"
echo "  → View docker login command → save the config from ~/.docker/config.json"
echo "  Or use a Robot Account: Quay.io → Your Org → Robot Accounts → Download credentials"
echo ""
read -rp "  REGISTRY_AUTH_JSON (absolute path to Docker config JSON file): " REGISTRY_AUTH_JSON
if [ -z "$REGISTRY_AUTH_JSON" ]; then
  echo "  ✘  REGISTRY_AUTH_JSON is required — cannot create regcred without credentials."
  exit 1
fi
if [ ! -f "$REGISTRY_AUTH_JSON" ]; then
  echo "  ✘  File not found: $REGISTRY_AUTH_JSON"
  exit 1
fi
echo "  ✔  Using credentials file: $REGISTRY_AUTH_JSON"

echo ""
read -rp "  Tenant namespace [default-tenant]: " NS_INPUT
NS="${NS_INPUT:-default-tenant}"
echo "  ✔  Using namespace: $NS"

echo ""
echo "  ── Summary ───────────────────────────────────────────────"
echo "  REGISTRY_AUTH_JSON : $REGISTRY_AUTH_JSON"
echo "  Namespace          : $NS"
echo "  ──────────────────────────────────────────────────────────"
echo ""

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Registry Credentials Setup                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════════
# PART A — Run before Phase 5
# ═══════════════════════════════════════════════════════════════

# ── Step 1: Verify the tenant namespace ───────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Verify the tenant namespace"
echo "──────────────────────────────────────────────────────────────"
echo "  Checking namespace '$NS' labels..."
NS_LABELS=$(oc get namespace "$NS" --show-labels)
echo "$NS_LABELS"
# Required label: konflux-ci.dev/type=tenant
# If it's missing, label it:
#   oc label namespace "$NS" konflux-ci.dev/type=tenant
if echo "$NS_LABELS" | grep -q 'konflux-ci.dev/type=tenant'; then
  echo "  ✔  Required label 'konflux-ci.dev/type=tenant' is present"
else
  echo "  ⚠  Label 'konflux-ci.dev/type=tenant' not found — apply with:"
  echo "       oc label namespace \"$NS\" konflux-ci.dev/type=tenant"
fi

# To create a brand-new custom tenant namespace:
# oc create namespace my-team-tenant
# oc label namespace my-team-tenant \
#   konflux-ci.dev/type=tenant \
#   pod-security.kubernetes.io/audit=baseline \
#   pod-security.kubernetes.io/audit-version=latest \
#   pod-security.kubernetes.io/warn=baseline \
#   pod-security.kubernetes.io/warn-version=latest

# ── Step 2: Delete existing regcred to avoid immutable field errors ────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Remove existing regcred (if present)"
echo "──────────────────────────────────────────────────────────────"
echo "  Removing existing regcred if present..."
# Delete first to avoid "field is immutable" error on re-runs
oc delete secret regcred -n "$NS" --ignore-not-found
echo "  –  Existing regcred removed (or was not present)"

# ── Step 3: Create the regcred push secret ─────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 3: Create the regcred push secret"
echo "──────────────────────────────────────────────────────────────"
# For how to obtain registry credentials for quay.io, Docker Hub, or any
# other OCI-compatible registry, refer to the official documentation:
#
#   https://konflux-ci.dev/konflux-ci/docs/guides/registry-configuration/#obtaining-registry-credentials
#
# Once you have your credentials as a Docker config JSON file, create the secret:

echo "  Creating regcred secret from: $REGISTRY_AUTH_JSON ..."
if oc create secret generic regcred \
  --from-file=.dockerconfigjson="${REGISTRY_AUTH_JSON}" \
  --type=kubernetes.io/dockerconfigjson \
  -n "$NS"; then
  echo "  ✔  regcred secret created"
else
  echo "  ✘  regcred secret creation failed — check that REGISTRY_AUTH_JSON path is correct"
fi

# ── Step 4: Label the secret so Build Service links it automatically ───────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 4: Apply Build Service label to regcred"
echo "──────────────────────────────────────────────────────────────"
# ── Label the secret so Build Service links it to all Component SAs automatically ──
# The label below marks regcred as a "common secret" for the tenant namespace.
# Build Service watches for this label and automatically mounts the secret onto
# every build-pipeline-<component-name> ServiceAccount it creates, so you do
# NOT need to manually patch each SA after onboarding a new Component (Phase 5 Part B).
echo "  Applying build.appstudio.openshift.io/common-secret=true label..."
if oc label secret regcred \
  -n "$NS" \
  build.appstudio.openshift.io/common-secret=true; then
  echo "  ✔  Label applied"
else
  echo "  ✘  Label apply failed"
fi

# ── Step 5: Verify the secret was created correctly ───────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 5: Verify regcred"
echo "──────────────────────────────────────────────────────────────"
echo "  Secret summary:"
# ── Step 3: Confirm the secret was created correctly ───────────
oc get secret regcred -n "$NS"
echo ""
echo "  Decoded .dockerconfigjson keys:"
oc get secret regcred -n "$NS" \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -m json.tool
echo ""
echo "  Secret labels:"
# Confirm the label is present
oc get secret regcred -n "$NS" --show-labels

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 03-onboard-application/observe-build.sh"
echo "        Onboard a component and observe the first build."
echo ""
