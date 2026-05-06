#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/slurm_manager.conf"
OPERATION=""
INPUT_FILE=""
DRY_RUN=false
FORCE_APPROVE=false

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/op_common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/op_add.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/op_remove.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/op_move.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/copy_to_source.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/revert_on_failure.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/scripts/restart_controllers.sh"

usage() {
    cat <<EOF
SLURM Resource Manager (Modular)

Usage:
  $(basename "$0") <operation> [options]

Operations:
  add          Add hosts and partition membership from input file
  remove       Remove hosts and partition membership from input file
  delete       Alias for remove
  move         Move hosts between controllers from input file

Options:
  --input-file <path>   Input file path (default from config: DEFAULT_INPUT_FILE)
  --config <path>       Config file path (default: config/slurm_manager.conf)
  --yes                 Apply changes without confirmation prompt
  --dry-run             Validate + mutate backup workspace only (no source copy/restart)
  -h, --help            Show this help

Input format:
  add/remove:
    <controller> <partition_names|all> <full NodeName/NodeAddr host config line>

  move:
    NodeName=<hostname> NodeAddr=<ip> <source_controller> <target_controller>

Examples:
  $(basename "$0") add --input-file input_add.txt
  $(basename "$0") remove --input-file input_remove.txt
  $(basename "$0") move --input-file input_move.txt
  $(basename "$0") add --config ./config/slurm_manager.conf --yes
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            add|remove|delete|move)
                if [[ -n "${OPERATION}" ]]; then
                    error_exit "Only one operation is allowed per run"
                fi
                OPERATION="$1"
                shift
                ;;
            --input-file)
                [[ $# -ge 2 ]] || error_exit "--input-file requires a value"
                INPUT_FILE="$2"
                shift 2
                ;;
            --config)
                [[ $# -ge 2 ]] || error_exit "--config requires a value"
                CONFIG_FILE="$2"
                shift 2
                ;;
            --yes)
                FORCE_APPROVE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error_exit "Unknown argument: $1 (use --help)"
                ;;
        esac
    done

    [[ -n "${OPERATION}" ]] || error_exit "Operation is required (add/remove/move)"
    [[ "${OPERATION}" == "delete" ]] && OPERATION="remove"
}

create_dual_backup() {
    local run_stamp day_stamp run_dir
    day_stamp="$(date '+%Y%m%d')"
    run_stamp="$(date '+%H%M%S')"
    run_dir="${BACKUP_BASE_DIR}/${day_stamp}"

    ORIGINAL_BACKUP_DIR="${run_dir}/slurm-backup-main-${run_stamp}"
    WORKING_BACKUP_DIR="${run_dir}/slurm-backup-edited-${run_stamp}"

    mkdir -p "${ORIGINAL_BACKUP_DIR}" "${WORKING_BACKUP_DIR}"

    local controller
    for controller in $(get_controllers); do
        local source_dir="${SLURM_BASE_DIR}/${controller}"
        local main_target="${ORIGINAL_BACKUP_DIR}/${controller}"
        local work_target="${WORKING_BACKUP_DIR}/${controller}"
        mkdir -p "${main_target}" "${work_target}"

        if [[ -d "${source_dir}" ]]; then
            cp -r "${source_dir}"/* "${main_target}/" 2>/dev/null || true
            cp -r "${source_dir}"/* "${work_target}/" 2>/dev/null || true
        else
            log "WARNING" "Source controller dir missing: ${source_dir}"
        fi
    done

    if [[ -f "${INPUT_FILE}" ]]; then
        cp "${INPUT_FILE}" "${run_dir}/input_${OPERATION}_${run_stamp}.log" 2>/dev/null || true
    fi
}

run_operation_module() {
    case "${OPERATION}" in
        add) run_add_operations "${INPUT_FILE}" "${WORKING_BACKUP_DIR}" ;;
        remove) run_remove_operations "${INPUT_FILE}" "${WORKING_BACKUP_DIR}" ;;
        move) run_move_operations "${INPUT_FILE}" "${WORKING_BACKUP_DIR}" ;;
        *) error_exit "Unsupported operation: ${OPERATION}" ;;
    esac
}

main() {
    parse_args "$@"

    CONFIG_FILE="$(to_abs_path "${CONFIG_FILE}")"
    load_config "${CONFIG_FILE}"
    initialize_runtime

    if [[ -z "${INPUT_FILE}" ]]; then
        INPUT_FILE="$(to_abs_path "${DEFAULT_INPUT_FILE}")"
    elif [[ "${INPUT_FILE}" != /* ]]; then
        INPUT_FILE="$(to_abs_path "${INPUT_FILE}")"
    fi

    [[ -f "${INPUT_FILE}" ]] || error_exit "Input file not found: ${INPUT_FILE}"
    [[ -d "${SLURM_BASE_DIR}" ]] || error_exit "SLURM_BASE_DIR not found: ${SLURM_BASE_DIR}"

    if [[ "${FORCE_APPROVE}" == "true" ]]; then
        AUTO_APPROVE=true
    fi

    log "INFO" "Starting operation: ${OPERATION}"
    log "INFO" "Config: ${CONFIG_FILE}"
    log "INFO" "Input: ${INPUT_FILE}"
    log "INFO" "SLURM_BASE_DIR: ${SLURM_BASE_DIR}"

    create_dual_backup
    log "INFO" "Original backup: ${ORIGINAL_BACKUP_DIR}"
    log "INFO" "Working backup:  ${WORKING_BACKUP_DIR}"
    log "LINE"

    run_operation_module

    log "INFO" "Operation phase complete: total=${TOTAL_OPERATIONS}, failed=${FAILED_OPERATIONS}"
    if [[ "${TOTAL_OPERATIONS}" -eq 0 ]]; then
        error_exit "No operations were parsed from input file"
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "WARNING" "Dry-run enabled. No source copy/restart executed."
        log "INFO" "Review working backup at: ${WORKING_BACKUP_DIR}"
        exit 0
    fi

    if ! prompt_apply_confirmation; then
        log "WARNING" "User skipped apply step. Changes remain in backup only."
        exit 0
    fi

    apply_changes_to_source "${WORKING_BACKUP_DIR}" "${ORIGINAL_BACKUP_DIR}"

    if [[ -n "${COPIED_CONTROLLERS}" ]]; then
        restart_controllers "${COPIED_CONTROLLERS}" "${ORIGINAL_BACKUP_DIR}"
    else
        log "INFO" "No source files changed. Restart skipped."
    fi

    log "SUCCESS" "Run completed."
}

main "$@"
