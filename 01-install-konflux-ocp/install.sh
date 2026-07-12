#!/bin/bash
# ── Phase 1: Install Konflux on OpenShift ─────────────────────────────────────
# Checks prerequisites, clones the konflux-ci repo, and runs deploy-konflux-on-ocp.sh.
# Run verify.sh afterward to confirm all components reached Ready state.

# ── Configuration: optional GitHub App pre-seeding ────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Optional: Pre-seed GitHub App credentials"
echo "  If you already have a GitHub App, enter values below."
echo "  Press Enter to skip any field — Konflux installs without them"
echo "  and you can configure them separately in 02-github-app-registry/"
echo "══════════════════════════════════════════════════════════════"
echo ""

read -rp "  GITHUB_APP_ID (numeric App ID, or Enter to skip): " GITHUB_APP_ID
read -rp "  WEBHOOK_SECRET (or Enter to skip): " WEBHOOK_SECRET

echo ""
echo "  GitHub private key — choose one method (or Enter to skip both):"
echo "  1) GITHUB_PRIVATE_KEY_PATH — absolute path to .pem file (interactive/local)"
echo "  2) GITHUB_PRIVATE_KEY      — paste key contents directly (CI/CD environments)"
echo "  3) Skip — configure later in 02-github-app-registry/"
echo ""
read -rp "  Enter 1, 2, or 3 [3]: " KEY_METHOD
KEY_METHOD="${KEY_METHOD:-3}"

case "$KEY_METHOD" in
  1)
    read -rp "  GITHUB_PRIVATE_KEY_PATH (absolute path to .pem): " GITHUB_PRIVATE_KEY_PATH
    ;;
  2)
    echo "  Paste the full PEM private key contents (press Ctrl+D on a new line when done):"
    GITHUB_PRIVATE_KEY=$(cat)
    ;;
  *)
    echo "  –  GitHub private key skipped"
    ;;
esac

echo ""
echo "  SMEE_CHANNEL — IMPORTANT: only required if GitHub cannot reach your cluster"
echo "  (behind VPN, firewall, or private network). If set, the smee-client Deployment"
echo "  is created during install. It CANNOT be added after install without re-running."
echo "  Leave empty if your cluster has a public internet-reachable ingress."
echo ""
read -rp "  SMEE_CHANNEL URL (e.g. https://smee.io/abc123, or Enter to skip): " SMEE_CHANNEL

read -rp "  OPERATOR_IMAGE override (or Enter to use default): " OPERATOR_IMAGE

echo ""
echo "  ── Summary of configuration ──────────────────────────────"
[ -n "$GITHUB_APP_ID" ]           && echo "  GITHUB_APP_ID          : $GITHUB_APP_ID"           || echo "  GITHUB_APP_ID          : (not set — configure later)"
[ -n "$WEBHOOK_SECRET" ]          && echo "  WEBHOOK_SECRET         : (set)"                     || echo "  WEBHOOK_SECRET         : (not set — configure later)"
[ -n "$GITHUB_PRIVATE_KEY_PATH" ] && echo "  GITHUB_PRIVATE_KEY_PATH: $GITHUB_PRIVATE_KEY_PATH" || true
[ -n "$GITHUB_PRIVATE_KEY" ]      && echo "  GITHUB_PRIVATE_KEY     : (set)"                    || true
[ -z "$GITHUB_PRIVATE_KEY_PATH" ] && [ -z "$GITHUB_PRIVATE_KEY" ] && echo "  GitHub private key     : (not set — configure later)"
[ -n "$SMEE_CHANNEL" ]            && echo "  SMEE_CHANNEL           : $SMEE_CHANNEL"            || echo "  SMEE_CHANNEL           : (not set — cluster must be publicly reachable)"
[ -n "$OPERATOR_IMAGE" ]          && echo "  OPERATOR_IMAGE         : $OPERATOR_IMAGE"          || echo "  OPERATOR_IMAGE         : (default)"
echo "  ──────────────────────────────────────────────────────────"
echo ""

# Export only the non-empty variables so deploy-konflux-on-ocp.sh picks them up
[ -n "$GITHUB_APP_ID" ]           && export GITHUB_APP_ID
[ -n "$WEBHOOK_SECRET" ]          && export WEBHOOK_SECRET
[ -n "$GITHUB_PRIVATE_KEY_PATH" ] && export GITHUB_PRIVATE_KEY_PATH
[ -n "$GITHUB_PRIVATE_KEY" ]      && export GITHUB_PRIVATE_KEY
[ -n "$SMEE_CHANNEL" ]            && export SMEE_CHANNEL
[ -n "$OPERATOR_IMAGE" ]          && export OPERATOR_IMAGE

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Konflux Platform Installation                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Prerequisite checks ───────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 1: Prerequisite checks"
echo "──────────────────────────────────────────────────────────────"
echo ""

