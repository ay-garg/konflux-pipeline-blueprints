# 06 — Pipeline as Code

This step demonstrates how to customize Konflux build pipelines using Pipelines-as-Code (PaC). With PaC, pipeline definitions live inside your source repository in a `.tekton/` directory. PaC detects events via GitHub webhook and runs the matching pipeline automatically — the push pipeline on merges to `main`, the pull-request pipeline on every PR open/update. This directory contains customized versions of both pipelines with an extra `print-build-summary` task added after the build. The `.tekton/` files are designed to be copied into your testrepo fork and committed there — they are NOT applied directly to the cluster with `oc apply`. PaC reads them from the repository at webhook time.

## Prerequisites

- Component onboarded and first build completed (complete `03-onboard-application/`)
- Your testrepo fork with the auto-generated `.tekton/` pipelines already merged into `main`
- The GitHub App is installed on your testrepo fork

## Environment Variables

The following placeholders appear in the `.tekton/` YAML files and must be replaced before copying them into your fork.

| Placeholder | File(s) | Description | Example |
|---|---|---|---|
| `YOUR-USERNAME` | `testrepo-push.yaml`, `testrepo-pull-request.yaml` | GitHub username — owner of the testrepo fork (used in the `build.appstudio.openshift.io/repo` annotation) | `jsmith` |
| `YOUR-ORG` | `testrepo-push.yaml`, `testrepo-pull-request.yaml` | Quay.io org/username for the output image (must match `containerImage` in the Component CR) | `jsmith` |
| `NAMESPACE` | `commands.sh` | Set at the top of `commands.sh` to your tenant namespace | `default-tenant` |

## Files in This Directory

| File | Description |
|---|---|
| `.tekton/testrepo-push.yaml` | Customized push pipeline — runs on push to `main`; adds `print-build-summary` inline task after `build-image-index`; scans always enabled |
| `.tekton/testrepo-pull-request.yaml` | Customized PR pipeline — `cancel-in-progress: true`; 5-day image expiry; adds `pr-build-summary` inline task |
| `.tekton/tasks/print-build-summary.yaml` | Standalone Tekton Task CRD — same logic as the inline `taskSpec` block, extracted for reuse across pipelines; apply to the cluster with `oc apply` if needed |
| `commands.sh` | Inspect PaC Repositories, watch PipelineRuns, verify the custom task ran, debug webhook delivery |

## Step-by-step Usage

### Step 1 — Replace placeholders in the YAML files

```bash
# Clone or navigate to this directory
cd 05-pipeline-as-code

# Replace YOUR-USERNAME and YOUR-ORG in both pipeline files

# Linux (GNU sed):
sed -i 's/YOUR-USERNAME/jsmith/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
sed -i 's/YOUR-ORG/jsmith/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml

# macOS (BSD sed — note the empty string '' after -i):
sed -i '' 's/YOUR-USERNAME/jsmith/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
sed -i '' 's/YOUR-ORG/jsmith/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml

# Cross-platform alternative (works on both Linux and macOS):
perl -pi -e 's/YOUR-USERNAME/jsmith/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
perl -pi -e 's/YOUR-ORG/jsmith/g' .tekton/testrepo-push.yaml .tekton/testrepo-pull-request.yaml
```

Verify no placeholders remain:

```bash
grep -r 'YOUR-' .tekton/
# Should return no output
```

### Step 2 — Copy the .tekton/ files into your testrepo fork

```bash
# Navigate to your local testrepo fork
TESTREPO_PATH="/path/to/your/testrepo-fork"

# Copy the customized pipeline files (replaces the auto-generated ones)
cp .tekton/testrepo-push.yaml "$TESTREPO_PATH/.tekton/"
cp .tekton/testrepo-pull-request.yaml "$TESTREPO_PATH/.tekton/"

# Create the tasks subdirectory if it doesn't exist
mkdir -p "$TESTREPO_PATH/.tekton/tasks"
cp .tekton/tasks/print-build-summary.yaml "$TESTREPO_PATH/.tekton/tasks/"
```

### Step 3 — Push to your testrepo fork

