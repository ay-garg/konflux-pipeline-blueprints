# 07 — Snapshots & Integration Tests

This step configures Konflux integration tests that run automatically after every successful push build. When a push pipeline completes, the Integration Service creates a `Snapshot` capturing the exact image digest built. The `IntegrationTestScenario` CR tells the Integration Service which Tekton Pipeline to run against each new Snapshot. The test pipeline in this directory runs the built container image as a Kubernetes Job and asserts its output contains "hello world". Two prerequisites are required before integration tests work: RBAC granting the `konflux-integration-runner` service account permission to create batch Jobs in the tenant namespace, and linking the `regcred` pull secret to the `default` service account so the Job pod can pull the built image. The `integration-tests/testrepo-integration.yaml` pipeline is fetched from your testrepo fork via the git resolver at test time — it is NOT applied to the cluster directly.

## Prerequisites

- First push build completed and a Snapshot exists (complete `03-onboard-application/`)
- `regcred` secret created and labelled in `default-tenant` (complete `02-github-app-registry/`)
- `integration-tests/testrepo-integration.yaml` committed in your testrepo fork at path `integration-tests/testrepo-integration.yaml` (this file is already present in the official `testrepo` repo — if you forked it, it is already there)

## Environment Variables

| Variable / Placeholder | Where Used | Description | Example |
|---|---|---|---|
| `NS` | `prerequisites.sh` | Tenant namespace | `default-tenant` |
| `YOUR-USERNAME` | `integration-test-scenario.yaml` | GitHub username (owner of the testrepo fork) — in the `url` field of the git resolver | `jsmith` |
| `YOUR-ORG` | `manual-snapshot.yaml` | Quay.io org/username for the image reference | `jsmith` |
| `IMAGE_URL` | Derived — see below | Full image URL from a previous push PipelineRun | `quay.io/jsmith/testrepo` |
| `IMAGE_DIGEST` | Derived — see below | Image digest from a previous push PipelineRun | `sha256:abc123...` |

### Deriving IMAGE_URL and IMAGE_DIGEST for manual-snapshot.yaml

The `containerImage` field in `manual-snapshot.yaml` requires a real digest from a successful push build. Run:

```bash
NS="default-tenant"
PR=$(oc get pipelinerun -n $NS --sort-by=.metadata.creationTimestamp \
       -o jsonpath='{.items[-1].metadata.name}')
IMAGE_URL=$(oc get pipelinerun $PR -n $NS \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
IMAGE_DIGEST=$(oc get pipelinerun $PR -n $NS \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')
echo "containerImage: ${IMAGE_URL}@${IMAGE_DIGEST}"
```

Then edit `manual-snapshot.yaml` and replace the placeholder with the printed value.

## Files in This Directory

| File | Description |
|---|---|
| `integration-runner-rbac.yaml` | Role + RoleBinding granting `konflux-integration-runner` permission to create/delete batch Jobs and read Pod logs in `default-tenant` |
| `prerequisites.sh` | Apply RBAC; link `regcred` to the `default` service account for image pull |
| `integration-test-scenario.yaml` | IntegrationTestScenario CR — points the Integration Service to the test pipeline via git resolver |
| `integration-tests/testrepo-integration.yaml` | Tekton Pipeline — runs the built image as a Job and asserts "hello world" output; committed to your testrepo fork, NOT applied to the cluster |
| `manual-snapshot.yaml` | Snapshot CR — trigger integration tests manually without waiting for a new build; requires a real image digest |

## Step-by-step Usage

### Step 1 — Apply RBAC

The integration runner service account has no `batch/jobs` permission by default. Without this step, the test PipelineRun fails immediately with a Forbidden error.

```bash
oc apply -f integration-runner-rbac.yaml

# Verify the Role and RoleBinding were created
oc get role default-tenant-pod-viewer-job-creator -n default-tenant
oc get rolebinding default-tenant-pod-viewer-job-creator-binding -n default-tenant
```

### Step 2 — Link the regcred pull secret to the default service account

The Kubernetes Job created by the test pipeline runs as the `default` service account. Without this step, the Job pod fails to pull the image.

```bash
oc secrets link default regcred --for=pull -n default-tenant

# Verify — output must include {"name": "regcred"}
oc get sa default -n default-tenant \
  -o jsonpath='{.imagePullSecrets}' | python3 -m json.tool
```

Or run both steps together:

```bash
bash prerequisites.sh
```

### Step 3 — Confirm the test pipeline file is in your testrepo fork

