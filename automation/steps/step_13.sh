#!/usr/bin/env bash
# DB RU automation step 13: Start node2 database instance
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="13" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 13 - start node2 instance}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would start node2 instance ${NODE2_INSTANCE:-<inst>}"
    ;;
  check)
    if command -v srvctl >/dev/null 2>&1 && [[ -n "${DB_UNIQUE_NAME:-}" ]]; then srvctl status database -d "${DB_UNIQUE_NAME}" || true; else ru_log "srvctl or DB_UNIQUE_NAME unavailable"; fi
    ;;
  real)
    ru_require_var DB_UNIQUE_NAME
    ru_require_var NODE2_INSTANCE
    ru_require_cmd srvctl
    ru_run srvctl start instance -d "${DB_UNIQUE_NAME}" -i "${NODE2_INSTANCE}"
    ;;
esac

ru_step_end
