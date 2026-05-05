#!/bin/bash
# =============================================================================
# env0 Pending Approval Resolver — ORGANIZATION LEVEL
# =============================================================================
# Scans ALL environments across the entire organization.
# Use this version in production.
#
# Required env vars:
#   ENV0_API_KEY              — Your env0 API key (used as Basic Auth user)
#   ENV0_ORGANIZATION_ID      — Your env0 organization ID
#
# Logic:
#   For each environment, if BOTH conditions are true:
#     1. There is at least one deployment in WAITING_FOR_USER (pending approval)
#     2. There is at least one deployment in QUEUED
#   Then:
#     - Cancel all QUEUED deployments except the most recent one
#     - Cancel all WAITING_FOR_USER deployments
#     - The most recent QUEUED deployment will auto-trigger after cancellation
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
BASE_URL="https://api.env0.com"
API_KEY="${ENV0_API_KEY:?ERROR: ENV0_API_KEY environment variable is not set}"
ORG_ID="${ENV0_ORGANIZATION_ID:?ERROR: ENV0_ORGANIZATION_ID environment variable is not set}"
PAGE_LIMIT=100

# ── Counters & log file ───────────────────────────────────────────────────────
ENVS_CHECKED=0
ENVS_ACTIONED=0
DEPLOYMENTS_CANCELLED=0
ACTION_LOG_FILE=$(mktemp)
ALL_ENVS_FILE=$(mktemp)

# Cleanup temp files on exit
trap 'rm -f "$ACTION_LOG_FILE" "$ALL_ENVS_FILE" "${ALL_ENVS_FILE}.tmp" 2>/dev/null' EXIT

# ── Helper: GET request ───────────────────────────────────────────────────────
api_get() {
  local endpoint="$1"
  curl -sf \
    -H "Accept: application/json" \
    --user "${API_KEY}:" \
    "${BASE_URL}${endpoint}"
}

# ── Helper: PUT request (no body) ─────────────────────────────────────────────
api_put() {
  local endpoint="$1"
  curl -sf -X PUT \
    -H "Accept: application/json" \
    --user "${API_KEY}:" \
    "${BASE_URL}${endpoint}"
}

