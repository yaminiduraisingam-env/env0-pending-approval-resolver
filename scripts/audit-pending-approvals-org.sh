#!/bin/bash
# =============================================================================
# env0 Pending Approval Auditor — ORGANIZATION LEVEL (READ-ONLY)
# =============================================================================
# Scans ALL environments across the entire organization and REPORTS which
# ones have BOTH a pending approval (WAITING_FOR_USER) AND a queued
# deployment (QUEUED).
#
# THIS SCRIPT DOES NOT CANCEL OR MODIFY ANYTHING.
# It is purely for auditing before running the real resolver.
#
# Required env vars:
#   ENV0_API_KEY            — Your env0 API key (injected or set manually)
#   ENV0_ORGANIZATION_ID    — Injected automatically by env0
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
BASE_URL="https://api.env0.com"
API_KEY="${ENV0_API_KEY:?ERROR: ENV0_API_KEY is not set}"
ORG_ID="${ENV0_ORGANIZATION_ID:?ERROR: ENV0_ORGANIZATION_ID is not set}"
PAGE_LIMIT=100

# ── Counters ──────────────────────────────────────────────────────────────────
ENVS_CHECKED=0
ENVS_FLAGGED=0
ALL_ENVS_FILE=$(mktemp)

trap 'rm -f "$ALL_ENVS_FILE" "${ALL_ENVS_FILE}.tmp" 2>/dev/null' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────
api_get() {
  curl -sf \
    -H "Accept: application/json" \
    --user "${API_KEY}:" \
    "${BASE_URL}${1}"
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo "========================================================================"
echo "  env0 Pending Approval Auditor — ORGANIZATION LEVEL (READ-ONLY)"
echo "  NO ACTIONS WILL BE TAKEN"
echo "========================================================================"
echo "  Organization ID : ${ORG_ID}"
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

  jq -s 'add' "$ALL_ENVS_FILE" <(echo "$PAGE") > "${ALL_ENVS_FILE}.tmp"
  mv "${ALL_ENVS_FILE}.tmp" "$ALL_ENVS_FILE"

  if [ "$PAGE_COUNT" -lt "$PAGE_LIMIT" ]; then
    break
  fi

  OFFSET=$((OFFSET + PAGE_LIMIT))
done

TOTAL_ENVS=$(jq 'length' "$ALL_ENVS_FILE")
echo "  Found ${TOTAL_ENVS} environment(s). Scanning..."
echo ""

# ── Scan each environment ─────────────────────────────────────────────────────
echo "▶ Environments with BOTH pending approval AND queued deployments:"
echo ""

while IFS= read -r env; do
  ENV_ID=$(echo "$env"   | jq -r '.id')
  ENV_NAME=$(echo "$env" | jq -r '.name')
  PROJ_NAME=$(echo "$env" | jq -r '.projectName // "Unknown Project"')
  PROJ_ID=$(echo "$env"  | jq -r '.projectId')

  ENVS_CHECKED=$((ENVS_CHECKED + 1))

  DEPS=$(api_get "/environments/${ENV_ID}/deployments?limit=20" 2>/dev/null || echo "[]")

  if [ -z "$DEPS" ] || [ "$DEPS" = "null" ] || [ "$DEPS" = "[]" ]; then
    continue
  fi

  PENDING=$(echo "$DEPS" | jq -c '[.[] | select(.status == "WAITING_FOR_USER")]')
  PENDING_COUNT=$(echo "$PENDING" | jq 'length')

  QUEUED=$(echo "$DEPS" | jq -c '[.[] | select(.status == "QUEUED")]')
  QUEUED_COUNT=$(echo "$QUEUED" | jq 'length')

  if [ "$PENDING_COUNT" -gt 0 ] && [ "$QUEUED_COUNT" -gt 0 ]; then
    ENVS_FLAGGED=$((ENVS_FLAGGED + 1))

    echo "  ⚠  ${ENV_NAME}"
    echo "     Project  : ${PROJ_NAME} (${PROJ_ID})"
    echo "     Env ID   : ${ENV_ID}"
    echo ""
    echo "     Pending Approval deployments (${PENDING_COUNT}):"
    while IFS= read -r dep; do
      DEP_ID=$(echo "$dep"      | jq -r '.id')
      CREATED=$(echo "$dep"     | jq -r '.startedAt // "unknown"')
      TRIGGERED=$(echo "$dep"   | jq -r '.deploymentApprovalPlan.userRequested.name // "unknown"')
      echo "       • ID: ${DEP_ID}"
      echo "         Started : ${CREATED}"
      echo "         By      : ${TRIGGERED}"
    done < <(echo "$PENDING" | jq -c '.[]')

    echo ""
    echo "     Queued deployments (${QUEUED_COUNT}):"
    while IFS= read -r dep; do
      DEP_ID=$(echo "$dep"   | jq -r '.id')
      CREATED=$(echo "$dep"  | jq -r '.startedAt // "unknown"')
      echo "       • ID: ${DEP_ID}"
      echo "         Started : ${CREATED}"
    done < <(echo "$QUEUED" | jq -c '.[]')

    echo ""
    echo "     ─────────────────────────────────────────────────────"
    echo ""
  fi

done < <(jq -c '.[]' "$ALL_ENVS_FILE")

# ── Summary ───────────────────────────────────────────────────────────────────
echo "========================================================================"
echo "  AUDIT SUMMARY"
echo "========================================================================"
printf "  %-35s %d\n" "Total environments scanned:" "$ENVS_CHECKED"
printf "  %-35s %d\n" "Environments flagged:"       "$ENVS_FLAGGED"
echo ""

if [ "$ENVS_FLAGGED" -eq 0 ]; then
  echo "  ✓ No environments found with both a pending approval and a queued deployment."
else
  echo "  ⚠  ${ENVS_FLAGGED} environment(s) would be actioned by the resolver."
  echo "     Run check-pending-approvals-org.sh to resolve them."
fi

echo ""
echo "  Completed at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "========================================================================"
