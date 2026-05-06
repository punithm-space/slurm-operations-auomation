#!/usr/bin/env bash

service_name_from_controller() {
    local controller="$1"
    local num
    num="$(echo "${controller}" | sed "s/^${CONTROLLER_PREFIX}//")"
    printf "slurmctld%s.service" "${num}"
}

rollback_controller() {
    local controller="$1"
    local original_backup_dir="$2"

    local source_dir="${SLURM_BASE_DIR}/${controller}"
    local backup_dir="${original_backup_dir}/${controller}"
    local service_name
    service_name="$(service_name_from_controller "${controller}")"

    if [[ ! -d "${backup_dir}" ]]; then
        log "ERROR" "Rollback backup missing for ${controller}: ${backup_dir}"
        return 1
    fi

    mkdir -p "${source_dir}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "${service_name}" >/dev/null 2>&1 || true
    fi

    if cp "${backup_dir}"/* "${source_dir}/" 2>/dev/null; then
        log "SUCCESS" "Restored original files for ${controller}"
    else
        log "ERROR" "Failed restoring files for ${controller}"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart "${service_name}" >/dev/null 2>&1; then
            log "SUCCESS" "Restarted ${service_name} after rollback"
        else
            log "ERROR" "Failed restarting ${service_name} after rollback"
            return 1
        fi
    fi

    return 0
}

