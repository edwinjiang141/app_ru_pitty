#!/usr/bin/env bash
# DB RU automation step 27: Compare final CRS status with baseline
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="27" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 27 - compare crs status}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would compare CRS status before/after"
    ;;
  check)
    if command -v crsctl >/dev/null 2>&1; then crsctl status resource -t | tee "${RU_BASE_DIR}/state/crs_status.current"; else ru_log "crsctl not found"; fi
    ;;
  real)
    ru_require_cmd crsctl
    crsctl status resource -t | tee "${RU_BASE_DIR}/state/crs_status.after"
    if [[ -f "${RU_BASE_DIR}/state/crs_status.before" ]]; then diff -u "${RU_BASE_DIR}/state/crs_status.before" "${RU_BASE_DIR}/state/crs_status.after" || ru_log "CRS status has differences; review required"; else ru_fail "baseline CRS status file missing" 3; fi
    ;;
esac

ru_step_end
