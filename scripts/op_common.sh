#!/usr/bin/env bash

# Shared host/partition mutations for add/remove/move modules.

host_file_path() {
    local workspace_dir="$1"
    local controller="$2"
    printf "%s/%s/host" "${workspace_dir}" "${controller}"
}

partition_file_path() {
    local workspace_dir="$1"
    local controller="$2"
    printf "%s/%s/partition" "${workspace_dir}" "${controller}"
}

hostname_in_host_file() {
    local workspace_dir="$1"
    local controller="$2"
    local hostname="$3"
    local host_file
    host_file="$(host_file_path "${workspace_dir}" "${controller}")"
    [[ -f "${host_file}" ]] && grep -q "NodeName=${hostname}[[:space:]]" "${host_file}"
}

hostname_in_partition() {
    local workspace_dir="$1"
    local controller="$2"
    local partition="$3"
    local hostname="$4"
    local partition_file
    partition_file="$(partition_file_path "${workspace_dir}" "${controller}")"
    [[ -f "${partition_file}" ]] || return 1

    local line
    line="$(grep "^PartitionName=${partition}[[:space:]]" "${partition_file}" || true)"
    [[ -n "${line}" ]] || return 1
    echo ",${line}," | grep -q "Nodes=[^[:space:]]*,${hostname}\(,\|[[:space:]]\|$\)\|Nodes=${hostname}\(,\|[[:space:]]\|$\)"
}

hostname_in_any_partition() {
    local workspace_dir="$1"
    local controller="$2"
    local hostname="$3"
    local partition_file
    partition_file="$(partition_file_path "${workspace_dir}" "${controller}")"
    [[ -f "${partition_file}" ]] || return 1
    grep -qE "Nodes=.*(,|^)${hostname}(,|[[:space:]]|$)" "${partition_file}"
}

add_host_entry() {
    local workspace_dir="$1"
    local controller="$2"
    local host_config="$3"
    local hostname
    hostname="$(extract_hostname "${host_config}")"
    local host_file
    host_file="$(host_file_path "${workspace_dir}" "${controller}")"

    [[ -f "${host_file}" ]] || touch "${host_file}"

    if hostname_in_host_file "${workspace_dir}" "${controller}" "${hostname}"; then
        log "WARNING" "Host ${hostname} already exists in ${controller}/host"
        return 0
    fi
    echo "${host_config}" >> "${host_file}"
    log "SUCCESS" "Added ${hostname} to ${controller}/host"
}

remove_host_entry() {
    local workspace_dir="$1"
    local controller="$2"
    local hostname="$3"
    local host_file
    host_file="$(host_file_path "${workspace_dir}" "${controller}")"

    [[ -f "${host_file}" ]] || return 0
    if ! hostname_in_host_file "${workspace_dir}" "${controller}" "${hostname}"; then
        log "WARNING" "Host ${hostname} not found in ${controller}/host"
        return 0
    fi

    local temp_file
    temp_file="$(mktemp)"
    grep -v "NodeName=${hostname}[[:space:]]" "${host_file}" > "${temp_file}"
    mv "${temp_file}" "${host_file}"
    log "SUCCESS" "Removed ${hostname} from ${controller}/host"
}

