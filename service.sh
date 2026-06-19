#!/system/bin/sh
# ThermalAI - Boot Service
# !! KernelSU on POCO F6 (peridot) / AOSP Android 16 / GlaciumKernel !!
# Module path: /data/adb/modules/thermalai  (confirmed by device check)

MODDIR="${0%/*}"

# ─── Wait for full boot ───────────────────────────────────────────────────────
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 3
done

# AOSP starts services faster than HyperOS; 5s is sufficient for mi_thermald
sleep 5

. "$MODDIR/scripts/logger.sh"
. "$MODDIR/scripts/state_manager.sh"
. "$MODDIR/scripts/advanced_ai.sh"
. "$MODDIR/scripts/governor_tuner.sh"

log_info "════════════════════════════════════════"
log_info " ThermalAI boot service starting"
log_info " Device  : $(getprop ro.product.model) ($(getprop ro.product.device))"
log_info " ROM     : $(getprop ro.build.display.id)"
log_info " Android : $(getprop ro.build.version.release)"
log_info " SoC     : $(getprop ro.board.platform)"
log_info " KSU     : $(ksud -V 2>/dev/null || echo 'unknown')"
log_info "════════════════════════════════════════"

# ─── Discover hardware ────────────────────────────────────────────────────────
discover_cpu_topology

# ─── Stop mi_thermald (present on both HyperOS and AOSP on peridot) ──────────
# Confirmed running as pid=2123 on AOSP (was 2418 on HyperOS).
# mi_thermald ships in the vendor partition — survives ROM flash.
disable_stock_thermal
take_snapshot 2>/dev/null

# ─── Verify critical write paths before starting daemon ──────────────────────
CRITICAL_OK=true
for chk in \
    "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" \
    "/sys/class/kgsl/kgsl-3d0/devfreq/governor" \
    "/sys/class/kgsl/kgsl-3d0/min_pwrlevel" \
    "/sys/class/kgsl/kgsl-3d0/max_pwrlevel" \
    "/proc/sys/vm/swappiness" \
    "/dev/cpuset/background/cpus"; do
    if [ ! -w "$chk" ]; then
        log_warn "Critical path not writable: $chk"
        CRITICAL_OK=false
    fi
done

if ! $CRITICAL_OK; then
    log_warn "Some paths are not writable — daemon will run but some features may be limited"
fi

# ─── Bootloop Protection ──────────────────────────────────────────────────────
LOCK_FILE="/data/local/tmp/thermalai.lock"

# If the lock file exists from a previous boot and wasn't cleared, it means the
# device crashed shortly after our service started (potential bootloop).
if [ -f "$LOCK_FILE" ]; then
    log_error "CRITICAL: Lock file found! Possible bootloop detected."
    log_error "Aborting ThermalAI startup and restoring stock thermal."
    # Source governor tuner just to have access to restore_snapshot
    restore_stock_thermal
    . "$MODDIR/scripts/governor_tuner.sh" 2>/dev/null
    restore_snapshot
    restore_stock_thermal
    exit 1
fi

# Create lock file to monitor stability
touch "$LOCK_FILE"

# Background task to clear the lock file after 2 minutes of uptime (meaning boot was stable)
(
    sleep 120
    rm -f "$LOCK_FILE"
    log_info "System stable for 2 minutes. Bootloop lock cleared."
) &

# ─── Launch AI daemon ─────────────────────────────────────────────────────────
log_info "Launching AI thermal daemon..."
sh "$MODDIR/scripts/thermal_ai.sh" &
DAEMON_PID=$!
echo "$DAEMON_PID" > /data/local/tmp/thermalai.pid

log_info "ThermalAI daemon started (PID=$DAEMON_PID)"
log_info "Log: /data/local/tmp/thermalai.log"
