#!/bin/bash
# ── Phase 2: Deploy the GitHub App secret to Konflux namespaces ───────────────
# Generates (or accepts) a webhook secret, waits for the PaC Route, guides
# through GitHub App creation in the browser, then prompts for the App ID and
# private key AFTER the app has been created, and deploys pipelines-as-code-secret
# to all three required namespaces.

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         GitHub App Secret Deployment                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── STEP A: Webhook secret ─────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step A: Webhook secret"
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  The webhook secret is a shared string between GitHub and your cluster."
echo "  You will paste it into the GitHub App form in the next step."
echo ""
read -rp "  Do you already have a webhook secret? Enter it here, or press Enter to auto-generate: " WEBHOOK_SECRET
if [ -z "$WEBHOOK_SECRET" ]; then
  WEBHOOK_SECRET=$(head -c 30 /dev/random | base64)
  echo ""
  echo "  ✔  Auto-generated WEBHOOK_SECRET:"
  echo ""
  echo "      $WEBHOOK_SECRET"
  echo ""
  echo "  ⚠  Copy this value now — you will paste it into the GitHub App"
  echo "     'Webhook secret' field in Step B below."
else
  echo ""
  echo "  ✔  Using provided WEBHOOK_SECRET."
fi

# ── STEP A2: Wait for the PaC controller Route ────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step A2: Determine the Webhook URL for your GitHub App"
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  If your cluster is internet-reachable from GitHub, the script will"
echo "  extract the PaC controller Route URL automatically."
echo ""
echo "  If your cluster is behind a VPN or firewall and you set SMEE_CHANNEL"
echo "  in 01-install-konflux-ocp/ before installing, use your Smee URL instead"
echo "  — skip this wait and paste the Smee URL into Step B below."
echo ""

echo "  Waiting for the PaC controller Route to be created..."
echo "  (created by the OpenShift Pipelines operator — may take 2–3 minutes)"
echo ""
until oc get route pipelines-as-code-controller -n openshift-pipelines &>/dev/null; do
  echo "  Waiting for Route to appear (retrying in 10s)..."
  sleep 10
done
echo "  ✔  Route found"
echo ""

WEBHOOK_URL=$(oc get route pipelines-as-code-controller \
  -n openshift-pipelines \
  -o jsonpath='https://{.spec.host}')

echo "  ┌─────────────────────────────────────────────────────────────"
echo "  │  PaC Webhook URL (use this in the GitHub App Webhook URL field):"
echo "  │"
echo "  │    $WEBHOOK_URL"
echo "  │"
echo "  │  If the cluster is NOT internet-reachable from GitHub, use your"
echo "  │  Smee URL (the value of SMEE_CHANNEL set in 01-install-konflux-ocp/)"
echo "  │  instead of the URL above."
echo "  └─────────────────────────────────────────────────────────────"
echo ""

# Optional sanity check
echo "  Checking URL reachability from this machine..."
curl -sk -o /dev/null -w "  HTTP status from PaC Route: %{http_code}\n" "$WEBHOOK_URL" || \
  echo "  Note: curl failed — the cluster may not be reachable from this machine"
echo ""