add_hostname_to_partition() {
    local workspace_dir="$1"
    local controller="$2"
    local partition_name="$3"
    local hostname="$4"
    local partition_file
    partition_file="$(partition_file_path "${workspace_dir}" "${controller}")"
    [[ -f "${partition_file}" ]] || { log "ERROR" "Partition file missing for ${controller}"; return 1; }

    local line_num line
    line_num="$(grep -n "^PartitionName=${partition_name}[[:space:]]" "${partition_file}" | cut -d: -f1)"
    [[ -n "${line_num}" ]] || { log "ERROR" "Partition ${partition_name} not found in ${controller}"; return 1; }
    line="$(sed -n "${line_num}p" "${partition_file}")"

    if echo ",${line}," | grep -q "Nodes=[^[:space:]]*,${hostname}\(,\|[[:space:]]\|$\)\|Nodes=${hostname}\(,\|[[:space:]]\|$\)"; then
        log "WARNING" "${hostname} already exists in ${controller}/${partition_name}"
        return 0
    fi

    local nodes_part updated_line
    nodes_part="$(echo "${line}" | sed -n 's/.*Nodes=\([^[:space:]]*\).*/\1/p')"
    if [[ -z "${nodes_part}" && "${line}" != *"Nodes="* ]]; then
        log "ERROR" "Partition ${partition_name} in ${controller} has no Nodes= field"
        return 1
    fi

    if [[ -z "${nodes_part}" ]]; then
        updated_line="$(echo "${line}" | sed "s/Nodes=[^[:space:]]*/Nodes=${hostname}/")"
    else
        updated_line="$(echo "${line}" | sed "s/Nodes=${nodes_part}/Nodes=${nodes_part},${hostname}/")"
    fi

    local temp_file
    temp_file="$(mktemp)"
    awk -v line_num="${line_num}" -v replacement="${updated_line}" 'NR==line_num{print replacement; next} {print}' "${partition_file}" > "${temp_file}"
    mv "${temp_file}" "${partition_file}"
    log "SUCCESS" "Added ${hostname} to partition ${partition_name} in ${controller}"
}

remove_hostname_from_partition() {
    local workspace_dir="$1"
    local controller="$2"
    local partition_name="$3"
    local hostname="$4"
    local partition_file
    partition_file="$(partition_file_path "${workspace_dir}" "${controller}")"
    [[ -f "${partition_file}" ]] || return 0

    local line_num line
    line_num="$(grep -n "^PartitionName=${partition_name}[[:space:]]" "${partition_file}" | cut -d: -f1)"
    [[ -n "${line_num}" ]] || { log "WARNING" "Partition ${partition_name} not found in ${controller}"; return 0; }
    line="$(sed -n "${line_num}p" "${partition_file}")"

    local nodes_part
    nodes_part="$(echo "${line}" | sed -n 's/.*Nodes=\([^[:space:]]*\).*/\1/p')"
    [[ -n "${nodes_part}" ]] || return 0
    if ! echo ",${nodes_part}," | grep -q ",${hostname},"; then
        return 0
    fi

    local filtered=""
    local IFS=','
    read -r -a node_array <<< "${nodes_part}"
    local node
    for node in "${node_array[@]}"; do
        node="$(trim "${node}")"
        [[ "${node}" == "${hostname}" || -z "${node}" ]] && continue
        if [[ -z "${filtered}" ]]; then
            filtered="${node}"
        else
            filtered="${filtered},${node}"
        fi
    done

    local updated_line
    updated_line="$(echo "${line}" | sed "s/Nodes=[^[:space:]]*/Nodes=${filtered}/")"

    local temp_file
    temp_file="$(mktemp)"
    awk -v line_num="${line_num}" -v replacement="${updated_line}" 'NR==line_num{print replacement; next} {print}' "${partition_file}" > "${temp_file}"
    mv "${temp_file}" "${partition_file}"
    log "SUCCESS" "Removed ${hostname} from partition ${partition_name} in ${controller}"
}

partition_names_for_host() {
    local workspace_dir="$1"
    local controller="$2"
    local hostname="$3"
    local partition_file
    partition_file="$(partition_file_path "${workspace_dir}" "${controller}")"
    [[ -f "${partition_file}" ]] || return 0

    local names=""
    local line pname
    while IFS= read -r line; do
        [[ "${line}" =~ ^PartitionName=([^[:space:]]+) ]] || continue
        pname="${BASH_REMATCH[1]}"
        if echo "${line}" | grep -qE "Nodes=.*(,|^)${hostname}(,|[[:space:]]|$)"; then
            if [[ -z "${names}" ]]; then
                names="${pname}"
            else
                names="${names},${pname}"
            fi
        fi
    done < "${partition_file}"
    printf "%s" "${names}"
}

