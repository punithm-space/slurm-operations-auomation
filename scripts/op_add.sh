#!/usr/bin/env bash

run_add_operations() {
    local input_file="$1"
    local workspace_dir="$2"
    local line_num=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))
        line="$(trim "${line}")"
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        increment_total

        local controller partition_names host_config
        read -r controller partition_names host_config <<< "${line}"

        if [[ -z "${controller}" || -z "${partition_names}" || -z "${host_config}" ]]; then
            log "ERROR" "Line ${line_num}: expected '<controller> <partition_names> <host_config>'"
            increment_failed
            continue
        fi
        if ! is_valid_controller "${controller}"; then
            log "ERROR" "Line ${line_num}: invalid controller '${controller}'"
            increment_failed
            continue
        fi
        if ! validate_host_config "${host_config}" "${line_num}"; then
            increment_failed
            continue
        fi

        local hostname
        hostname="$(extract_hostname "${host_config}")"

        if ! add_host_entry "${workspace_dir}" "${controller}" "${host_config}"; then
            increment_failed
            continue
        fi

        if [[ "${partition_names}" == "all" ]]; then
            local partition_file
            partition_file="$(partition_file_path "${workspace_dir}" "${controller}")"
            if [[ -f "${partition_file}" ]]; then
                local partition_line partition_name
                while IFS= read -r partition_line; do
                    [[ "${partition_line}" =~ ^PartitionName=([^[:space:]]+) ]] || continue
                    partition_name="${BASH_REMATCH[1]}"
                    add_hostname_to_partition "${workspace_dir}" "${controller}" "${partition_name}" "${hostname}" || true
                done < "${partition_file}"
            else
                log "WARNING" "No partition file for ${controller}; host added only to host file"
            fi
        else
            local IFS=','
            local partitions
            read -r -a partitions <<< "${partition_names}"
            local p
            for p in "${partitions[@]}"; do
                p="$(trim "${p}")"
                [[ -z "${p}" ]] && continue
                if ! add_hostname_to_partition "${workspace_dir}" "${controller}" "${p}" "${hostname}"; then
                    increment_failed
                fi
            done
        fi
        log "LINE"
    done < "${input_file}"
}