# ── STEP B: Create the GitHub App in your browser ─────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step B: Create the GitHub App in your browser"
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  Open in your browser:"
echo "    Personal account : https://github.com/settings/apps/new"
echo "    Organisation     : https://github.com/organizations/YOUR-ORG/settings/apps/new"
echo ""
echo "  Fill in the form using the values printed above:"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────"
echo "  │  GitHub App name  : My Konflux CI  (must be globally unique)"
echo "  │  Homepage URL     : https://localhost:9443  (any value)"
echo "  │  Webhook ─ Active : YES (toggle on)"
echo "  │  Webhook URL      : $WEBHOOK_URL"
echo "  │                     (or your Smee URL if cluster is behind a firewall)"
echo "  │  Webhook secret   : $WEBHOOK_SECRET"
echo "  └─────────────────────────────────────────────────────────────"
echo ""
echo "  Repository permissions — set EXACTLY these:"
echo "    Checks           : Read & Write"
echo "    Contents         : Read & Write"
echo "    Issues           : Read & Write"
echo "    Metadata         : Read-only  (auto-selected, required)"
echo "    Pull requests    : Read & Write"
echo "    Commit statuses  : Read & Write"
echo ""
echo "  Subscribe to events — check ALL of these:"
echo "    ✓ Check run    ✓ Commit comment    ✓ Issue comment"
echo "    ✓ Pull request ✓ Push"
echo ""
echo "  Where can this GitHub App be installed?  →  Any account"
echo ""
echo "  Click 'Create GitHub App'."
echo ""
echo "  After creating the app:"
echo "    1. Note the numeric App ID shown on the next page (e.g. 123456)"
echo "    2. Scroll to 'Private keys' → click 'Generate a private key'"
echo "       A .pem file will download — note its path"
echo "    3. Click 'Install App' in the left sidebar"
echo "       → your account/org → All repositories (or select specific repos)"
echo ""
read -rp "  Press Enter when you have completed the GitHub App creation above... " _PAUSE

# ── Prompt for App ID and private key AFTER app creation ──────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step B (continued): Enter the App ID and private key"
echo "──────────────────────────────────────────────────────────────"
echo ""

# GITHUB_APP_ID — required, only known after app creation
read -rp "  GITHUB_APP_ID (numeric App ID shown on the GitHub App settings page): " GITHUB_APP_ID
if [ -z "$GITHUB_APP_ID" ]; then
  echo "  ✘  GITHUB_APP_ID is required — cannot deploy the secret without it."
  exit 1
fi
echo "  ✔  App ID: $GITHUB_APP_ID"

# Private key — either file path or inline paste
echo ""
echo "  GitHub private key — choose ONE method:"
echo "  1) GITHUB_PRIVATE_KEY_PATH — absolute path to the downloaded .pem file"
echo "     (use this for interactive/local setups where the file is on disk)"
echo "  2) GITHUB_PRIVATE_KEY      — paste the full PEM key contents directly"
echo "     (use this in CI/CD environments where file paths are not available)"
echo ""
read -rp "  Enter 1 or 2: " KEY_METHOD
case "$KEY_METHOD" in
  1)
    read -rp "  GITHUB_PRIVATE_KEY_PATH (absolute path to .pem file): " GITHUB_PRIVATE_KEY_PATH
    if [ -z "$GITHUB_PRIVATE_KEY_PATH" ]; then
      echo "  ✘  Path cannot be empty."
      exit 1
    fi
    if [ ! -f "$GITHUB_PRIVATE_KEY_PATH" ]; then
      echo "  ✘  File not found: $GITHUB_PRIVATE_KEY_PATH"
      exit 1
    fi
    echo "  ✔  Using key file: $GITHUB_PRIVATE_KEY_PATH"
    ;;
  2)
    echo "  Paste the full PEM private key contents and press Ctrl+D on a new line when done:"
    GITHUB_PRIVATE_KEY=$(cat)
    if [ -z "$GITHUB_PRIVATE_KEY" ]; then
      echo "  ✘  Private key cannot be empty."
      exit 1
    fi
    echo "  ✔  Private key contents received"
    ;;
  *)
    echo "  ✘  Invalid choice. Enter 1 or 2."
    exit 1
    ;;
esac

echo ""
echo "  ── Summary ───────────────────────────────────────────────"
echo "  GITHUB_APP_ID  : $GITHUB_APP_ID"
echo "  WEBHOOK_SECRET : (set)"
[ -n "${GITHUB_PRIVATE_KEY_PATH:-}" ] && echo "  Key method     : file ($GITHUB_PRIVATE_KEY_PATH)"
[ -n "${GITHUB_PRIVATE_KEY:-}" ]      && echo "  Key method     : inline string"
echo "  ──────────────────────────────────────────────────────────"
echo ""

