# 03 — Onboard an Application

This step creates the two core Konflux Custom Resources — `Application` and `Component` — that define what to build and where to push the resulting image. The `Application` CR is a logical grouping of related components. The `Component` CR contains the git URL, target branch, and target container image reference. Immediately after the Component CR is applied, Build Service opens an automatic pull request on your forked repository that adds `.tekton/` pipeline definitions. You must not create a `Repository` CR manually — Build Service creates it automatically when it reconciles the Component CR. After merging the auto-generated PR, a full push build runs and the Integration Service creates a `Snapshot` capturing the exact image digest.

## Prerequisites

- GitHub App configured and secrets deployed to all 3 namespaces (complete `02-github-app-registry/`)
- `regcred` secret created and labelled in `default-tenant` (complete `02-github-app-registry/`)
- A fork of `https://github.com/konflux-ci/testrepo` in your GitHub account
- The GitHub App is installed on your testrepo fork (check: GitHub → Settings → Applications → Configure → Repository access)

## Environment Variables

The following placeholders appear in `component.yaml` and `observe-build.sh`. Replace them before applying.

| Variable / Placeholder | Where Used | Description | Example |
|---|---|---|---|
| `YOUR-USERNAME` | `component.yaml` (git URL) | Your GitHub username — owner of the testrepo fork | `jsmith` |
| `YOUR-ORG` | `component.yaml` (containerImage) | Your Quay.io org or username where the image will be pushed | `jsmith` or `myteam` |
| `NS` | `observe-build.sh` | Tenant namespace — set at the top of the script | `default-tenant` |

## Files in This Directory

| File | Description |
|---|---|
| `application.yaml` | Application CR named `my-first-app` in `default-tenant` — logical grouping of components |
| `component.yaml` | Component CR named `testrepo` — points to your fork URL and target image; contains `YOUR-USERNAME` and `YOUR-ORG` placeholders |
| `observe-build.sh` | Verify Component reconciliation, watch for the auto-generated PR, follow PipelineRun logs, extract image URL and digest |

## Step-by-step Usage

### Step 1 — Fork the testrepo

Go to https://github.com/konflux-ci/testrepo and click **Fork**. Confirm the GitHub App is installed on the fork:
- GitHub → Settings → Applications → your app name → Configure → Repository access → add your fork

### Step 2 — Edit the YAML files

In `component.yaml`, replace the two placeholders:

```bash
# Replace YOUR-USERNAME with your GitHub username (owner of the fork)
# Replace YOUR-ORG with your Quay.io org/username

# Linux (GNU sed):
sed -i 's/YOUR-USERNAME/jsmith/g' component.yaml
sed -i 's/YOUR-ORG/jsmith/g' component.yaml

# macOS (BSD sed — note the empty string '' after -i):
sed -i '' 's/YOUR-USERNAME/jsmith/g' component.yaml
sed -i '' 's/YOUR-ORG/jsmith/g' component.yaml

# Cross-platform alternative (works on both Linux and macOS):
perl -pi -e 's/YOUR-USERNAME/jsmith/g' component.yaml
perl -pi -e 's/YOUR-ORG/jsmith/g' component.yaml
```

Verify the result:
```yaml
# component.yaml should look like:
spec:
  source:
    git:
      url: https://github.com/jsmith/testrepo.git
  containerImage: quay.io/jsmith/testrepo
```

### Step 3 — Apply the Application CR

```bash
oc apply -f application.yaml
oc get application my-first-app -n default-tenant
```

### Step 4 — Apply the Component CR

```bash
oc apply -f component.yaml
```

Within 30–60 seconds, Build Service reconciles the Component and opens a pull request on your fork. Check the reconciliation status:

```bash
oc get component testrepo -n default-tenant \
  -o jsonpath='{.metadata.annotations.build\.appstudio\.openshift\.io/status}' \
  | python3 -m json.tool
# Successful reconciliation shows: {"pac":{"state":"enabled",...}}
```

