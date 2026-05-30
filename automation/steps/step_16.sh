#!/usr/bin/env bash
# DB RU automation step 16: Switch node1 Oracle Home to gold image
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="16" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 16 - switch node1 home}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would switch node1 home to ${NEW_ORACLE_HOME:-<unset>}"
    ;;
  check)
    [[ -n "${NEW_ORACLE_HOME:-}" ]] && ru_check_file "${NEW_ORACLE_HOME}" || ru_log "NEW_ORACLE_HOME not set"
    ;;
  real)
    ru_require_destructive_allowed
    # Prefer an explicit site-reviewed command from AWX Extra Vars/env.
    # If it is not provided, call the ru_script Perl entry point staged by Step 02.
    if [[ -n "${SWITCH_NODE1_HOME_CMD:-}" ]]; then
      ru_run_bash "${SWITCH_NODE1_HOME_CMD}"
    else
      ru_run_perl_script "${RU_GOLD_IMAGE_SCRIPT:-upgrade_ru_with_gold_image}" "node1"
    fi
    ;;
esac

ru_step_end
