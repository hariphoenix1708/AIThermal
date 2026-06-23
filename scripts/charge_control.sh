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
BATT_CAPACITY="/sys/class/power_supply/battery/capacity"

# ─── Robust Battery Temp Read ─────────────────────────────────────────────────
get_robust_battery_temp() {
    local batt_temp=0

    # Best reliable path on most Android devices
    local primary_path="/sys/class/power_supply/battery/temp"

    if [ -f "$primary_path" ]; then
        batt_temp=$(cat "$primary_path" 2>/dev/null || echo 0)
        [ "$batt_temp" -gt 10000 ] && batt_temp=$((batt_temp / 100))
        if [ "$batt_temp" -ge 100 ] && [ "$batt_temp" -le 800 ]; then
            echo "$batt_temp"
            return
        fi
    fi

    # Fallback to dynamic thermal zones
    # We want MIN of matched to avoid charger_therm inflating actual battery temp
    local min_t=999
    local found_exact_battery="false"

    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')

        # If we find EXACTLY "battery", take it and exit loop.
        if [ "$type_val" = "battery" ]; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 10000 ] && raw=$((raw / 100))
                if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                    echo "$raw"
                    return
                fi
            fi
        fi

        # Otherwise, collect matches and find the minimum valid one
        if echo "$type_val" | grep -iqE "battery|charger_therm|vbat"; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 10000 ] && raw=$((raw / 100))
                if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                    if [ "$raw" -lt "$min_t" ]; then
                        min_t="$raw"
                    fi
                fi
            fi
        fi
    done

    if [ "$min_t" -lt 999 ]; then
        echo "$min_t"
    else
        # Safe default
        echo 350
    fi
}

# ─── Adjust Charging Current ──────────────────────────────────────────────────
# Global Charging State Machine variables
CHARGE_STATE="NORMAL" # States: NORMAL, GAMING, THERMAL_THROTTLE, EMERGENCY

apply_charging_control() {
    local realtime_gaming="$1"  # Unlatched true/false indicating instant game status
    local max_current_ua="5000000"

    # Read actual battery temperature safely
    local batt_temp_raw
    batt_temp_raw=$(get_robust_battery_temp)
    local batt_temp=$((batt_temp_raw / 10))

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")

    # Read battery capacity / SOC percentage
    local batt_level=0
    if [ -f "$BATT_CAPACITY" ]; then
        batt_level=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 0)
    fi

    # 1. State Machine Transitions
    local next_state="$CHARGE_STATE"

    if [ "$batt_temp" -ge 40 ]; then
        next_state="EMERGENCY"
    elif [ "$batt_temp" -ge 37 ]; then
        next_state="THERMAL_THROTTLE"
    elif [ "$batt_temp" -le 35 ] && { [ "$CHARGE_STATE" = "THERMAL_THROTTLE" ] || [ "$CHARGE_STATE" = "EMERGENCY" ]; }; then
        # Hysteresis: Only exit thermal throttling/emergency when temp drops to 35C
        if [ "$realtime_gaming" = "true" ]; then
            next_state="GAMING"
        else
            next_state="NORMAL"
        fi
    elif [ "$CHARGE_STATE" != "THERMAL_THROTTLE" ] && [ "$CHARGE_STATE" != "EMERGENCY" ]; then
        # We are not throttling. Choose base state based on gaming.
        if [ "$realtime_gaming" = "true" ]; then
            next_state="GAMING"
        else
            next_state="NORMAL"
        fi
    fi

    # Only enforce limits if the device is actually charging
    if [ "$current_plugged" != "Charging" ]; then
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT=""
        return 0
    fi

    # Force a state transition logging flush if state changed
    if [ "$CHARGE_STATE" != "$next_state" ]; then
        log_info "Charging State Transition: $CHARGE_STATE -> $next_state (batt_temp=${batt_temp}°C)"
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT="" # invalidate cache to force immediate application
    fi

    # 2. Apply Limits Based on Current State
    if [ "$CHARGE_STATE" = "EMERGENCY" ]; then
        max_current_ua="500000"
    elif [ "$CHARGE_STATE" = "THERMAL_THROTTLE" ]; then
        if [ "$batt_temp" -ge 39 ]; then
            max_current_ua="500000"
        elif [ "$batt_temp" -ge 38 ]; then
            max_current_ua="1000000"
        else
            max_current_ua="1500000"
        fi
    elif [ "$CHARGE_STATE" = "GAMING" ]; then
        if [ "$batt_temp" -ge 36 ]; then
            max_current_ua="1000000"
        else
            max_current_ua="2000000"
        fi
    else
        # NORMAL state
        if [ "$batt_temp" -ge 36 ]; then
            max_current_ua="3000000"
        else
            max_current_ua="5000000"
        fi
    fi

    # 3. Apply SOC-based graceful degradation overriding everything except emergency limits
    if [ "$batt_level" -ge 90 ] && [ "$max_current_ua" -gt 1000000 ]; then
        max_current_ua="1000000"
    fi

    # 4. Hardware Enforcement
    if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"

        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C, state=$CHARGE_STATE)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null

        if [ "$CHARGE_STATE" = "EMERGENCY" ]; then
            log_warn "Battery Temp Critical (${batt_temp}°C) - Throttling to $((max_current_ua / 1000))mA"
        elif [ "$CHARGE_STATE" = "NORMAL" ] && [ "$max_current_ua" = "5000000" ]; then
            log_info "Charging limit released to 5A (batt_temp=${batt_temp}°C)"
        else
            log_info "Charging limit adjusted to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C, state=$CHARGE_STATE)"
        fi

        LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
    else
        # Prevent hardware resetting it under our nose without spamming log
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"
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
/sys/class/power_supply/battery/constant_charge_current
/sys/class/power_supply/main/constant_charge_current_max
/sys/class/qcom-battery/restricted_current
/sys/devices/virtual/power_supply/battery/current_max
/sys/class/power_supply/battery/step_charging_current
/sys/class/power_supply/bms/constant_charge_current_max
/sys/class/power_supply/usb/input_current_limit
/sys/class/power_supply/usb/current_max
/sys/class/power_supply/wireless/input_current_limit
/sys/devices/platform/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/power_supply/battery/constant_charge_current
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

    # Dynamic search for any other power_supply nodes with input_current_limit or constant_charge_current
    for dyn_node in /sys/class/power_supply/*/input_current_limit /sys/class/power_supply/*/constant_charge_current; do
        if [ -w "$dyn_node" ]; then
            sysfs_write "$target_ua" "$dyn_node"
            applied="true"
        fi
    done

    if [ "$applied" = "false" ]; then
        log_debug "No compatible fast-charging control node found on this kernel."
    fi
}
