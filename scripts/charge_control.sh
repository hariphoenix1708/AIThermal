#!/system/bin/sh
# ThermalAI - Advanced Adaptive Charge Controller
# Architecture:
# Layer 1: Thermal Safety (Battery + Ambient + USB + Prediction)
# Layer 2: Performance Awareness (Gaming, GPU Load, SOC)
# Layer 3: Adaptive Learning (Stable Current Memory, Decay)

BATT_CURRENT_MAX="/sys/class/power_supply/battery/constant_charge_current_max"
BATT_CAPACITY="/sys/class/power_supply/battery/capacity"

SOC_80_CAP_UA="${SOC_80_CAP_UA:-1200000}"
SOC_50_CAP_UA="${SOC_50_CAP_UA:-2500000}"

# ─── Robust Battery Temp Read ─────────────────────────────────────────────────
get_robust_battery_temp() {
    local primary_path="/sys/class/power_supply/battery/temp"
    if [ -f "$primary_path" ]; then
        local t=$(cat "$primary_path" 2>/dev/null || echo 0)
        [ "$t" -gt 10000 ] && t=$((t / 100))
        if [ "$t" -ge 100 ] && [ "$t" -le 800 ]; then
            echo "$t"
            return
        fi
    fi

    local min_t=999
    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')
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
        if echo "$type_val" | grep -iqE "battery|vbat"; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 10000 ] && raw=$((raw / 100))
                if [ "$raw" -ge 100 ] && [ "$raw" -le 800 ]; then
                    [ "$raw" -lt "$min_t" ] && min_t="$raw"
                fi
            fi
        fi
    done
    [ "$min_t" -lt 999 ] && echo "$min_t" || echo 350
}

# ─── Ambient / Skin Temp Proxy ────────────────────────────────────────────────
get_ambient_proxy_temp() {
    local skin_t=0
    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')
        if echo "$type_val" | grep -iqE "quiet_therm|skin|xo_therm|board"; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 1000 ] && raw=$((raw / 1000))
                if [ "$raw" -ge 20 ] && [ "$raw" -le 70 ]; then
                    [ "$raw" -gt "$skin_t" ] && skin_t="$raw"
                fi
            fi
        fi
    done
    [ "$skin_t" -gt 0 ] && echo "$skin_t" || echo 30
}

# ─── USB / Connector Temp Proxy ───────────────────────────────────────────────
get_usb_proxy_temp() {
    local usb_t=0
    for tz_type in /sys/class/thermal/thermal_zone*/type; do
        [ -f "$tz_type" ] || continue
        local type_val=$(cat "$tz_type" 2>/dev/null | tr -d '\n')
        if echo "$type_val" | grep -iqE "usb|charger_therm|pmic_therm|chg-therm|usbc-therm|connector_therm|pmic"; then
            local tz_dir="${tz_type%/*}"
            if [ -f "$tz_dir/temp" ]; then
                local raw=$(cat "$tz_dir/temp" 2>/dev/null || echo 0)
                [ "$raw" -gt 1000 ] && raw=$((raw / 1000))
                if [ "$raw" -ge 20 ] && [ "$raw" -le 80 ]; then
                    [ "$raw" -gt "$usb_t" ] && usb_t="$raw"
                fi
            fi
        fi
    done
    [ "$usb_t" -gt 0 ] && echo "$usb_t" || echo 30
}


# ─── Fast Charger Hardware Detection ──────────────────────────────────────────
is_hardware_fast_charger() {
    local pd_active=$(cat /sys/class/power_supply/usb/pd_active 2>/dev/null || echo 0)
    [ "$pd_active" = "1" ] && echo "true" && return

    local real_type=$(cat /sys/class/power_supply/usb/real_type 2>/dev/null | tr '[:lower:]' '[:upper:]')
    local type_val=$(cat /sys/class/power_supply/usb/type 2>/dev/null | tr '[:lower:]' '[:upper:]')

    local combined="${real_type}_${type_val}"
    case "$combined" in
        *PD*|*PPS*|*QC*|*FAST*|*CHARGE_TURBO*|*MI_FAST*) echo "true" && return ;;
    esac

    local v_now=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null || cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)
    [ "$v_now" -gt 8500000 ] && echo "true" && return

    echo "false"
}

