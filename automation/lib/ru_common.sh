#!/usr/bin/env bash
# Common helpers for AWX/AAP DB RU step scripts.
# This file is sourced by steps/step_*.sh.
#
# The generic target-host runner exports values that originate from:
# - AWX Workflow/Job Template Extra Vars for fixed node inputs such as STEP_ID,
#   STEP_NAME, RUN_MODE, ALLOW_DESTRUCTIVE_STEP, and APPROVAL_REPORT_REQUIRED.
# - Optional target-host conf/ru_env.conf for per-change inputs such as CHANGE_ID,
#   backup paths, RU package paths, Oracle/Grid links, and site commands.
#
# The defaults below are only safe fallbacks for local/mock execution. In AWX runs
# they should already be set by ru_step_runner.sh before this file is sourced.

set -Eeuo pipefail

: "${RU_BASE_DIR:=/u01/patch1930/ru_automation}"
: "${STEP_ID:=unknown}"
: "${STEP_NAME:=step_${STEP_ID}}"
: "${RUN_MODE:=mock}"
: "${CHANGE_ID:=UNKNOWN_CHANGE}"
: "${ALLOW_DESTRUCTIVE_STEP:=false}"
: "${LOG_FILE:=${RU_BASE_DIR}/logs/step_${STEP_ID}.log}"

ru_ts() { date -Is; }

ru_log() {
  printf '[%s] [step=%s] [mode=%s] %s\n' "$(ru_ts)" "${STEP_ID}" "${RUN_MODE}" "$*"
}

ru_fail() {
  local rc="${2:-1}"
  ru_log "ERROR: $1"
  exit "${rc}"
}

ru_on_error() {
  local rc=$?
  ru_log "ERROR: command failed at line ${BASH_LINENO[0]} with rc=${rc}: ${BASH_COMMAND}"
  exit "${rc}"
}
trap ru_on_error ERR

ru_step_begin() {
  mkdir -p "${RU_BASE_DIR}/logs" "${RU_BASE_DIR}/state" "${RU_BASE_DIR}/reports" "${RU_BASE_DIR}/tmp"
  ru_log "BEGIN ${STEP_NAME}"
  ru_log "change_id=${CHANGE_ID} host=$(hostname) user=$(whoami) pwd=$(pwd)"
}

ru_step_end() {
  ru_log "END ${STEP_NAME}"
}

ru_require_mode() {
  case "${RUN_MODE}" in
    mock|check|real) ;;
    *) ru_fail "unsupported RUN_MODE=${RUN_MODE}; expected mock/check/real" 2 ;;
  esac
}

ru_is_true() {
  case "${1:-}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

ru_require_destructive_allowed() {
  if [[ "${RUN_MODE}" == "real" ]] && ! ru_is_true "${ALLOW_DESTRUCTIVE_STEP}"; then
    ru_fail "destructive real step requires ALLOW_DESTRUCTIVE_STEP=true" 9
  fi
}

ru_require_var() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "${value}" ]] || ru_fail "required variable ${name} is empty" 2
}

ru_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || ru_fail "required command not found: $1" 127
}

ru_run() {
  ru_log "RUN: $*"
  "$@"
}

ru_run_bash() {
  local cmd="$1"
  ru_log "RUN: ${cmd}"
  bash -lc "${cmd}"
}

ru_script_dir() {
  printf '%s\n' "${RU_SCRIPT_DIR:-${RU_BASE_DIR}/packages/ru_script}"
}

ru_require_ru_script_file() {
  local script_name="$1"
  local script_path="$(ru_script_dir)/${script_name}"
  [[ -f "${script_path}" ]] || ru_fail "required ru_script file does not exist: ${script_path}" 3
  printf '%s\n' "${script_path}"
}

ru_run_perl_script() {
  local script_name="$1"
  shift || true
  ru_require_cmd perl
  local script_path
  script_path="$(ru_require_ru_script_file "${script_name}")"
  ru_log "RUN: perl ${script_path} $*"
  perl "${script_path}" "$@"
}

ru_mock() {
  ru_log "MOCK: $*"
}

ru_check_file() {
  local path="$1"
  [[ -e "${path}" ]] || ru_fail "required path does not exist: ${path}" 3
  ru_log "verified path exists: ${path}"
}

ru_assert_safe_path() {
  local path="$1"
  [[ -n "${path}" ]] || ru_fail "safe path check failed: empty path" 9
  [[ "${path}" == /* ]] || ru_fail "safe path check failed: not absolute: ${path}" 9
  case "${path}" in
    /|/u01|/u01/|/tmp|/tmp/|/var|/var/|/home|/home/|/opt|/opt/)
      ru_fail "safe path check failed: path too broad: ${path}" 9
      ;;
  esac
}

ru_write_kv_report() {
  local file="$1"
  shift
  mkdir -p "$(dirname "${file}")"
  {
    printf 'step_id=%s\n' "${STEP_ID}"
    printf 'step_name=%s\n' "${STEP_NAME}"
    printf 'run_mode=%s\n' "${RUN_MODE}"
    printf 'change_id=%s\n' "${CHANGE_ID}"
    printf 'host=%s\n' "$(hostname)"
    printf 'user=%s\n' "$(whoami)"
    printf 'timestamp=%s\n' "$(ru_ts)"
    printf '%s\n' "$@"
  } > "${file}"
  ru_log "wrote report: ${file}"
}
