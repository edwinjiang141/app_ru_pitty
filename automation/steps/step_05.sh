#!/usr/bin/env bash
# DB RU automation step 05: Backup current Oracle/Grid environment
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="05" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 05 - backup current home}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would backup current home from BACKUP_SOURCE to BACKUP_DEST"
    ;;
  check)
    if [[ -n "${BACKUP_SOURCE:-}" ]]; then ru_check_file "${BACKUP_SOURCE}"; fi
    if [[ -n "${BACKUP_DEST:-}" ]]; then mkdir -p "${BACKUP_DEST}"; fi
    ;;
  real)
    ru_require_var BACKUP_SOURCE
    ru_require_var BACKUP_DEST
    ru_check_file "${BACKUP_SOURCE}"
    mkdir -p "${BACKUP_DEST}"
    if command -v rsync >/dev/null 2>&1; then ru_run rsync -aH --delete "${BACKUP_SOURCE}/" "${BACKUP_DEST}/"; else ru_run cp -a "${BACKUP_SOURCE}" "${BACKUP_DEST}/"; fi
    ;;
esac

ru_step_end
