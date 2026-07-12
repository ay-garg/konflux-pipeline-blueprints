#!/bin/bash
# ── Uninstall Konflux from OpenShift ──────────────────────────────────────────
# Removes the Konflux CR (and all managed components), then runs make undeploy
# and make uninstall to remove the operator and all CRDs.

set -e

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Konflux Platform Uninstall                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"

echo ""
echo "  ⚠  This will remove ALL Konflux components. Press Ctrl+C within 5 seconds to cancel."
echo ""
sleep 5

# ── Step 1: Remove the CR (this removes all managed components) ───────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Delete the Konflux CR"
echo "──────────────────────────────────────────────────────────────"
echo "  Deleting konflux/konflux CR (triggers removal of all managed components)..."
# Remove the CR (this removes all managed components)
oc delete konflux konflux
echo "  ✔  Konflux CR deleted"

# ── Step 2: Remove the operator and CRDs ──────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Remove the operator and CRDs"
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  Running make undeploy..."
# Remove the operator and CRDs
cd operator
make undeploy
echo "  ✔  Operator undeployed"

echo ""
echo "  Running make uninstall..."
make uninstall
echo "  ✔  CRDs uninstalled"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Uninstall complete. All Konflux components have been removed."
echo ""
