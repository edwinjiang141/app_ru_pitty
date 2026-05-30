#!/usr/bin/env bash
# DB RU automation step 03: Clean previous temporary image data
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="03" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 03 - clean old image}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would clean old image path: ${OLD_IMAGE_DIR:-<unset>}"
    ;;
  check)
    if [[ -n "${OLD_IMAGE_DIR:-}" ]]; then ru_assert_safe_path "${OLD_IMAGE_DIR}"; ru_log "safe cleanup candidate: ${OLD_IMAGE_DIR}"; else ru_log "OLD_IMAGE_DIR not set; no cleanup candidate"; fi
    ;;
  real)
    ru_require_destructive_allowed
    ru_require_var OLD_IMAGE_DIR
    ru_assert_safe_path "${OLD_IMAGE_DIR}"
    [[ "${OLD_IMAGE_DIR}" == *gold* || "${OLD_IMAGE_DIR}" == *image* || "${OLD_IMAGE_DIR}" == *patch* ]] || ru_fail "OLD_IMAGE_DIR must contain gold/image/patch for safety: ${OLD_IMAGE_DIR}" 9
    rm -rf --one-file-system "${OLD_IMAGE_DIR}"
    ru_log "removed OLD_IMAGE_DIR=${OLD_IMAGE_DIR}"
    ;;
esac

ru_step_end