```bash
cd "$TESTREPO_PATH"
git add .tekton/
git commit -m "feat: add custom build summary tasks to push and PR pipelines"
git push origin main
```

### Step 4 — Watch the new PipelineRun

```bash
NS="default-tenant"

# Watch for the PipelineRun triggered by the push
oc get pipelinerun -n $NS -w

# Follow the logs and look for the KONFLUX BUILD SUMMARY banner
tkn pipelinerun logs --last -f -n $NS
```

### Step 5 — Verify the custom task ran

```bash
NS="default-tenant"

# Look for the print-build-summary task output
tkn pipelinerun logs --last -n $NS | grep -A 20 "print-build-summary"

# List all tasks in the PipelineRun
PR_NAME=$(oc get pipelinerun -n $NS \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

oc get taskruns -n $NS \
  --selector=tekton.dev/pipelineRun=$PR_NAME \
  -o 'custom-columns=NAME:.metadata.name,TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason'
```

### Step 6 — (Optional) Apply the standalone Task to the cluster

If you want to reference `print-build-summary` by name (instead of an inline `taskSpec`) from other pipelines:

```bash
oc apply -f .tekton/tasks/print-build-summary.yaml -n default-tenant
oc get task print-build-summary -n default-tenant
```

### Step 7 — Inspect PaC configuration

```bash
NS="default-tenant"

# See all PaC Repositories (registered webhooks) in your namespace
oc get repository -n $NS

# Describe the repository to see webhook and last run status
REPO_NAME=$(oc get repository -n $NS -o jsonpath='{.items[0].metadata.name}')
oc describe repository "$REPO_NAME" -n $NS
```

Or run the script directly:

```bash
NS="default-tenant"
# Edit NAMESPACE at the top of commands.sh first
bash commands.sh
```

## What to Expect

- After pushing the updated `.tekton/` files, PaC detects the push event and creates a new PipelineRun within 10–30 seconds.
- The PipelineRun name contains `push` or `on-push`.
- In the logs, `tkn pipelinerun logs --last -n default-tenant | grep -A 20 "print-build-summary"` prints:
  ```
  ==================================================
             KONFLUX BUILD SUMMARY
  ==================================================
  Source repository:     https://github.com/jsmith/testrepo
  Git commit:            abc1234...
  Built image URL:       quay.io/jsmith/testrepo
  Image digest:          sha256:def456...
  ==================================================
  ```
- The PR pipeline (`testrepo-pull-request.yaml`) runs when you open a pull request and prints a similar `KONFLUX PR BUILD SUMMARY` banner.
- On the PR pipeline, the image tag starts with `on-pr-` and has a 5-day expiry — it is a disposable artifact.

## Troubleshooting

**No new PipelineRun after pushing `.tekton/` changes**
PaC only creates PipelineRuns when it detects a matching event (push or pull_request) delivered by the GitHub App webhook. Check that the push event was delivered in GitHub:
- GitHub repo → Settings → Webhooks → your webhook → Recent Deliveries
- Look for a push event with a 200 response
```bash
oc logs -n openshift-pipelines \
  -l app.kubernetes.io/component=controller,app.kubernetes.io/part-of=pipelines-as-code --tail=50
```

**PipelineRun uses the old pipeline definition (without the custom task)**
PaC resolves pipeline definitions from the repository at event time. If the files were not pushed before the event fired, it uses the previous version. Trigger a new push (empty commit works):
```bash
git commit --allow-empty -m "trigger: re-run pipeline"
git push origin main
```

**`print-build-summary` task not found in TaskRun list**
The task only runs if its `runAfter` dependencies succeeded. Check if `build-image-index` completed successfully first:
```bash
oc get taskruns -n default-tenant --selector=tekton.dev/pipelineRun=$PR_NAME \
  -o custom-columns=TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason
```

**`commands.sh` namespace is wrong**
Edit `NAMESPACE="your-username-tenant"` at the top of `commands.sh` to `NAMESPACE="default-tenant"` before running.

## Next Step

`07-snapshots-integration-tests/` — Write integration tests that run against the built image.
