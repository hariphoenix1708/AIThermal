#!/system/bin/sh
# ThermalAI - CPU/GPU Governor Tuner
# !! Tuned for POCO F6 (peridot) — Snapdragon 8s Gen 3 (pineapple) !!
#
# CPU Topology (from device check):
#   Cluster 0 — LITTLE : cpu0, cpu1, cpu2  — max 2016000 kHz  (Cortex-A510)
#   Cluster 1 — BIG    : cpu3, cpu4, cpu5, cpu6 — max 2803200 kHz (Cortex-A720)
#   Cluster 2 — PRIME  : cpu7             — max 3014400 kHz  (Cortex-X4)
#
# Governor: WALT (Qualcomm Window-Assisted Load Tracking) — NOT schedutil
# GPU: Adreno 735, 11 power levels (0=1100MHz .. 10=255MHz)
#      ONLY governor available: msm-adreno-tz (no performance/powersave modes)
#      Control via: min_pwrlevel / max_pwrlevel
# Stock thermal: mi_thermald (MIUI/HyperOS) — stopped on init, restored on exit

# ─── Hardcoded Cluster Map (peridot) ─────────────────────────────────────────
# Populated by discover_cpu_topology(); these are the fallback known values.
# Min freqs reflect GlaciumKernel (AOSP) — lower idle floors than HyperOS:
#   LITTLE: 364800 (was 595200)  BIG: 480000 (was 633600)  PRIME: 480000 (was 633600)
CLUSTER_0_CPUS="0 1 2"
CLUSTER_0_MIN=364800
CLUSTER_0_MAX=2016000

CLUSTER_1_CPUS="3 4 5 6"
CLUSTER_1_MIN=480000
CLUSTER_1_MAX=2803200

CLUSTER_2_CPUS="7"
CLUSTER_2_MIN=480000
CLUSTER_2_MAX=3014400

# Runtime-discovered (filled by discover_cpu_topology)
CPU_CLUSTERS_0=""
CPU_CLUSTERS_1=""
CPU_CLUSTERS_2=""
CLUSTER_MAXFREQ_0=0
CLUSTER_MAXFREQ_1=0
CLUSTER_MAXFREQ_2=0
CLUSTER_MINFREQ_0=0
CLUSTER_MINFREQ_1=0
CLUSTER_MINFREQ_2=0

# ─── CPU Topology Discovery ───────────────────────────────────────────────────
discover_cpu_topology() {
    log_debug "Discovering CPU topology (pineapple/peridot)..."

    local cluster_id=0
    local prev_max=""
    local cluster_maxfreqs=""

    for cpu_num in 0 1 2 3 4 5 6 7; do
        local cpu_path="/sys/devices/system/cpu/cpu${cpu_num}"
        [ -d "$cpu_path" ] || continue

        local hw_max
        hw_max=$(cat "$cpu_path/cpufreq/cpuinfo_max_freq" 2>/dev/null) || continue
        local hw_min
        hw_min=$(cat "$cpu_path/cpufreq/cpuinfo_min_freq" 2>/dev/null || echo "0")

        # Find which cluster this CPU belongs to by matching hw_max
        local matched=0
        for cid in 0 1 2; do
            eval "local cmax=\$CLUSTER_MAXFREQ_${cid}"
            if [ "$cmax" = "$hw_max" ]; then
                eval "CPU_CLUSTERS_${cid}=\"\${CPU_CLUSTERS_${cid}} ${cpu_num}\""
                matched=1
                break
            fi
        done

        if [ "$matched" = "0" ]; then
            eval "CLUSTER_MAXFREQ_${cluster_id}=$hw_max"
            eval "CLUSTER_MINFREQ_${cluster_id}=$hw_min"
            eval "CPU_CLUSTERS_${cluster_id}=\"${cpu_num}\""
            cluster_id=$((cluster_id + 1))
        fi
    done

    # Strip leading spaces
    CPU_CLUSTERS_0="${CPU_CLUSTERS_0# }"
    CPU_CLUSTERS_1="${CPU_CLUSTERS_1# }"
    CPU_CLUSTERS_2="${CPU_CLUSTERS_2# }"

    # Fallback to known values if discovery failed
    [ -z "$CPU_CLUSTERS_0" ] && CPU_CLUSTERS_0="$CLUSTER_0_CPUS" && CLUSTER_MAXFREQ_0=$CLUSTER_0_MAX && CLUSTER_MINFREQ_0=$CLUSTER_0_MIN
    [ -z "$CPU_CLUSTERS_1" ] && CPU_CLUSTERS_1="$CLUSTER_1_CPUS" && CLUSTER_MAXFREQ_1=$CLUSTER_1_MAX && CLUSTER_MINFREQ_1=$CLUSTER_1_MIN
    [ -z "$CPU_CLUSTERS_2" ] && CPU_CLUSTERS_2="$CLUSTER_2_CPUS" && CLUSTER_MAXFREQ_2=$CLUSTER_2_MAX && CLUSTER_MINFREQ_2=$CLUSTER_2_MIN

    log_info "Cluster 0 (LITTLE): CPUs=${CPU_CLUSTERS_0}  max=${CLUSTER_MAXFREQ_0}"
    log_info "Cluster 1 (BIG)   : CPUs=${CPU_CLUSTERS_1}  max=${CLUSTER_MAXFREQ_1}"
    log_info "Cluster 2 (PRIME) : CPUs=${CPU_CLUSTERS_2}  max=${CLUSTER_MAXFREQ_2}"
}

