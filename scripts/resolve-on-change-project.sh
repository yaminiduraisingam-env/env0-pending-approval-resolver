#!/bin/bash
# =============================================================================
# env0 Instant Pending Approval Resolver — PER-DEPLOYMENT
# =============================================================================
# This script runs at the START of every deployment on environments it is
# attached to (via project-level custom flow).
#
# When a new deployment is triggered on an environment, this script:
#   1. Checks if the SAME environment has any WAITING_FOR_USER deployments
#   2. If found (AND the current deployment is different), cancels them
#   3. The current deployment then proceeds unblocked
#
# This is scoped only to the environment being deployed — no org-wide scan.
#
# Injected by env0 automatically (no manual setup needed):
#   ENV0_ENVIRONMENT_ID     — The environment being deployed
#   ENV0_DEPLOYMENT_LOG_ID  — The current deployment's ID
#   ENV0_ORGANIZATION_ID    — The org ID
#   ENV0_PROJECT_ID         — The project ID
#   ENV0_ENVIRONMENT_NAME   — The environment name
#
# Required (set as a sensitive project/environment variable):
#   ENV0_API_KEY            — Your env0 API key
# =============================================================================

set -euo pipefail

BASE_URL="https://api.env0.com"
API_KEY="${ENV0_API_KEY:?ERROR: ENV0_API_KEY is not set}"
CURRENT_ENV_ID="${ENV0_ENVIRONMENT_ID}"
CURRENT_DEP_ID="${ENV0_DEPLOYMENT_LOG_ID}"
ENV_NAME="${ENV0_ENVIRONMENT_NAME:-${CURRENT_ENV_ID}}"

CANCELLED=0

# ── Helpers ───────────────────────────────────────────────────────────────────
api_get() {
  curl -sf \
    -H "Accept: application/json" \
    --user "${API_KEY}:" \
    "${BASE_URL}${1}"
}

api_put() {
  curl -sf -X PUT \
    -H "Accept: application/json" \
    --user "${API_KEY}:" \
    "${BASE_URL}${1}"
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo "========================================================================"
echo "  env0 Instant Pending Approval Resolver"
echo "========================================================================"
echo "  Environment : ${ENV_NAME}"
echo "  Env ID      : ${CURRENT_ENV_ID}"
echo "  Deployment  : ${CURRENT_DEP_ID}"
echo "  Started at  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================================================"
echo ""

# ── Fetch recent deployments for THIS environment only ────────────────────────
echo "▶ Checking for pending approval deployments on this environment..."
echo ""

DEPS=$(api_get "/environments/${CURRENT_ENV_ID}/deployments?limit=20")

if [ -z "$DEPS" ] || [ "$DEPS" = "null" ] || [ "$DEPS" = "[]" ]; then
  echo "  No deployments found. Nothing to do."
  exit 0
fi

# Find WAITING_FOR_USER deployments that are NOT the current deployment
PENDING=$(echo "$DEPS" | jq -c \
  --arg current "$CURRENT_DEP_ID" \
  '[.[] | select(.status == "WAITING_FOR_USER" and .id != $current)]'
)
PENDING_COUNT=$(echo "$PENDING" | jq 'length')

echo "  Pending approval deployments found (excluding current): ${PENDING_COUNT}"
echo ""

if [ "$PENDING_COUNT" -eq 0 ]; then
  echo "  ✓ No blocking deployments. Proceeding normally."
  echo ""
  exit 0
fi

# ── Cancel each pending approval deployment ───────────────────────────────────
echo "▶ Cancelling ${PENDING_COUNT} blocking deployment(s)..."
echo ""

while IFS= read -r dep; do
  DEP_ID=$(echo "$dep"    | jq -r '.id')
  STARTED=$(echo "$dep"   | jq -r '.startedAt // "unknown"')
  TRIGGERED=$(echo "$dep" | jq -r '.deploymentApprovalPlan.userRequested.name // "unknown"')

  echo "  → Cancelling : ${DEP_ID}"
  echo "    Started    : ${STARTED}"
  echo "    Triggered by: ${TRIGGERED}"

  api_put "/environments/deployments/${DEP_ID}/cancel"

  echo "  ✓ Cancelled"
  echo ""
  CANCELLED=$((CANCELLED + 1))

done < <(echo "$PENDING" | jq -c '.[]')

# ── Summary ───────────────────────────────────────────────────────────────────
echo "========================================================================"
echo "  SUMMARY"
echo "========================================================================"
printf "  %-35s %s\n" "Environment:"         "${ENV_NAME}"
printf "  %-35s %s\n" "Current deployment:"  "${CURRENT_DEP_ID}"
printf "  %-35s %d\n" "Deployments cancelled:" "${CANCELLED}"
echo ""
echo "  ✓ This deployment can now proceed."
echo "========================================================================"
