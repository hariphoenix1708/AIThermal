#!/system/bin/sh
# ThermalAI - Uninstall script
# Executed by Magisk/KernelSU when the module is uninstalled.

# Path to local tmp files
PID_FILE="/data/local/tmp/thermalai.pid"
LOG_FILE="/data/local/tmp/thermalai.log"
LOCK_FILE="/data/local/tmp/thermalai.lock"

# Clean up logs and runtime files
rm -f "$PID_FILE"
rm -f "$LOG_FILE"
rm -f "$LOG_FILE.1"
rm -f "$LOCK_FILE"
rm -f "/data/local/tmp/thermalai.gaming_tweaks_state"
rm -f "/data/local/tmp/thermalai.snapshot"
rm -rf "/data/local/tmp/thermalai.game_profiles"
rm -f "/data/local/tmp/thermalai.calibration"

# The module's shutdown logic or the OS reboot will naturally revert kernel settings
# to their stock values, since we don't permanently flash them to boot partitions.
# But just in case, we log the cleanup.
log -t ThermalAI -p I "Module uninstalled. Temporary files cleaned up."
