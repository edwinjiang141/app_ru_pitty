#!/usr/bin/env bash
# DB RU automation step 09: Unpack gold image on target nodes
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="09" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 09 - unzip goldimage}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would unpack GOLD_IMAGE_ARCHIVE to GOLD_IMAGE_DIR"
    ;;
  check)
    [[ -n "${GOLD_IMAGE_ARCHIVE:-}" ]] && ru_check_file "${GOLD_IMAGE_ARCHIVE}" || ru_log "GOLD_IMAGE_ARCHIVE not set"
    ;;
  real)
    ru_require_var GOLD_IMAGE_ARCHIVE
    ru_require_var GOLD_IMAGE_DIR
    ru_check_file "${GOLD_IMAGE_ARCHIVE}"
    mkdir -p "${GOLD_IMAGE_DIR}"
    ru_require_cmd unzip
    ru_run unzip -oq "${GOLD_IMAGE_ARCHIVE}" -d "${GOLD_IMAGE_DIR}"
    ;;
esac

ru_step_end
