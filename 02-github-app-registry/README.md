# 02 — GitHub App & Registry Configuration

This step sets up the two external integrations Konflux needs before you can onboard a component: a GitHub App and a container registry push secret. The GitHub App enables Pipelines-as-Code to receive webhook events from GitHub and post build status checks back to pull requests. The registry secret (`regcred`) lets Build Service push built images to Quay.io (or any OCI-compatible registry). The GitHub App secret must be deployed to three namespaces simultaneously (`openshift-pipelines`, `build-service`, `integration-service`) because each service independently validates webhook signatures. The `regcred` secret is labelled so Build Service automatically mounts it on every Component's build service account — you do not need to patch service accounts manually after onboarding.

## Prerequisites

- Konflux installed and the Konflux CR is `Ready=True` (complete `01-install-konflux-ocp/`)
- A GitHub account with permission to create GitHub Apps (personal account or organization owner)
- A Quay.io account with a robot account or personal credentials that have push access to the target repository
- The Pipelines-as-Code controller Route is reachable from GitHub **or** you exported `SMEE_CHANNEL` before running `install.sh` in `01-install-konflux-ocp/` (the smee-client was then deployed by the installer — the Smee URL you used there is your webhook URL for the GitHub App below)

## Environment Variables

### deploy-github-secret.sh

| Variable | Manual / Auto | Description | Example |
|---|---|---|---|
| `WEBHOOK_SECRET` | **Must generate manually** | Generate with `head -c 30 /dev/random \| base64` in Step 1 of this directory; paste the output into the GitHub App webhook secret field | `dGVzdA==` (base64 string) |
| `GITHUB_APP_ID` | **Must set manually** | Numeric App ID shown on the GitHub App settings page after creation (Step 2 of this directory) | `123456` |
| `GITHUB_PRIVATE_KEY_PATH` | **Set this OR `GITHUB_PRIVATE_KEY`** | Absolute path to the `.pem` file downloaded from GitHub — use for interactive/local setups | `/home/user/github-app.pem` |
| `GITHUB_PRIVATE_KEY` | **Set this OR `GITHUB_PRIVATE_KEY_PATH`** | Full PEM private key as a string — use for CI/CD pipelines where file paths are not available; mutually exclusive with `GITHUB_PRIVATE_KEY_PATH` | (PEM file contents) |
| `WEBHOOK_URL` | Auto-derived (Option A) or manually set (Option B) | Option A: extracted from the PaC Route by the script. Option B: the Smee URL set as `SMEE_CHANNEL` in `01-install-konflux-ocp/` — use the same value here | `https://pipelines-as-code-controller-openshift-pipelines.apps.cluster.example.com` |

### configure-registry.sh

| Variable | Manual / Auto | Description | Example |
|---|---|---|---|
| `NS` | Set in script | Tenant namespace; change if using a custom namespace | `default-tenant` |
| `REGISTRY_AUTH_JSON` | **Must set manually** | Path to your Docker config JSON file containing registry credentials | `/home/user/.docker/config.json` |

## Files in This Directory

| File | Description |
|---|---|
| `deploy-github-secret.sh` | STEP A: generate webhook secret; STEP A2: wait for PaC Route and extract the webhook URL; STEP B: browser instructions to create the GitHub App; STEP C: deploy `pipelines-as-code-secret` to all 3 namespaces; STEP D: notes on image-controller Quay secret (optional) |
| `configure-registry.sh` | Verify tenant namespace label, create the `regcred` secret from your Docker config JSON, apply the `build.appstudio.openshift.io/common-secret=true` label |

## Step-by-step Usage

### Step 1 — Generate webhook secret and determine your webhook URL

Run the first part of `deploy-github-secret.sh` to generate the webhook secret and determine the correct URL to use in the GitHub App.

```bash
# Generate webhook secret — save the printed value, you will paste it into the GitHub App form
WEBHOOK_SECRET=$(head -c 30 /dev/random | base64)
echo "Your webhook secret: $WEBHOOK_SECRET"
```

**Determine which URL to use as the GitHub App webhook URL:**

