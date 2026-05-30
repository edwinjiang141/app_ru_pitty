#!/usr/bin/env bash
# DB RU automation step 21: Restore database job parameter
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="21" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 21 - restore job param}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would restore job parameter"
    ;;
  check)
    ru_log "check-only: RESTORE_JOB_PARAM_CMD=${RESTORE_JOB_PARAM_CMD:-<unset>}"
    ;;
  real)
    if [[ -n "${RESTORE_JOB_PARAM_CMD:-}" ]]; then ru_run_bash "${RESTORE_JOB_PARAM_CMD}"; else ru_fail "RESTORE_JOB_PARAM_CMD required for real mode" 2; fi
    ;;
esac

ru_step_end
