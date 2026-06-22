#!/system/bin/sh
# ThermalAI - Uninstall script
# Executed by Magisk/KernelSU when the module is uninstalled.

MODDIR="${0%/*}"

# Path to local tmp files
PID_FILE="/data/local/tmp/thermalai.pid"
LOG_FILE="/data/local/tmp/thermalai.log"
LOCK_FILE="/data/local/tmp/thermalai.lock"

# Stop daemon if running
if [ -f "$PID_FILE" ]; then
    DAEMON_PID=$(cat "$PID_FILE")
    if [ -n "$DAEMON_PID" ]; then
        kill "$DAEMON_PID" 2>/dev/null
    fi
fi

# Restore settings
if [ -f "$MODDIR/scripts/governor_tuner.sh" ] && [ -f "$MODDIR/scripts/state_manager.sh" ]; then
    . "$MODDIR/scripts/logger.sh"
    . "$MODDIR/scripts/governor_tuner.sh"
    . "$MODDIR/scripts/state_manager.sh"
    restore_stock_thermal
    restore_snapshot
fi

# Clean up logs and runtime files
rm -f "$PID_FILE"
rm -f "$LOG_FILE"
rm -f "$LOG_FILE.1"
rm -f "$LOCK_FILE"
rm -f "/data/local/tmp/thermalai_verbose.log"
rm -f "/data/local/tmp/thermalai_verbose.log.1"
rm -f "/data/local/tmp/thermalai.gaming_tweaks_state"
rm -f "/data/local/tmp/thermalai.snapshot"
rm -rf "/data/local/tmp/thermalai.game_profiles"
rm -f "/data/local/tmp/thermalai.calibration"
rm -f "/data/local/tmp/thermalai.calibration_offset"

log -t ThermalAI -p I "Module uninstalled. Daemon stopped, settings restored, and temporary files cleaned up."