# ── STEP C: Deploy the secret to ALL 3 required namespaces ────────────────────
# Source: https://raw.githubusercontent.com/konflux-ci/konflux-ci/refs/heads/main/scripts/deploy-secrets.sh
#
# This block mirrors scripts/deploy-secrets.sh create_github_integration_secrets()
# exactly — same flag syntax, same two-path conditional, same secret key names.
#
# On OCP (USE_OPENSHIFT_PIPELINES=true):
#   pac_ns is set to "openshift-pipelines", not "pipelines-as-code".
#   The loop targets: openshift-pipelines  build-service  integration-service
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Step C: Deploy GitHub App secret to all 3 namespaces"
echo "──────────────────────────────────────────────────────────────"
echo ""

# The official script has two code paths depending on how the private key is provided:
#   Path A — key is a file on disk (GITHUB_PRIVATE_KEY_PATH set + file exists)
#   Path B — key is passed as a literal string (e.g. from a CI env var: GITHUB_PRIVATE_KEY)
# Match this exactly so the secret data format is identical to what the script produces.

for ns in openshift-pipelines build-service integration-service; do
  echo "  Deploying secret to namespace: $ns ..."

  if [ -n "${GITHUB_PRIVATE_KEY_PATH:-}" ] && [ -f "${GITHUB_PRIVATE_KEY_PATH}" ]; then
    # Path A: read private key from a .pem file (most common for interactive installs)
    if oc -n "$ns" create secret generic pipelines-as-code-secret \
      --from-file=github-private-key="$GITHUB_PRIVATE_KEY_PATH" \
      --from-literal github-application-id="$GITHUB_APP_ID" \
      --from-literal webhook.secret="$WEBHOOK_SECRET" \
      --dry-run=client -o yaml | oc apply -f -; then
      echo "  ✔  $ns — secret applied"
    else
      echo "  ✘  $ns — secret apply failed"
    fi
  else
    # Path B: key content is already in the GITHUB_PRIVATE_KEY env var (CI pipelines)
    if oc -n "$ns" create secret generic pipelines-as-code-secret \
      --from-literal github-private-key="$GITHUB_PRIVATE_KEY" \
      --from-literal github-application-id="$GITHUB_APP_ID" \
      --from-literal webhook.secret="$WEBHOOK_SECRET" \
      --dry-run=client -o yaml | oc apply -f -; then
      echo "  ✔  $ns — secret applied"
    else
      echo "  ✘  $ns — secret apply failed"
    fi
  fi
done

# Verify the secret exists in all 3 namespaces
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Verification: decoded App ID from each namespace"
echo "──────────────────────────────────────────────────────────────"
echo ""
for ns in openshift-pipelines build-service integration-service; do
  echo -n "  $ns — App ID: "
  oc get secret pipelines-as-code-secret -n $ns \
    -o jsonpath='{.data.github-application-id}' 2>/dev/null | base64 -d \
    || echo '(missing!)'
  echo ""
done

# ── STEP D: image-controller Quay secret (optional) ──────────────────────────
# Required ONLY when spec.imageController.enabled: true in the Konflux CR.
# image-controller auto-creates Quay.io repos when you onboard Components
# via the Konflux UI. Skip entirely if you create Components with oc.
#
# ⚠ This step is NOT covered here — refer to the official documentation:
#
#   quay.io (cloud):
#   https://konflux-ci.dev/konflux-ci/docs/guides/registry-configuration/#quayio-auto-provisioning-image-controller
#
#   Self-hosted Quay registry:
#   https://konflux-ci.dev/konflux-ci/docs/guides/registry-configuration/#self-hosted-quay-registry

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 02-github-app-registry/configure-registry.sh"
echo "        Set up push/pull registry credentials (regcred) for builds."
echo ""
