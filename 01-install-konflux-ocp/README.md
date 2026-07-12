# 01 — Install Konflux on OpenShift

This step clones the official `konflux-ci/konflux-ci` repository and runs the single `deploy-konflux-on-ocp.sh` script that installs the entire Konflux platform on your OCP cluster. The script handles OLM operators (OpenShift Pipelines, cert-manager), Kyverno policies, Tekton Chains RBAC, Konflux CRDs, and the Konflux Operator — you do not need to pre-install any of these components separately. After the script completes, the `verify.sh` script confirms all namespaces and components are healthy. The `uninstall.sh` script tears everything down cleanly when you are done.

## Prerequisites

- OpenShift Container Platform 4.20+ with cluster-admin access (`oc auth can-i '*' '*' --all-namespaces` returns `yes`)
- `oc` CLI v1.31.4+ (`oc version --client`)
- `git` 2.46+ (`git --version`)
- `go` 1.26+ (`go version`)
- `openssl` 3.0.13+ (`openssl version`)
- `make` (GNU make)
- A default StorageClass with ReadWriteOnce support — check with `oc get storageclass` and confirm one row has `(default)`
- Internet access from the cluster nodes (OLM operator downloads, quay.io image pulls)
- Do **not** pre-install OpenShift Pipelines — the install script installs it via OLM and a pre-installed operator will conflict

## Environment Variables

The following variables are optional. If set before running the installer, the script configures the GitHub App secret and Smee proxy in a single pass. If omitted, the platform installs successfully and you configure them separately in `02-github-app-registry/`.

| Variable | Description | Example / Default |
|---|---|---|
| `GITHUB_APP_ID` | Numeric App ID from the GitHub App settings page | `123456` |
| `WEBHOOK_SECRET` | Secret string set in the GitHub App webhook configuration | `myS3cretV@lue` |
| `GITHUB_PRIVATE_KEY_PATH` | Absolute path to the `.pem` private key downloaded from GitHub | `/home/user/github-app.pem` |
| `SMEE_CHANNEL` | Smee.io channel URL — required when GitHub cannot reach the cluster directly (VPN, firewall, private network). **Must be exported before running `install.sh`** — the smee-client Deployment is created by the script only when this variable is set at install time. | `https://smee.io/abc123XYZ` |
| `OPERATOR_IMAGE` | Optional override of the Konflux Operator image to deploy | `quay.io/konflux-ci/konflux-operator:v0.1.0` |

> **⚠ Important — `SMEE_CHANNEL` must be set before installation:**
> The smee-client pod (which forwards GitHub webhook events to the cluster) is deployed by
> `deploy-konflux-on-ocp.sh` **only when `SMEE_CHANNEL` is already exported** at the time the
> script runs. If you run `install.sh` without it and later discover GitHub cannot reach your
> cluster's PaC Route directly, you must export `SMEE_CHANNEL` and **re-run the full installation**
> to deploy the smee-client. There is no partial way to add smee-client after the fact without
> re-running the installer.

## Files in This Directory

| File | Description |
|---|---|
| `install.sh` | Prerequisite checks, clone the official Konflux repo, optionally export GitHub App variables, run `deploy-konflux-on-ocp.sh` |
| `verify.sh` | Wait for the Konflux CR to reach `Ready=True`, list all component namespace pod statuses, print the UI Route URL |
| `uninstall.sh` | Remove the Konflux CR and all managed components, then remove the operator and CRDs |

## Step-by-step Usage

### Step 1 — Verify prerequisites

```bash
oc version --client        # must be v1.31.4+
oc version                 # server must be 4.20+
git --version              # must be 2.46+
go version                 # must be 1.26+
openssl version            # must be 3.0.13+
make --version             # any GNU make version
oc auth can-i '*' '*' --all-namespaces   # must print: yes
oc get storageclass        # confirm a (default) row exists
```

### Step 2 — (Optional) Export GitHub App variables

Skip the GitHub App block if you do not have a GitHub App yet — you can configure it later in `02-github-app-registry/`.

