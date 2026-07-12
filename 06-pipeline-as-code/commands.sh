#!/bin/bash
# ── Phase 5: Pipeline as Code — verification and customization commands ────────
# Commands for inspecting PaC configuration, pushing .tekton changes, listing
# tasks in a PipelineRun, and debugging webhook delivery on OpenShift.

# Set NAMESPACE to your tenant namespace.
# Options (in order of precedence):
#   1. Export before running:  export NAMESPACE="your-actual-namespace"
#   2. Replace "default-tenant" below with your namespace name
#   3. Leave as-is — the script will use "default-tenant"
NAMESPACE="${NAMESPACE:-default-tenant}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Pipeline as Code — Verification Commands             ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Inspect PaC configuration ─────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Inspect PaC configuration"
echo "──────────────────────────────────────────────────────────────"
# ── Inspect PaC configuration ─────────────────────────────────
# On OCP, the PaC controller runs in openshift-pipelines (not pipelines-as-code)
echo "  PaC controller pods (openshift-pipelines namespace):"
oc get pods -n openshift-pipelines \
  -l app.kubernetes.io/part-of=pipelines-as-code

echo ""
echo "  All PaC Repository CRs in namespace '$NAMESPACE':"
# See all PaC Repositories (registered webhooks)
# The NAME column from this output is what you pass to describe below
oc get repository -n $NAMESPACE

echo ""
echo "  Describing the Repository CR (webhook status)..."
# Describe your repository to see webhook status
# Use the exact NAME shown by the command above — it typically matches
# the component name but use the value from oc get repository, not a guess
REPO_NAME=$(oc get repository -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
oc describe repository "$REPO_NAME" -n $NAMESPACE

# ── After pushing .tekton changes ─────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " After pushing .tekton changes"
echo "──────────────────────────────────────────────────────────────"
# ── After pushing .tekton changes ────────────────────────────
echo "  Watching for new PipelineRun..."
# Watch the new PipelineRun appear
oc get pipelinerun -n $NAMESPACE -w

echo ""
echo "  Verifying custom task ran (look for the KONFLUX BUILD SUMMARY banner)..."
# Verify the custom task ran (look for the KONFLUX BUILD SUMMARY banner)
tkn pipelinerun logs --last -n $NAMESPACE | grep -A 20 "print-build-summary"

# ── List all tasks in the pipeline ────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " List all tasks in the last PipelineRun"
echo "──────────────────────────────────────────────────────────────"
# ── List all tasks in the pipeline ────────────────────────────
PR_NAME=$(oc get pipelinerun -n $NAMESPACE \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

echo "  Last PipelineRun: $PR_NAME"
echo "  TaskRun status:"
oc get taskruns -n $NAMESPACE \
  --selector=tekton.dev/pipelineRun=$PR_NAME \
  -o 'custom-columns=NAME:.metadata.name,TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason'

# ── Inspect the resolved pipeline definition ──────────────────────────────────
echo ""
echo "──────────────────────────────────────────────────────────────"
echo " Inspect the resolved pipeline definition"
echo "──────────────────────────────────────────────────────────────"
# ── Inspect the resolved pipeline definition ───────────────────
# See which OCI bundle version was actually used
echo "  Task names in resolved pipelineSpec:"
oc get pipelinerun $PR_NAME -n $NAMESPACE \
  -o jsonpath='{.status.pipelineSpec.tasks[*].name}' | tr ' ' '\n'

echo ""
echo "  PaC controller logs (last 50 lines — useful for webhook delivery issues):"
# ── Debug PaC webhook delivery issues ─────────────────────────
# On OCP, PaC controller runs in openshift-pipelines
oc logs -n openshift-pipelines \
  -l app.kubernetes.io/component=controller,app.kubernetes.io/part-of=pipelines-as-code --tail=50

echo ""
echo "  Recent events in namespace '$NAMESPACE' (last 20):"
# List recent events from PaC
oc get events -n $NAMESPACE \
  --sort-by=.lastTimestamp | tail -20

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        Complete                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next: 06-snapshots-integration-tests/prerequisites.sh"
echo "        Set up RBAC and pull secrets for integration tests."
echo ""
