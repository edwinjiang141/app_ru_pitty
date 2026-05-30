#!/usr/bin/env bash
# DB RU automation step 10: Run pre-upgrade database checks
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="10" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 10 - pre db check}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would run pre-upgrade DB checks"
    ;;
  check)
    if [[ -n "${PRE_DB_CHECK_CMD:-}" ]]; then ru_log "PRE_DB_CHECK_CMD configured"; else ru_log "no PRE_DB_CHECK_CMD; use real site sqlplus/srvctl checks later"; fi
    ;;
  real)
    ru_require_var PRE_DB_CHECK_CMD
    ru_run_bash "${PRE_DB_CHECK_CMD}"
    ;;
esac

ru_step_end
