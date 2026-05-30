#!/usr/bin/env bash
# DB RU automation step 07: Save Oracle Home symlink state
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="07" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 07 - save oracle symlink}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would save Oracle Home symlink ${ORACLE_HOME_LINK:-<unset>}"
    ;;
  check)
    [[ -n "${ORACLE_HOME_LINK:-}" ]] && ls -ld "${ORACLE_HOME_LINK}" || ru_log "ORACLE_HOME_LINK not set"
    ;;
  real)
    ru_require_var ORACLE_HOME_LINK
    ru_check_file "${ORACLE_HOME_LINK}"
    readlink -f "${ORACLE_HOME_LINK}" > "${RU_BASE_DIR}/state/oracle_home_link.before"
    ;;
esac

ru_step_end