# ─── Set CPU Frequency Limits ─────────────────────────────────────────────────
set_cpu_freq_limits() {
    local cpu_num="$1"
    local min_freq="$2"
    local max_freq="$3"
    local base_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"

    # Must write min before max to avoid kernel rejecting out-of-range
    [ -w "$base_path/scaling_min_freq" ] && echo "$min_freq" > "$base_path/scaling_min_freq" 2>/dev/null
    [ -w "$base_path/scaling_max_freq" ] && echo "$max_freq" > "$base_path/scaling_max_freq" 2>/dev/null
}

set_cpu_governor() {
    local cpu_num="$1"
    local governor="$2"
    local gov_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_governor"
    [ -w "$gov_path" ] && echo "$governor" > "$gov_path" 2>/dev/null
}

# ─── WALT Governor Tuning ─────────────────────────────────────────────────────
# WALT tunables live at: /sys/devices/system/cpu/cpuX/cpufreq/walt/
# Key params:
#   hispeed_freq         — freq to jump to on high load (kHz)
#   hispeed_load         — load % threshold to trigger hispeed_freq
#   target_loads         — load→freq mapping string e.g. "85 1536000:90"
#   up_rate_limit_us     — min time (µs) before scaling UP
#   down_rate_limit_us   — min time (µs) before scaling DOWN
tune_walt() {
    local cpu_num="$1"
    local hispeed_freq="$2"
    local hispeed_load="$3"
    local up_rate_us="$4"
    local down_rate_us="$5"
    local target_loads="$6"

    local walt_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/walt"
    [ -d "$walt_path" ] || return 0

    [ -n "$hispeed_freq" ] && [ -w "$walt_path/hispeed_freq" ] && \
        echo "$hispeed_freq" > "$walt_path/hispeed_freq" 2>/dev/null
    [ -n "$hispeed_load" ] && [ -w "$walt_path/hispeed_load" ] && \
        echo "$hispeed_load" > "$walt_path/hispeed_load" 2>/dev/null
    [ -n "$up_rate_us" ] && [ -w "$walt_path/up_rate_limit_us" ] && \
        echo "$up_rate_us" > "$walt_path/up_rate_limit_us" 2>/dev/null
    [ -n "$down_rate_us" ] && [ -w "$walt_path/down_rate_limit_us" ] && \
        echo "$down_rate_us" > "$walt_path/down_rate_limit_us" 2>/dev/null
    [ -n "$target_loads" ] && [ -w "$walt_path/target_loads" ] && \
        echo "$target_loads" > "$walt_path/target_loads" 2>/dev/null
}

# ─── Apply Per-Cluster Settings ───────────────────────────────────────────────
# walt_hispeed_freq and walt_hispeed_load are WALT-specific, ignored if missing
apply_cluster_settings() {
    local cluster_id="$1"
    local governor="$2"       # walt | performance | powersave | conservative
    local min_pct="$3"        # % of hw_max for scaling_min_freq
    local max_pct="$4"        # % of hw_max for scaling_max_freq
    local walt_hispeed="$5"   # hispeed_freq in kHz (or "" to skip)
    local walt_hsload="$6"    # hispeed_load % (or "" to skip)
    local walt_up_us="$7"     # up_rate_limit_us (or "" to skip)
    local walt_dn_us="$8"     # down_rate_limit_us (or "" to skip)

    eval "local cpus=\$CPU_CLUSTERS_${cluster_id}"
    eval "local hw_max=\$CLUSTER_MAXFREQ_${cluster_id}"
    eval "local hw_min=\$CLUSTER_MINFREQ_${cluster_id}"

    [ -z "$cpus" ] && return
    [ "$hw_max" -eq 0 ] 2>/dev/null && return

    local target_min=$((hw_max * min_pct / 100))
    local target_max=$((hw_max * max_pct / 100))
    [ "$target_min" -lt "$hw_min" ] && target_min="$hw_min"
    [ "$target_max" -gt "$hw_max" ] && target_max="$hw_max"

    for cpu_num in $cpus; do
        set_cpu_governor "$cpu_num" "$governor"
        set_cpu_freq_limits "$cpu_num" "$target_min" "$target_max"
        tune_walt "$cpu_num" "$walt_hispeed" "$walt_hsload" "$walt_up_us" "$walt_dn_us" ""
        apply_universal_cpu_tuning "$cpu_num" "$governor"
    done

    log_debug "Cluster ${cluster_id} -> gov=${governor} ${target_min}-${target_max}kHz hs=${walt_hispeed}@${walt_hsload}%"
}

