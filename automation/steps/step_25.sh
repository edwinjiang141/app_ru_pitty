#!/usr/bin/env bash
# DB RU automation step 25: Clean Oracle Home intermediate backup
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="25" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 25 - clean oracle backup home}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would clean Oracle backup home ${ORACLE_BACKUP_HOME:-<unset>}"
    ;;
  check)
    if [[ -n "${ORACLE_BACKUP_HOME:-}" ]]; then ru_assert_safe_path "${ORACLE_BACKUP_HOME}"; fi
    ;;
  real)
    ru_require_destructive_allowed
    ru_require_var ORACLE_BACKUP_HOME
    ru_assert_safe_path "${ORACLE_BACKUP_HOME}"
    [[ "${ORACLE_BACKUP_HOME}" == *backup* || "${ORACLE_BACKUP_HOME}" == *bak* ]] || ru_fail "ORACLE_BACKUP_HOME must look like backup path" 9
    rm -rf --one-file-system "${ORACLE_BACKUP_HOME}"
    ;;
esac

ru_step_end
