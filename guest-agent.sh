#!/bin/bash
#
# PVY-LIMA-UI Guest Agent
# This script runs inside Lima VMs to provide system information to the PVY-LIMA-UI desktop app.
# Copyright: PVY.swiss LTD | Author: André Grueter 2026, released under GPL v.3.0
VERSION="1.0.0"
#
# Installation:
#   Copy this script to your Lima VM templates or add as a provisioning script:
#
#   provision:
#   - mode: system
#     script: |
#       curl -fsSL https://raw.githubusercontent.com/your-repo/pvy-lima-ui/main/scripts/guest-agent.sh | bash
#
# Usage:
#   ./guest-agent.sh [command]
#
# Commands:
#   all         - Output all system info (default)
#   os          - OS information
#   kernel      - Kernel version
#   uptime      - System uptime
#   memory      - Memory usage
#   cpu         - CPU usage and info
#   disk        - Disk usage
#   network     - Network interfaces and IPs
#   containers   - Container runtime info (Podman/Docker)
#   json        - Output all info as JSON

set -euo pipefail

OUTPUT_JSON=false

if [[ "${1:-}" == "json" ]]; then
    OUTPUT_JSON=true
fi

get_os_info() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        echo "Unknown Linux"
    fi
}

get_kernel_version() {
    uname -r
}

get_uptime() {
    if command -v uptime >/dev/null 2>&1; then
        uptime -p 2>/dev/null || uptime
    else
        cat /proc/uptime | awk '{print $1}'
    fi
}

get_memory_info() {
    if [[ -f /proc/meminfo ]]; then
        local total used available
        total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        used=$(grep MemAvailable /proc/meminfo | awk '{print $3}')
        if [[ -z "$used" ]]; then
            used=$(grep MemFree /proc/meminfo | awk '{print $2}')
        fi
        available=$((total - used))
        echo "total:${total} used:${used} available:${available}"
    fi
}

get_cpu_info() {
    local model cores
    model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    echo "model:${model} cores:${cores}"
}

# Enhanced CPU usage using /proc/stat with proper delta calculation
# Returns: user nice system idle iowait irq softirq steal guest guest_nice
get_cpu_stats() {
    if [[ -f /proc/stat ]]; then
        # Read first line (aggregate CPU)
        local stats
        stats=$(head -1 /proc/stat)
        # Format: cpu user nice system idle iowait irq softirq steal guest guest_nice
        # Remove "cpu" prefix and normalize
        echo "$stats" | sed 's/^cpu\s*/cpu /'
    else
        echo "cpu 0 0 0 0 0 0 0 0 0 0"
    fi
}

# Calculate CPU utilization from two /proc/stat samples
# Takes two stat snapshots and calculates percentage
# Returns: utilization (0-100)
get_cpu_usage() {
    local previous_file="/tmp/pvy_cpu_stats"
    local current_stats
    local previous_stats
    
    current_stats=$(get_cpu_stats)
    
    if [[ -f "$previous_file" ]]; then
        previous_stats=$(cat "$previous_file")
        
        # Parse previous values
        local prev_user prev_nice prev_system prev_idle prev_iowait prev_irq prev_softirq prev_steal
        read -r _ prev_user prev_nice prev_system prev_idle prev_iowait prev_irq prev_softirq prev_steal <<< "$previous_stats"
        
        # Parse current values
        local curr_user curr_nice curr_system curr_idle curr_iowait curr_irq curr_softirq curr_steal
        read -r _ curr_user curr_nice curr_system curr_idle curr_iowait curr_irq curr_softirq curr_steal <<< "$current_stats"
        
        # Calculate deltas (default to 0 if empty)
        prev_user=${prev_user:-0}; prev_nice=${prev_nice:-0}; prev_system=${prev_system:-0}
        prev_idle=${prev_idle:-0}; prev_iowait=${prev_iowait:-0}; prev_irq=${prev_irq:-0}
        prev_softirq=${prev_softirq:-0}; prev_steal=${prev_steal:-0}
        
        curr_user=${curr_user:-0}; curr_nice=${curr_nice:-0}; curr_system=${curr_system:-0}
        curr_idle=${curr_idle:-0}; curr_iowait=${curr_iowait:-0}; curr_irq=${curr_irq:-0}
        curr_softirq=${curr_softirq:-0}; curr_steal=${curr_steal:-0}
        
        # Calculate totals
        local prev_total curr_total prev_idle_total curr_idle_total
        prev_total=$((prev_user + prev_nice + prev_system + prev_irq + prev_softirq + prev_steal))
        curr_total=$((curr_user + curr_nice + curr_system + curr_irq + curr_softirq + curr_steal))
        prev_idle_total=$((prev_idle + prev_iowait))
        curr_idle_total=$((curr_idle + curr_iowait))
        
        # Calculate deltas
        local total_delta idle_delta
        total_delta=$((curr_total - prev_total))
        idle_delta=$((curr_idle_total - prev_idle_total))
        
        # Calculate utilization (avoid division by zero)
        if [[ $total_delta -gt 0 ]]; then
            local utilization
            utilization=$(awk "BEGIN {printf \"%.1f\", $total_delta / ($total_delta + $idle_delta) * 100}")
            echo "$utilization"
        else
            echo "0.0"
        fi
    else
        # First run - save stats and return 0
        echo "$current_stats" > "$previous_file"
        echo "0.0"
    fi
    
    # Save current stats for next run
    echo "$current_stats" > "$previous_file"
}

# Check if enhanced CPU stats are available
has_enhanced_cpu_support() {
    [[ -f /proc/stat ]] && command -v awk >/dev/null 2>&1
}

get_disk_info() {
    df -BG --output=size,used,avail,pcent / 2>/dev/null | tail -1 || echo "N/A"
}

get_network_info() {
    local ip hostname
    ip=$(hostname -I 2>/dev/null | xargs || echo "N/A")
    hostname=$(hostname)
    echo "ip:${ip} hostname:${hostname}"
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

# Check enhanced CPU support and set capability flag
ENHANCED_CPU_SUPPORTED="false"
if has_enhanced_cpu_support; then
    ENHANCED_CPU_SUPPORTED="true"
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
    # JSON output
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
    # Simple key=value output
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
