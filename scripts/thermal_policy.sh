#!/system/bin/sh
# ThermalAI - Thermal Policy Enforcement
# !! Tuned for POCO F6 (peridot) — Snapdragon 8s Gen 3 (pineapple) !!
#
# CPU Clusters:
#   0 = LITTLE  cpu0-2   hw_max=2016000 kHz
#   1 = BIG     cpu3-6   hw_max=2803200 kHz
#   2 = PRIME   cpu7     hw_max=3014400 kHz
#
# GPU Adreno 735 power levels (max_pwrlevel=ceiling, min_pwrlevel=floor):
#   PL0=1100  PL1=1000  PL2=950   PL3=900  PL4=835  PL5=736
#   PL6=684   PL7=633   PL8=500   PL9=353  PL10=255  MHz
#
# WALT tuning reference:
#   up_rate_limit_us   — lower = snappier upscale response
#   down_rate_limit_us — higher = holds freq longer before dropping
#   hispeed_freq       — freq to boost to on hispeed_load trigger
#   hispeed_load       — % load to trigger hispeed_freq jump

apply_thermal_policy() {
    local policy="$1"
    local is_gaming="$2"
    local temp="$3"
    local event_type="$4" # watchdog, transition

    log_info "Applying policy: $policy (gaming=$is_gaming, event=$event_type)"

    # Unlock emergency cooling devices if we are recovering to a normal state
    if [ "$policy" != "emergency_cool" ] && [ "$policy" != "suspend" ]; then
        for cdev_path in /sys/class/thermal/cooling_device*/; do
            local ctype=$(cat "${cdev_path}type" 2>/dev/null)
            case "$ctype" in
                cpu-cluster*|cpufreq-cpu*)
                    [ -w "${cdev_path}cur_state" ] && echo "0" > "${cdev_path}cur_state" 2>/dev/null || true
                    ;;
            esac
        done
    fi

    case "$policy" in
        suspend)          _policy_suspend                   ;;
        performance)      _policy_performance  "$is_gaming" "$event_type" ;;
        balanced)         _policy_balanced     "$is_gaming" "$event_type" ;;
        conservative)     _policy_conservative "$is_gaming" "$event_type" ;;
        powersave)        _policy_powersave    "$is_gaming" "$event_type" ;;
        emergency_cool)   _policy_emergency                 "$event_type" ;;
        *)                _policy_balanced     "$is_gaming" "$event_type" ;;
    esac

    _apply_vm_params    "$policy" "$is_gaming"
    _apply_io_scheduler "$policy"
    _apply_cpuset       "$policy" "$is_gaming"

    # Apply optional gaming tweaks (if the function is available)
    if command -v apply_gaming_enhancements >/dev/null 2>&1; then
        apply_gaming_enhancements "$is_gaming"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# PERFORMANCE  — temp <42°C, score ≥60
# ══════════════════════════════════════════════════════════════════════════════
_policy_performance() {
    local gaming="$1"

    if $gaming; then
        # Gaming Performance: Smooth but prevent unnecessary 100% heat spikes.
        # BIG/PRIME absolute max is capped to 90/95% (plenty for 120fps smooth).
        apply_cluster_settings 0 "$ACTIVE_GOV" 25 95 "1209600" "70" "500"  "5000"
        apply_cluster_settings 1 "$ACTIVE_GOV" 30 95 "2188800" "80" "500"  "8000"
        apply_cluster_settings 2 "$ACTIVE_GOV" 30 90 "2419200" "85" "500"  "10000"
        # GPU: Fast up, but leave max power level (0) for emergency frame drops
        set_gpu_power_levels 1 4

    else
        # UI "Sweet Spot" Performance: Fast upscale but hispeed is efficient.
        # Keeps animations butter smooth without massive voltage/heat.
        apply_cluster_settings 0 "$ACTIVE_GOV" 20 90 "1209600" "80" "1000" "4000"
        apply_cluster_settings 1 "$ACTIVE_GOV" 25 90 "1881600" "85" "1000" "6000"
        apply_cluster_settings 2 "$ACTIVE_GOV" 25 85 "2112000" "85" "1000" "8000"
        set_gpu_power_levels 2 6
    fi

    log_info "Policy PERFORMANCE applied (gaming=$gaming)"
}

