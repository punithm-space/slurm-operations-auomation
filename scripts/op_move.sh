#!/usr/bin/env bash

run_move_operations() {
    local input_file="$1"
    local workspace_dir="$2"
    local line_num=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_num=$((line_num + 1))
        line="$(trim "${line}")"
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        increment_total

        if [[ ! "${line}" =~ NodeName=([^[:space:]]+)[[:space:]]+NodeAddr=([^[:space:]]+)[[:space:]]+(${CONTROLLER_PREFIX}[0-9]+)[[:space:]]+(${CONTROLLER_PREFIX}[0-9]+) ]]; then
            log "ERROR" "Line ${line_num}: invalid move format"
            log "ERROR" "Expected: NodeName=<host> NodeAddr=<ip> <source_controller> <target_controller>"
            increment_failed
            continue
        fi

        local hostname ip source_controller target_controller
        hostname="${BASH_REMATCH[1]}"
        ip="${BASH_REMATCH[2]}"
        source_controller="${BASH_REMATCH[3]}"
        target_controller="${BASH_REMATCH[4]}"

        if [[ "${source_controller}" == "${target_controller}" ]]; then
            log "ERROR" "Line ${line_num}: source and target controllers cannot match"
            increment_failed
            continue
        fi
        if ! is_valid_controller "${source_controller}" || ! is_valid_controller "${target_controller}"; then
            log "ERROR" "Line ${line_num}: invalid source/target controller"
            increment_failed
            continue
        fi
        if ! validate_ip "${ip}"; then
            log "ERROR" "Line ${line_num}: invalid IP '${ip}'"
            increment_failed
            continue
        fi

        local source_host
        source_host="$(host_file_path "${workspace_dir}" "${source_controller}")"
        if [[ ! -f "${source_host}" ]]; then
            log "ERROR" "Line ${line_num}: source host file missing for ${source_controller}"
            increment_failed
            continue
        fi

        local host_config
        host_config="$(grep "NodeName=${hostname}[[:space:]]" "${source_host}" | head -n 1 || true)"
        if [[ -z "${host_config}" ]]; then
            log "ERROR" "Line ${line_num}: host ${hostname} not found in ${source_controller}"
            increment_failed
            continue
        fi

        local existing_ip
        existing_ip="$(extract_nodeaddr "${host_config}")"
        if [[ "${existing_ip}" != "${ip}" ]]; then
            log "ERROR" "Line ${line_num}: IP mismatch for ${hostname} (${existing_ip} != ${ip})"
            increment_failed
            continue
        fi

        local partitions
        partitions="$(partition_names_for_host "${workspace_dir}" "${source_controller}" "${hostname}")"

        if [[ -n "${partitions}" ]]; then
            local IFS=','
            local source_partitions
            read -r -a source_partitions <<< "${partitions}"
            local p
            for p in "${source_partitions[@]}"; do
                remove_hostname_from_partition "${workspace_dir}" "${source_controller}" "${p}" "${hostname}" || true
            done
        fi

        remove_host_entry "${workspace_dir}" "${source_controller}" "${hostname}" || true
        add_host_entry "${workspace_dir}" "${target_controller}" "${host_config}" || true

        if [[ -n "${partitions}" ]]; then
            local IFS=','
            local target_partitions
            read -r -a target_partitions <<< "${partitions}"
            local p
            for p in "${target_partitions[@]}"; do
                add_hostname_to_partition "${workspace_dir}" "${target_controller}" "${p}" "${hostname}" || true
            done
        fi

        log "SUCCESS" "Moved ${hostname} (${ip}) from ${source_controller} to ${target_controller}"
        log "LINE"
    done < "${input_file}"
}

