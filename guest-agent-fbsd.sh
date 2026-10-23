#!/usr/bin/env bash
#
# PVY-LIMA-UI Guest Agent - FreeBSD port (based on v1.0.3)
# Same output contract as guest-agent.sh, FreeBSD data sources (sysctl).
# This script runs inside Lima FreeBSD VMs to provide system information
# to the PVY-LIMA-UI desktop app.
# Requires: bash + sudo from pkg. sysctl/df/ifconfig/awk/sed are in base.
# Copyright: PVY.swiss LTD | Author: André Grueter 2026, released under GPL v.3.0
VERSION="1.0.3-fbsd"
#
# Installation:
#   provision:
#   - mode: system
#     script: |
#       fetch -o /usr/local/bin/guest-agent.sh https://raw.githubusercontent.com/pvyswiss/PVY-LIMA-DESKTOP-Agent/main/guest-agent-fbsd.sh
#       chmod +x /usr/local/bin/guest-agent.sh
#       /usr/bin/env bash /usr/local/bin/guest-agent.sh install
#
# Usage:
#   ./guest-agent.sh [command]
#
# Commands: (same as Linux guest-agent.sh)
#   all/json/install/os/kernel/uptime/memory/cpu/disk/network/containers

set -uo pipefail

OUTPUT_JSON=false

if [[ "${1:-}" == "install" ]]; then
    script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    dest_path="/usr/local/bin/guest-agent.sh"
    if [[ "$script_path" != "$dest_path" ]]; then
        cp "$script_path" "$dest_path" 2>/dev/null
        chmod +x "$dest_path" 2>/dev/null
        echo "Installed guest-agent.sh to /usr/local/bin/"
    else
        echo "guest-agent.sh already installed at /usr/local/bin/"
    fi
    mkdir -p /tmp 2>/dev/null || true
    stats_file="/tmp/pvy_cpu_stats"
    if [[ ! -f "$stats_file" ]]; then
        ( sysctl -n kern.cp_time | sed -E 's/^/cpu /' > "$stats_file" 2>/dev/null || echo "cpu 0 0 0 0 0" > "$stats_file" )
        chmod 666 "$stats_file" 2>/dev/null || true
        echo "Initialized CPU stats file at $stats_file"
    else
        chmod 666 "$stats_file" 2>/dev/null || true
    fi
    exit 0
elif [[ "${1:-}" == "json" ]]; then
    OUTPUT_JSON=true
fi

get_os_info() {
    if command -v freebsd-version >/dev/null 2>&1; then
        echo "FreeBSD $(freebsd-version)"
    else
        uname -sr
    fi
}

get_kernel_version() {
    uname -r
}

get_uptime() {
    local boot secs up_d up_h up_m
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/\{ sec = ([0-9]+).*/\1/')
    if [[ -n "$boot" ]]; then
        secs=$(( $(date +%s) - boot ))
        up_d=$(( secs / 86400 ))
        up_h=$(( (secs % 86400) / 3600 ))
        up_m=$(( (secs % 3600) / 60 ))
        echo "up ${up_d} days, ${up_h} hours, ${up_m} minutes"
    else
        uptime
    fi
}

get_memory_info() {
    local page_size total_kb avail_kb used_kb free_pages inactive cache
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    total_kb=$(( $(sysctl -n hw.physmem 2>/dev/null || echo 0) / 1024 ))
    free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo 0)
    inactive=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null || echo 0)
    cache=$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null || echo 0)
    if [[ $total_kb -gt 0 ]]; then
        avail_kb=$(( (free_pages + inactive + cache) * page_size / 1024 ))
        used_kb=$(( total_kb - avail_kb ))
        echo "total:${total_kb} used:${used_kb} available:${avail_kb}"
    else
        echo "total:0 used:0 available:0"
    fi
}

get_cpu_info() {
    local model cores
    model=$(sysctl -n hw.model 2>/dev/null || echo "N/A")
    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "0")
    echo "model:${model} cores:${cores}"
}

# FreeBSD kern.cp_time = user nice system interrupt idle (aggregate ticks)
get_cpu_stats() {
    if sysctl -n kern.cp_time >/dev/null 2>&1; then
        sysctl -n kern.cp_time | sed -E 's/^/cpu /'
    else
        echo "cpu 0 0 0 0 0"
    fi
}

