#!/system/bin/sh
# ThermalAI - Charge Heat Control
# Dynamically adjusts maximum charging current to prevent the phone from overheating
# while plugged in.

# Charging paths (qualcomm standard)
BATT_CURRENT_MAX="/sys/class/power_supply/battery/constant_charge_current_max"
BATT_CURRENT_NOW="/sys/class/power_supply/battery/current_now"

# Set limits in microamps (uA)
# 3000mA = 3000000 uA
# 2000mA = 2000000 uA
# 1000mA = 1000000 uA
# 500mA  = 500000 uA

# Battery Paths
BATT_TEMP="/sys/class/power_supply/battery/temp"
BATT_CAPACITY="/sys/class/power_supply/battery/capacity"

# ─── Adjust Charging Current ──────────────────────────────────────────────────
apply_charging_control() {
    local policy="$1"
    local is_gaming="$2"
    local max_current_ua="0" # 0 means disabled / let hardware decide

    # Read actual battery temperature (usually in tenths of a degree, e.g., 400 = 40.0C)
    local batt_temp_raw=0
    local batt_temp=0
    if [ -f "$BATT_TEMP" ]; then
        batt_temp_raw=$(cat "$BATT_TEMP" 2>/dev/null || echo 0)
        batt_temp=$((batt_temp_raw / 10))
    fi

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")

    if [ "$is_gaming" = "true" ] && [ "$current_plugged" = "Charging" ]; then
        log_warn "Compound Guard: Gaming + Charging detected. Proactively capping charge at 1A."
        sysfs_write "1000000" "$BATT_CURRENT_MAX"
        apply_universal_charging_control "1000000"
        return 0
    fi

    if [ ! -w "$BATT_CURRENT_MAX" ]; then
        return 0
    fi

    # Read battery capacity / SOC percentage
    local batt_level=0
    if [ -f "$BATT_CAPACITY" ]; then
        batt_level=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 0)
    fi

    # SOC-based graceful degradation (Charge slower as it gets full)
    if [ "$batt_level" -ge 90 ]; then
        # Above 90%, limit to trickle regardless of thermal policy
        sysfs_write "1000000" "$BATT_CURRENT_MAX"
        apply_universal_charging_control "1000000"
        return 0
    fi

    # Target: keep battery below 39C
    if [ "$batt_temp" -ge 39 ]; then
        log_warn "Battery Temp Critical (${batt_temp}°C) - Throttling to trickle charge"
        max_current_ua="500000"
    elif [ "$batt_temp" -ge 38 ]; then
        max_current_ua="1000000"
    elif [ "$batt_temp" -ge 37 ]; then
        max_current_ua="2000000"
    elif [ "$batt_temp" -ge 35 ]; then
        max_current_ua="3000000"
    else
        max_current_ua="5000000" # Cool, full speed
    fi

    # Ensure we don't accidentally completely disable charging unless intended
    if [ "$max_current_ua" != "0" ]; then
        sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        apply_universal_charging_control "$max_current_ua"
        log_debug "Charging current limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)"
    fi
}

# ─── Restore Charging Control ──────────────────────────────────────────────────
restore_charging_control() {
    # Qualcomm standard for "unlimited" or hardware max is usually very high or 0
    # Writing 5000000 (5A) usually restores full speed
    if [ -w "$BATT_CURRENT_MAX" ]; then
         echo "5000000" > "$BATT_CURRENT_MAX" 2>/dev/null
         log_info "Charging limits restored to hardware default"
    fi
    apply_universal_charging_control "5000000"
}

# ─── Universal Charging Control Fallbacks ─────────────────────────────────────
# Since node paths differ greatly between custom ROMs and kernels (e.g., Mediatek,
# Exynos, custom Qualcomm trees), we maintain an array of common limits.

CHARGE_NODES="
/sys/class/power_supply/battery/constant_charge_current_max
/sys/class/power_supply/main/constant_charge_current_max
/sys/class/qcom-battery/restricted_current
/sys/devices/virtual/power_supply/battery/current_max
/sys/class/power_supply/battery/step_charging_current
/sys/class/power_supply/bms/constant_charge_current_max
"

apply_universal_charging_control() {
    local target_ua="$1"
    local applied="false"

    for node in $CHARGE_NODES; do
        if [ -w "$node" ]; then
             sysfs_write "$target_ua" "$node"
             applied="true"
        fi
    done

    if [ "$applied" = "false" ]; then
        log_debug "No compatible fast-charging control node found on this kernel."
    fi
}