# ── Helper: Cancel a single deployment ────────────────────────────────────────
cancel_deployment() {
  local dep_id="$1"
  local env_name="$2"
  local reason="$3"

  echo "    → Cancelling deployment: ${dep_id}"
  echo "      Reason              : ${reason}"

  api_put "/environments/deployments/${dep_id}/cancel"

  echo "    ✓ Cancelled successfully"
  DEPLOYMENTS_CANCELLED=$((DEPLOYMENTS_CANCELLED + 1))
  echo "ENV: ${env_name} | Deployment ID: ${dep_id} | Reason: ${reason}" >> "$ACTION_LOG_FILE"
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo "========================================================================"
echo "  env0 Pending Approval Resolver — ORGANIZATION LEVEL"
echo "========================================================================"
echo "  Organization ID : ${ORG_ID}"
echo "  API Base URL    : ${BASE_URL}"
echo "  Started at      : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================================================"
echo ""

# ── Fetch all environments (paginated) ────────────────────────────────────────
echo "▶ Fetching all environments in organization..."
echo "[]" > "$ALL_ENVS_FILE"
OFFSET=0

while true; do
  PAGE=$(api_get "/environments?organizationId=${ORG_ID}&limit=${PAGE_LIMIT}&offset=${OFFSET}")
  PAGE_COUNT=$(echo "$PAGE" | jq 'length')

  if [ "$PAGE_COUNT" -eq 0 ]; then
    break
  fi

  # Merge page into running list
  jq -s 'add' "$ALL_ENVS_FILE" <(echo "$PAGE") > "${ALL_ENVS_FILE}.tmp"
  mv "${ALL_ENVS_FILE}.tmp" "$ALL_ENVS_FILE"

  # If we got fewer than the limit, we've reached the last page
  if [ "$PAGE_COUNT" -lt "$PAGE_LIMIT" ]; then
    break
  fi

  OFFSET=$((OFFSET + PAGE_LIMIT))
done

TOTAL_ENVS=$(jq 'length' "$ALL_ENVS_FILE")
echo "  Found ${TOTAL_ENVS} environment(s) across the organization."
echo ""

if [ "$TOTAL_ENVS" -eq 0 ]; then
  echo "No environments found. Exiting."
  exit 0
fi

# ── Process each environment ──────────────────────────────────────────────────
echo "▶ Checking each environment..."
echo ""

while IFS= read -r env; do
  ENV_ID=$(echo "$env" | jq -r '.id')
  ENV_NAME=$(echo "$env" | jq -r '.name')
  PROJECT_NAME=$(echo "$env" | jq -r '.projectName // "Unknown Project"')
  PROJECT_ID=$(echo "$env" | jq -r '.projectId')

  ENVS_CHECKED=$((ENVS_CHECKED + 1))

  echo "┌─ [${ENVS_CHECKED}/${TOTAL_ENVS}] ${ENV_NAME}"
  echo "│  Project    : ${PROJECT_NAME} (${PROJECT_ID})"
  echo "│  Env ID     : ${ENV_ID}"

  # Fetch recent deployments for this environment
  DEPS=$(api_get "/environments/${ENV_ID}/deployments?limit=20" 2>/dev/null || echo "[]")

  if [ -z "$DEPS" ] || [ "$DEPS" = "null" ] || [ "$DEPS" = "[]" ]; then
    echo "└─ No deployments found. Skipping."
    echo ""
    continue
  fi

  # Filter by status — results are assumed newest-first
  PENDING=$(echo "$DEPS" | jq -c '[.[] | select(.status == "WAITING_FOR_USER")]')
  PENDING_COUNT=$(echo "$PENDING" | jq 'length')

  QUEUED=$(echo "$DEPS" | jq -c '[.[] | select(.status == "QUEUED")]')
  QUEUED_COUNT=$(echo "$QUEUED" | jq 'length')

  echo "│  Pending Approval (WAITING_FOR_USER) : ${PENDING_COUNT}"
  echo "│  Queued (QUEUED)                     : ${QUEUED_COUNT}"

  # ── AND condition: only act if BOTH exist ──────────────────────────────────
  if [ "$PENDING_COUNT" -gt 0 ] && [ "$QUEUED_COUNT" -gt 0 ]; then
    echo "│"
    echo "│  ⚠  BOTH conditions met — taking action"
    ENVS_ACTIONED=$((ENVS_ACTIONED + 1))

    # If more than 1 queued, cancel all except the most recent (index 0 = newest)
    if [ "$QUEUED_COUNT" -gt 1 ]; then
      OLDER_COUNT=$((QUEUED_COUNT - 1))
      echo "│  Found ${QUEUED_COUNT} queued deployments — cancelling ${OLDER_COUNT} older one(s), keeping the most recent"
      while IFS= read -r dep; do
        DEP_ID=$(echo "$dep" | jq -r '.id')
        cancel_deployment "$DEP_ID" "$ENV_NAME" "Older queued deployment — superseded by a more recent queued deployment"
      done < <(echo "$QUEUED" | jq -c '.[1:][]')
    fi

    # Cancel all pending approval deployments
    echo "│  Cancelling ${PENDING_COUNT} pending approval deployment(s)..."
    while IFS= read -r dep; do
      DEP_ID=$(echo "$dep" | jq -r '.id')
      TRIGGERED_BY=$(echo "$dep" | jq -r '.deploymentApprovalPlan.userRequested.name // "unknown"')
      echo "│  Originally approved by: ${TRIGGERED_BY}"
      cancel_deployment "$DEP_ID" "$ENV_NAME" "Pending approval superseded by a newer queued deployment"
    done < <(echo "$PENDING" | jq -c '.[]')

    echo "│"
    echo "└─ ✓ Done. Most recent queued deployment will auto-trigger."

  else
    echo "└─ ✓ No action needed."
  fi

  echo ""

done < <(jq -c '.[]' "$ALL_ENVS_FILE")

# ── Final Summary ─────────────────────────────────────────────────────────────
echo "========================================================================"
echo "  SUMMARY"
echo "========================================================================"
printf "  %-35s %d\n" "Total environments checked:"  "$ENVS_CHECKED"
printf "  %-35s %d\n" "Environments actioned:"       "$ENVS_ACTIONED"
printf "  %-35s %d\n" "Total deployments cancelled:" "$DEPLOYMENTS_CANCELLED"
echo ""

if [ -s "$ACTION_LOG_FILE" ]; then
  echo "  Actions taken:"
  while IFS= read -r line; do
    echo "    • ${line}"
  done < "$ACTION_LOG_FILE"
else
  echo "  No actions were taken — all environments are clean."
fi

echo ""
echo "  Completed at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================================================"