# ─── Global State ─────────────────────────────────────────────────────────────
CHARGE_STATE="NORMAL" # COOL, NORMAL, WARM, HOT, EMERGENCY
LAST_APPLIED_CHARGE_LIMIT=""
LAST_ENFORCE_TIME=0

# Trend EMA Variables
EMA_SLOPE=0
PREV_BATT_TEMP=0
PREDICTION_STRIKES=0

# Adaptive Learning
STABLE_CURRENT_UA=2000000
LEARNED_CHARGE_PROFILE="/data/local/tmp/thermalai.charge_profile"
[ -f "$LEARNED_CHARGE_PROFILE" ] && STABLE_CURRENT_UA=$(cat "$LEARNED_CHARGE_PROFILE" 2>/dev/null || echo 2000000)

apply_charging_control() {
    local realtime_gaming="$1"

    local current_plugged=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")
    if [ "$current_plugged" != "Charging" ]; then
        LAST_APPLIED_CHARGE_LIMIT=""
        EMA_SLOPE=0
        PREV_BATT_TEMP=0
        PREDICTION_STRIKES=0

        # Export Telemetry State safely
        export G_CHARGE_LIMIT=0
        export G_CHARGE_STATE="DISCHARGING"
        export G_BATT_TEMP=$(( $(get_robust_battery_temp) / 10 ))
        return 0
    fi

    # Read base inputs
    local batt_temp_raw=$(get_robust_battery_temp)
    local batt_temp=$((batt_temp_raw / 10))
    local ambient_temp=$(get_ambient_proxy_temp)
    local usb_temp=$(get_usb_proxy_temp)
    local is_fast=$(is_hardware_fast_charger)
    local batt_level=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 50)
    local gpu_load=${PREV_GPU_LOAD:-0}

    # Input Wattage Calculation
    local v_now=$(cat /sys/class/power_supply/usb/voltage_now 2>/dev/null || echo 0)
    local i_now=$(cat /sys/class/power_supply/usb/current_now 2>/dev/null || echo 0)
    # Absolute value for current (some kernels report negative during discharge)
    if [ "$i_now" -lt 0 ]; then i_now=$((i_now * -1)); fi
    export G_INPUT_WATTS=$(( (v_now / 1000) * (i_now / 1000) / 1000000 ))

    # EMA Slope Calculation
    if [ "$PREV_BATT_TEMP" -ne 0 ]; then
        local delta=$((batt_temp - PREV_BATT_TEMP))
        local scaled_delta=$((delta * 10))
        EMA_SLOPE=$(( (scaled_delta * 3 + EMA_SLOPE * 7) / 10 ))
    else
        PREV_BATT_TEMP=$batt_temp
    fi
    PREV_BATT_TEMP=$batt_temp

    # Dampened Prediction (~10-15 seconds out instead of 1 minute)
    local predicted_temp=$((batt_temp + (EMA_SLOPE * 5 / 10) ))

    # Penalty Layer: Ambient, USB, & Load
    if [ "$ambient_temp" -gt 38 ]; then predicted_temp=$((predicted_temp + 1)); fi
    if [ "$usb_temp" -gt 45 ]; then predicted_temp=$((predicted_temp + 2)); fi
    if [ "$gpu_load" -gt 80 ]; then predicted_temp=$((predicted_temp + 1)); fi
    if [ "$is_fast" = "true" ]; then predicted_temp=$((predicted_temp + 1)); fi

    # State Machine Escalation Guard (Requires consecutive predictions to escalate severely)
    local proposed_state="$CHARGE_STATE"

    # Priority hardware safety checks override battery prediction
    if [ "$usb_temp" -gt 52 ]; then
        proposed_state="EMERGENCY"
        log_debug "Connector/PMIC is extremely hot (${usb_temp}°C) - forcing EMERGENCY"
    elif [ "$usb_temp" -gt 48 ]; then
        proposed_state="HOT"
        log_debug "Connector/PMIC is hot (${usb_temp}°C) - forcing HOT"
    else
        if [ "$predicted_temp" -ge 42 ]; then proposed_state="EMERGENCY"
        elif [ "$predicted_temp" -ge 40 ]; then proposed_state="HOT"
        elif [ "$predicted_temp" -ge 38 ]; then proposed_state="WARM"
        elif [ "$predicted_temp" -ge 34 ]; then proposed_state="NORMAL"
        else proposed_state="COOL"
        fi
    fi

    # Smoothing jump escalation
    if [ "$proposed_state" = "EMERGENCY" ] && [ "$CHARGE_STATE" != "HOT" ] && [ "$CHARGE_STATE" != "EMERGENCY" ]; then
        proposed_state="HOT" # Step up sequentially
    fi

    local next_state="$proposed_state"

    # Hysteresis guards (wait for lower temps before stepping down)
    if [ "$CHARGE_STATE" = "EMERGENCY" ] && [ "$predicted_temp" -ge 40 ]; then next_state="EMERGENCY"; fi
    if [ "$CHARGE_STATE" = "HOT" ] && [ "$predicted_temp" -ge 38 ]; then next_state="HOT"; fi
    if [ "$CHARGE_STATE" = "WARM" ] && [ "$predicted_temp" -ge 36 ]; then next_state="WARM"; fi
    if [ "$CHARGE_STATE" = "NORMAL" ] && [ "$predicted_temp" -ge 32 ]; then next_state="NORMAL"; fi

    # Strike tracking to reduce false jumps into aggressive states
    if [ "$next_state" = "HOT" ] || [ "$next_state" = "EMERGENCY" ]; then
        if [ "$CHARGE_STATE" != "$next_state" ]; then
            export PREDICTION_STRIKES=$((PREDICTION_STRIKES + 1))
            if [ "$PREDICTION_STRIKES" -lt 2 ]; then
                log_debug "Prediction suggested $next_state, holding until confirmed ($PREDICTION_STRIKES strikes)."
                next_state="$CHARGE_STATE"
            fi
        fi
    else
        export PREDICTION_STRIKES=0
    fi

    if [ "$CHARGE_STATE" != "$next_state" ]; then
        log_info "Charging State: $CHARGE_STATE -> $next_state (t=${batt_temp}°C p=${predicted_temp}°C u=${usb_temp}°C s=${EMA_SLOPE})"
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT=""

        # Decay learning if we hit thermal walls (Seasonal Adaptation)
        if [ "$CHARGE_STATE" = "HOT" ] || [ "$CHARGE_STATE" = "EMERGENCY" ]; then
            STABLE_CURRENT_UA=$((STABLE_CURRENT_UA - 200000))
            [ "$STABLE_CURRENT_UA" -lt 1000000 ] && STABLE_CURRENT_UA=1000000
            echo "$STABLE_CURRENT_UA" > "$LEARNED_CHARGE_PROFILE"
        fi
    fi

    # Determine Target Current
    local target_current_ua=2000000

    if [ "$realtime_gaming" = "true" ]; then
        if [ "$batt_level" -lt 50 ]; then
            case "$CHARGE_STATE" in
                COOL)       target_current_ua=3500000 ;;
                NORMAL)     target_current_ua=3000000 ;;
                WARM)       target_current_ua=2000000 ;;
                HOT)        target_current_ua=1200000 ;;
                EMERGENCY)  target_current_ua=800000  ;;
                *)          target_current_ua=1500000 ;;
            esac
        elif [ "$batt_level" -lt 80 ]; then
            case "$CHARGE_STATE" in
                COOL)       target_current_ua=3000000 ;;
                NORMAL)     target_current_ua=2500000 ;;
                WARM)       target_current_ua=1800000 ;;
                HOT)        target_current_ua=1200000 ;;
                EMERGENCY)  target_current_ua=800000  ;;
                *)          target_current_ua=1500000 ;;
            esac
        else
            case "$CHARGE_STATE" in
                COOL|NORMAL|WARM) target_current_ua=1200000 ;;
                HOT)              target_current_ua=800000 ;;
                EMERGENCY)        target_current_ua=500000 ;;
                *)                target_current_ua=1000000 ;;
            esac
        fi

        # Improvement 4: Game-specific Charge Aggressiveness
        if [ "$CHARGE_STATE" = "WARM" ] || [ "$CHARGE_STATE" = "HOT" ]; then
            local is_aggressive="false"
            if [ -n "$_CONFIRMED_GAME_PKG" ]; then
                is_aggressive=$(grep CHARGE_AGGRESSIVE /data/local/tmp/thermalai.game_profiles/"$_CONFIRMED_GAME_PKG".conf 2>/dev/null | cut -d= -f2 || echo "false")
            fi
            if [ "$is_aggressive" = "true" ]; then
                target_current_ua=$((target_current_ua * 80 / 100))
                log_debug "Applying CHARGE_AGGRESSIVE 80% multiplier for $_CONFIRMED_GAME_PKG -> ${target_current_ua}uA"
            fi
        fi
    else
        case "$CHARGE_STATE" in
            COOL)       target_current_ua=4500000 ;;
            NORMAL)     target_current_ua=3000000 ;;
            WARM)       target_current_ua=$STABLE_CURRENT_UA ;;
            HOT)        target_current_ua=1000000 ;;
            EMERGENCY)  target_current_ua=500000  ;;
        esac
    fi

    # SOC Modification Layer (Applies to both gaming and non-gaming)
    if [ "$CHARGE_STATE" != "EMERGENCY" ]; then
        if [ "$batt_level" -ge 80 ]; then
            [ "$target_current_ua" -gt "$SOC_80_CAP_UA" ] && target_current_ua="$SOC_80_CAP_UA"
        elif [ "$batt_level" -ge 50 ]; then
            [ "$target_current_ua" -gt "$SOC_50_CAP_UA" ] && target_current_ua="$SOC_50_CAP_UA"
        fi
    fi

    # Adaptive Learning Memory Increment
    if [ "$CHARGE_STATE" = "WARM" ] && [ "$realtime_gaming" = "false" ]; then
        if [ "$EMA_SLOPE" -le 0 ] && [ "$batt_temp" -lt 37 ]; then
            STABLE_CURRENT_UA=$((STABLE_CURRENT_UA + 100000))
            # Hard upper cap for safety
            [ "$STABLE_CURRENT_UA" -gt 3500000 ] && STABLE_CURRENT_UA=3500000
            if [ $((NOW_TIME % 60)) -eq 0 ]; then echo "$STABLE_CURRENT_UA" > "$LEARNED_CHARGE_PROFILE"; fi
        fi
    fi

    # Hardware Enforcement
    if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$target_current_ua" ]; then
        apply_universal_charging_control "$target_current_ua"
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((target_current_ua / 1000))mA (batt=${batt_temp}°C pred=${predicted_temp}°C usb=${usb_temp} slope=${EMA_SLOPE} soc=${batt_level}% state=$CHARGE_STATE fast=$is_fast)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null
        LAST_APPLIED_CHARGE_LIMIT="$target_current_ua"
        LAST_ENFORCE_TIME="$NOW_TIME"
    else
        if [ $((NOW_TIME - LAST_ENFORCE_TIME)) -ge 30 ]; then
            apply_universal_charging_control "$target_current_ua"
            LAST_ENFORCE_TIME="$NOW_TIME"
        fi
    fi

    # Export Telemetry State safely
    export G_CHARGE_LIMIT=$((target_current_ua / 1000))
    export G_CHARGE_STATE="$CHARGE_STATE"
    export G_BATT_TEMP="$batt_temp"
}

