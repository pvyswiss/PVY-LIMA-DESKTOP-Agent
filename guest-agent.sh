#!/bin/bash
#
# PVY-LIMA-UI Guest Agent
# This script runs inside Lima VMs to provide system information to the PVY-LIMA-UI desktop app.
# Minimum Lima-Version: 2.0 or higher
# Copyright: PVY.swiss LTD | Author: André Grueter 2026, released under GPL v.3.0
VERSION="1.0.0"
#
# Installation:
#   Copy this script to your Lima VM templates or add as a provisioning script:
#
#   provision:
#   - mode: system
#     script: |
#       curl -fsSL https://raw.githubusercontent.com/pvyswiss/PVY-LIMA-DESKTOP-Agent/main/guest-agent.sh -o /usr/local/bin/guest-agent.sh && chmod +x /usr/local/bin/guest-agent.sh
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
#   install     - Install this script to /usr/local/bin/guest-agent.sh

set -euo pipefail

OUTPUT_JSON=false

if [[ "${1:-}" == "install" ]]; then
    # Install this script to /usr/local/bin (skip if already at same location)
    local script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    local dest_path="/usr/local/bin/guest-agent.sh"
    
    if [[ "$script_path" != "$dest_path" ]]; then
        sudo cp "$script_path" "$dest_path" 2>/dev/null || cp "$script_path" "$dest_path"
        sudo chmod +x "$dest_path" 2>/dev/null || chmod +x "$dest_path"
        echo "Installed guest-agent.sh to /usr/local/bin/"
    else
        echo "guest-agent.sh already installed at /usr/local/bin/"
    fi
    
    # Create stats directory and initialize if needed
    mkdir -p /tmp 2>/dev/null || true
    local stats_file="/tmp/pvy_cpu_stats"
    if [[ ! -f "$stats_file" ]]; then
        # Initialize with current CPU stats (run in subshell to avoid function dependencies)
        (
            if [[ -f /proc/stat ]]; then
                head -1 /proc/stat | sed 's/^cpu\s*/cpu /' > "$stats_file" 2>/dev/null || true
            else
                echo "cpu 0 0 0 0 0 0 0 0 0 0" > "$stats_file" 2>/dev/null || true
            fi
        )
        # Make stats file readable/writable by all (since guest agent runs as different users)
        chmod 666 "$stats_file" 2>/dev/null || true
        echo "Initialized CPU stats file at $stats_file"
    else
        # Ensure stats file has correct permissions
        chmod 666 "$stats_file" 2>/dev/null || true
    fi
    
    exit 0
