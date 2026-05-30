#!/usr/bin/env bash
# DB RU automation step 22: Restore Oracle Home symlink
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="22" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 22 - restore oracle symlink}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would restore Oracle symlink from saved state"
    ;;
  check)
    ru_check_file "${RU_BASE_DIR}/state/oracle_home_link.before" || true
    ;;
  real)
    ru_require_var ORACLE_HOME_LINK
    ru_check_file "${RU_BASE_DIR}/state/oracle_home_link.before"
    target="$(cat "${RU_BASE_DIR}/state/oracle_home_link.before")"
    ru_check_file "${target}"
    ln -sfn "${target}" "${ORACLE_HOME_LINK}"
    ;;
esac

ru_step_end
