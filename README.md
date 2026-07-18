# Konflux Pipeline Blueprints

> **📖 Full learning guide with architecture diagrams, detailed commands, and step-by-step explanations:**
> **[https://ay-garg.github.io/konflux-pipeline-blueprints/](https://ay-garg.github.io/konflux-pipeline-blueprints/)**

Production-ready YAML blueprints and an interactive learning guide for Konflux CI — covering build pipelines (single-arch and multi-arch), release pipelines, integration test scenarios, and Enterprise Contract policies on OpenShift and CRC.

Each numbered directory maps to one topic in the learning guide. Follow them in order — each step builds on the previous one. Every directory contains a `README.md` with enough detail to implement the step independently, plus a shell script that prompts for required values interactively.

📖 **Blog:** [Konflux CI on OpenShift — Build, Sign, Test & Release with Enterprise Contract and SLSA Provenance](https://blackhatinside.com/2026/07/17/konflux-ci-on-openshift-build-sign-test-release-with-enterprise-contract-and-slsa-provenance/)

## Prerequisites

Before starting, confirm every item below is in place.

| Requirement | Minimum | Check |
|---|---|---|
| OpenShift Container Platform | 4.20+ | `oc version` |
| `oc` CLI | v1.31.4+ | `oc version --client` |
| `git` | 2.46+ | `git --version` |
| `go` | 1.22+ | `go version` |
| `openssl` | 3.x | `openssl version` |
| `tkn` CLI | Latest | `tkn version` |
| `cosign` CLI | v2.x | `cosign version` |
| `skopeo` | Latest | `skopeo --version` |
| `python3` | 3.8+ | `python3 --version` |
| Quay.io account | — | Robot account or personal account with push access |
| GitHub account | — | Permission to create GitHub Apps and fork repositories |
| Default StorageClass | ReadWriteOnce | `oc get storageclass` — look for a `(default)` row |
| Cluster-admin role | — | `oc auth can-i '*' '*' --all-namespaces` must return `yes` |

## Directory Overview

| Directory | Topic | Key Output |
|---|---|---|
| `01-install-konflux-ocp/` | Install Konflux on OCP 4 | Running Konflux instance |
| `02-github-app-registry/` | GitHub App + Quay.io registry | PaC webhook secret, `regcred` push secret |
| `03-onboard-application/` | Onboard testrepo as a Component | First successful build, auto-generated `.tekton/` |
| `04-build-pipeline-internals/` | Inspect tasks, SBOM, signatures | `IMAGE_DIGEST`, cosign verify, SLSA attestation |
| `05-bundle-pipeline/` | Bundle-based pipeline with `pipelineRef` | Short pipeline YAML, skip-checks for CRC arm64 |
| `06-pipeline-as-code/` | Inline `pipelineSpec` with custom tasks | `print-build-summary` task, PR vs push differences |
| `07-snapshots-integration-tests/` | Integration tests via IntegrationTestScenario | `AppStudioTestSucceeded=True` on Snapshot |
| `08-release-planning/` | ReleasePlan, ReleasePlanAdmission, release pipeline | Auto-release to staging registry |
| `09-enterprise-contract-slsa/` | EC CLI, cosign verify, SLSA attestation | `ec validate image` report |
| `10-multi-arch-builds/` | Multi-platform OCI Image Index | `linux/amd64 + arm64 + s390x` manifest list |

## Quick Start

```bash
# Clone this repo
git clone https://github.com/YOUR-USERNAME/konflux-pipeline-blueprints
cd konflux-pipeline-blueprints

# Work through each directory in order
cd 01-install-konflux-ocp && bash install.sh
cd ../02-github-app-registry && bash deploy-github-secret.sh
# ...continue through each directory
```

Each directory's `README.md` lists the exact prerequisites for that step and the expected outcome. The shell scripts prompt interactively — no manual placeholder editing required.

## Placeholder Convention

All YAML files use these placeholders. The setup scripts replace them automatically; for manual edits use `perl -pi -e`:

| Placeholder | Replace With |
|---|---|
| `YOUR-USERNAME` | GitHub username (owner of the testrepo fork) |
| `YOUR-ORG` | Quay.io username or organization |

```bash
# Cross-platform placeholder replacement (macOS and Linux)
perl -pi -e 's/YOUR-USERNAME/your-github-username/g' file.yaml
perl -pi -e 's/YOUR-ORG/your-quay-org/g'             file.yaml
```

> **Do not use `sed -i`** — it requires different syntax on macOS (`sed -i ''`) vs Linux (`sed -i`). Use `perl -pi -e` for cross-platform compatibility.

## Namespace

The default tenant namespace throughout this guide is `default-tenant`. Set it as an environment variable to simplify commands:

```bash
export NS="default-tenant"
```

## Important Notes

- **Follow directories in order** — each step depends on the previous one
- **Do not pre-install OpenShift Pipelines** — `deploy-konflux-on-ocp.sh` installs it via OLM
- **On CRC arm64 (Silicon Mac)** — use `05-bundle-pipeline/` with `skip-checks: "true"`; the multi-platform pipeline in `10-multi-arch-builds/` requires the Multi-Platform Controller which is not available on CRC
- **Tekton Chains namespace on OCP** — resources live in `openshift-pipelines`, not `tekton-chains`

## Links

| Resource | URL |
|---|---|
| Konflux documentation | https://konflux-ci.dev/docs/ |
| Konflux GitHub org | https://github.com/konflux-ci |
| testrepo (fork this) | https://github.com/konflux-ci/testrepo |
| All pipeline definitions | https://github.com/konflux-ci/build-definitions/tree/main/pipelines |
| Multi-Platform Controller | https://github.com/konflux-ci/architecture/blob/main/architecture/add-ons/multi-platform-controller.md |
| Tekton Pipelines | https://tekton.dev/ |
| Pipelines-as-Code | https://pipelinesascode.com/ |
| Enterprise Contract | https://enterprisecontract.dev/ |
| Hosted Konflux | https://console.redhat.com/application-pipeline |
