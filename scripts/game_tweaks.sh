#!/system/bin/sh
# ThermalAI - Gaming Enhancements
# Applies optional network, display, and touch improvements when gaming

# ─── Network Tweaks (TCP/Wi-Fi) ────────────────────────────────────────────────
_apply_network_tweaks() {
    local enable="$1"

    if [ "$enable" = "true" ]; then
        if check_network_quality; then
            # Enable BBR congestion control if kernel supports it
            if [ -f "/proc/sys/net/ipv4/tcp_available_congestion_control" ]; then
                if grep -q "bbr" "/proc/sys/net/ipv4/tcp_available_congestion_control"; then
                    echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
                fi
            fi
            # Reduce TCP SYN retries to fail fast in games
            echo 2 > /proc/sys/net/ipv4/tcp_syn_retries 2>/dev/null
            echo 2 > /proc/sys/net/ipv4/tcp_synack_retries 2>/dev/null
            # Disable Wi-Fi power saving (if supported by wlan driver path)
            if [ -w "/sys/module/wlan/parameters/fwpath" ]; then
                 # Note: actual wifi power save node varies heavily by device
                 # Standard fallback is checking standard wlan0
                 iw dev wlan0 set power_save off 2>/dev/null || true
            fi
            log_debug "Gaming network tweaks applied (BBR, Fast Fail, Wi-Fi PS Off)"
        else
            log_warn "Network quality poor, bypassing gaming network enhancements."
        fi
    else
        # Restore to default
        if [ -f "/proc/sys/net/ipv4/tcp_available_congestion_control" ]; then
            if grep -q "cubic" "/proc/sys/net/ipv4/tcp_available_congestion_control"; then
                echo "cubic" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
            fi
        fi
        echo 6 > /proc/sys/net/ipv4/tcp_syn_retries 2>/dev/null
        echo 5 > /proc/sys/net/ipv4/tcp_synack_retries 2>/dev/null
        iw dev wlan0 set power_save on 2>/dev/null || true
        log_debug "Network tweaks restored to default"
    fi
}

# ─── Touch and Display Tweaks ──────────────────────────────────────────────────
_apply_touch_display_tweaks() {
    local enable="$1"

    if [ "$enable" = "true" ]; then
        # Force high touch sampling rate if available on Xiaomi/POCO
        if [ -w "/sys/class/touch/touch_dev/touch_game_mode" ]; then
            echo 1 > /sys/class/touch/touch_dev/touch_game_mode 2>/dev/null
        fi
        if [ -w "/sys/devices/virtual/touch/tp_dev/bump_sample_rate" ]; then
             echo 1 > /sys/devices/virtual/touch/tp_dev/bump_sample_rate 2>/dev/null
        fi
        log_debug "Gaming touch sampling tweaks applied"
    else
        # Restore touch mode
        if [ -w "/sys/class/touch/touch_dev/touch_game_mode" ]; then
            echo 0 > /sys/class/touch/touch_dev/touch_game_mode 2>/dev/null
        fi
        if [ -w "/sys/devices/virtual/touch/tp_dev/bump_sample_rate" ]; then
             echo 0 > /sys/devices/virtual/touch/tp_dev/bump_sample_rate 2>/dev/null
        fi
        log_debug "Touch sampling tweaks restored"
    fi
}

# ─── Main Game Enhancements Router ─────────────────────────────────────────────
apply_gaming_enhancements() {
    local is_gaming="$1"

    # We use a state file to ensure we don't repeatedly apply/restore tweaks
    local STATE_FILE="/data/local/tmp/thermalai.gaming_tweaks_state"

    if [ "$is_gaming" = "true" ]; then
        if [ ! -f "$STATE_FILE" ]; then
            _apply_network_tweaks "true"
            _apply_touch_display_tweaks "true"
            touch "$STATE_FILE"
        fi
    else
        if [ -f "$STATE_FILE" ]; then
            _apply_network_tweaks "false"
            _apply_touch_display_tweaks "false"
            rm -f "$STATE_FILE"
        fi
    fi
}

# Network Quality Check
check_network_quality() {
    local ping_result=$(ping -c 1 -W 1 8.8.8.8 2>/dev/null)
    if [ $? -eq 0 ]; then
        # Ping successful, check latency
        local latency=$(echo "$ping_result" | awk -F'time=' '/time=/{print $2}' | cut -d' ' -f1 | cut -d'.' -f1)
        if [ "$latency" -gt 150 ]; then
            log_debug "Network latency high ($latency ms), skipping aggressive network tweaks."
            return 1 # High latency
        fi
        return 0 # Good quality
    fi
    log_debug "Network unreachable, skipping network tweaks."
    return 1 # Unreachable
}
