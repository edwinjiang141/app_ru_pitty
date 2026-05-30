#!/usr/bin/env bash
# DB RU automation step 19: Set database job queue/process parameter to zero
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="19" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 19 - set job zero}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would set job parameter to zero"
    ;;
  check)
    ru_log "check-only: verify planned job parameter change; SET_JOB_ZERO_CMD=${SET_JOB_ZERO_CMD:-<unset>}"
    ;;
  real)
    if [[ -n "${SET_JOB_ZERO_CMD:-}" ]]; then ru_run_bash "${SET_JOB_ZERO_CMD}"; else ru_fail "SET_JOB_ZERO_CMD required for real mode" 2; fi
    ;;
esac

ru_step_end