elif [[ "${1:-}" == "json" ]]; then
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
    if command -v free >/dev/null 2>&1; then
        # Use free command (more reliable)
        local total used available
        # free -b outputs in bytes, convert to kB (divide by 1024)
        total=$(free -b | awk '/^Mem:/ {printf "%d", $2/1024}')
        used=$(free -b | awk '/^Mem:/ {printf "%d", $3/1024}')
        available=$(free -b | awk '/^Mem:/ {printf "%d", $7/1024}')  # available column
        echo "total:${total} used:${used} available:${available}"
    elif [[ -f /proc/meminfo ]]; then
        # Fallback to /proc/meminfo
        local total available used
        total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        if [[ -z "$available" ]]; then
            available=$(awk '/MemFree/ {print $2}' /proc/meminfo)
        fi
        used=$((total - available))
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
    local user_id
    user_id=$(id -u 2>/dev/null || echo "0")
    local previous_file="/tmp/pvy_cpu_stats_${user_id}"
    local current_stats
    local previous_stats
    
    # Check if previous stats file exists and is fresh (<30 seconds)
    local use_previous=false
    if [[ -f "$previous_file" ]]; then
        local file_age=0
        if command -v stat >/dev/null 2>&1; then
            # Try different stat formats for Linux/BSD
            if stat -c %Y "$previous_file" >/dev/null 2>&1; then
                file_age=$(($(date +%s) - $(stat -c %Y "$previous_file")))
            elif stat -f %m "$previous_file" >/dev/null 2>&1; then
                file_age=$(($(date +%s) - $(stat -f %m "$previous_file")))
            fi
        fi
        if [[ $file_age -lt 30 ]]; then
            use_previous=true
        else
            echo "[DEBUG] Previous stats file is stale (${file_age}s old), doing fresh measurement" >&2
        fi
    fi
    
    if $use_previous; then
        # Use existing stats file for delta calculation
        current_stats=$(get_cpu_stats)
        
        # Debug: log current stats (truncated)
        echo "[DEBUG] Current stats: $(echo "$current_stats" | cut -d' ' -f1-5)..." >&2
        
        previous_stats=$(cat "$previous_file" 2>/dev/null || echo "")
        
        # Debug: log previous stats (truncated)
        echo "[DEBUG] Previous stats: $(echo "$previous_stats" | cut -d' ' -f1-5)..." >&2
    else
        # Do fresh measurement: two samples 1 second apart
        echo "[DEBUG] Taking fresh CPU measurement (two samples 1s apart)" >&2
        
        local first_stats second_stats
        first_stats=$(get_cpu_stats)
        sleep 1
        second_stats=$(get_cpu_stats)
        
        # Debug: log both samples
        echo "[DEBUG] First sample: $(echo "$first_stats" | cut -d' ' -f1-5)..." >&2
        echo "[DEBUG] Second sample: $(echo "$second_stats" | cut -d' ' -f1-5)..." >&2
        
        previous_stats="$first_stats"
        current_stats="$second_stats"
    fi
    
    # Initialize variables with defaults
    local prev_user=0 prev_nice=0 prev_system=0 prev_idle=0 prev_iowait=0 prev_irq=0 prev_softirq=0 prev_steal=0
    local curr_user=0 curr_nice=0 curr_system=0 curr_idle=0 curr_iowait=0 curr_irq=0 curr_softirq=0 curr_steal=0
    local utilization="0.0"
    
    # Parse current values (always try to parse, even if fails)
    {
        read -r _ curr_user curr_nice curr_system curr_idle curr_iowait curr_irq curr_softirq curr_steal _ _ <<< "$current_stats" || true
    } 2>/dev/null
    
    # Default current values if empty
    curr_user=${curr_user:-0}; curr_nice=${curr_nice:-0}; curr_system=${curr_system:-0}
    curr_idle=${curr_idle:-0}; curr_iowait=${curr_iowait:-0}; curr_irq=${curr_irq:-0}
    curr_softirq=${curr_softirq:-0}; curr_steal=${curr_steal:-0}
    
    if [[ -n "$previous_stats" ]]; then
        # Parse previous values (silently ignore errors)
        {
            read -r _ prev_user prev_nice prev_system prev_idle prev_iowait prev_irq prev_softirq prev_steal _ _ <<< "$previous_stats" || true
        } 2>/dev/null
        
        # Default previous values if empty
        prev_user=${prev_user:-0}; prev_nice=${prev_nice:-0}; prev_system=${prev_system:-0}
        prev_idle=${prev_idle:-0}; prev_iowait=${prev_iowait:-0}; prev_irq=${prev_irq:-0}
        prev_softirq=${prev_softirq:-0}; prev_steal=${prev_steal:-0}
        
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
        
        # Debug: log calculation
        echo "[DEBUG] total_delta=$total_delta, idle_delta=$idle_delta" >&2
        
        # Calculate utilization (avoid division by zero)
        if [[ $total_delta -gt 0 ]]; then
            utilization=$(awk "BEGIN {printf \"%.1f\", $total_delta / ($total_delta + $idle_delta) * 100}" 2>/dev/null || echo "0.0")
            echo "[DEBUG] CPU usage: $utilization%" >&2
        else
            echo "[DEBUG] No CPU activity or first measurement" >&2
            utilization="0.0"
        fi
    else
        echo "[DEBUG] Previous stats empty or unreadable" >&2
        utilization="0.0"
    fi
    
    # Save current stats for next run (atomic write to avoid race conditions)
    echo "$current_stats" > "${previous_file}.tmp" 2>/dev/null && mv "${previous_file}.tmp" "$previous_file" 2>/dev/null || true
    
    # Always return a value (safety fallback)
    echo "${utilization}"
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
