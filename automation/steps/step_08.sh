#!/usr/bin/env bash
# DB RU automation step 08: Save CRS status before upgrade
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="08" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 08 - save crs status}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would collect CRS status"
    ;;
  check)
    if command -v crsctl >/dev/null 2>&1; then crsctl status resource -t || true; else ru_log "crsctl not found in PATH"; fi
    ;;
  real)
    ru_require_cmd crsctl
    crsctl status resource -t | tee "${RU_BASE_DIR}/state/crs_status.before"
    ;;
esac

ru_step_end