# ─── GPU Control (Adreno 735 — msm-adreno-tz only) ───────────────────────────
# Power levels:   0=1100  1=1000  2=950  3=900  4=835  5=736
#                 6=684   7=633   8=500  9=353  10=255  MHz
# IMPORTANT: min_pwrlevel >= max_pwrlevel is INVALID on this SoC
#            max_pwrlevel sets the CEILING (lowest number = fastest)
#            min_pwrlevel sets the FLOOR  (highest number = slowest)
# Only msm-adreno-tz governor exists — no performance/powersave switch possible.
# We control speed purely through min/max power level clamping.
set_gpu_power_levels() {
    local max_pl="$1"   # ceiling: 0 (1100MHz/fastest) to 10 (255MHz/slowest)
    local min_pl="$2"   # floor:   must be >= max_pl

    local adreno="/sys/class/kgsl/kgsl-3d0"
    [ -d "$adreno" ] || return

    # Validate: floor must be slower than or equal to ceiling
    if [ "$min_pl" -lt "$max_pl" ] 2>/dev/null; then
        log_warn "GPU: min_pl($min_pl) < max_pl($max_pl) — correcting floor to match ceiling"
        min_pl="$max_pl"
    fi

    # Write min (floor/slowest) FIRST to avoid transient invalid state
    [ -w "$adreno/min_pwrlevel" ] && echo "$min_pl" > "$adreno/min_pwrlevel" 2>/dev/null
    [ -w "$adreno/max_pwrlevel" ] && echo "$max_pl" > "$adreno/max_pwrlevel" 2>/dev/null

    log_debug "GPU power levels -> max(ceil)=${max_pl} min(floor)=${min_pl}"
}

# ─── Disable Stock Thermal (mi_thermald for peridot/HyperOS) ─────────────────
disable_stock_thermal() {
    # Primary: mi_thermald (MIUI / HyperOS — confirmed running pid=2418)
    stop mi_thermald 2>/dev/null || true
    # Belt-and-suspenders: try generic names too
    stop thermal-engine        2>/dev/null || true
    stop vendor.thermal-engine 2>/dev/null || true
    stop thermald              2>/dev/null || true

    # Reset all cooling device states to 0 (no throttle)
    for cdev in /sys/class/thermal/cooling_device*/cur_state; do
        [ -w "$cdev" ] && echo "0" > "$cdev" 2>/dev/null || true
    done

    log_info "Stock thermal daemon (mi_thermald) disabled"
}

# ─── Restore Stock Thermal ────────────────────────────────────────────────────
restore_stock_thermal() {
    start mi_thermald          2>/dev/null || true
    start thermal-engine       2>/dev/null || true
    start vendor.thermal-engine 2>/dev/null || true
    start thermald             2>/dev/null || true

    # Restore freq limits to hardware maximums
    for cpu_num in 0 1 2 3 4 5 6 7; do
        local base="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
        local hw_max
        hw_max=$(cat "$base/cpuinfo_max_freq" 2>/dev/null) || continue
        local hw_min
        hw_min=$(cat "$base/cpuinfo_min_freq" 2>/dev/null || echo "0")
        echo "$hw_min" > "$base/scaling_min_freq" 2>/dev/null || true
        echo "$hw_max" > "$base/scaling_max_freq" 2>/dev/null || true
    done

    # Restore GPU to full range
    set_gpu_power_levels 0 10

    # Restore charging (if charge_control.sh is available)
    if command -v restore_charging_control >/dev/null 2>&1; then
        restore_charging_control
    fi

    log_info "Stock thermal (mi_thermald) restored and freq limits reset"
}

# ─── Universal CPU Tuning Fallbacks ───────────────────────────────────────────
# If WALT is not available (e.g., standard schedutil, interactive, or MediaTek)
apply_universal_cpu_tuning() {
    local cpu_num="$1"
    local governor="$2"

    local gov_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_governor"
    echo "$governor" > "$gov_path" 2>/dev/null

    # Try generic schedutil tuning if WALT is missing
    local schedutil_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/schedutil"
    if [ -d "$schedutil_path" ]; then
        if [ "$governor" = "performance" ] || [ "$governor" = "walt" ]; then
            sysfs_write 500 "$schedutil_path/up_rate_limit_us"
            sysfs_write 20000 "$schedutil_path/down_rate_limit_us"
        else
            sysfs_write 2000 "$schedutil_path/up_rate_limit_us"
            sysfs_write 5000 "$schedutil_path/down_rate_limit_us"
        fi
    fi
}
