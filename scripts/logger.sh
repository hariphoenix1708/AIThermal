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

# ─── Auto-Blacklist Sysfs Writer ──────────────────────────────────────────────
BLACKLIST_DIR="/data/local/tmp/thermalai.blacklist"
mkdir -p "$BLACKLIST_DIR" 2>/dev/null || true

sysfs_write() {
    local val="$1"
    local path="$2"

    [ -z "$path" ] && return 1

    # Generate a safe filename for the blacklist based on the path
    local safe_path=$(echo "$path" | tr '/' '_')
    local blacklist_file="$BLACKLIST_DIR/$safe_path.blacklisted"
    local fail_file="$BLACKLIST_DIR/$safe_path.fails"

    # Check if blacklisted
    if [ -f "$blacklist_file" ]; then
        local blacklist_time=$(cat "$blacklist_file" 2>/dev/null || echo 0)
        local current_time=$(date +%s)

        # Periodically re-test after 1 hour (3600 seconds)
        if [ $((current_time - blacklist_time)) -gt 3600 ]; then
            log_info "Re-testing blacklisted node: $path"
            rm -f "$blacklist_file"
            rm -f "$fail_file"
        else
            return 1 # Skip write, still blacklisted
        fi
    fi

    # Attempt write
    if [ -w "$path" ]; then
        # Try to write
        if ! echo "$val" > "$path" 2>/dev/null; then
             # Write failed
             local fails=$(cat "$fail_file" 2>/dev/null || echo 0)
             fails=$((fails + 1))
             echo "$fails" > "$fail_file"

             if [ "$fails" -ge 3 ]; then
                 log_warn "Auto-Blacklisting node due to write failures: $path"
                 date +%s > "$blacklist_file"
             fi
             return 1
        fi

        # Clear fails on success
        rm -f "$fail_file"
        return 0
    else
        # Not writable / doesn't exist
        local fails=$(cat "$fail_file" 2>/dev/null || echo 0)
        fails=$((fails + 1))
        echo "$fails" > "$fail_file"

        if [ "$fails" -ge 3 ]; then
            log_warn "Auto-Blacklisting missing/read-only node: $path"
            date +%s > "$blacklist_file"
        fi
        return 1
    fi
}
