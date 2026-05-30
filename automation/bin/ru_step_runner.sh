#!/usr/bin/env bash
# Generic target-host runner for AWX/AAP DB RU workflow steps.
#
# Data flow:
#   AWX Workflow/Job Template Extra Vars -> run_ru_step.yml -> this runner args
#   target-host ru_env.conf -> this runner environment -> step_*.sh / ru_common.sh
#
# Precedence:
#   1. Built-in safe defaults in this runner.
#   2. Optional target-host env file: /u01/patch1930/ru_automation/conf/ru_env.conf.
#   3. Non-empty CLI args from AWX run_ru_step.yml override the env file.
#
# This means fixed per-node values such as step_id and step_name should stay in
# AWX node Extra Vars, while per-change values such as CHANGE_ID and backup paths
# can be edited in ru_env.conf before the change window.

set -Eeuo pipefail

RU_BASE_DIR="${RU_BASE_DIR:-/u01/patch1930/ru_automation}"
ENV_FILE=""
STEP_ID="${STEP_ID:-}"
STEP_NAME="${STEP_NAME:-}"
RUN_MODE="${RUN_MODE:-mock}"
PLATFORM_MODE="${PLATFORM_MODE:-awx_test}"
CHANGE_ID="${CHANGE_ID:-UNKNOWN_CHANGE}"
ALLOW_DESTRUCTIVE_STEP="${ALLOW_DESTRUCTIVE_STEP:-false}"
APPROVAL_REPORT_REQUIRED="${APPROVAL_REPORT_REQUIRED:-true}"

usage() {
  cat <<'USAGE'
Usage: ru_step_runner.sh --step-id <id> [options]

Required fixed AWX node arguments:
  --step-id <id>                       Workflow step id, for example 01 or 05A.

Optional AWX node arguments:
  --step-name <name>                   Human-readable step name for logs.
  --run-mode <mock|check|real>         Execution mode. Default: mock.
  --platform-mode <name>               Platform marker, for example awx_test.
  --allow-destructive-step <bool>      Required as true for real destructive steps.
  --approval-report-required <bool>    Marker used by summary/approval steps.
  --change-id <id>                     Change id. Prefer ru_env.conf for per-change use.
  --ru-base-dir <path>                 Target-host automation base dir.
  --env-file <path>                    Optional env file. Default: RU_BASE_DIR/conf/ru_env.conf.
USAGE
}

# Pre-scan only the path controls so the env file can be loaded before normal args.
args=("$@")
i=0
while [[ ${i} -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --ru-base-dir)
      (( i + 1 < ${#args[@]} )) || { echo "ERROR: --ru-base-dir requires value" >&2; exit 2; }
      RU_BASE_DIR="${args[$((i+1))]}"
      i=$((i+2))
      ;;
    --env-file)
      (( i + 1 < ${#args[@]} )) || { echo "ERROR: --env-file requires value" >&2; exit 2; }
      ENV_FILE="${args[$((i+1))]}"
      i=$((i+2))
      ;;
    *)
      i=$((i+1))
      ;;
  esac
done

if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="${RU_BASE_DIR}/conf/ru_env.conf"
fi

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

# After sourcing ru_env.conf, parse all AWX-supplied args. Empty values are ignored
# so optional playbook args do not accidentally erase per-change values from env file.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --step-id) [[ -n "${2:-}" ]] && STEP_ID="$2"; shift 2 ;;
    --step-name) [[ -n "${2:-}" ]] && STEP_NAME="$2"; shift 2 ;;
    --run-mode) [[ -n "${2:-}" ]] && RUN_MODE="$2"; shift 2 ;;
    --platform-mode) [[ -n "${2:-}" ]] && PLATFORM_MODE="$2"; shift 2 ;;
    --change-id) [[ -n "${2:-}" ]] && CHANGE_ID="$2"; shift 2 ;;
    --allow-destructive-step) [[ -n "${2:-}" ]] && ALLOW_DESTRUCTIVE_STEP="$2"; shift 2 ;;
    --approval-report-required) [[ -n "${2:-}" ]] && APPROVAL_REPORT_REQUIRED="$2"; shift 2 ;;
    --ru-base-dir) [[ -n "${2:-}" ]] && RU_BASE_DIR="$2"; shift 2 ;;
    --env-file) shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RUN_MODE="${RUN_MODE:-mock}"