Verify the Repository CR was auto-created:

```bash
oc get repository -n default-tenant
```

### Step 5 — Watch for the auto-generated PR and observe the build

Run `observe-build.sh` to follow all the steps:

```bash
bash observe-build.sh
```

Or follow the steps manually:

```bash
NS="default-tenant"

# Watch PipelineRuns appear (the PR itself triggers a pull-request PipelineRun)
oc get pipelinerun -n "$NS" -w

# Follow logs of the pull-request build
tkn pipelinerun logs --last -f -n "$NS"
```

### Step 6 — Merge the auto-generated PR

Go to `https://github.com/YOUR-USERNAME/testrepo/pulls`. The PR is titled "Add Konflux CI pipelines". Wait until the pull-request PipelineRun shows `Succeeded` and the GitHub check is green, then merge.

**Do not merge until the pull-request PipelineRun has Succeeded.** If you merge while the pipeline is still running or has failed, the `.tekton/` files may have issues that need to be resolved.

### Step 7 — Watch the push build

Merging the PR is a push event to `main`. PaC delivers the webhook and creates a new PipelineRun automatically.

```bash
NS="default-tenant"

# Watch for the push PipelineRun
oc get pipelinerun -n "$NS" -w

# Follow the full push build logs (clone → build → scan → sign → push)
tkn pipelinerun logs --last -f -n "$NS"

# After the push build succeeds, verify a Snapshot was created
oc get snapshot -n "$NS"
```

### Step 8 — Extract the image URL and digest

```bash
NS="default-tenant"
PR_NAME=$(oc get pipelinerun -n "$NS" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

IMAGE_URL=$(oc get pipelinerun "$PR_NAME" -n "$NS" \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
IMAGE_DIGEST=$(oc get pipelinerun "$PR_NAME" -n "$NS" \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

echo "Built image: ${IMAGE_URL}@${IMAGE_DIGEST}"
```

## What to Expect

- Within 30–60 seconds of applying `component.yaml`, a PR appears in your GitHub fork titled "Add Konflux CI pipelines".
- A pull-request PipelineRun runs automatically against the PR branch. It completes in a few minutes with status `Succeeded`.
- After merging, a push PipelineRun runs the full build. It completes with status `Succeeded` and the task results include `IMAGE_URL` and `IMAGE_DIGEST`.
- `oc get snapshot -n default-tenant` shows a new Snapshot CR named after the component and commit SHA.
- The Snapshot status shows `AppStudioTestSucceeded: False` at this point — integration tests are configured in `06-snapshots-integration-tests/`.

## Troubleshooting

**No PR appears in the GitHub fork after applying component.yaml**
Check Component reconciliation status and PaC controller logs:
```bash
oc get component testrepo -n default-tenant \
  -o jsonpath='{.metadata.annotations.build\.appstudio\.openshift\.io/status}'
oc logs -n openshift-pipelines \
  -l app.kubernetes.io/component=controller,app.kubernetes.io/part-of=pipelines-as-code --tail=50
```
Common causes: GitHub App not installed on the fork; `pipelines-as-code-secret` missing from one of the 3 namespaces; cluster not internet-reachable (needs Smee proxy).

**Pull-request PipelineRun fails immediately with an image pull error**
`regcred` is missing or does not have the `build.appstudio.openshift.io/common-secret=true` label. Re-run `configure-registry.sh` from `02-github-app-registry/`.

**Push PipelineRun stuck in Pending**
Check PVC binding and node resources:
```bash
oc describe pvc -n default-tenant | grep -A 10 Events
oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory
```

**GitHub PR base branch points to upstream instead of your fork**
GitHub sometimes pre-fills the PR target as the upstream `konflux-ci/testrepo`. Change the base to your fork's `main` branch before merging.

## Next Step

`04-build-pipeline-internals/` — Inspect the build tasks, download the SBOM, and verify the cosign signature.