> **⚠ `SMEE_CHANNEL` is different:** if your cluster is behind a VPN, firewall, or private
> network where GitHub cannot deliver webhooks directly, you **must** export `SMEE_CHANNEL`
> **now**, before running `install.sh`. The smee-client Deployment is created by the installer
> only when this variable is present. Re-running the installer is required to add it later.

```bash
export GITHUB_APP_ID="123456"
export WEBHOOK_SECRET="your-webhook-secret"
export GITHUB_PRIVATE_KEY_PATH="/absolute/path/to/github-app.pem"

# REQUIRED before install if cluster is behind a VPN or firewall — cannot be added after:
export SMEE_CHANNEL="https://smee.io/your-channel-id"
```

### Step 3 — Clone the Konflux repo and run the installer

```bash
git clone https://github.com/konflux-ci/konflux-ci.git
cd konflux-ci
./deploy-konflux-on-ocp.sh
```

The script takes 10–20 minutes on a fresh cluster. It installs (in order):
1. OpenShift Pipelines Operator via OLM
2. Red Hat cert-manager Operator via OLM
3. Kyverno policy engine
4. Tekton Chains RBAC for image signing
5. Prometheus CRDs for observability
6. Konflux CRDs (`make install` inside the operator directory)
7. Konflux Operator deployment
8. Default Konflux CR — waits for `Ready=True`

To use a custom operator image:

```bash
OPERATOR_IMAGE=quay.io/konflux-ci/konflux-operator:v0.1.0 ./deploy-konflux-on-ocp.sh
```

### Step 4 — Verify the installation

```bash
bash verify.sh
```

`verify.sh` runs `oc wait --for=condition=Ready=True konflux konflux --timeout=600s` and then lists pods in all expected namespaces.

### Step 5 — (If needed) Uninstall

```bash
bash uninstall.sh
```

This runs `oc delete konflux konflux` followed by `make undeploy` and `make uninstall` inside the cloned repo.

## What to Expect

When installation completes successfully:

- `oc wait --for=condition=Ready=True konflux konflux --timeout=600s` exits with `konflux.konflux.dev/konflux condition met`
- `verify.sh` shows Running pods in all of these namespaces:

```
openshift-pipelines        (Tekton, PaC, Chains — all co-located on OCP)
cert-manager-operator      (OLM subscription namespace)
cert-manager               (created by the cert-manager operator)
kyverno                    (Kyverno policy engine)
konflux-operator           (Konflux Operator controller)
build-service              (Build Service controller)
integration-service        (Integration Service controller)
release-service            (Release Service controller)
namespace-lister           (Namespace discovery service)
konflux-ui                 (Konflux web UI)
enterprise-contract-service (EC validator)
konflux-info               (Cluster info service)
konflux-cli                (CLI helper)
default-tenant             (your default tenant namespace)
```

- The Konflux UI Route is printed by `verify.sh`. Open it in your browser to confirm the UI loads.
- `oc api-resources | grep -E 'appstudio|enterprisecontract|konflux'` returns multiple CRD groups.

## Troubleshooting

**Pipelines not triggering on PRs after install**
Check that `pipelines-as-code-secret` exists in all three namespaces. On OCP the PaC controller runs in `openshift-pipelines`, not a separate `pipelines-as-code` namespace.
```bash
oc get secret pipelines-as-code-secret -n openshift-pipelines
oc get secret pipelines-as-code-secret -n build-service
oc get secret pipelines-as-code-secret -n integration-service
```
All three must exist. If any are missing, run `02-github-app-registry/deploy-github-secret.sh`.

**Konflux CR never reaches Ready**
Check the operator pod logs and the CR conditions:
```bash
oc get pods -n konflux-operator
oc describe konflux konflux | grep -A 30 "Conditions:"
```

**Cluster out of resources**
```bash
oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory
oc adm top nodes
```

## Next Step

`02-github-app-registry/` — Create the GitHub App and configure Quay.io registry credentials.