restore_charging_control() {
    apply_universal_charging_control "5000000"
    log_info "Charging limits restored to hardware default"
}

# ─── Prioritized Hardware Application ─────────────────────────────────────────
apply_universal_charging_control() {
    local target_ua="$1"

    local p1="/sys/class/power_supply/battery/constant_charge_current_max"
    if [ -w "$p1" ]; then echo "$target_ua" > "$p1" 2>/dev/null; return; fi

    local p2="/sys/class/power_supply/battery/constant_charge_current"
    if [ -w "$p2" ]; then echo "$target_ua" > "$p2" 2>/dev/null; return; fi

    local p3_a="/sys/class/power_supply/main/constant_charge_current_max"
    local p3_b="/sys/class/power_supply/bms/constant_charge_current_max"
    if [ -w "$p3_a" ]; then echo "$target_ua" > "$p3_a" 2>/dev/null; return; fi
    if [ -w "$p3_b" ]; then echo "$target_ua" > "$p3_b" 2>/dev/null; return; fi

    local p4_a="/sys/class/power_supply/usb/current_max"
    local p4_b="/sys/class/power_supply/usb/input_current_limit"
    if [ -w "$p4_a" ]; then echo "$target_ua" > "$p4_a" 2>/dev/null; fi
    if [ -w "$p4_b" ]; then echo "$target_ua" > "$p4_b" 2>/dev/null; fi
}
