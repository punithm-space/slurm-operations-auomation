#!/usr/bin/env bash

# Shared runtime utilities for SLURM manager modules.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_OPERATIONS=0
FAILED_OPERATIONS=0
COPIED_CONTROLLERS=""

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S')"
    local logfile="${LOG_DIR}/slurm-manager-$(date '+%Y-%m-%d').log"
    mkdir -p "${LOG_DIR}"

    case "${level}" in
        INFO) echo -e "[${ts}] ${BLUE}[INFO]${NC} ${msg}" | tee -a "${logfile}" ;;
        SUCCESS) echo -e "[${ts}] ${GREEN}[SUCCESS]${NC} ${msg}" | tee -a "${logfile}" ;;
        WARNING) echo -e "[${ts}] ${YELLOW}[WARNING]${NC} ${msg}" | tee -a "${logfile}" ;;
        ERROR) echo -e "[${ts}] ${RED}[ERROR]${NC} ${msg}" | tee -a "${logfile}" ;;
        LINE) echo "--------------------------------------------------------------------------------" | tee -a "${logfile}" ;;
        *) echo -e "[${ts}] ${msg}" | tee -a "${logfile}" ;;
    esac
}

error_exit() {
    log "ERROR" "$*"
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "${value}"
}

to_abs_path() {
    local path="$1"
    if [[ "${path}" = /* ]]; then
        printf "%s" "${path}"
    else
        printf "%s/%s" "${SCRIPT_DIR}" "${path}"
    fi
}

load_config() {
    local config_file="$1"
    if [[ ! -f "${config_file}" ]]; then
        error_exit "Config file not found: ${config_file}"
    fi

    set -a
    # shellcheck disable=SC1090
    source "${config_file}"
    set +a
}

initialize_runtime() {
    : "${CONTROLLER_PREFIX:=slurm}"
    : "${MAX_CONTROLLERS:=4}"
    : "${DEFAULT_INPUT_FILE:=input_data}"
    : "${BACKUP_BASE_DIR:=backups}"
    : "${LOG_DIR:=logs}"
    : "${RESTART_STABILIZE_SECONDS:=5}"
    : "${ENABLE_ANSIBLE_SYNC:=false}"
    : "${AUTO_APPROVE:=false}"

    BACKUP_BASE_DIR="$(to_abs_path "${BACKUP_BASE_DIR}")"
    LOG_DIR="$(to_abs_path "${LOG_DIR}")"

    mkdir -p "${BACKUP_BASE_DIR}" "${LOG_DIR}"
}

get_controllers() {
    local i
    for i in $(seq 1 "${MAX_CONTROLLERS}"); do
        printf "%s%d " "${CONTROLLER_PREFIX}" "${i}"
    done
}

is_valid_controller() {
    local controller="$1"
    [[ "${controller}" =~ ^${CONTROLLER_PREFIX}[0-9]+$ ]]
}

extract_hostname() {
    local host_config="$1"
    echo "${host_config}" | sed -n 's/.*NodeName=\([^[:space:]]\+\).*/\1/p'
}

extract_nodeaddr() {
    local host_config="$1"
    echo "${host_config}" | sed -n 's/.*NodeAddr=\([^[:space:]]\+\).*/\1/p'
}

validate_ip() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local octets
    read -r -a octets <<< "${ip}"
    for n in "${octets[@]}"; do
        [[ "${n}" -ge 0 && "${n}" -le 255 ]] || return 1
    done
}

validate_host_config() {
    local host_config="$1"
    local line_num="$2"

    local hostname nodeaddr
    hostname="$(extract_hostname "${host_config}")"
    nodeaddr="$(extract_nodeaddr "${host_config}")"

    if [[ -z "${hostname}" ]]; then
        log "ERROR" "Line ${line_num}: missing NodeName in host config"
        return 1
    fi
    if [[ -z "${nodeaddr}" ]]; then
        log "ERROR" "Line ${line_num}: missing NodeAddr in host config"
        return 1
    fi
    if ! validate_ip "${nodeaddr}"; then
        log "ERROR" "Line ${line_num}: invalid NodeAddr '${nodeaddr}'"
        return 1
    fi
    return 0
}

checksum_file() {
    local file="$1"
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "${file}" | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "${file}"
    else
        shasum "${file}" | awk '{print $1}'
    fi
}

increment_total() {
    TOTAL_OPERATIONS=$((TOTAL_OPERATIONS + 1))
}

increment_failed() {
    FAILED_OPERATIONS=$((FAILED_OPERATIONS + 1))
}

prompt_apply_confirmation() {
    if [[ "${AUTO_APPROVE}" == "true" ]]; then
        return 0
    fi
    while true; do
        read -r -p "Apply validated changes to source directories? (yes/no): " response
        case "${response}" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please enter yes or no." ;;
        esac
    done
}

