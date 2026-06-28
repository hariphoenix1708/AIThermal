#!/system/bin/sh
# ThermalAI - Charge Heat Control (Unified Adaptive Controller)
# Dynamically adjusts maximum charging current to behave like a stock controller.

# Hardware limits and Paths
BATT_CURRENT_MAX="/sys/class/power_supply/battery/constant_charge_current_max"
BATT_CAPACITY="/sys/class/power_supply/battery/capacity"
CHARGE_LOG_FILE="/data/local/tmp/thermalai_charging.log"

MAX_HW_CURRENT_UA=14000000
EMERGENCY_MIN_CURRENT_UA=500000 # Only if literally overheating

# Memory globals for rate limiter, history, and learning
LAST_APPLIED_UA=0
LAST_ENFORCE_TIME=0
PREV_BATT_TEMP=0
BATT_TEMP_EMA_X10=0
EMA_ALPHA=7 # Tuning for EMA. EMA = (alpha * current + (10 - alpha) * prev) / 10
CHARGE_STATE="DISCONNECTED"
PREV_CHARGE_STATE="DISCONNECTED"

SESSION_START_SOC=0
SESSION_START_TIME=0
SESSION_PEAK_BATT=0
SESSION_PEAK_USB=0
SESSION_PEAK_PMIC=0
SESSION_MAX_POWER=0
SESSION_RED_COUNT=0
SESSION_REC_COUNT=0
SESSION_SAMPLES_COUNT=0
SESSION_SAMPLES_SUM_UA=0
SESSION_SAMPLES_SUM_W_X10=0

LEARNED_STABLE_UA=7000000
STABLE_TIME_SEC=0

log_charge_event() {
    local evt="$1"
    echo "[$(date "+%H:%M:%S")] EVENT: $evt" >> "$CHARGE_LOG_FILE"
}

get_thermal_sensor_data() {
    # We want max relevant temperature
    local batt_t=0
    local usb_t=0
    local pmic_t=0
    local chg_t=0

    # Best reliable path for battery specifically
    local primary_path="/sys/class/power_supply/battery/temp"
    if [ -f "$primary_path" ]; then
        local raw=$(cat "$primary_path" 2>/dev/null || echo 0)
        [ "$raw" -gt 10000 ] && raw=$((raw / 100))
        [ "$raw" -ge 100 ] && [ "$raw" -le 800 ] && batt_t=$raw
    fi

    # Read all relevant thermal zones
    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')
        local tz_dir="${tz_type%/*}"
        local raw=0
        if [ -f "$tz_dir/temp" ]; then
            raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
            [ "$raw" -gt 10000 ] && raw=$((raw / 100))
            [ "$raw" -lt 100 ] || [ "$raw" -gt 800 ] && raw=0
        fi

        if echo "$type_val" | grep -iqE "battery|vbat"; then
            [ "$raw" -gt "$batt_t" ] && batt_t=$raw
        elif echo "$type_val" | grep -iq "usb"; then
            [ "$raw" -gt "$usb_t" ] && usb_t=$raw
        elif echo "$type_val" | grep -iqE "pmic"; then
            [ "$raw" -gt "$pmic_t" ] && pmic_t=$raw
        elif echo "$type_val" | grep -iqE "charger|chg"; then
            [ "$raw" -gt "$chg_t" ] && chg_t=$raw
        fi
    done

    # Fallback bounds
    [ "$batt_t" -eq 0 ] && batt_t=350

    echo "${batt_t}:${usb_t}:${pmic_t}:${chg_t}"
}

