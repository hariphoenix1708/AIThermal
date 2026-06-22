#!/system/bin/sh
# ThermalAI - State Manager
# Handles Full State Snapshot & Restore, Policy Verification Layer

SNAPSHOT_FILE="/data/local/tmp/thermalai.snapshot"

# Paths to snapshot
CPU_GOV_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
GPU_PWR_MIN="/sys/class/kgsl/kgsl-3d0/min_pwrlevel"
GPU_PWR_MAX="/sys/class/kgsl/kgsl-3d0/max_pwrlevel"
SWAPPINESS_PATH="/proc/sys/vm/swappiness"
BATT_CURRENT_MAX="/sys/class/power_supply/battery/constant_charge_current_max"

# Global CPUSET path detection
export CPUSET_ROOT="/dev/cpuset"
if [ ! -d "/dev/cpuset" ]; then
    if [ -d "/sys/fs/cgroup/cpuset" ]; then
        export CPUSET_ROOT="/sys/fs/cgroup/cpuset"
    elif [ -d "/sys/fs/cgroup" ] && [ -f "/sys/fs/cgroup/cpuset.cpus" ]; then
        export CPUSET_ROOT="/sys/fs/cgroup"
    fi
fi

take_snapshot() {
    log_info "Taking full state snapshot..."
    echo "CPU_GOV_VAL=$(cat $CPU_GOV_PATH 2>/dev/null || echo 'schedutil')" > "$SNAPSHOT_FILE"
    echo "GPU_PWR_MIN_VAL=$(cat $GPU_PWR_MIN 2>/dev/null || echo '0')" >> "$SNAPSHOT_FILE"
    echo "GPU_PWR_MAX_VAL=$(cat $GPU_PWR_MAX 2>/dev/null || echo '0')" >> "$SNAPSHOT_FILE"
    echo "SWAPPINESS_VAL=$(cat $SWAPPINESS_PATH 2>/dev/null || echo '100')" >> "$SNAPSHOT_FILE"
    echo "BATT_CURRENT_MAX_VAL=$(cat $BATT_CURRENT_MAX 2>/dev/null || echo '5000000')" >> "$SNAPSHOT_FILE"

    # Save cpusets
    local cpus_file="cpus"
    [ "$CPUSET_ROOT" = "/sys/fs/cgroup" ] && cpus_file="cpuset.cpus"

    echo "CPUSET_BG=\"$(cat $CPUSET_ROOT/background/$cpus_file 2>/dev/null)\"" >> "$SNAPSHOT_FILE"
    echo "CPUSET_SYSBG=\"$(cat $CPUSET_ROOT/system-background/$cpus_file 2>/dev/null)\"" >> "$SNAPSHOT_FILE"
    echo "CPUSET_FG=\"$(cat $CPUSET_ROOT/foreground/$cpus_file 2>/dev/null)\"" >> "$SNAPSHOT_FILE"
    echo "CPUSET_TOPAPP=\"$(cat $CPUSET_ROOT/top-app/$cpus_file 2>/dev/null)\"" >> "$SNAPSHOT_FILE"

    # Save TCP config
    echo "TCP_SYN_RETRIES=\"$(cat /proc/sys/net/ipv4/tcp_syn_retries 2>/dev/null || echo '6')\"" >> "$SNAPSHOT_FILE"
    echo "TCP_SYNACK_RETRIES=\"$(cat /proc/sys/net/ipv4/tcp_synack_retries 2>/dev/null || echo '5')\"" >> "$SNAPSHOT_FILE"

    log_debug "Snapshot taken."
}

restore_snapshot() {
    if [ -f "$SNAPSHOT_FILE" ]; then
        log_info "Restoring full state snapshot..."
        . "$SNAPSHOT_FILE"
        echo "$CPU_GOV_VAL" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
        echo "$GPU_PWR_MIN_VAL" > /sys/class/kgsl/kgsl-3d0/min_pwrlevel 2>/dev/null
        echo "$GPU_PWR_MAX_VAL" > /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null
        echo "$SWAPPINESS_VAL" > /proc/sys/vm/swappiness 2>/dev/null
        echo "$BATT_CURRENT_MAX_VAL" > /sys/class/power_supply/battery/constant_charge_current_max 2>/dev/null

        local cpus_file="cpus"
        [ "$CPUSET_ROOT" = "/sys/fs/cgroup" ] && cpus_file="cpuset.cpus"

        [ -n "$CPUSET_BG" ] && echo "$CPUSET_BG" > "$CPUSET_ROOT/background/$cpus_file" 2>/dev/null
        [ -n "$CPUSET_SYSBG" ] && echo "$CPUSET_SYSBG" > "$CPUSET_ROOT/system-background/$cpus_file" 2>/dev/null
        [ -n "$CPUSET_FG" ] && echo "$CPUSET_FG" > "$CPUSET_ROOT/foreground/$cpus_file" 2>/dev/null
        [ -n "$CPUSET_TOPAPP" ] && echo "$CPUSET_TOPAPP" > "$CPUSET_ROOT/top-app/$cpus_file" 2>/dev/null

        [ -n "$TCP_SYN_RETRIES" ] && echo "$TCP_SYN_RETRIES" > /proc/sys/net/ipv4/tcp_syn_retries 2>/dev/null
        [ -n "$TCP_SYNACK_RETRIES" ] && echo "$TCP_SYNACK_RETRIES" > /proc/sys/net/ipv4/tcp_synack_retries 2>/dev/null

        log_info "Snapshot restored."
    else
        log_warn "No snapshot file found to restore."
    fi
}

verify_policy() {
    local target_gov="$1"
    local target_gpu_max="$2"
    local max_retries=3
    local retry=0

    while [ "$retry" -lt "$max_retries" ]; do
        local current_gov=$(cat "$CPU_GOV_PATH" 2>/dev/null)
        local current_gpu_max=$(cat "$GPU_PWR_MAX" 2>/dev/null)

        if [ "$current_gov" = "$target_gov" ] && [ "$current_gpu_max" = "$target_gpu_max" ]; then
            log_debug "Policy verification passed."
            return 0
        fi

        log_debug "Verification retry $retry..."
        sleep 1
        retry=$((retry + 1))
    done

    log_error "Policy verification failed! Target GOV: $target_gov, Target GPU MAX: $target_gpu_max. Actual GOV: $current_gov, Actual GPU MAX: $current_gpu_max"
    return 1
}
