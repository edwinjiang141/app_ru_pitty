#!/usr/bin/env bash
# DB RU automation step 14: Check node2 after switch
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="14" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 14 - check node2}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would check node2 instance status"
    ;;
  check)
    if command -v srvctl >/dev/null 2>&1 && [[ -n "${DB_UNIQUE_NAME:-}" ]]; then srvctl status database -d "${DB_UNIQUE_NAME}" || true; else ru_log "srvctl or DB_UNIQUE_NAME unavailable"; fi
    ;;
  real)
    if [[ -n "${CHECK_NODE2_CMD:-}" ]]; then ru_run_bash "${CHECK_NODE2_CMD}"; else ru_fail "CHECK_NODE2_CMD required for real mode" 2; fi
    ;;
esac

ru_step_end
