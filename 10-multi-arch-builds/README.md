# 10 — Multi-Architecture Builds

Enable multi-arch builds on the existing `testrepo` component — no new repository or Dockerfile needed. This replaces the single-arch push pipeline with the `pipeline-docker-build-multi-platform-oci-ta` bundle, which fans out one `build-images` TaskRun per platform in parallel and merges the results into a single OCI Image Index.

## What This Directory Covers

- Replacing the single-arch pipeline with the multi-platform bundle for an existing component
- Why `multiarch-push.yaml` must *replace* (not coexist with) the existing push pipeline
- The `build-platforms` parameter and how Tekton Matrix parallelises per-arch builds
- The Multi-Platform Controller — what it does, why it is required, and CRC limitations
- Verifying the OCI Image Index with `skopeo inspect --raw`
- How the existing release pipeline handles multi-arch images transparently

## Prerequisites

| Requirement | Details |
|---|---|
| Completed `08-release-planning/` | `release/release-pipeline.yaml` is committed to your testrepo fork |
| `skopeo` installed | `skopeo --version` |
| `python3` installed | `python3 --version` |
| Multi-Platform Controller | Required for real multi-arch builds — see section below |
| Local testrepo fork clone | The fork that already has your `.tekton/` and `release/` directories |

## The Multi-Platform Controller — Required Infrastructure

The `pipeline-docker-build-multi-platform-oci-ta` bundle uses `task-buildah-remote-oci-ta` for every platform entry. This task does **not** use QEMU emulation. Instead it relies on the **Multi-Platform Controller**, which:

1. Detects the waiting `TaskRun` (it needs a `multi-platform-ssh-<name>` secret and has a `PLATFORM` param)
2. Provisions a native VM of the correct architecture from a cloud provider or static pool
3. Creates a per-build SSH keypair, sends the key to an OTP server, and writes the OTP into the secret
4. The build task redeems the OTP once to get the SSH key, SSHes into the native host, and runs `buildah`
5. On completion, the controller deprovisions the per-build user

**Supported cloud providers**: AWS (Graviton for arm64), IBM Z (s390x), IBM Power (ppc64le)  
**Architecture doc**: https://github.com/konflux-ci/architecture/blob/main/architecture/add-ons/multi-platform-controller.md

### CRC (OpenShift Local) Limitation

On CRC the Multi-Platform Controller is not installed. Build pods will hang indefinitely with:
```
MountVolume.SetUp failed: secret "multi-platform-ssh-..." not found
```
This happens even with a single platform entry — the pipeline always uses the remote SSH path.

**Options on CRC:**
| Option | How |
|---|---|
| Hosted Konflux | Use `console.redhat.com/application-pipeline` — controller is pre-configured |
| Full cluster | Install the controller and register remote hosts in the `host-config` ConfigMap |
| Standard bundle | Use `05-bundle-pipeline/` — builds natively on the CRC node (arm64 on Silicon Mac) |

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Interactive script — replaces push pipeline and commits to your fork |
| `.tekton/multiarch-push.yaml` | Multi-platform push pipeline (replaces `testrepo-push.yaml`) |
| `verify-manifest.sh` | Verifies the OCI Image Index after the build completes |

## Placeholders

| Placeholder | Replace With |
|---|---|
| `YOUR-USERNAME` | Your GitHub username (owner of the testrepo fork) |
| `YOUR-ORG` | Your quay.io username or organization |

## Steps

### Option A — Automated

```bash
bash setup.sh
```

### Option B — Manual

```bash
cd /path/to/your/testrepo

# 1. Remove the single-arch push pipeline.
#    IMPORTANT: Both files share the same CEL expression
#    (event == "push" && target_branch == "main"). Keeping both causes
#    two PipelineRuns to fire on every push to main.
git rm .tekton/testrepo-push.yaml

# 2. Copy the multi-arch pipeline
cp /path/to/10-multi-arch-builds/.tekton/multiarch-push.yaml .tekton/

# 3. Replace placeholders (cross-platform)
perl -pi -e 's/YOUR-USERNAME/your-github-username/g' .tekton/multiarch-push.yaml
perl -pi -e 's/YOUR-ORG/your-quay-org/g'             .tekton/multiarch-push.yaml

# 4. Confirm release/release-pipeline.yaml is present (from 08-release-planning/)
ls release/release-pipeline.yaml

# 5. Commit and push
git add .tekton/multiarch-push.yaml
git commit -m "feat: replace single-arch pipeline with multi-arch (amd64, arm64, s390x)"
git push origin main
```

## Watch the Build

```bash
NS="default-tenant"

# Watch the multiarch PipelineRun start
oc get pipelinerun -n $NS -w

# Watch the three build-images TaskRuns appear simultaneously
oc get taskruns -n $NS -w | grep build-images

# All three should show STATUS=Running at the same time
oc get taskruns -n $NS \
  --selector=tekton.dev/pipelineTask=build-images \
  -o custom-columns='NAME:.metadata.name,PLATFORM:.spec.params[?(@.name=="PLATFORM")].value,STATUS:.status.conditions[0].reason'

# Follow logs for the amd64 build specifically
AMD64_TR=$(oc get taskruns -n $NS \
  --selector=tekton.dev/pipelineTask=build-images \
  -o jsonpath='{.items[?(@.spec.params[?(@.name=="PLATFORM")].value=="linux/amd64")].metadata.name}')
tkn taskrun logs "$AMD64_TR" -n $NS -f

# Get results after completion
PR=$(oc get pipelinerun -n $NS \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')
IMAGE_URL=$(oc get pipelinerun "$PR" -n $NS \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
MANIFEST_DIGEST=$(oc get pipelinerun "$PR" -n $NS \
  -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')
echo "OCI Image Index: ${IMAGE_URL}@${MANIFEST_DIGEST}"
```

## Verify the Manifest List

```bash
# Auto-detect from the latest PipelineRun
bash verify-manifest.sh

# Or pass image and digest directly
bash verify-manifest.sh quay.io/YOUR-ORG/testrepo sha256:...
```

The `mediaType` in the output must be `application/vnd.oci.image.index.v1+json` and all three platform entries (`linux/amd64`, `linux/arm64`, `linux/s390x`) must appear in the `manifests` array.

## Release Pipeline Compatibility

The `release/release-pipeline.yaml` from `08-release-planning/` handles multi-arch images without modification. The `skopeo copy --all` flag copies the entire OCI manifest list (all per-arch images) to the staging registry, preserving the manifest list structure.

No changes to the ReleasePlan, ReleasePlanAdmission, or EnterpriseContractPolicy are needed.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `secret "multi-platform-ssh-..." not found` | Multi-Platform Controller not installed | Use hosted Konflux or see the controller architecture doc above |
| Two PipelineRuns fire on every push | Old `testrepo-push.yaml` still in `.tekton/` | `git rm .tekton/testrepo-push.yaml` and push |
| Build stuck even with one platform | Multi-platform bundle always uses remote SSH | Switch to `05-bundle-pipeline/` for single-arch local builds |
| `MANIFEST_UNKNOWN` on bundle | Old `:latest` tag reference | The digest in this repo's YAML is pinned — verify the `sha256:` value |