# ══════════════════════════════════════════════════════════════════════════════
# BALANCED  — temp 42-48°C, score 20-60
# Normal operation. Focus on heat mitigation without breaking UI smoothness.
# ══════════════════════════════════════════════════════════════════════════════
_policy_balanced() {
    local gaming="$1"

    if $gaming; then
        # Gaming balanced: Phone is warming up. Cap max ceilings.
        # BIG capped at 85%, PRIME capped at 80% to stop thermal runaway.
        apply_cluster_settings 0 "$ACTIVE_GOV" 20 90 "1209600" "80" "1000" "6000"
        apply_cluster_settings 1 "$ACTIVE_GOV" 25 85 "1881600" "85" "1000" "8000"
        apply_cluster_settings 2 "$ACTIVE_GOV" 25 80 "2112000" "90" "1000" "10000"
        # GPU: ceiling PL2 (950MHz), floor PL6 (684MHz)
        set_gpu_power_levels 2 6

    else
        # Standard balanced UI: Slightly slower upscale to prevent heat.
        apply_cluster_settings 0 "$ACTIVE_GOV" 15 85 "806400"  "85" "2000" "4000"
        apply_cluster_settings 1 "$ACTIVE_GOV" 20 80 "1267200" "85" "2000" "5000"
        apply_cluster_settings 2 "$ACTIVE_GOV" 20 75 "1612800" "90" "2000" "6000"
        # GPU: ceiling PL3 (900MHz), floor PL8 (500MHz)
        set_gpu_power_levels 3 8
    fi

    log_info "Policy BALANCED applied (gaming=$gaming)"
}

# ══════════════════════════════════════════════════════════════════════════════
# CONSERVATIVE  — temp 55-65°C, score -20 to 20
# Throttle background/LITTLE cluster. Preserve BIG+PRIME for foreground.
# Gaming: push all non-game threads to LITTLE; BIG/PRIME stay uncapped.
# ══════════════════════════════════════════════════════════════════════════════
_policy_conservative() {
    local gaming="$1"

    if $gaming; then
        # LITTLE: throttled — background work gets capped at 75%
        apply_cluster_settings 0 "$ACTIVE_GOV" 20 75  "1209600" "90" "3000" "3000"

        # BIG: maintained — game's primary threads stay fast
        apply_cluster_settings 1 "$ACTIVE_GOV" 30 100 "2342400" "85" "1000" "8000"

        # PRIME: slight ceiling cap to 90% to reduce heat on hottest core
        apply_cluster_settings 2 "$ACTIVE_GOV" 30 90  "2419200" "88" "500"  "10000"

        # GPU: ceiling PL1 (1000MHz), floor PL6 (684MHz)
        set_gpu_power_levels 1 6

        # Push background daemons off BIG cores
        _constrain_background_to_little

    else
        apply_cluster_settings 0 "$ACTIVE_GOV" 15 70  "806400"  "90" "4000" "2000"
        apply_cluster_settings 1 "$ACTIVE_GOV" 20 85  "1881600" "88" "3000" "4000"
        apply_cluster_settings 2 "$ACTIVE_GOV" 20 80  "2112000" "90" "2000" "5000"
        set_gpu_power_levels 2 8
    fi

    log_info "Policy CONSERVATIVE applied (gaming=$gaming)"
}

