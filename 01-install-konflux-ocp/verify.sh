#!/bin/bash
# ── Phase 2: Verify the Konflux CR and all components are Ready ───────────────
# Run this script after install.sh completes to confirm the installation is healthy.

set -e

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Konflux Installation Verification                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Wait for the Konflux CR to be Ready ───────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Waiting for Konflux CR to reach Ready state"
echo "──────────────────────────────────────────────────────────────"
oc wait --for=condition=Ready=True konflux konflux --timeout=600s
echo ""
echo "✔  Konflux CR is Ready"

# ── Step 2: Check the Konflux CR status and component conditions ──────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Konflux CR conditions"
echo "──────────────────────────────────────────────────────────────"
oc describe konflux konflux | grep -A 30 "Conditions:"

# ── Step 3: Verify the Konflux Operator pod is running ───────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 3: Konflux Operator pods (konflux-operator namespace)"
echo "──────────────────────────────────────────────────────────────"
oc get pods -n konflux-operator

# ── Step 4: Always-created namespace inventory ────────────────────────────────
#
# Namespace source reference (from deploy-konflux-on-ocp.sh on OCP):
#   SOURCE A — OpenShift Pipelines OLM Operator
#     openshift-pipelines  → TektonConfig targetNamespace; Tekton + PaC + Chains all here
#                            (PaC does NOT get its own namespace on OCP)
#   SOURCE B — Red Hat cert-manager OLM Operator
#     cert-manager-operator → OLM Subscription + OperatorGroup
#     cert-manager          → created by the cert-manager operator upon reconciliation
#   SOURCE C — Kyverno
#     kyverno               → Kyverno policy engine
#   SOURCE D — Konflux Operator CRDs + deploy
#     konflux-operator      → operator controller namespace
#   SOURCE E — Konflux CR reconciliation (always enabled)
#     build-service, integration-service, release-service, namespace-lister,
#     konflux-ui, enterprise-contract-service, konflux-info, konflux-cli, default-tenant
#
#   NOT present on OCP:
#     pipelines-as-code  → upstream Tekton/Kind only; on OCP PaC runs in openshift-pipelines
#     tekton-pipelines   → upstream Tekton only; OCP uses openshift-pipelines
#     dex                → SKIP_DEX=true; OCP has its own OAuth
#
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 4: Always-created namespaces — pod status"
echo "──────────────────────────────────────────────────────────────"

ALWAYS_NS=(
  openshift-pipelines
  cert-manager-operator
  cert-manager
  kyverno
  konflux-operator
  build-service
  integration-service
  release-service
  namespace-lister
  konflux-ui
  enterprise-contract-service
  konflux-info
  konflux-cli
  default-tenant
)

for ns in "${ALWAYS_NS[@]}"; do
  echo ""
  echo "  ┌─ $ns"
  POD_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$POD_COUNT" -eq 0 ] 2>/dev/null; then
    echo "  │  (namespace not found or no pods yet)"
  else
    oc get pods -n "$ns" --no-headers 2>/dev/null | \
      awk '{printf "  │  %-50s %s\n", $1, $3}' || \
      echo "  │  (namespace not found or no pods yet)"
  fi
  echo "  └─────────────────────────────────────────────────"
done

# ── Step 5: Conditionally-created namespaces ──────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 5: Conditionally-created namespaces"
echo "──────────────────────────────────────────────────────────────"

# image-controller: only when spec.imageController.enabled: true in the Konflux CR
echo ""
echo "  Checking image-controller (requires spec.imageController.enabled: true) ..."
if oc get namespace image-controller &>/dev/null; then
  echo "  ✔  image-controller namespace exists"
  echo ""
  oc get pods -n image-controller --no-headers 2>/dev/null | \
    awk '{printf "  │  %-50s %s\n", $1, $3}'
  # Verify quaytoken secret required for image-controller to auto-provision repos
  echo ""
  echo "  Checking quaytoken secret (required by image-controller) ..."
  if oc get secret quaytoken -n image-controller &>/dev/null; then
    echo "  ✔  quaytoken secret found in image-controller"
  else
    echo "  ✘  quaytoken secret NOT found — image-controller cannot provision Quay repos"
    echo "     See: https://konflux-ci.dev/konflux-ci/docs/guides/registry-configuration/"
  fi
else
  echo "  –  image-controller not present (imageController.enabled is false in Konflux CR)"
fi

# segment-bridge: only when spec.telemetry.enabled: true in the Konflux CR
echo ""
echo "  Checking segment-bridge (requires spec.telemetry.enabled: true) ..."
if oc get namespace segment-bridge &>/dev/null; then
  echo "  ✔  segment-bridge namespace exists"
  oc get pods -n segment-bridge --no-headers 2>/dev/null | \
    awk '{printf "  │  %-50s %s\n", $1, $3}'
else
  echo "  –  segment-bridge not present (telemetry.enabled is false in Konflux CR)"
fi

# smee-client: only when SMEE_CHANNEL was set during deploy-konflux-on-ocp.sh
echo ""
echo "  Checking smee-client (only deployed when SMEE_CHANNEL was set during install) ..."
if oc get namespace smee-client &>/dev/null; then
  echo "  ✔  smee-client namespace exists — cluster is behind a firewall/VPN"
  oc get pods -n smee-client --no-headers 2>/dev/null | \
    awk '{printf "  │  %-50s %s\n", $1, $3}'
else
  echo "  –  smee-client not present (cluster is internet-reachable — no Smee proxy needed)"
fi

# ── Step 6: Verify all Konflux CRDs are registered ───────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 6: Konflux CRDs registered in the cluster"
echo "──────────────────────────────────────────────────────────────"
oc api-resources | grep -E 'appstudio|enterprisecontract|konflux' | \
  awk '{printf "  %-55s %s\n", $1, $NF}'

# ── Step 7: Konflux UI Route ──────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 7: Konflux UI access URL"
echo "──────────────────────────────────────────────────────────────"
UI_ROUTE=$(oc get route -A 2>/dev/null | grep konflux | awk '{print $3}' | head -1)
if [ -n "$UI_ROUTE" ]; then
  echo "  ✔  Open in your browser: https://$UI_ROUTE"
else
  echo "  –  No Konflux UI Route found yet (may still be reconciling)"
fi

# ── Step 8: GitHub App secret presence check ──────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 8: GitHub App secret — must exist in all 3 namespaces"
echo "         (required for PaC webhooks and Build Service)"
echo "──────────────────────────────────────────────────────────────"
echo ""
for ns in openshift-pipelines build-service integration-service; do
  if oc get secret pipelines-as-code-secret -n "$ns" &>/dev/null; then
    APP_ID=$(oc get secret pipelines-as-code-secret -n "$ns" \
      -o jsonpath='{.data.github-application-id}' 2>/dev/null | base64 -d 2>/dev/null)
    echo "  ✔  $ns — App ID: ${APP_ID:-<could not decode>}"
  else
    echo "  ✘  $ns — pipelines-as-code-secret MISSING"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Verification Complete                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  If all steps above show ✔ and pods are Running/Completed,"
echo "  Konflux is installed correctly."
echo ""
echo "  Next step: 02-github-app-registry/"
echo "             Create the GitHub App and deploy its secret."
echo ""
