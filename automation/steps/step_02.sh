#!/usr/bin/env bash
# DB RU automation step 02: Prepare or unpack RU script bundle
# Generated production-ready wrapper for AWX/AAP workflow execution.
# Mapping rule: Workflow Extra Vars step_id="02" -> this script.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ru_common.sh
source "${SCRIPT_DIR}/../lib/ru_common.sh"

STEP_NAME="${STEP_NAME:-Step 02 - unzip ru script}"
ru_require_mode
ru_step_begin

case "${RUN_MODE}" in
  mock)
    ru_mock "would unpack RU script bundle from RU_SCRIPT_ARCHIVE if provided"
    ;;
  check)
    # ru_script is the target-host directory that contains the Perl entry scripts shown in ru_play.txt.
    # Default: /u01/patch1930/ru_automation/packages/ru_script
    if [[ -n "${RU_SCRIPT_ARCHIVE:-}" ]]; then ru_check_file "${RU_SCRIPT_ARCHIVE}"; fi
    if [[ -d "$(ru_script_dir)" ]]; then
      ru_check_file "$(ru_script_dir)/${RU_GOLD_IMAGE_SCRIPT:-upgrade_ru_with_gold_image}"
      ru_check_file "$(ru_script_dir)/${RU_OPATCH_SCRIPT:-upgrade_ru_with_opatch}"
      ru_check_file "$(ru_script_dir)/${RU_PATCH_NUMBER_INI:-ru_patch_number.ini}"
      ru_check_file "$(ru_script_dir)/${RU_COMMENTS_PM:-Comments.pm}"
    else
      ru_log "ru_script dir not present yet: $(ru_script_dir)"
    fi
    ;;
  real)
    ru_require_var RU_SCRIPT_ARCHIVE
    ru_check_file "${RU_SCRIPT_ARCHIVE}"
    ru_require_cmd unzip
    stage_dir="${RU_BASE_DIR}/tmp/ru_script_unpack.$$"
    rm -rf "${stage_dir}"
    mkdir -p "${stage_dir}" "$(ru_script_dir)"
    ru_run unzip -oq "${RU_SCRIPT_ARCHIVE}" -d "${stage_dir}"
    if [[ -d "${stage_dir}/ru_script" ]]; then
      cp -a "${stage_dir}/ru_script/." "$(ru_script_dir)/"
    else
      cp -a "${stage_dir}/." "$(ru_script_dir)/"
    fi
    rm -rf "${stage_dir}"
    chmod -R a+rX "$(ru_script_dir)"
    ru_check_file "$(ru_script_dir)/${RU_GOLD_IMAGE_SCRIPT:-upgrade_ru_with_gold_image}"
    ru_check_file "$(ru_script_dir)/${RU_OPATCH_SCRIPT:-upgrade_ru_with_opatch}"
    ru_check_file "$(ru_script_dir)/${RU_PATCH_NUMBER_INI:-ru_patch_number.ini}"
    ru_check_file "$(ru_script_dir)/${RU_COMMENTS_PM:-Comments.pm}"
    ;;
esac

ru_step_end