# ══════════════════════════════════════════════════════════════════════════════
# POWERSAVE  — temp 65-72°C, score -60 to -20
# Significant throttle. During gaming: BIG capped at 80%, PRIME at 70%.
# Maintains minimum viable 30fps headroom for most titles.
# ══════════════════════════════════════════════════════════════════════════════
_policy_powersave() {
    local gaming="$1"
    local event_type="$2"

    if $gaming; then
        # LITTLE: hard cap at 60% (1209600 kHz) — bg tasks only
        apply_cluster_settings 0 "$ACTIVE_GOV" 15 60  "806400"  "95" "8000" "2000"

        # BIG: capped at 80% (2242560 → nearest step 2188800 kHz)
        # Slow upscale to avoid heat spikes, hold freq when loaded
        apply_cluster_settings 1 "$ACTIVE_GOV" 25 80  "1881600" "88" "4000" "6000"

        # PRIME: capped at 70% (2110080 → 2112000 kHz)
        # Higher hispeed_load so it doesn't boost unless truly needed
        apply_cluster_settings 2 "$ACTIVE_GOV" 20 70  "2112000" "92" "3000" "5000"

        # GPU: ceiling PL3 (900MHz), floor PL8 (500MHz) — meaningful reduction
        set_gpu_power_levels 3 8

        _constrain_background_to_little
        [ "$event_type" = "transition" ] && _drop_page_cache

    else
        apply_cluster_settings 0 "$ACTIVE_GOV" 10 50  "595200"  "95" "12000" "1000"
        apply_cluster_settings 1 "$ACTIVE_GOV" 15 60  "1267200" "90" "8000"  "2000"
        apply_cluster_settings 2 "$ACTIVE_GOV" 15 55  "1612800" "92" "6000"  "2000"
        set_gpu_power_levels 5 10
    fi

    log_info "Policy POWERSAVE applied (gaming=$gaming)"
}

# ══════════════════════════════════════════════════════════════════════════════
# SUSPEND (Screen Off) - Lowest possible frequencies
# Instant cool-down when phone is locked/in pocket.
# ══════════════════════════════════════════════════════════════════════════════
_policy_suspend() {
    # All clusters locked to absolute minimum. Use ACTIVE_GOV to avoid "powersave" not found failures
    apply_cluster_settings 0 "$ACTIVE_GOV" 0 30 "" "" "32000" "500"
    apply_cluster_settings 1 "$ACTIVE_GOV" 0 20 "" "" "32000" "500"
    apply_cluster_settings 2 "$ACTIVE_GOV" 0 20 "" "" "32000" "500"

    # GPU locked to minimum
    set_gpu_power_levels 10 10

    # Force background cpuset
    _constrain_background_to_little

    log_info "Policy SUSPEND applied (Screen Off)"
}

# ══════════════════════════════════════════════════════════════════════════════
# EMERGENCY COOL  — temp >68°C, score <-60
# Prevent thermal shutdown. Minimal viable operation.
# Releases automatically once AI score recovers above -20.
# ══════════════════════════════════════════════════════════════════════════════
_policy_emergency() {
    local event_type="$1"
    log_warn "EMERGENCY COOLING: temp critical — maximum throttle engaged"

    # All clusters hard-capped at 50%. Use ACTIVE_GOV to avoid "powersave" not found failures
    apply_cluster_settings 0 "$ACTIVE_GOV" 10 50 "" "" "32000" "500"
    apply_cluster_settings 1 "$ACTIVE_GOV" 10 50 "" "" "32000" "500"
    apply_cluster_settings 2 "$ACTIVE_GOV" 10 45 "" "" "32000" "500"

    # GPU to near-minimum: ceiling PL6 (684MHz), floor PL10 (255MHz)
    set_gpu_power_levels 6 10

    # Freeze cooling devices at max state to accelerate dissipation
    # cpufreq cooling devices let kernel enforce hard freq caps too
    for cdev_path in /sys/class/thermal/cooling_device*/; do
        local ctype
        ctype=$(cat "${cdev_path}type" 2>/dev/null)
        case "$ctype" in
            cpu-cluster*|cpufreq-cpu*)
                local cmax
                cmax=$(cat "${cdev_path}max_state" 2>/dev/null || echo "0")
                [ -w "${cdev_path}cur_state" ] && \
                    echo "$cmax" > "${cdev_path}cur_state" 2>/dev/null || true
                ;;
        esac
    done

    if [ "$event_type" = "transition" ]; then
        _drop_page_cache
        _drop_slab_cache
    fi

    log_warn "Emergency cooling active — will auto-release when score recovers"
}

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