The file must exist at `integration-tests/testrepo-integration.yaml` in your fork at the `main` branch. If you forked from `https://github.com/konflux-ci/testrepo`, the file is already there. Verify:

```bash
# In your local testrepo clone
ls integration-tests/testrepo-integration.yaml
```

If it is missing, copy it from this directory:

```bash
# In your local testrepo clone
mkdir -p integration-tests
cp /path/to/06-snapshots-integration-tests/integration-tests/testrepo-integration.yaml \
   integration-tests/
git add integration-tests/testrepo-integration.yaml
git commit -m "feat: add integration test pipeline"
git push origin main
```

### Step 4 — Replace placeholders and apply the IntegrationTestScenario

Edit `integration-test-scenario.yaml` and replace `YOUR-USERNAME`:

```bash
# Linux (GNU sed):
sed -i 's/YOUR-USERNAME/jsmith/g' integration-test-scenario.yaml

# macOS (BSD sed — note the empty string '' after -i):
sed -i '' 's/YOUR-USERNAME/jsmith/g' integration-test-scenario.yaml

# Cross-platform alternative (works on both Linux and macOS):
perl -pi -e 's/YOUR-USERNAME/jsmith/g' integration-test-scenario.yaml
```

Apply the CR:

```bash
oc apply -f integration-test-scenario.yaml

# Verify it was created
oc get integrationtestscenario -n default-tenant
```

### Step 5 — Trigger a new build and watch the integration test run

Push any change to your testrepo fork to trigger a build. After the push PipelineRun succeeds and the Integration Service creates a Snapshot, it automatically starts the integration test PipelineRun.

```bash
NS="default-tenant"

# Watch PipelineRuns (integration test creates its own PipelineRun)
oc get pipelinerun -n $NS -w

# Follow integration test logs
tkn pipelinerun logs --last -f -n $NS

# Check Snapshot status
# Single-quote the -o argument — unquoted square brackets cause zsh to
# attempt glob expansion and fail with "no matches found"
oc get snapshot -n $NS \
  -o 'custom-columns=NAME:.metadata.name,TESTS:.status.conditions[0].reason'
```

### Step 6 — (Optional) Trigger integration tests manually without a new build

First, get the real image digest from the last successful push build (see the Environment Variables section above), then edit `manual-snapshot.yaml` to set the correct `containerImage`:

```bash
# Edit manual-snapshot.yaml:
#   containerImage: quay.io/jsmith/testrepo@sha256:<actual-digest>
# Replace YOUR-ORG with your Quay.io org too

oc apply -f manual-snapshot.yaml

# Watch the integration test PipelineRun appear
oc get pipelinerun -n default-tenant -w
```

## What to Expect

- After applying the IntegrationTestScenario, the next successful push build automatically triggers an integration test PipelineRun.
- The test PipelineRun runs a `test-hello-world` task that creates a Kubernetes Job, waits for it to complete, reads its logs, and asserts the output contains "hello world".
- A passing test updates the Snapshot status: `AppStudioTestSucceeded=True`.
- A failing test updates the Snapshot with `AppStudioTestSucceeded=False` — the Snapshot is then blocked from being released.
- `oc get snapshot -n default-tenant -o wide` shows `True` in the test status column when all tests pass.

## Troubleshooting

**Integration test PipelineRun fails with "Forbidden: jobs.batch ... cannot ... create"**
The RBAC was not applied, or was applied to the wrong namespace. Verify and re-apply:
```bash
oc get role default-tenant-pod-viewer-job-creator -n default-tenant
oc apply -f integration-runner-rbac.yaml
```

**Job pod fails with "unauthorized: access to the requested resource is not authorized"**
The `regcred` pull secret is not linked to the `default` service account:
```bash
oc secrets link default regcred --for=pull -n default-tenant
```

**Integration test PipelineRun never appears after push build succeeds**
Check the IntegrationTestScenario and Integration Service logs:
```bash
oc get integrationtestscenario -n default-tenant
oc logs -n integration-service -l app=integration-service --tail=50
```
Common cause: `YOUR-USERNAME` placeholder not replaced in `integration-test-scenario.yaml`, so the git resolver cannot find the pipeline file.

**"hello world" assertion fails in the test**
The testrepo image's `entrypoint.sh` must print "hello world". Check the Job pod logs directly:
```bash
oc logs -l job-name=test-hello -n default-tenant
```
If the output is different, update the `grep "hello world"` assertion in `integration-tests/testrepo-integration.yaml` in your fork to match the actual output.

## Next Step

`08-release-planning/` — Gate releases with ReleasePlan, ReleasePlanAdmission, and an Enterprise Contract policy.
