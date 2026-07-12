# 08 — Release Planning & Gating

This step configures the Konflux release pipeline that promotes a successfully tested image to a staging registry. The release system uses a two-sided contract: the `ReleasePlan` represents your team's intent to release an application, and the `ReleasePlanAdmission` represents the approved release process (which pipeline to run, which policy to enforce). A `Release` CR triggers the process manually against a specific Snapshot. Before the release pipeline runs, the Enterprise Contract evaluates the image against a policy CR. For this learning setup, everything runs in `default-tenant` — no separate managed namespace is needed. The `release/release-pipeline.yaml` file is stored in your testrepo fork and fetched at release time by the git resolver referenced in `release-plan-admission.yaml`.

## Prerequisites

- Integration tests passing and a Snapshot with `AppStudioTestSucceeded=True` exists (complete `07-snapshots-integration-tests/`)
- `regcred` secret available in `default-tenant` (the release pipeline reuses it — no separate staging secret needed)
- `release/release-pipeline.yaml` committed to your testrepo fork at path `release/release-pipeline.yaml`

## Environment Variables

| Variable / Placeholder | Where Used | Manual / Auto | Description | Example |
|---|---|---|---|---|
| `NAMESPACE` | `prerequisites.sh` | Set in script | Tenant namespace | `default-tenant` |
| `YOUR-USERNAME` | `release-plan-admission.yaml` | **Must replace** | GitHub username — owner of testrepo fork (in the git resolver `url` field) | `jsmith` |
| `YOUR-ORG` | `release/release-pipeline.yaml` (two places) | **Must replace** | Quay.io org/username for the staging registry target | `jsmith` |
| `SNAPSHOT` | `prerequisites.sh` | Auto-derived via `jq` | Name of the latest passing Snapshot (derived from `oc get snapshot`) | `my-first-app-abc123` |

## Files in This Directory

| File | Description |
|---|---|
| `release-plan.yaml` | ReleasePlan CR — declares intent to release `my-first-app` from `default-tenant` |
| `release-plan-admission.yaml` | ReleasePlanAdmission CR — points to the git-resolved release pipeline and the EC policy; contains `YOUR-USERNAME` placeholder |
| `release.yaml` | Release CR — triggers a manual release against `testrepo-manual-snapshot`; update the `snapshot` field before applying |
| `release/release-pipeline.yaml` | Tekton Pipeline with 4 tasks: extract-images → validate-enterprise-contract → push-to-staging-registry → post-release-actions (tag stable); commit this to your testrepo fork |
| `prerequisites.sh` | Create the EC policy, apply CRs in the required order, and watch the release |

## Important Notes

- **Create the EnterpriseContractPolicy first** (Step 2 below). The ReleasePlanAdmission references it by name and every Release fails immediately if it is missing. The policy is created by copying the cluster default from `enterprise-contract-service` — no separate YAML file is needed.
- **`auto-release: "true"` is now set** on the ReleasePlan. The Release Service automatically creates a Release CR after every Snapshot that passes integration tests — no manual `oc apply -f release.yaml` is needed.
- **`standing-attribution: "true"` label is required** when `auto-release: "true"`. Without it, automated releases fail with "no author in the ReleasePlan found for automated release".
- **EC validation runs as Task 2** using the `quay.io/conforma/cli` image directly in an inline `taskSpec`. `STRICT` is set to `"false"` by default so violations are reported in the logs but do not block the release. Change it to `"true"` once all EC rules pass cleanly in your environment.
- **`regcred` is reused** by the release pipeline for both EC validation and the skopeo push — no separate `staging-registry-secret` is needed.

## Step-by-step Usage

### Step 1 — Replace placeholders in the cluster-side YAML files

Replace `YOUR-USERNAME` in `release-plan-admission.yaml` with your GitHub username:

```bash
# Linux (GNU sed):
sed -i 's/YOUR-USERNAME/jsmith/g' release-plan-admission.yaml

# macOS (BSD sed — note the empty string '' after -i):
sed -i '' 's/YOUR-USERNAME/jsmith/g' release-plan-admission.yaml

# Cross-platform alternative (works on both Linux and macOS):
perl -pi -e 's/YOUR-USERNAME/jsmith/g' release-plan-admission.yaml
```

### Step 2 — Create the EnterpriseContractPolicy from the cluster default

Copy the default policy from the `enterprise-contract-service` namespace and apply it to `default-tenant` in one command — no YAML file needed:

```bash
oc get enterprisecontractpolicy default \
  -n enterprise-contract-service \
  -o json \
  | jq 'del(.metadata.resourceVersion,
            .metadata.uid,
            .metadata.creationTimestamp,
            .metadata.generation,
            .metadata.ownerReferences,
            .metadata.labels,
            .metadata.managedFields,
            .status)
        | .metadata.name = "testrepo-ec-policy"
        | .metadata.namespace = "default-tenant"' \
  | oc apply -f -

# Verify it was created
oc get enterprisecontractpolicy testrepo-ec-policy -n default-tenant
```

This mirrors the cluster-managed default policy into `default-tenant` so the release pipeline can reference it as `default-tenant/testrepo-ec-policy` without cross-namespace access. The copy strips all server-managed fields (`resourceVersion`, `uid`, `ownerReferences`, etc.) and renames the object.