# Move non-foreground processes to LITTLE cores (cpu0-2)
# Uses /dev/cpuset/background (confirmed writable on peridot)
_constrain_background_to_little() {
    # Dynamically find the little range from CPU_CLUSTERS_0 space separated string
    local first_cpu=$(echo "$CPU_CLUSTERS_0" | awk '{print $1}')
    local last_cpu=$(echo "$CPU_CLUSTERS_0" | awk '{print $NF}')
    local little_cpu_range="${first_cpu}-${last_cpu}"

    local cpus_file="cpus"
    [ "$CPUSET_ROOT" = "/sys/fs/cgroup" ] && cpus_file="cpuset.cpus"

    if [ -w "$CPUSET_ROOT/background/$cpus_file" ]; then
        sysfs_write "$little_cpu_range" "$CPUSET_ROOT/background/$cpus_file"
        log_debug "Background cpuset constrained to $little_cpu_range"
    fi
    if [ -w "$CPUSET_ROOT/system-background/$cpus_file" ]; then
        sysfs_write "$little_cpu_range" "$CPUSET_ROOT/system-background/$cpus_file"
    fi
}

# Restore cpusets to original snapshot values
_restore_cpusets() {
    local cpus_file="cpus"
    [ "$CPUSET_ROOT" = "/sys/fs/cgroup" ] && cpus_file="cpuset.cpus"

    [ -w "$CPUSET_ROOT/background/$cpus_file" ]        && [ -n "$CPUSET_BG" ]     && echo "$CPUSET_BG" > "$CPUSET_ROOT/background/$cpus_file" 2>/dev/null || true
    [ -w "$CPUSET_ROOT/system-background/$cpus_file" ] && [ -n "$CPUSET_SYSBG" ]  && echo "$CPUSET_SYSBG" > "$CPUSET_ROOT/system-background/$cpus_file" 2>/dev/null || true
    [ -w "$CPUSET_ROOT/foreground/$cpus_file" ]        && [ -n "$CPUSET_FG" ]     && echo "$CPUSET_FG" > "$CPUSET_ROOT/foreground/$cpus_file" 2>/dev/null || true
    [ -w "$CPUSET_ROOT/top-app/$cpus_file" ]           && [ -n "$CPUSET_TOPAPP" ] && echo "$CPUSET_TOPAPP" > "$CPUSET_ROOT/top-app/$cpus_file" 2>/dev/null || true
}

# Drop page cache only (safe during gaming — no app data lost)
_drop_page_cache() {
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    log_debug "Page cache dropped"
}

# Drop page + slab cache (emergency only)
_drop_slab_cache() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    log_debug "Slab+page cache dropped"
}

# ─── VM Parameters ────────────────────────────────────────────────────────────
# Device has 12GB RAM, swappiness=100 (stock HyperOS default).
# During gaming we want LESS swapping to prevent jank from ZRAM decompression.
_apply_vm_params() {
    local policy="$1"
    local gaming="$2"

    # Helper for checking writability to prevent blacklist buildup
    _safe_vm_write() {
        [ -w "$2" ] && echo "$1" > "$2" 2>/dev/null || true
    }

    case "$policy" in
        performance)
            # Minimal swapping — keep game assets in RAM
            _safe_vm_write 10  /proc/sys/vm/swappiness
            _safe_vm_write 10  /proc/sys/vm/vfs_cache_pressure
            _safe_vm_write 4000 /proc/sys/vm/dirty_expire_centisecs
            _safe_vm_write 0   /proc/sys/vm/compaction_proactiveness
            ;;
        balanced)
            local swap_val=40
            $gaming && swap_val=20
            _safe_vm_write "$swap_val" /proc/sys/vm/swappiness
            _safe_vm_write 50  /proc/sys/vm/vfs_cache_pressure
            _safe_vm_write 3000 /proc/sys/vm/dirty_expire_centisecs
            _safe_vm_write 0   /proc/sys/vm/compaction_proactiveness
            ;;
        conservative)
            local swap_val=60
            $gaming && swap_val=30
            _safe_vm_write "$swap_val" /proc/sys/vm/swappiness
            _safe_vm_write 75  /proc/sys/vm/vfs_cache_pressure
            _safe_vm_write 2000 /proc/sys/vm/dirty_expire_centisecs
            ;;
        powersave|emergency_cool)
            # Restore to AOSP default swappiness (40, not HyperOS's 100)
            _safe_vm_write 40  /proc/sys/vm/swappiness
            _safe_vm_write 100 /proc/sys/vm/vfs_cache_pressure
            _safe_vm_write 1000 /proc/sys/vm/dirty_expire_centisecs
            _safe_vm_write 20  /proc/sys/vm/compaction_proactiveness
            ;;
    esac
}

