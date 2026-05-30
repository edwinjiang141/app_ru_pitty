#!/usr/bin/env bash
# DB RU automation step 06: Save Grid Home symlink state
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="06" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 06 - save grid symlink}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would save Grid Home symlink ${GRID_HOME_LINK:-<unset>}"
    ;;
  check)
    [[ -n "${GRID_HOME_LINK:-}" ]] && ls -ld "${GRID_HOME_LINK}" || ru_log "GRID_HOME_LINK not set"
    ;;
  real)
    ru_require_var GRID_HOME_LINK
    ru_check_file "${GRID_HOME_LINK}"
    readlink -f "${GRID_HOME_LINK}" > "${RU_BASE_DIR}/state/grid_home_link.before"
    ;;
esac

ru_step_end
