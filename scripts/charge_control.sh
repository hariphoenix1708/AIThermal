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
    local max_t=0

    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')

        # Collect highest relevant temperature across battery, charger, pmic, usb
        if echo "$type_val" | grep -iqE "battery|charger_therm|vbat|pmic|usb|chg"; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 10000 ] && raw=$((raw / 100))
                if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                    if [ "$raw" -gt "$max_t" ]; then
                        max_t="$raw"
                    fi
                fi
            fi
        fi
    done

    if [ "$max_t" -gt 0 ]; then
        echo "$max_t"
    else
        # Safe default
        echo 350
    fi
}

get_soc_target_ua() {
    local soc="$1"
    local gaming="$2"
    local target=1500000

    if [ "$gaming" = "true" ]; then
        if [ "$soc" -lt 5 ]; then target=4000000
        elif [ "$soc" -lt 10 ]; then target=4200000
        elif [ "$soc" -lt 20 ]; then target=4500000
        elif [ "$soc" -lt 25 ]; then target=4300000
        elif [ "$soc" -lt 30 ]; then target=4200000
        elif [ "$soc" -lt 35 ]; then target=4000000
        elif [ "$soc" -lt 40 ]; then target=3900000
        elif [ "$soc" -lt 45 ]; then target=3800000
        elif [ "$soc" -lt 50 ]; then target=3700000
        elif [ "$soc" -lt 55 ]; then target=3600000
        elif [ "$soc" -lt 70 ]; then target=3500000
        elif [ "$soc" -lt 75 ]; then target=3400000
        elif [ "$soc" -lt 80 ]; then target=3300000
        elif [ "$soc" -lt 85 ]; then target=3000000
        elif [ "$soc" -lt 90 ]; then target=2750000
        elif [ "$soc" -lt 95 ]; then target=2000000
        else target=1500000; fi
    else
        if [ "$soc" -lt 5 ]; then target=5500000
        elif [ "$soc" -lt 10 ]; then target=6000000
        elif [ "$soc" -lt 15 ]; then target=6500000
        elif [ "$soc" -lt 20 ]; then target=7000000
        elif [ "$soc" -lt 30 ]; then target=7000000
        elif [ "$soc" -lt 35 ]; then target=6800000
        elif [ "$soc" -lt 40 ]; then target=6500000
        elif [ "$soc" -lt 45 ]; then target=6000000
        elif [ "$soc" -lt 50 ]; then target=5600000
        elif [ "$soc" -lt 55 ]; then target=5200000
        elif [ "$soc" -lt 60 ]; then target=4800000
        elif [ "$soc" -lt 65 ]; then target=4500000
        elif [ "$soc" -lt 70 ]; then target=4200000
        elif [ "$soc" -lt 75 ]; then target=3900000
        elif [ "$soc" -lt 80 ]; then target=3500000
        elif [ "$soc" -lt 85 ]; then target=3000000
        elif [ "$soc" -lt 90 ]; then target=2750000
        elif [ "$soc" -lt 95 ]; then target=2000000
        else target=1500000; fi
    fi

    echo "$target"
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

    # Only enforce limits if the device is actually charging
    if [ "$current_plugged" != "Charging" ]; then
        LAST_APPLIED_CHARGE_LIMIT=""
        # Do not adapt learned current while disconnected
        return 0
    fi

    # 1. Base Target from Battery Percentage (SOC Rule)
    local soc_target=$(get_soc_target_ua "$batt_level" "$realtime_gaming")

    # 2. Temperature and Trend Adjustments
    local is_emergency="false"

    if [ "$realtime_gaming" = "true" ]; then
        CHARGE_STATE="GAMING"
        if [ "$batt_temp" -gt 39 ]; then
            is_emergency="true"
        elif [ "$batt_temp" -lt 34 ]; then
            # No reduction
            :
        elif [ "$batt_temp" -ge 34 ] && [ "$batt_temp" -lt 36 ]; then
            # Hold target current
            :
        elif [ "$batt_temp" -ge 36 ] && [ "$batt_temp" -lt 37 ]; then
            if [ "$BATT_TEMP_SLOPE" -gt 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 200000))
            fi
        elif [ "$batt_temp" -ge 37 ] && [ "$batt_temp" -lt 38 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 300000))
        elif [ "$batt_temp" -ge 38 ] && [ "$batt_temp" -le 39 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 500000))
        fi
    else
        CHARGE_STATE="NORMAL"
        if [ "$batt_temp" -gt 45 ]; then
            is_emergency="true"
        elif [ "$batt_temp" -lt 36 ]; then
            # No reduction
            :
        elif [ "$batt_temp" -ge 36 ] && [ "$batt_temp" -lt 39 ]; then
            # Hold target current
            :
        elif [ "$batt_temp" -ge 39 ] && [ "$batt_temp" -lt 41 ]; then
            if [ "$BATT_TEMP_SLOPE" -gt 0 ]; then
                DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 200000))
            fi
        elif [ "$batt_temp" -ge 41 ] && [ "$batt_temp" -lt 43 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 400000))
        elif [ "$batt_temp" -ge 43 ] && [ "$batt_temp" -le 44 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 500000))
        elif [ "$batt_temp" -gt 44 ] && [ "$batt_temp" -le 45 ]; then
            DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 800000))
        fi
    fi

    # 3. Recovery Learning Rule
    if [ "$is_emergency" = "false" ]; then
        if [ "$BATT_TEMP_SLOPE" -le 0 ]; then
            # Only recover if we are below the SOC target
            if [ "$DYNAMIC_CURRENT_UA" -lt "$soc_target" ]; then
                # Recovery increments every 60-90s (approx. handled by occasional triggers or we do it directly)
                # To simulate gradual, we step up slowly if temperature is falling or flat.
                if [ "$BATT_TEMP_SLOPE" -lt 0 ]; then
                    DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA + 200000))
                else
                    # Stable, increment slower
                    DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA + 100000))
                fi
            fi
        fi

        # Clamp to physical max bounds
        [ "$DYNAMIC_CURRENT_UA" -gt "$MAX_CURRENT_UA" ] && DYNAMIC_CURRENT_UA="$MAX_CURRENT_UA"

        # In non-emergency, enforce MIN_CURRENT_UA floor first
        [ "$DYNAMIC_CURRENT_UA" -lt "$MIN_CURRENT_UA" ] && DYNAMIC_CURRENT_UA="$MIN_CURRENT_UA"

        # Then clamp to SOC target (SOC target is the absolute ceiling, overriding the minimum)
        if [ "$DYNAMIC_CURRENT_UA" -gt "$soc_target" ]; then
            DYNAMIC_CURRENT_UA="$soc_target"
        fi

        max_current_ua="$DYNAMIC_CURRENT_UA"
    else
        CHARGE_STATE="EMERGENCY"
        # Emergency Override: Ignore SOC target, drop aggressively until recovered.
        DYNAMIC_CURRENT_UA=$((DYNAMIC_CURRENT_UA - 1000000))

        [ "$DYNAMIC_CURRENT_UA" -lt "$EMERGENCY_MIN_CURRENT_UA" ] && DYNAMIC_CURRENT_UA="$EMERGENCY_MIN_CURRENT_UA"
        max_current_ua="$DYNAMIC_CURRENT_UA"
    fi

    # Save learned optimal state occasionally
    if [ $((NOW_TIME % 60)) -eq 0 ]; then
        echo "$DYNAMIC_CURRENT_UA" > "$LEARNED_CHARGE_PROFILE"
    fi

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
