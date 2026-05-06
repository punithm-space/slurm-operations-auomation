#!/usr/bin/env bash

sync_controller_to_ansible() {
    local controller="$1"
    [[ "${ENABLE_ANSIBLE_SYNC}" == "true" ]] || return 0

    local source_dir="${SLURM_BASE_DIR}/${controller}"
    local target_dir="${ANSIBLE_TARGET_BASE}/${controller}/slurm"
    [[ -d "${source_dir}" ]] || return 0

    mkdir -p "${target_dir}"
    if cp -rp "${source_dir}"/* "${target_dir}/" 2>/dev/null; then
        log "SUCCESS" "Synced ${controller} to ${target_dir}"
    else
        log "WARNING" "Ansible sync failed for ${controller}"
    fi
}

restart_controllers() {
    local controllers="$1"
    local original_backup_dir="$2"

    [[ -n "${controllers}" ]] || return 0
    if ! command -v systemctl >/dev/null 2>&1; then
        log "WARNING" "systemctl not found; restart step skipped"
        return 0
    fi

    local controller
    for controller in ${controllers}; do
        local service_name
        service_name="$(service_name_from_controller "${controller}")"

        log "INFO" "Restarting ${controller} (${service_name})"
        if ! systemctl list-unit-files | grep -q "^${service_name}"; then
            log "WARNING" "Service ${service_name} not found; skipping restart"
            continue
        fi

        if systemctl restart "${service_name}" >/dev/null 2>&1; then
            sleep "${RESTART_STABILIZE_SECONDS}"
            if systemctl is-active --quiet "${service_name}"; then
                log "SUCCESS" "${service_name} is active"
                sync_controller_to_ansible "${controller}"
            else
                log "ERROR" "${service_name} failed health check post-restart; rolling back ${controller}"
                rollback_controller "${controller}" "${original_backup_dir}" || return 1
            fi
        else
            log "ERROR" "Restart failed for ${service_name}; rolling back ${controller}"
            rollback_controller "${controller}" "${original_backup_dir}" || return 1
        fi
    done

    return 0
}