get_cpu_usage() {
    local user_id previous_file current_stats previous_stats use_previous file_age
    user_id=$(id -u 2>/dev/null || echo "0")
    previous_file="/tmp/pvy_cpu_stats_${user_id}"

    use_previous=false
    if [[ -f "$previous_file" ]]; then
        file_age=0
        if command -v stat >/dev/null 2>&1; then
            if stat -f %m "$previous_file" >/dev/null 2>&1; then
                file_age=$(( $(date +%s) - $(stat -f %m "$previous_file") ))
            fi
        fi
        [[ $file_age -lt 10 ]] && use_previous=true
    fi

    if $use_previous; then
        current_stats=$(get_cpu_stats)
        previous_stats=$(cat "$previous_file" 2>/dev/null || echo "")
    else
        local first_stats second_stats
        first_stats=$(get_cpu_stats)
        sleep 1
        second_stats=$(get_cpu_stats)
        previous_stats="$first_stats"
        current_stats="$second_stats"
    fi

    local curr_user=0 curr_nice=0 curr_system=0 curr_intr=0 curr_idle=0
    local prev_user=0 prev_nice=0 prev_system=0 prev_intr=0 prev_idle=0
    local utilization="0.0"

    read -r _ curr_user curr_nice curr_system curr_intr curr_idle <<< "$current_stats" 2>/dev/null || true
    curr_user=${curr_user:-0}; curr_nice=${curr_nice:-0}; curr_system=${curr_system:-0}
    curr_intr=${curr_intr:-0}; curr_idle=${curr_idle:-0}

    if [[ -n "$previous_stats" ]]; then
        read -r _ prev_user prev_nice prev_system prev_intr prev_idle <<< "$previous_stats" 2>/dev/null || true
        prev_user=${prev_user:-0}; prev_nice=${prev_nice:-0}; prev_system=${prev_system:-0}
        prev_intr=${prev_intr:-0}; prev_idle=${prev_idle:-0}

        local prev_busy curr_busy prev_total curr_total
        prev_busy=$(( prev_user + prev_nice + prev_system + prev_intr ))
        curr_busy=$(( curr_user + curr_nice + curr_system + curr_intr ))
        prev_total=$(( prev_busy + prev_idle ))
        curr_total=$(( curr_busy + curr_idle ))

        local busy_delta total_delta
        busy_delta=$(( curr_busy - prev_busy ))
        total_delta=$(( curr_total - prev_total ))

        if [[ $total_delta -gt 0 ]]; then
            utilization=$(awk "BEGIN {printf \"%.1f\", ($busy_delta / $total_delta) * 100}" 2>/dev/null || echo "0.0")
        fi
    fi

    echo "$current_stats" > "${previous_file}.tmp" 2>/dev/null && mv "${previous_file}.tmp" "$previous_file" 2>/dev/null || true
    echo "${utilization}"
}

has_enhanced_cpu_support() {
    sysctl -n kern.cp_time >/dev/null 2>&1 && command -v awk >/dev/null 2>&1
}

get_disk_info() {
    df -k / 2>/dev/null | tail -1 | awk '{printf "size:%d used:%d avail:%d pcent:%s", $2, $3, $4, $5}'
}

get_network_info() {
    local ip hostname_name
    ip=$(ifconfig 2>/dev/null | awk '$1=="inet" && $2 !~ /^127\./ {print $2; exit}')
    ip=${ip:-N/A}
    hostname_name=$(hostname)
    echo "ip:${ip} hostname:${hostname_name}"
}

get_container_info() {
    local podman_version docker_version
    if command -v podman >/dev/null 2>&1; then
        podman_version=$(podman --version)
    fi
    if command -v docker >/dev/null 2>&1; then
        docker_version=$(docker --version)
    fi
    echo "podman:${podman_version:-N/A} docker:${docker_version:-N/A}"
}

ENHANCED_CPU_SUPPORTED="false"
if has_enhanced_cpu_support; then
    ENHANCED_CPU_SUPPORTED="true"
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
    echo "{"
    echo "  \"version\": \"$VERSION\","
    echo "  \"os\": \"$(get_os_info)\","
    echo "  \"kernel\": \"$(get_kernel_version)\","
    echo "  \"uptime\": \"$(get_uptime)\","
    echo "  \"memory\": \"$(get_memory_info)\","
    echo "  \"cpu\": \"$(get_cpu_info)\","
    echo "  \"cpu_usage\": \"$(get_cpu_usage)%\","
    echo "  \"enhanced_cpu_support\": \"$ENHANCED_CPU_SUPPORTED\","
    echo "  \"disk\": \"$(get_disk_info)\","
    echo "  \"network\": \"$(get_network_info)\","
    echo "  \"containers\": \"$(get_container_info)\""
    echo "}"
else
    echo "VERSION=$VERSION"
    echo "OS=$(get_os_info)"
    echo "KERNEL=$(get_kernel_version)"
    echo "UPTIME=$(get_uptime)"
    echo "MEMORY=$(get_memory_info)"
    echo "CPU=$(get_cpu_info)"
    echo "CPU_USAGE=$(get_cpu_usage)%"
    echo "ENHANCED_CPU_SUPPORTED=$ENHANCED_CPU_SUPPORTED"
    echo "DISK=$(get_disk_info)"
    echo "NETWORK=$(get_network_info)"
    echo "CONTAINERS=$(get_container_info)"
fi