PLATFORM_MODE="${PLATFORM_MODE:-awx_test}"
CHANGE_ID="${CHANGE_ID:-UNKNOWN_CHANGE}"
ALLOW_DESTRUCTIVE_STEP="${ALLOW_DESTRUCTIVE_STEP:-false}"
APPROVAL_REPORT_REQUIRED="${APPROVAL_REPORT_REQUIRED:-true}"

if [[ -z "${STEP_ID}" ]]; then
  echo "ERROR: --step-id is required; it should come from AWX workflow node Extra Vars" >&2
  exit 2
fi

case "${STEP_ID}" in
  00|01|02|03|04|05|05A|06|07|08|09|10|10A|11|12|13|14|14A|15|16|17|18|18A|19|19A|20|21|22|23|24|24A|25|26|27|99) ;;
  *) echo "ERROR: unsupported step id: ${STEP_ID}" >&2; exit 2 ;;
esac

if [[ -z "${STEP_NAME}" ]]; then
  STEP_NAME="step_${STEP_ID}"
fi

mkdir -p "${RU_BASE_DIR}"/{logs,state,reports,tmp}
TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_FILE:-${RU_BASE_DIR}/logs/step_${STEP_ID}_${TS}.log}"
RESULT_FILE="${RESULT_FILE:-${RU_BASE_DIR}/state/step_${STEP_ID}_result.json}"
DONE_FILE="${RU_BASE_DIR}/state/step_${STEP_ID}.done"
FAILED_FILE="${RU_BASE_DIR}/state/step_${STEP_ID}.failed"
SCRIPT_FILE="${RU_BASE_DIR}/steps/step_${STEP_ID}.sh"

is_true() {
  case "${1:-}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

DESTRUCTIVE_STEPS="03 11 12 15 16 20 25 26"
if [[ " ${DESTRUCTIVE_STEPS} " == *" ${STEP_ID} "* ]]; then
  if [[ "${RUN_MODE}" == "real" ]] && ! is_true "${ALLOW_DESTRUCTIVE_STEP}"; then
    echo "ERROR: step ${STEP_ID} is destructive; allow_destructive_step=true is required in real mode" | tee -a "${LOG_FILE}"
    exit 9
  fi
fi

if [[ ! -x "${SCRIPT_FILE}" ]]; then
  echo "ERROR: script not found or not executable: ${SCRIPT_FILE}" | tee -a "${LOG_FILE}"
  exit 3
fi

export RU_BASE_DIR STEP_ID STEP_NAME RUN_MODE PLATFORM_MODE CHANGE_ID ALLOW_DESTRUCTIVE_STEP APPROVAL_REPORT_REQUIRED LOG_FILE RESULT_FILE

set +e
{
  echo "===== DB RU STEP START ====="
  echo "timestamp=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "whoami=$(whoami)"
  echo "ru_base_dir=${RU_BASE_DIR}"
  echo "env_file=${ENV_FILE}"
  echo "step_id=${STEP_ID}"
  echo "step_name=${STEP_NAME}"
  echo "run_mode=${RUN_MODE}"
  echo "platform_mode=${PLATFORM_MODE}"
  echo "change_id=${CHANGE_ID}"
  echo "allow_destructive_step=${ALLOW_DESTRUCTIVE_STEP}"
  echo "approval_report_required=${APPROVAL_REPORT_REQUIRED}"
  echo "script_file=${SCRIPT_FILE}"
  echo "log_file=${LOG_FILE}"
  echo "================================"
  "${SCRIPT_FILE}"
  rc=$?
  echo "step_rc=${rc}"
  exit "${rc}"
} 2>&1 | tee -a "${LOG_FILE}"
RC=${PIPESTATUS[0]}
set -e

if [[ ${RC} -eq 0 ]]; then
  rm -f "${FAILED_FILE}"
  touch "${DONE_FILE}"
  STATUS="success"
else
  rm -f "${DONE_FILE}"
  touch "${FAILED_FILE}"
  STATUS="failed"
fi

cat > "${RESULT_FILE}" <<EOF_JSON
{
  "step_id": "${STEP_ID}",
  "step_name": "${STEP_NAME}",
  "status": "${STATUS}",
  "rc": ${RC},
  "run_mode": "${RUN_MODE}",
  "platform_mode": "${PLATFORM_MODE}",
  "change_id": "${CHANGE_ID}",
  "host": "$(hostname)",
  "user": "$(whoami)",
  "env_file": "${ENV_FILE}",
  "script_file": "${SCRIPT_FILE}",
  "log_file": "${LOG_FILE}",
  "timestamp": "$(date -Is)"
}
EOF_JSON

cat "${RESULT_FILE}"
exit "${RC}"
