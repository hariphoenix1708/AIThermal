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
CHARGE_STATE="NORMAL" # States: COOL, NORMAL, WARM, HOT, EMERGENCY
LEARNED_CHARGE_PROFILE="/data/local/tmp/thermalai.charge_profile"

# Initialize learned dynamic current
if [ -f "$LEARNED_CHARGE_PROFILE" ]; then
    DYNAMIC_CURRENT_UA=$(cat "$LEARNED_CHARGE_PROFILE" 2>/dev/null || echo "3000000")
else
    DYNAMIC_CURRENT_UA=3000000
fi
# Hardware physical limit bounds
MIN_CURRENT_UA=500000
MAX_CURRENT_UA=5000000

LAST_APPLIED_CHARGE_LIMIT=""
LAST_ENFORCE_TIME=0

# Slope tracking
BATT_TEMP_HISTORY=""

apply_charging_control() {
    local realtime_gaming="$1"

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

    # Only enforce limits and calculate slopes if the device is actually charging
    if [ "$current_plugged" != "Charging" ]; then
        LAST_APPLIED_CHARGE_LIMIT=""
        BATT_TEMP_HISTORY="" # reset slope history
        return 0
    fi

    # Track temperature slope (last 5 ticks)
    BATT_TEMP_HISTORY="${BATT_TEMP_HISTORY:+$BATT_TEMP_HISTORY }$batt_temp"
    local history_count=$(echo "$BATT_TEMP_HISTORY" | wc -w)
    if [ "$history_count" -gt 5 ]; then
        BATT_TEMP_HISTORY=$(echo "$BATT_TEMP_HISTORY" | awk '{for(i=2;i<=NF;i++)printf "%s%s",$i,(i==NF?"":" ")}')
    fi

    local temp_slope=0
    if [ "$history_count" -ge 3 ]; then
        # Simple trend: (current - oldest)
        local oldest=$(echo "$BATT_TEMP_HISTORY" | awk '{print $1}')
        temp_slope=$((batt_temp - oldest))
    fi

    # Charger Type Awareness (Wattage estimation)
    # Read signed current. Positive generally means charging on standard Android,
    # but some devices invert it. If current is very close to 0, it might be full or discharging.
    local current_now_ua_signed=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
    # Convert negative to positive strictly for wattage magnitude calculation ONLY IF we know it's charging
    local current_now_ua="$current_now_ua_signed"
    local voltage_now_uv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)

    local is_fast_charger=false
    if [ "$current_now_ua" -gt 0 ] && [ "$voltage_now_uv" -gt 0 ]; then
        # Watts = (mA * mV) / 1,000,000
        local ma=$((current_now_ua / 1000))
        local mv=$((voltage_now_uv / 1000))
        local watts=$(( (ma * mv) / 1000000 ))

        if [ "$watts" -gt 15 ]; then
            is_fast_charger=true
        fi
    fi

    # 1. State Machine Transitions with Slope Awareness
    # We define states based on temp + slope.
    # If slope is high (heating fast), we penalize the effective temperature by adding to it.
    local effective_temp="$batt_temp"
    if [ "$temp_slope" -gt 1 ]; then
        # Fast heating -> pretend it's 2 degrees hotter to trigger early throttling
        effective_temp=$((batt_temp + 2))
    elif [ "$temp_slope" -lt -1 ]; then
        # Cooling down fast -> relax restrictions slightly
        effective_temp=$((batt_temp - 1))
    fi

    local next_state="$CHARGE_STATE"

    if [ "$effective_temp" -ge 40 ]; then
        next_state="EMERGENCY"
    elif [ "$effective_temp" -ge 38 ]; then
        next_state="HOT"
    elif [ "$effective_temp" -ge 36 ]; then
        next_state="WARM"
    elif [ "$effective_temp" -ge 34 ]; then
        next_state="NORMAL"
    else
        # Hysteresis: only enter COOL if we dropped below 32
        if [ "$batt_temp" -le 32 ]; then
            next_state="COOL"
        elif [ "$CHARGE_STATE" = "HOT" ] || [ "$CHARGE_STATE" = "EMERGENCY" ]; then
            # If coming down from hot, don't drop all the way to cool/normal instantly
            next_state="WARM"
        fi
    fi

    if [ "$CHARGE_STATE" != "$next_state" ]; then
        log_info "Charging State: $CHARGE_STATE -> $next_state (temp=${batt_temp}°C, slope=${temp_slope}, eff=${effective_temp}°C)"
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT="" # force re-apply
    fi

    # 2. Assign Current Limits based on State and Gaming context
    local target_current_ua=2000000 # fallback default

    if [ "$realtime_gaming" = "true" ]; then
        # GAMING PROFILES
        case "$CHARGE_STATE" in
            COOL)       target_current_ua=2500000 ;; # Cool gaming: ~2500mA
            NORMAL)     target_current_ua=1800000 ;; # Normal gaming: ~1800mA
            WARM)       target_current_ua=1200000 ;; # Warm gaming: ~1200mA
            HOT)        target_current_ua=750000  ;; # Hot gaming: ~750mA
            EMERGENCY)  target_current_ua=500000  ;; # Emergency gaming: 500mA
            *)          target_current_ua=1000000 ;;
        esac
    else
        # NON-GAMING PROFILES
        case "$CHARGE_STATE" in
            COOL)       target_current_ua=4500000 ;; # Let it rip
            NORMAL)     target_current_ua=3000000 ;; # Fast charge
            WARM)
                if [ "$is_fast_charger" = "true" ]; then
                    target_current_ua=1800000 # Taper fast chargers
                else
                    target_current_ua=2000000
                fi
                ;;
            HOT)        target_current_ua=1000000 ;; # Taper hard
            EMERGENCY)  target_current_ua=500000  ;; # Minimum safe trickle
            *)          target_current_ua=2000000 ;;
        esac
    fi

    # 3. SOC-based Graceful Degradation (Overrides temperature unless emergency)
    if [ "$batt_level" -ge 90 ] && [ "$CHARGE_STATE" != "EMERGENCY" ]; then
        # Taper at high SOC to preserve battery health
        if [ "$target_current_ua" -gt 1500000 ]; then
            target_current_ua=1500000
        fi
    fi

    # 4. Hardware Enforcement
    if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$target_current_ua" ]; then
        if [ -w "$BATT_CURRENT_MAX" ]; then
            sysfs_write "$target_current_ua" "$BATT_CURRENT_MAX"
        fi
        apply_universal_charging_control "$target_current_ua"

        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((target_current_ua / 1000))mA (batt_temp=${batt_temp}°C, slope=${temp_slope}, state=$CHARGE_STATE, gaming=$realtime_gaming)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null

        if [ "$CHARGE_STATE" = "EMERGENCY" ] || [ "$CHARGE_STATE" = "HOT" ]; then
            log_warn "Battery Temp High (${batt_temp}°C) - Throttling charge to $((target_current_ua / 1000))mA"
        fi

        LAST_APPLIED_CHARGE_LIMIT="$target_current_ua"
        LAST_ENFORCE_TIME="$NOW_TIME"
    else
        # Prevent hardware resetting it under our nose without spamming log
        local time_since=$((NOW_TIME - LAST_ENFORCE_TIME))
        if [ "$time_since" -ge 30 ]; then
            if [ -w "$BATT_CURRENT_MAX" ]; then
                sysfs_write "$target_current_ua" "$BATT_CURRENT_MAX"
            fi
            apply_universal_charging_control "$target_current_ua"
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