get_soc_target_ua() {
    local soc="$1"
    local gaming="$2"
    local target=1500000

    if [ "$gaming" = "true" ]; then
        if [ "$soc" -lt 20 ]; then target=9800000
        elif [ "$soc" -lt 40 ]; then target=8750000
        elif [ "$soc" -lt 51 ]; then target=8400000
        elif [ "$soc" -lt 55 ]; then target=8000000
        elif [ "$soc" -lt 60 ]; then target=7000000
        elif [ "$soc" -lt 65 ]; then target=6600000
        elif [ "$soc" -lt 73 ]; then target=6300000
        elif [ "$soc" -lt 76 ]; then target=5600000
        elif [ "$soc" -lt 80 ]; then target=4900000
        elif [ "$soc" -lt 83 ]; then target=4500000
        elif [ "$soc" -lt 86 ]; then target=3800000
        elif [ "$soc" -lt 89 ]; then target=3100000
        elif [ "$soc" -lt 91 ]; then target=2800000
        elif [ "$soc" -lt 93 ]; then target=2500000
        elif [ "$soc" -lt 95 ]; then target=2100000
        elif [ "$soc" -lt 97 ]; then target=1500000
        else target=1000000; fi
    else
        if [ "$soc" -lt 20 ]; then target=14000000
        elif [ "$soc" -lt 40 ]; then target=12500000
        elif [ "$soc" -lt 51 ]; then target=12000000
        elif [ "$soc" -lt 55 ]; then target=11500000
        elif [ "$soc" -lt 60 ]; then target=10000000
        elif [ "$soc" -lt 65 ]; then target=9500000
        elif [ "$soc" -lt 73 ]; then target=9000000
        elif [ "$soc" -lt 76 ]; then target=8000000
        elif [ "$soc" -lt 80 ]; then target=7000000
        elif [ "$soc" -lt 83 ]; then target=6500000
        elif [ "$soc" -lt 86 ]; then target=5500000
        elif [ "$soc" -lt 89 ]; then target=4500000
        elif [ "$soc" -lt 91 ]; then target=4000000
        elif [ "$soc" -lt 93 ]; then target=3600000
        elif [ "$soc" -lt 95 ]; then target=3000000
        elif [ "$soc" -lt 97 ]; then target=2200000
        else target=1500000; fi
    fi

    echo "$target"
}

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
                break
            fi
        done
    fi
}

finish_charging_session() {
    local end_soc="$1"
    local time_mins=$(( (NOW_TIME - SESSION_START_TIME) / 60 ))
    if [ "$time_mins" -le 0 ]; then time_mins=1; fi

    local avg_ua=0
    local avg_w_x10=0
    if [ "$SESSION_SAMPLES_COUNT" -gt 0 ]; then
        avg_ua=$(( SESSION_SAMPLES_SUM_UA / SESSION_SAMPLES_COUNT ))
        avg_w_x10=$(( SESSION_SAMPLES_SUM_W_X10 / SESSION_SAMPLES_COUNT ))
    fi

    echo "" >> "$CHARGE_LOG_FILE"
    echo "==============================" >> "$CHARGE_LOG_FILE"
    echo "FINAL CHARGING SUMMARY" >> "$CHARGE_LOG_FILE"
    echo "==============================" >> "$CHARGE_LOG_FILE"
    echo "Charging started at ${SESSION_START_SOC}%" >> "$CHARGE_LOG_FILE"
    echo "Charging ended at ${end_soc}%" >> "$CHARGE_LOG_FILE"
    echo "Total charging time: ${time_mins}m" >> "$CHARGE_LOG_FILE"
    echo "Average Charging Current: $(( avg_ua / 1000 )) mA" >> "$CHARGE_LOG_FILE"
    echo "Average Charging Power: $(( avg_w_x10 / 10 )).$(( avg_w_x10 % 10 )) W" >> "$CHARGE_LOG_FILE"
    echo "Peak Charging Power: $(( SESSION_MAX_POWER / 10 )).$(( SESSION_MAX_POWER % 10 )) W" >> "$CHARGE_LOG_FILE"
    echo "Peak Battery Temperature: $(( SESSION_PEAK_BATT / 10 )).$(( SESSION_PEAK_BATT % 10 )) °C" >> "$CHARGE_LOG_FILE"
    echo "Peak USB Temperature: $(( SESSION_PEAK_USB / 10 )).$(( SESSION_PEAK_USB % 10 )) °C" >> "$CHARGE_LOG_FILE"
    echo "Peak PMIC Temperature: $(( SESSION_PEAK_PMIC / 10 )).$(( SESSION_PEAK_PMIC % 10 )) °C" >> "$CHARGE_LOG_FILE"
    echo "Number of Thermal Reductions: $SESSION_RED_COUNT" >> "$CHARGE_LOG_FILE"
    echo "Number of Recovery Events: $SESSION_REC_COUNT" >> "$CHARGE_LOG_FILE"
    echo "" >> "$CHARGE_LOG_FILE"
}

