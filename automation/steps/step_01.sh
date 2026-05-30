#!/usr/bin/env bash
# DB RU automation step 01: Create backup and automation runtime directories
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="01" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 01 - create backup dir}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "create runtime directories under ${RU_BASE_DIR}"
    mkdir -p "${RU_BASE_DIR}"/{logs,state,reports,tmp,packages}
    ru_write_kv_report "${RU_BASE_DIR}/reports/step_01_mock.txt" "action=create_dirs"
    ;;
  check)
    mkdir -p "${RU_BASE_DIR}"/{logs,state,reports,tmp,packages}
    ru_check_file "${RU_BASE_DIR}/logs"
    ru_check_file "${RU_BASE_DIR}/state"
    ru_check_file "${RU_BASE_DIR}/reports"
    ;;
  real)
    mkdir -p "${RU_BASE_DIR}"/{logs,state,reports,tmp,packages}
    chmod 750 "${RU_BASE_DIR}" "${RU_BASE_DIR}"/{logs,state,reports,tmp,packages}
    ru_write_kv_report "${RU_BASE_DIR}/reports/step_01_real.txt" "action=create_dirs"
    ;;
esac

ru_step_end
