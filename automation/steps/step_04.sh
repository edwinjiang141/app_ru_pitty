#!/usr/bin/env bash
# DB RU automation step 04: Run DB RU precheck
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="04" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 04 - precheck}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would run precheck command PRECHECK_CMD or standard environment checks"
    ;;
  check)
    ru_require_cmd hostname
    ru_require_cmd df
    df -h /u01 || true
    if [[ -n "${PRECHECK_CMD:-}" ]]; then ru_log "PRECHECK_CMD configured: ${PRECHECK_CMD}"; fi
    ;;
  real)
    if [[ -n "${PRECHECK_CMD:-}" ]]; then ru_run_bash "${PRECHECK_CMD}"; else ru_fail "PRECHECK_CMD is required for real precheck" 2; fi
    ;;
esac

ru_step_end