apply_charging_control() {
    local gaming="$1"

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")
    local soc=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 0)

    # Disconnect Logic
    if [ "$current_plugged" != "Charging" ] && [ "$current_plugged" != "Full" ]; then
        if [ "$CHARGE_STATE" != "DISCONNECTED" ]; then
            CHARGE_STATE="DISCONNECTED"
            finish_charging_session "$soc"
        fi
        LAST_APPLIED_UA=0
        return 0
    fi

    # Read thermal array (batt:usb:pmic:chg)
    local therm_str=$(get_thermal_sensor_data)
    local b_raw=$(echo "$therm_str" | cut -d: -f1)
    local u_raw=$(echo "$therm_str" | cut -d: -f2)
    local p_raw=$(echo "$therm_str" | cut -d: -f3)
    local c_raw=$(echo "$therm_str" | cut -d: -f4)

    # Hardware read
    local current_now_ua=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)
    [ "$current_now_ua" -lt 0 ] && current_now_ua=$(( current_now_ua * -1 ))
    local voltage_now_uv=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)

    local power_w_x10=$(( (current_now_ua / 1000) * (voltage_now_uv / 1000) / 100000 ))

    # Setup New Session
    if [ "$CHARGE_STATE" = "DISCONNECTED" ]; then
        SESSION_START_SOC=$soc
        SESSION_START_TIME=$NOW_TIME
        SESSION_PEAK_BATT=0
        SESSION_PEAK_USB=0
        SESSION_PEAK_PMIC=0
        SESSION_MAX_POWER=0
        SESSION_RED_COUNT=0
        SESSION_REC_COUNT=0
        SESSION_SAMPLES_COUNT=0
        SESSION_SAMPLES_SUM_UA=0
        SESSION_SAMPLES_SUM_W_X10=0
        LEARNED_STABLE_UA=7000000
        BATT_TEMP_EMA_X10=$(( b_raw * 10 ))
        LAST_APPLIED_UA=$current_now_ua
        PREV_BATT_TEMP=$b_raw

        # We start by letting HW decide its max, but bound to SOC target immediately
        if [ "$LAST_APPLIED_UA" -lt 100000 ]; then
            LAST_APPLIED_UA=$(get_soc_target_ua "$soc" "$gaming")
        fi
    fi

    # Track Peaks
    [ "$b_raw" -gt "$SESSION_PEAK_BATT" ] && SESSION_PEAK_BATT=$b_raw
    [ "$u_raw" -gt "$SESSION_PEAK_USB" ] && SESSION_PEAK_USB=$u_raw
    [ "$p_raw" -gt "$SESSION_PEAK_PMIC" ] && SESSION_PEAK_PMIC=$p_raw
    [ "$power_w_x10" -gt "$SESSION_MAX_POWER" ] && SESSION_MAX_POWER=$power_w_x10

    SESSION_SAMPLES_COUNT=$(( SESSION_SAMPLES_COUNT + 1 ))
    SESSION_SAMPLES_SUM_UA=$(( SESSION_SAMPLES_SUM_UA + current_now_ua ))
    SESSION_SAMPLES_SUM_W_X10=$(( SESSION_SAMPLES_SUM_W_X10 + power_w_x10 ))

    # Determine highest relevant safety temp
    local max_t=$b_raw
    [ "$u_raw" -gt "$max_t" ] && max_t=$u_raw
    [ "$p_raw" -gt "$max_t" ] && max_t=$p_raw
    [ "$c_raw" -gt "$max_t" ] && max_t=$c_raw

    # EMA Trend
    if [ "$BATT_TEMP_EMA_X10" -eq 0 ]; then
        BATT_TEMP_EMA_X10=$(( b_raw * 10 ))
    else
        BATT_TEMP_EMA_X10=$(( (EMA_ALPHA * (b_raw * 10) + (10 - EMA_ALPHA) * BATT_TEMP_EMA_X10) / 10 ))
    fi
    local ema_temp=$(( BATT_TEMP_EMA_X10 / 10 ))
    local slope=$(( b_raw - PREV_BATT_TEMP ))
    PREV_BATT_TEMP=$b_raw

    local slope_str="Stable"
    if [ "$slope" -ge 2 ]; then slope_str="Rising quickly";
    elif [ "$slope" -eq 1 ]; then slope_str="Rising slowly";
    elif [ "$slope" -le -2 ]; then slope_str="Falling quickly";
    elif [ "$slope" -eq -1 ]; then slope_str="Falling slowly"; fi

    local charge_mode="Normal"
    [ "$gaming" = "true" ] && charge_mode="Gaming"

    local soc_target=$(get_soc_target_ua "$soc" "$gaming")
    local therm_target=$LAST_APPLIED_UA
    local reason=""

    # Base Safety Override (Always wins)
    local is_safety_override="false"
    if [ "$b_raw" -ge 460 ]; then
        is_safety_override="true"
        CHARGE_STATE="EMERGENCY"
        therm_target=$EMERGENCY_MIN_CURRENT_UA
        reason="Safety_Override (T=${b_raw})"
    else
        CHARGE_STATE="ACTIVE"
        # Determine Thermal Adjustments Based on Mode
        if [ "$gaming" = "true" ]; then
            if [ "$b_raw" -lt 340 ]; then
                :
            elif [ "$b_raw" -ge 340 ] && [ "$b_raw" -lt 360 ]; then
                :
            elif [ "$b_raw" -ge 360 ] && [ "$b_raw" -lt 370 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$slope" -gt 0 ] && [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    therm_target=$(( therm_target - 100000 ))
                    reason="Gaming_Taper (36C+)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 370 ] && [ "$b_raw" -lt 380 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    local severity=$(( (b_raw - 370) / 3 ))
                    therm_target=$(( therm_target - (100000 + (100000 * severity)) ))
                    reason="Gaming_Taper (37C+)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 380 ] && [ "$b_raw" -lt 390 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    local severity=$(( (b_raw - 380) / 2 ))
                    therm_target=$(( therm_target - (200000 + (200000 * severity)) ))
                    reason="Gaming_Taper (38C+)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 390 ]; then
                is_safety_override="true"
                CHARGE_STATE="EMERGENCY"
                therm_target=$(( therm_target - 1000000 ))
                reason="Gaming_Emergency (>39C)"
            fi
        else
            if [ "$b_raw" -lt 360 ]; then
                :
            elif [ "$b_raw" -ge 360 ] && [ "$b_raw" -lt 390 ]; then
                :
            elif [ "$b_raw" -ge 390 ] && [ "$b_raw" -lt 410 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$slope" -gt 0 ] && [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    therm_target=$(( therm_target - 100000 ))
                    reason="Normal_Taper (39C+)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 410 ] && [ "$b_raw" -lt 430 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    local severity=$(( (b_raw - 410) / 5 ))
                    therm_target=$(( therm_target - (200000 + (100000 * severity)) ))
                    reason="Normal_Taper (41C+)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 430 ] && [ "$b_raw" -lt 440 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    therm_target=$(( therm_target - 400000 ))
                    reason="Normal_Taper (43C+)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 440 ] && [ "$b_raw" -lt 450 ]; then
                STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 ))
                if [ "$STABLE_TIME_SEC" -ge 25 ]; then
                    therm_target=$(( therm_target - 600000 ))
                    reason="Normal_Aggressive (>44C)"
                    STABLE_TIME_SEC=0
                fi
            elif [ "$b_raw" -ge 450 ]; then
                is_safety_override="true"
                CHARGE_STATE="EMERGENCY"
                therm_target=$(( therm_target - 1000000 ))
                reason="Normal_Emergency (>45C)"
            fi
        fi
    fi

    # Recovery Learning Rule (If we are not reducing due to thermal)
    if [ "$reason" = "" ] && [ "$is_safety_override" = "false" ]; then
        if [ "$slope" -le 0 ]; then
            STABLE_TIME_SEC=$(( STABLE_TIME_SEC + 5 )) # Approx time per loop cycle
            if [ "$STABLE_TIME_SEC" -ge 60 ]; then
                therm_target=$(( therm_target + 150000 ))
                LEARNED_STABLE_UA=$(( LEARNED_STABLE_UA + 150000 ))
                STABLE_TIME_SEC=0
                reason="Recovery_Learning"
                SESSION_REC_COUNT=$(( SESSION_REC_COUNT + 1 ))
            fi
        else
            STABLE_TIME_SEC=0
        fi
    else
        # Only reset time if reason is NOT taper, we want tapers to fire every few cycles
        if ! echo "$reason" | grep -q "Taper"; then
            STABLE_TIME_SEC=0
        else
            SESSION_RED_COUNT=$(( SESSION_RED_COUNT + 1 ))
        fi
        max_current_ua="$RAMP_CURRENT"
    fi

    # Evaluate Minimums (Order: SOC -> Thermal -> Learned)
    local final_target=$soc_target
    [ "$therm_target" -lt "$final_target" ] && final_target=$therm_target
    [ "$LEARNED_STABLE_UA" -lt "$final_target" ] && final_target=$LEARNED_STABLE_UA

    # Rate Limiter
    if [ "$is_safety_override" = "false" ]; then
        local diff=$(( final_target - LAST_APPLIED_UA ))
        if [ "$diff" -gt 200000 ]; then
            final_target=$(( LAST_APPLIED_UA + 200000 ))
            reason="Rate_Limiter_Up"
        elif [ "$diff" -lt -300000 ]; then
            final_target=$(( LAST_APPLIED_UA - 300000 ))
            reason="Rate_Limiter_Down"
        fi
    fi

    # Clamp bounds absolutely to HW capability
    [ "$final_target" -gt "$MAX_HW_CURRENT_UA" ] && final_target=$MAX_HW_CURRENT_UA
    [ "$final_target" -lt "$EMERGENCY_MIN_CURRENT_UA" ] && final_target=$EMERGENCY_MIN_CURRENT_UA

    # If no explicit reason, state is just SOC target clamp
    [ "$reason" = "" ] && [ "$final_target" -eq "$soc_target" ] && reason="SOC_Target"

    # Write log if target changes
    if [ "$LAST_APPLIED_UA" != "$final_target" ]; then
        echo "[$(date "+%H:%M:%S")]" >> "$CHARGE_LOG_FILE"
        echo "Mode=${charge_mode} State=${CHARGE_STATE} SOC=${soc}% Batt=$(( b_raw / 10 )).$(( b_raw % 10 ))°C (EMA=$(( ema_temp / 10 )).$(( ema_temp % 10 ))°C) USB=$(( u_raw / 10 )).$(( u_raw % 10 ))°C PMIC=$(( p_raw / 10 )).$(( p_raw % 10 ))°C Slope=${slope_str} SOCT=$(( soc_target / 1000 ))mA TT=$(( therm_target / 1000 ))mA LT=$(( LEARNED_STABLE_UA / 1000 ))mA Final=$(( final_target / 1000 ))mA Applied=$(( LAST_APPLIED_UA / 1000 ))->$(( final_target / 1000 ))mA Reason=${reason}" >> "$CHARGE_LOG_FILE"

        sysfs_write "$final_target" "$BATT_CURRENT_MAX"
        apply_universal_charging_control "$final_target"
        LAST_APPLIED_UA=$final_target
        LAST_ENFORCE_TIME=$NOW_TIME
    else
        local time_since=$((NOW_TIME - LAST_ENFORCE_TIME))
        if [ "$time_since" -ge 30 ]; then
            sysfs_write "$final_target" "$BATT_CURRENT_MAX"
            apply_universal_charging_control "$final_target"
            LAST_ENFORCE_TIME=$NOW_TIME
        fi
    fi
}

restore_charging_control() {
    if [ -w "$BATT_CURRENT_MAX" ]; then
         echo "$MAX_HW_CURRENT_UA" > "$BATT_CURRENT_MAX" 2>/dev/null
    fi
    apply_universal_charging_control "$MAX_HW_CURRENT_UA"
}
