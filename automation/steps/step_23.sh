#!/usr/bin/env bash
# DB RU automation step 23: Restore Grid Home symlink
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="23" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 23 - restore grid symlink}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would restore Grid symlink from saved state"
    ;;
  check)
    ru_check_file "${RU_BASE_DIR}/state/grid_home_link.before" || true
    ;;
  real)
    ru_require_var GRID_HOME_LINK
    ru_check_file "${RU_BASE_DIR}/state/grid_home_link.before"
    target="$(cat "${RU_BASE_DIR}/state/grid_home_link.before")"
    ru_check_file "${target}"
    ln -sfn "${target}" "${GRID_HOME_LINK}"
    ;;
esac

ru_step_end