**Option A — Cluster is internet-reachable from GitHub (no SMEE_CHANNEL was set in `01-install-konflux-ocp/`)**

The script waits for the PaC Route (created by the OpenShift Pipelines operator, may take 2–3 minutes):

```bash
until oc get route pipelines-as-code-controller -n openshift-pipelines &>/dev/null; do
  echo "Route not ready yet, retrying in 10s..."
  sleep 10
done

WEBHOOK_URL=$(oc get route pipelines-as-code-controller \
  -n openshift-pipelines \
  -o jsonpath='https://{.spec.host}')
echo "PaC Webhook URL (use this in the GitHub App form): $WEBHOOK_URL"
```

**Option B — Cluster is behind a VPN or firewall (SMEE_CHANNEL was exported before running `01-install-konflux-ocp/install.sh`)**

If you set `SMEE_CHANNEL` before running `install.sh`, the smee-client was deployed by the
installer and is already forwarding events to your cluster. Use the **same Smee URL** you
provided in `01-install-konflux-ocp/` as the webhook URL in the GitHub App — do not use the PaC Route URL.

```bash
# Use the Smee URL you already set as SMEE_CHANNEL in 01-install-konflux-ocp/, e.g.:
WEBHOOK_URL="https://smee.io/your-channel-id"   # same value as SMEE_CHANNEL in 01-install-konflux-ocp/
echo "Webhook URL (Smee proxy): $WEBHOOK_URL"
```

> **⚠ If you did not export `SMEE_CHANNEL` in `01-install-konflux-ocp/`** and your cluster is not internet-reachable,
> GitHub webhook deliveries will silently fail. Go back to `01-install-konflux-ocp/`, export `SMEE_CHANNEL`, and
> re-run the installer before proceeding here.

Save both `WEBHOOK_SECRET` and `WEBHOOK_URL` — you need them in the next step.

### Step 2 — Create the GitHub App in your browser

1. Go to https://github.com/settings/apps/new (personal) or https://github.com/organizations/YOUR-ORG/settings/apps/new (org)
2. Fill in the form:
   - **GitHub App name**: any globally-unique name, e.g. `My Konflux CI`
   - **Homepage URL**: `https://localhost:9443` (value does not matter)
   - **Webhook — Active**: toggle ON
   - **Webhook URL**: paste the `$WEBHOOK_URL` value from Step 1 — the PaC Route URL (Option A) or the Smee URL from `01-install-konflux-ocp/` (Option B)
   - **Webhook secret**: paste the `$WEBHOOK_SECRET` value printed above
3. Set **Repository permissions**:
   - Checks: Read & Write
   - Contents: Read & Write
   - Issues: Read & Write
   - Metadata: Read-only (auto-selected)
   - Pull requests: Read & Write
   - Commit statuses: Read & Write
4. **Subscribe to events**: Check run, Commit comment, Issue comment, Pull request, Push
5. **Where can this GitHub App be installed?**: Any account
6. Click **Create GitHub App**
7. Note the numeric **App ID** shown on the next page (e.g. `123456`) — this is `GITHUB_APP_ID`
8. Scroll to **Private keys** and click **Generate a private key** — a `.pem` file downloads automatically
9. Click **Install App** in the left sidebar → your account/org → **All repositories** (or select specific repos)

### Step 3 — Deploy the GitHub App secret to all 3 namespaces

```bash
# Set the values from steps 1 and 2
GITHUB_APP_ID="123456"                              # from Step 2, item 7
GITHUB_PRIVATE_KEY_PATH="/path/to/github-app.pem"  # downloaded in Step 2, item 8
# WEBHOOK_SECRET is already set from Step 1

for ns in openshift-pipelines build-service integration-service; do
  echo "Creating secret in ${ns}..."
  oc -n "$ns" create secret generic pipelines-as-code-secret \
    --from-file=github-private-key="$GITHUB_PRIVATE_KEY_PATH" \
    --from-literal=github-application-id="$GITHUB_APP_ID" \
    --from-literal=webhook.secret="$WEBHOOK_SECRET" \
    --dry-run=client -o yaml | oc apply -f -
done
```

Verify all three secrets were created:

