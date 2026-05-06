#!/usr/bin/env bash

apply_changes_to_source() {
    local working_backup_dir="$1"
    local original_backup_dir="$2"

    COPIED_CONTROLLERS=""

    local controller
    for controller in $(get_controllers); do
        local working_dir="${working_backup_dir}/${controller}"
        local original_dir="${original_backup_dir}/${controller}"
        local source_dir="${SLURM_BASE_DIR}/${controller}"

        [[ -d "${working_dir}" ]] || continue
        [[ -d "${source_dir}" ]] || mkdir -p "${source_dir}"

        local copied_count=0
        local file
        for file in "${working_dir}"/*; do
            [[ -f "${file}" ]] || continue
            local name target_file original_file
            name="$(basename "${file}")"
            target_file="${source_dir}/${name}"
            original_file="${original_dir}/${name}"

            local changed=true
            if [[ -f "${original_file}" ]]; then
                local work_sum orig_sum
                work_sum="$(checksum_file "${file}")"
                orig_sum="$(checksum_file "${original_file}")"
                [[ "${work_sum}" == "${orig_sum}" ]] && changed=false
            fi

            if [[ "${changed}" == "true" ]]; then
                if cp "${file}" "${target_file}"; then
                    copied_count=$((copied_count + 1))
                    log "SUCCESS" "Copied ${controller}/${name} to source"
                else
                    log "ERROR" "Failed copying ${controller}/${name} to source"
                    return 1
                fi
            fi
        done

        if [[ "${copied_count}" -gt 0 ]]; then
            if [[ -z "${COPIED_CONTROLLERS}" ]]; then
                COPIED_CONTROLLERS="${controller}"
            else
                COPIED_CONTROLLERS="${COPIED_CONTROLLERS} ${controller}"
            fi
            log "INFO" "Controller ${controller}: ${copied_count} file(s) updated in source"
        else
            log "INFO" "Controller ${controller}: no source changes"
        fi
    done

    return 0
}