# oc version            # must be 4.20+
if oc version &>/dev/null; then
  echo "  ✔  oc (server)"
  oc version
else
  echo "  ✘  oc — not found or cluster unreachable (must be 4.20+)"
fi

echo ""
# oc version --client  # must be v1.31.4+
if oc version --client &>/dev/null; then
  echo "  ✔  oc (client)"
  oc version --client
else
  echo "  ✘  oc client — not found (must be v1.31.4+)"
fi

echo ""
# git --version         # must be 2.46+
if git --version &>/dev/null; then
  echo "  ✔  $(git --version)"
else
  echo "  ✘  git — not found (must be 2.46+)"
fi

echo ""
# go version            # must be 1.26+
if go version &>/dev/null; then
  echo "  ✔  $(go version)"
else
  echo "  ✘  go — not found (must be 1.26+)"
fi

echo ""
# openssl version       # must be 3.0.13+
if openssl version &>/dev/null; then
  echo "  ✔  $(openssl version)"
else
  echo "  ✘  openssl — not found (must be 3.0.13+)"
fi

echo ""
if make --version &>/dev/null; then
  echo "  ✔  $(make --version | head -1)"
else
  echo "  ✘  make — not found"
fi

echo ""
# Verify cluster-admin
echo "  Checking cluster-admin permissions..."
if oc auth can-i '*' '*' --all-namespaces 2>/dev/null | grep -q yes; then
  echo "  ✔  cluster-admin — yes"
else
  echo "  ✘  cluster-admin — NO (oc auth can-i '*' '*' --all-namespaces did not return yes)"
fi

echo ""
# Verify default StorageClass exists (required for PVC binding)
echo "  Checking StorageClass (look for a row with '(default)')..."
oc get storageclass
# Look for a row with (default) — e.g. gp3-csi (default)

# ── Step 2: Clone + run installer ─────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step 2: Clone the Konflux repository and run the installer"
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  Cloning https://github.com/konflux-ci/konflux-ci.git ..."
# ── Clone the official Konflux repository ─────────────────────
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci

# ── NOTE: Pre-export optional variables before running the script ─────────────
#
# The script can automatically configure the GitHub App secret and the Smee
# client if the corresponding environment variables are exported beforehand.
#
# If you already have a GitHub App created and want the script to configure
# everything in one shot, export these before running ./deploy-konflux-on-ocp.sh:
#
#   export GITHUB_APP_ID="123456"                       # numeric App ID from GitHub
#   export WEBHOOK_SECRET="your-webhook-secret"         # secret you set in the GitHub App
#   export GITHUB_PRIVATE_KEY_PATH="/path/to/app.pem"  # private key .pem downloaded from GitHub
#
# Additionally, if your cluster is NOT reachable from the internet (e.g. behind
# a VPN or firewall) and GitHub cannot deliver webhooks directly, also export:
#
#   export SMEE_CHANNEL="https://smee.io/your-channel-id"
#
# When SMEE_CHANNEL is set, the script deploys a Smee proxy client inside the
# cluster that forwards GitHub webhook events to the PaC controller.
#
# If you don't have a GitHub App yet or prefer to configure these manually
# after installation, simply skip the exports — the platform installs fine
# without them. You can run scripts/deploy-secrets.sh standalone afterwards.
# See Phase 3 below for the manual post-installation steps.
#
echo ""
echo "  Running ./deploy-konflux-on-ocp.sh ..."
echo "  This single script does EVERYTHING:"
echo "    - Installs OpenShift Pipelines Operator via OLM (DO NOT pre-install separately)"
echo "    - Installs Red Hat cert-manager Operator via OLM"
echo "    - Deploys Kyverno for namespace RBAC policy"
echo "    - Sets up Tekton Chains RBAC for image signing"
echo "    - Installs Prometheus CRDs for observability"
echo "    - Installs Konflux CRDs (make install in operator/)"
echo "    - Deploys the Konflux Operator to konflux-operator namespace"
echo "    - Applies the default Konflux CR"
echo "    - Waits for the CR to reach Ready"
echo ""
# ── Run the deployment script ─────────────────────────────────
./deploy-konflux-on-ocp.sh

# To use a specific operator image (optional override):
# OPERATOR_IMAGE=quay.io/konflux-ci/konflux-operator:v0.1.0 ./deploy-konflux-on-ocp.sh

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: run 01-install-konflux-ocp/verify.sh to confirm all"
echo "        components are Running and the Konflux CR is Ready."
echo ""
