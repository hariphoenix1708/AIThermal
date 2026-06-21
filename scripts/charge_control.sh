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
    local max_t=0
    # List of possible battery thermal zones or paths.
    # Usually in tenths of a degree (350 = 35.0C), but sometimes in millidegrees (35000 = 35.0C).
    local paths="
/sys/class/power_supply/battery/temp
/sys/class/thermal/thermal_zone54/temp
/sys/class/thermal/thermal_zone60/temp
"

    # We will grab all and use the max realistic one (to be safe and throttle properly)
    for p in $paths; do
        if [ -f "$p" ]; then
            local raw
            raw=$(cat "$p" 2>/dev/null || echo 0)

            # Convert millidegrees to tenths if needed (if it's e.g., 35000 -> 350)
            if [ "$raw" -gt 10000 ]; then
                raw=$((raw / 100))
            fi

            # Plausibility check: between 10C (100) and 80C (800)
            if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                if [ "$raw" -gt "$max_t" ]; then
                    max_t="$raw"
                fi
            fi
        fi
    done

    # Check fallback type=battery thermal zones dynamically just in case
    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        if [ -f "$tz_type" ]; then
            local type_val
            type_val=$(cat "$tz_type" 2>/dev/null || echo "")
            if case "$type_val" in *battery*|*charger_therm*|*vbat*) true;; *) false;; esac; then
                local tz_dir="${tz_type%/*}"
                if [ -f "$tz_dir/temp" ]; then
                    local raw
                    raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                    if [ "$raw" -gt 10000 ]; then
                        raw=$((raw / 100))
                    fi
                    if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                        if [ "$raw" -gt "$max_t" ]; then
                            max_t="$raw"
                        fi
                    fi
                fi
            fi
        fi
    done

    # If we couldn't find anything plausible, return 350 (35.0C) as a safe default
    if [ "$max_t" -eq 0 ]; then
        max_t=350
    fi

    echo "$max_t"
}

# ─── Adjust Charging Current ──────────────────────────────────────────────────
apply_charging_control() {
    local policy="$1"
    local is_gaming="$2"
    local max_current_ua="0" # 0 means disabled / let hardware decide

    # Read actual battery temperature safely
    local batt_temp_raw
    batt_temp_raw=$(get_robust_battery_temp)
    local batt_temp=$((batt_temp_raw / 10))

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")

    # Only enforce limits if the device is actually charging
    if [ "$current_plugged" != "Charging" ]; then
        LAST_APPLIED_CHARGE_LIMIT=""
        return 0
    fi

    if [ "$is_gaming" = "true" ]; then
        if [ "$batt_temp" -ge 35 ]; then
            max_current_ua="1000000"
            if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
                log_warn "Compound Guard: Gaming + Charging (batt_temp=${batt_temp}°C). Capping charge at 1A."
                LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
            fi
        else
            max_current_ua="2000000"
            if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
                log_warn "Compound Guard: Gaming + Charging (batt_temp=${batt_temp}°C). Capping charge at 2A."
                LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
            fi
        fi

        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"

        if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null
        fi
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
        max_current_ua="1000000"
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"

        if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null
            log_info "Battery >= 90%. Trickle charging at 1A."
            LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
        fi
        return 0
    fi

    # Target: keep battery below 39C
    if [ "$batt_temp" -ge 39 ]; then
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
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$max_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$max_current_ua"

        if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$max_current_ua" ]; then
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null

            if [ "$max_current_ua" = "500000" ]; then
                log_warn "Battery Temp Critical (${batt_temp}°C) - Throttling to trickle charge"
            elif [ "$max_current_ua" = "5000000" ]; then
                log_info "Charging limit released to 5A (batt_temp=${batt_temp}°C)"
            else
                log_info "Charging limit adjusted to $((max_current_ua / 1000))mA (batt_temp=${batt_temp}°C)"
            fi
            LAST_APPLIED_CHARGE_LIMIT="$max_current_ua"
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
