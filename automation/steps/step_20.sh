#!/usr/bin/env bash
# DB RU automation step 20: Run datapatch
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="20" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 20 - datapatch}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would run datapatch"
    ;;
  check)
    if command -v datapatch >/dev/null 2>&1; then datapatch -verbose -prereq || true; else ru_log "datapatch not found in PATH"; fi
    ;;
  real)
    ru_require_destructive_allowed
    if [[ -n "${DATAPATCH_CMD:-}" ]]; then ru_run_bash "${DATAPATCH_CMD}"; else ru_require_cmd datapatch; ru_run datapatch -verbose; fi
    ;;
esac

ru_step_end
