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
LEARNED_CHARGE_PROFILE="/data/local/tmp/thermalai.charge_profile"

# Initialize learned dynamic current
if [ -f "$LEARNED_CHARGE_PROFILE" ]; then
    DYNAMIC_CURRENT_UA=$(cat "$LEARNED_CHARGE_PROFILE" 2>/dev/null || echo "3000000")
else
    DYNAMIC_CURRENT_UA=3000000
fi
# Hardware physical limit bounds
MIN_CURRENT_UA=3500000
MAX_CURRENT_UA=5000000
EMERGENCY_MIN_CURRENT_UA=1500000

LAST_APPLIED_CHARGE_LIMIT=""
LAST_ENFORCE_TIME=0
PREV_BATT_TEMP=""
BATT_TEMP_SLOPE=0

apply_charging_control() {
    local realtime_gaming="$1"  # Unlatched true/false indicating instant game status
    local max_current_ua="$DYNAMIC_CURRENT_UA"

    # Read actual battery temperature safely
    local batt_temp_raw
    batt_temp_raw=$(get_robust_battery_temp)
    local batt_temp=$((batt_temp_raw / 10))

    if [ -n "$PREV_BATT_TEMP" ]; then
        BATT_TEMP_SLOPE=$((batt_temp - PREV_BATT_TEMP))
    fi
    PREV_BATT_TEMP=$batt_temp

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")

    # Read battery capacity / SOC percentage
    local batt_level=0
    if [ -f "$BATT_CAPACITY" ]; then
        batt_level=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 0)
    fi

    # 1. State Machine Transitions
    local next_state="$CHARGE_STATE"

    if [ "$realtime_gaming" = "true" ]; then
        if [ "$batt_temp" -gt 39 ]; then
            next_state="EMERGENCY"
        elif [ "$batt_temp" -ge 38 ]; then
            next_state="THERMAL_THROTTLE"
        elif [ "$batt_temp" -le 37 ] && { [ "$CHARGE_STATE" = "THERMAL_THROTTLE" ] || [ "$CHARGE_STATE" = "EMERGENCY" ]; }; then
            next_state="GAMING"
        elif [ "$CHARGE_STATE" != "THERMAL_THROTTLE" ] && [ "$CHARGE_STATE" != "EMERGENCY" ]; then
            next_state="GAMING"
        fi
    else
        if [ "$batt_temp" -gt 44 ]; then
            next_state="EMERGENCY"
        elif [ "$batt_temp" -ge 42 ]; then
            next_state="THERMAL_THROTTLE"
        elif [ "$batt_temp" -le 40 ] && { [ "$CHARGE_STATE" = "THERMAL_THROTTLE" ] || [ "$CHARGE_STATE" = "EMERGENCY" ]; }; then
            next_state="NORMAL"
        elif [ "$CHARGE_STATE" != "THERMAL_THROTTLE" ] && [ "$CHARGE_STATE" != "EMERGENCY" ]; then
            next_state="NORMAL"
        fi
    fi

    # Only enforce limits if the device is actually charging
    if [ "$current_plugged" != "Charging" ]; then
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT=""
        # Do not adapt learned current while disconnected
        return 0
    fi

    # Force a state transition logging flush if state changed
    if [ "$CHARGE_STATE" != "$next_state" ]; then
        log_info "Charging State Transition: $CHARGE_STATE -> $next_state (batt_temp=${batt_temp}°C)"
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT="" # invalidate cache to force immediate application

        # When shifting back to Normal/Gaming from Emergency/Throttle,
        # start from the stable min current and climb up slowly
        if [ "$next_state" = "NORMAL" ] || [ "$next_state" = "GAMING" ]; then
             DYNAMIC_CURRENT_UA=$MIN_CURRENT_UA
             rm -f "$LEARNED_CHARGE_PROFILE"
        fi
    fi

    # 2. Learning-based Step Adaptation
    if [ "$CHARGE_STATE" = "GAMING" ]; then
        if [ "$batt_temp" -lt 34 ]; then
            # Recover quickly
            if [ "$BATT_TEMP_SLOPE" -le 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA + 200000))
            fi
        elif [ "$batt_temp" -ge 34 ] && [ "$batt_temp" -lt 36 ]; then
            # Hold around 3500mA
            if [ "$DYNAMIC_CURRENT_UA" -gt 3500000 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 100000))
            elif [ "$DYNAMIC_CURRENT_UA" -lt 3500000 ] && [ "$BATT_TEMP_SLOPE" -le 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA + 100000))
            fi
        elif [ "$batt_temp" -ge 36 ] && [ "$batt_temp" -lt 38 ]; then
            if [ "$BATT_TEMP_SLOPE" -gt 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 100000))
            fi
        elif [ "$batt_temp" -ge 38 ] && [ "$batt_temp" -le 39 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 200000))
        fi
    elif [ "$CHARGE_STATE" = "NORMAL" ]; then
        if [ "$batt_temp" -lt 36 ]; then
            if [ "$BATT_TEMP_SLOPE" -le 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA + 200000))
            fi
        elif [ "$batt_temp" -ge 36 ] && [ "$batt_temp" -lt 40 ]; then
            if [ "$BATT_TEMP_SLOPE" -gt 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 100000))
            elif [ "$BATT_TEMP_SLOPE" -lt 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA + 100000))
            fi
        elif [ "$batt_temp" -ge 40 ] && [ "$batt_temp" -lt 42 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 200000))
        elif [ "$batt_temp" -ge 42 ] && [ "$batt_temp" -le 44 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 300000))
        fi
    fi

    # 3. Apply Hard Limits Based on Current State (Overrides Learned Curve)
    if [ "$CHARGE_STATE" = "EMERGENCY" ]; then
        # Drop heavily until temperature falls
        DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 500000))
        max_current_ua=$DYNAMIC_CURRENT_UA
        if [ "$max_current_ua" -lt "$EMERGENCY_MIN_CURRENT_UA" ]; then
            max_current_ua=$EMERGENCY_MIN_CURRENT_UA
        fi
    elif [ "$CHARGE_STATE" = "THERMAL_THROTTLE" ]; then
        DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 300000))
        max_current_ua=$DYNAMIC_CURRENT_UA
        if [ "$max_current_ua" -lt "$MIN_CURRENT_UA" ]; then
            max_current_ua=$MIN_CURRENT_UA
        fi
    else
        # Clamp bounds normally
        [ "$DYNAMIC_CURRENT_UA" -gt "$MAX_CURRENT_UA" ] && DYNAMIC_CURRENT_UA="$MAX_CURRENT_UA"
        [ "$DYNAMIC_CURRENT_UA" -lt "$MIN_CURRENT_UA" ] && DYNAMIC_CURRENT_UA="$MIN_CURRENT_UA"
        max_current_ua="$DYNAMIC_CURRENT_UA"
    fi

    # Save learned optimal state occasionally
    if [ $((NOW_TIME % 60)) -eq 0 ]; then
        echo "$DYNAMIC_CURRENT_UA" > "$LEARNED_CHARGE_PROFILE"
    fi

    # 4. Apply SOC-based Graceful Degradation
    if [ "$batt_level" -ge 80 ]; then
        # 80-100% Conservative taper
        local taper_limit=1500000
        [ "$max_current_ua" -gt "$taper_limit" ] && max_current_ua="$taper_limit"
    elif [ "$batt_level" -ge 50 ]; then
        # 50-80% Balanced
        local balanced_limit=3500000
        [ "$max_current_ua" -gt "$balanced_limit" ] && max_current_ua="$balanced_limit"
    fi
    # 0-50% Aggressive charging allows up to MAX_CURRENT_UA if temps permit

    # 5. Hardware Enforcement
    if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"

        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C, state=$CHARGE_STATE)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null

        if [ "$CHARGE_STATE" = "EMERGENCY" ] || [ "$CHARGE_STATE" = "THERMAL_THROTTLE" ]; then
            log_warn "Battery Temp High (${batt_temp}°C) - Throttling to $((max_current_ua / 1000))mA"
        else
            log_info "Learned charging curve adjusted to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C, state=$CHARGE_STATE)"
        fi

        LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
        LAST_ENFORCE_TIME="$NOW_TIME"
    else
        # Prevent hardware resetting it under our nose without spamming log
        local time_since=$((NOW_TIME - LAST_ENFORCE_TIME))
        if [ "$time_since" -ge 30 ]; then
            if [ -w "$BATT_CURRENT_MAX" ]; then
                sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
            fi
            apply_universal_charging_control "$max_current_ua"
            LAST_ENFORCE_TIME="$NOW_TIME"
        fi
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
            break
        fi
    done

    if [ "$applied" = "false" ]; then
        for dyn_node in /sys/class/power_supply/*/input_current_limit \
                        /sys/class/power_supply/*/constant_charge_current; do
            if [ -w "$dyn_node" ]; then
                sysfs_write "$target_ua" "$dyn_node"
                applied="true"
                break
            fi
        done
    fi

    if [ "$applied" = "false" ]; then
        log_debug "No compatible charging control node found on this kernel."
    fi
}