# ─── I/O Scheduler ────────────────────────────────────────────────────────────
# Device uses /sys/block/sda (UFS). Available schedulers vary by kernel version.
# Check available options before writing to prevent silent failure or log spam.
_apply_io_scheduler() {
    local policy="$1"
    local target=""

    for block in /sys/block/sda /sys/block/sdb /sys/block/sdc /sys/block/mmcblk0; do
        local sched_path="$block/queue/scheduler"
        [ -w "$sched_path" ] || continue

        local available=$(cat "$sched_path" 2>/dev/null | tr -d '[]')
        local chosen=""

        case "$policy" in
            performance)
                # Prefer zero queue latency
                for s in none noop mq-deadline deadline cfq; do
                    if echo "$available" | grep -qw "$s"; then chosen="$s"; break; fi
                done
                ;;
            powersave|emergency_cool)
                # Prefer fair/power-friendly
                for s in bfq cfq mq-deadline deadline; do
                    if echo "$available" | grep -qw "$s"; then chosen="$s"; break; fi
                done
                ;;
            *)
                # Balanced
                for s in mq-deadline deadline cfq; do
                    if echo "$available" | grep -qw "$s"; then chosen="$s"; break; fi
                done
                ;;
        esac

        if [ -n "$chosen" ]; then
            sysfs_write "$chosen" "$sched_path" || true
            target="$chosen"
        fi
    done

    [ -n "$target" ] && log_debug "I/O scheduler -> $target"
}

# ─── cpuset Management ────────────────────────────────────────────────────────
_apply_cpuset() {
    local policy="$1"
    local gaming="$2"

    case "$policy" in
        conservative|powersave)
            $gaming && _constrain_background_to_little || _restore_cpusets
            ;;
        emergency_cool)
            # In emergency: everything except top-app goes to LITTLE
            _constrain_background_to_little
            ;;
        *)
            # performance/balanced: restore full access
            _restore_cpusets
            ;;
    esac
}

# ─── Universal GPU Control Fallbacks ──────────────────────────────────────────
# Standard paths for generic kernels / Exynos / MediaTek / Older Adreno
GPU_GOVERNOR_NODES="
/sys/class/kgsl/kgsl-3d0/devfreq/governor
/sys/class/devfreq/1c00000.qcom,kgsl-3d0/governor
/sys/class/devfreq/gpufreq/governor
/sys/devices/platform/g3d/devfreq/g3d/governor
"

GPU_MIN_FREQ_NODES="
/sys/class/kgsl/kgsl-3d0/devfreq/min_freq
/sys/class/devfreq/1c00000.qcom,kgsl-3d0/min_freq
/sys/class/devfreq/gpufreq/min_freq
/sys/devices/platform/g3d/devfreq/g3d/min_freq
"

GPU_MAX_FREQ_NODES="
/sys/class/kgsl/kgsl-3d0/devfreq/max_freq
/sys/class/devfreq/1c00000.qcom,kgsl-3d0/max_freq
/sys/class/devfreq/gpufreq/max_freq
/sys/devices/platform/g3d/devfreq/g3d/max_freq
"

apply_universal_gpu_control() {
    local target_gov="$1"

    # Try generic governor writes
    for node in $GPU_GOVERNOR_NODES; do
        if [ -w "$node" ]; then
             sysfs_write "$target_gov" "$node"
        fi
    done
}