```bash
for ns in openshift-pipelines build-service integration-service; do
  echo -n "$ns — App ID: "
  oc get secret pipelines-as-code-secret -n $ns \
    -o jsonpath='{.data.github-application-id}' | base64 -d
  echo ""
done
```

Or simply run the full script (which includes all of the above):

```bash
bash deploy-github-secret.sh
```

### Step 4 — Create the registry push secret

First, obtain Docker config JSON credentials for your registry. For Quay.io, go to your account settings and create a robot account or download a CLI password. Then:

```bash
# Set the path to your Docker config JSON file
export REGISTRY_AUTH_JSON="/path/to/your/auth.json"

# Run the script — it creates and labels the regcred secret
bash configure-registry.sh
```

Or run the commands manually:

```bash
NS="default-tenant"

# Verify the tenant namespace has the required label
oc get namespace "$NS" --show-labels
# Must include: konflux-ci.dev/type=tenant
# If missing: oc label namespace "$NS" konflux-ci.dev/type=tenant

# Create the regcred secret (delete first to avoid immutable field error on re-runs)
oc delete secret regcred -n "$NS" --ignore-not-found
oc create secret generic regcred \
  --from-file=.dockerconfigjson="${REGISTRY_AUTH_JSON}" \
  --type=kubernetes.io/dockerconfigjson \
  -n "$NS"

# Label it so Build Service links it to all Component service accounts automatically
oc label secret regcred \
  -n "$NS" \
  build.appstudio.openshift.io/common-secret=true
```

### Step 5 — Verify

```bash
# All 3 namespace secrets must exist
oc get secret pipelines-as-code-secret -n openshift-pipelines
oc get secret pipelines-as-code-secret -n build-service
oc get secret pipelines-as-code-secret -n integration-service

# regcred must exist with the common-secret label
oc get secret regcred -n default-tenant --show-labels

# Confirm regcred contents are valid JSON
oc get secret regcred -n default-tenant \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -m json.tool
```

## What to Expect

After running both scripts:

- `oc get secret pipelines-as-code-secret -n openshift-pipelines` returns a secret with keys `github-private-key`, `github-application-id`, and `webhook.secret`.
- `oc get secret regcred -n default-tenant --show-labels` shows the label `build.appstudio.openshift.io/common-secret=true`.
- In GitHub, the GitHub App shows as "Installed" on your account or org with the repositories you selected.
- Optionally verify the PaC Route is reachable: `curl -sk -o /dev/null -w "%{http_code}" $WEBHOOK_URL` — any HTTP response (even 400) means the Route is up.

## Troubleshooting

**Route `pipelines-as-code-controller` does not exist in `openshift-pipelines`**
The Route is created by the OpenShift Pipelines operator when `TektonConfig` reaches Ready. Wait 2–3 minutes after install and re-check: `oc get route -n openshift-pipelines`.

**Secret missing from one namespace**
The `for` loop in `deploy-github-secret.sh` uses `--dry-run=client -o yaml | oc apply -f -` so re-running it is safe. Run the loop again for the specific namespace that is missing the secret.

**regcred fails with "field is immutable"**
The secret type (`kubernetes.io/dockerconfigjson`) cannot be changed after creation. The script runs `oc delete secret regcred --ignore-not-found` before creating — if you run the commands manually, delete first.

**GitHub App webhook deliveries show connection refused or timeout**
Your cluster is not internet-reachable from GitHub. You have two options:
- **If you set `SMEE_CHANNEL` in `01-install-konflux-ocp/`:** The smee-client is already running. Confirm the GitHub App webhook URL is set to your Smee URL (not the PaC Route URL), and check the smee-client pod is healthy: `oc get pods -n smee-client`.
- **If you did not set `SMEE_CHANNEL` in `01-install-konflux-ocp/`:** Go to https://smee.io, start a new channel, copy the URL, then go back to `01-install-konflux-ocp/`, export `SMEE_CHANNEL=https://smee.io/your-channel`, and re-run the installer. Then update the GitHub App webhook URL to the Smee URL.

## Next Step

`03-onboard-application/` — Apply Application and Component CRs and observe the first build.
