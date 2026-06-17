#!/system/bin/sh
# ThermalAI - Logger

LOG_FILE="/data/local/tmp/thermalai.log"
LOG_LEVEL="${THERMALAI_LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
MAX_LOG_SIZE=524288  # 512KB before rotation

_log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local line="[$timestamp] [$level] $msg"
    
    echo "$line" >> "$LOG_FILE" 2>/dev/null
    
    # Also log to logcat for ADB visibility
    log -t ThermalAI -p "${level:0:1}" "$msg" 2>/dev/null || true
    
    # Rotate if too large
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
    if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
}

log_debug() { [ "$LOG_LEVEL" = "DEBUG" ] && _log "DEBUG" "$@"; }
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