### Step 3 — Apply the ReleasePlan and ReleasePlanAdmission

```bash
oc apply -f release-plan.yaml -n default-tenant
oc apply -f release-plan-admission.yaml -n default-tenant

# Verify they matched each other
oc get releaseplan -n default-tenant
oc get releaseplanadmission -n default-tenant
```

### Step 4 — Apply all cluster-side CRs interactively via prerequisites.sh

`prerequisites.sh` handles Steps 1–3 interactively: it prompts for your tenant namespace and GitHub username, replaces the `YOUR-USERNAME` placeholder, applies all three CRs in the correct order, and then pauses to let you commit the release pipeline before watching.

```bash
bash prerequisites.sh
```

The script will:
1. Prompt for your tenant namespace (defaults to `default-tenant`)
2. Prompt for your GitHub username and replace it in `release-plan-admission.yaml`
3. Create the EnterpriseContractPolicy from the cluster default, then apply `release-plan.yaml` and `release-plan-admission.yaml`
4. Pause and ask you to commit the release pipeline to your testrepo fork (see Step 6)
5. Watch for the auto-created Release CR and follow pipeline logs

### Step 5 — Commit the release pipeline to your testrepo fork

> **This must be done before the first automatic release can run.** The `release-plan-admission.yaml` git resolver fetches `release/release-pipeline.yaml` from your testrepo fork at release time — the file must exist there.

```bash
# In your local testrepo fork clone
mkdir -p release
cp /path/to/08-release-planning/release/release-pipeline.yaml release/

# Replace YOUR-ORG with your staging Quay.io org/username

# Linux (GNU sed):
sed -i 's/YOUR-ORG/jsmith-staging/g' release/release-pipeline.yaml

# macOS (BSD sed — note the empty string '' after -i):
sed -i '' 's/YOUR-ORG/jsmith-staging/g' release/release-pipeline.yaml

# Cross-platform alternative (works on both Linux and macOS):
perl -pi -e 's/YOUR-ORG/jsmith-staging/g' release/release-pipeline.yaml

git add release/release-pipeline.yaml
git commit -m "feat: add release pipeline for staging promotion"
git push origin main
```

After pushing, the next successful push build whose Snapshot passes integration tests will automatically trigger the release pipeline.

### Step 6 — Watch the automatic release

With `auto-release: "true"` set on the ReleasePlan, the Release Service automatically creates a Release CR after every Snapshot that passes integration tests. No manual `oc apply -f release.yaml` is needed.

```bash
NS="default-tenant"

# Watch for the auto-created Release CR
oc get release -n $NS -w

# Follow the release PipelineRun logs
tkn pipelinerun logs --last -f -n $NS

# Inspect the full Release status (picks the latest Release automatically)
RELEASE_NAME=$(oc get release -n $NS \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')
oc get release "$RELEASE_NAME" -n $NS \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## What to Expect

- The Release CR triggers a release PipelineRun in `default-tenant`.
- The PipelineRun runs four tasks in sequence: `extract-images` → `validate-enterprise-contract` → `push-to-staging-registry` → `post-release-actions`.
- `validate-enterprise-contract` runs `ec validate image` against `enterprise-contract-service/default` and records a `TEST_OUTPUT` result (`SUCCESS`, `WARNING`, or `FAILURE`). With `STRICT=false` (the default) the pipeline always continues past this task.
- `push-to-staging-registry` copies the built image to `quay.io/YOUR-ORG/testrepo:latest` using skopeo.
- `post-release-actions` tags the same image as `quay.io/YOUR-ORG/testrepo:stable`.
- `oc get release -n default-tenant` shows the auto-created Release CR; check `Succeeded` in the conditions when the pipeline completes.
- Check your staging Quay.io repository to confirm the `latest` and `stable` tags were pushed.

## Troubleshooting

**Release fails immediately with "EnterpriseContractPolicy not found"**
Create the policy by copying the cluster default (Step 2 above):
```bash
oc get enterprisecontractpolicy default \
  -n enterprise-contract-service \
  -o json \
  | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,
            .metadata.generation,.metadata.ownerReferences,.metadata.labels,
            .metadata.managedFields,.status)
        | .metadata.name = "testrepo-ec-policy"
        | .metadata.namespace = "default-tenant"' \
  | oc apply -f -
```

**ReleasePlan and ReleasePlanAdmission are not matched**
Both must reference the same application name and have matching `target`/`origin` fields. Describe them to check:
```bash
oc describe releaseplan testrepo-release-plan -n default-tenant
oc describe releaseplanadmission testrepo-admission -n default-tenant
```

**Release PipelineRun fails with "extract-images: component testrepo not found in snapshot"**
The Snapshot does not contain a component named `testrepo`. Check the Snapshot contents:
```bash
oc get snapshot $SNAPSHOT -n default-tenant -o yaml | grep -A 5 components
```
The component `name` field must be `testrepo` (matching the Component CR name).

**skopeo copy fails with authentication error**
`regcred` does not have push access to the staging registry. Verify the credentials cover both the source registry (where the build image lives) and the target staging registry:
```bash
oc get secret regcred -n default-tenant \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -m json.tool
```

## Next Step

`09-enterprise-contract-slsa/` — Validate images with the `ec` CLI and inspect SLSA attestations directly.
