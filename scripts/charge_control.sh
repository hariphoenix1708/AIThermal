#!/system/bin/sh
# ThermalAI - Advanced Adaptive Charge Controller
# Architecture:
# Layer 1: Thermal Safety (Battery + Ambient + Prediction)
# Layer 2: Performance Awareness (Gaming, GPU Load, SOC)
# Layer 3: Adaptive Learning (Stable Current Memory)

BATT_CURRENT_MAX="/sys/class/power_supply/battery/constant_charge_current_max"
BATT_CAPACITY="/sys/class/power_supply/battery/capacity"

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
        if echo "$type_val" | grep -iqE "battery|charger_therm|vbat"; then
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

    # Voltage check fallback (9V or higher is fast charging)
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
        return 0
    fi

    # Read base inputs
    local batt_temp_raw=$(get_robust_battery_temp)
    local batt_temp=$((batt_temp_raw / 10))
    local ambient_temp=$(get_ambient_proxy_temp)
    local is_fast=$(is_hardware_fast_charger)
    local batt_level=$(cat "$BATT_CAPACITY" 2>/dev/null || echo 50)
    local gpu_load=${PREV_GPU_LOAD:-0}

    # EMA Slope Calculation
    if [ "$PREV_BATT_TEMP" -ne 0 ]; then
        local delta=$((batt_temp - PREV_BATT_TEMP))
        # Scale slope by 10 for precision. EMA Alpha = 0.3
        # EMA = (Delta*10 * 3 + EMA * 7) / 10
        local scaled_delta=$((delta * 10))
        EMA_SLOPE=$(( (scaled_delta * 3 + EMA_SLOPE * 7) / 10 ))
    else
        PREV_BATT_TEMP=$batt_temp
    fi
    PREV_BATT_TEMP=$batt_temp

    # Predictive Temp (Predict where we will be in ~1 minute assuming 1 tick = ~2s, so ~30 ticks)
    # EMA_SLOPE is scaled by 10. To get actual degrees delta, divide by 10.
    # Prediction = batt_temp + (EMA_SLOPE / 10) * multiplier
    local predicted_temp=$((batt_temp + (EMA_SLOPE * 30 / 10) ))

    # Penalty Layer: Ambient & Load
    if [ "$ambient_temp" -gt 36 ]; then predicted_temp=$((predicted_temp + 1)); fi
    if [ "$gpu_load" -gt 80 ]; then predicted_temp=$((predicted_temp + 1)); fi

    # State Machine with Hysteresis
    local next_state="$CHARGE_STATE"
    if [ "$predicted_temp" -ge 42 ]; then
        next_state="EMERGENCY"
    elif [ "$predicted_temp" -ge 40 ]; then
        next_state="HOT"
    elif [ "$predicted_temp" -ge 38 ]; then
        next_state="WARM"
    elif [ "$predicted_temp" -ge 34 ]; then
        next_state="NORMAL"
    else
        next_state="COOL"
    fi

    # Hysteresis guards (prevents rapid bouncing)
    if [ "$CHARGE_STATE" = "HOT" ] && [ "$predicted_temp" -ge 39 ]; then next_state="HOT"; fi
    if [ "$CHARGE_STATE" = "WARM" ] && [ "$predicted_temp" -ge 37 ]; then next_state="WARM"; fi
    if [ "$CHARGE_STATE" = "NORMAL" ] && [ "$predicted_temp" -ge 33 ]; then next_state="NORMAL"; fi

    if [ "$CHARGE_STATE" != "$next_state" ]; then
        log_info "Charging State: $CHARGE_STATE -> $next_state (t=${batt_temp}°C p=${predicted_temp}°C s=${EMA_SLOPE} a=${ambient_temp}°C)"
        CHARGE_STATE="$next_state"
        LAST_APPLIED_CHARGE_LIMIT=""
    fi

    # Determine Target Current
    local target_current_ua=2000000

    if [ "$realtime_gaming" = "true" ]; then
        # Gaming Target Profile (Aggressive limits for F6)
        if   [ "$predicted_temp" -lt 34 ]; then target_current_ua=3000000
        elif [ "$predicted_temp" -lt 37 ]; then target_current_ua=2500000
        elif [ "$predicted_temp" -lt 39 ]; then target_current_ua=1800000
        elif [ "$predicted_temp" -lt 41 ]; then target_current_ua=1200000
        else                                    target_current_ua=800000
        fi
    else
        # Normal Target Profile
        case "$CHARGE_STATE" in
            COOL)       target_current_ua=4500000 ;;
            NORMAL)     target_current_ua=3000000 ;;
            WARM)       target_current_ua=$STABLE_CURRENT_UA ;; # Adaptive Recovery
            HOT)        target_current_ua=1000000 ;;
            EMERGENCY)  target_current_ua=500000  ;;
        esac
    fi

    # SOC Modification Layer
    if [ "$CHARGE_STATE" != "EMERGENCY" ]; then
        if [ "$batt_level" -gt 80 ]; then
            # Conservative: limit strictly
            [ "$target_current_ua" -gt 1500000 ] && target_current_ua=1500000
        elif [ "$batt_level" -gt 50 ]; then
            # Balanced: slight taper
            [ "$target_current_ua" -gt 2500000 ] && target_current_ua=2500000
        fi
    fi

    # Adaptive Learning: If we are WARM but temperature slope is zero or negative (cooling),
    # it means the current is perfectly stable. Store it as STABLE_CURRENT_UA.
    if [ "$CHARGE_STATE" = "WARM" ] && [ "$realtime_gaming" = "false" ]; then
        if [ "$EMA_SLOPE" -le 0 ] && [ "$batt_temp" -lt 37 ]; then
            STABLE_CURRENT_UA=$((STABLE_CURRENT_UA + 100000))
            if [ $((NOW_TIME % 60)) -eq 0 ]; then echo "$STABLE_CURRENT_UA" > "$LEARNED_CHARGE_PROFILE"; fi
        fi
    fi

    # Hardware Enforcement
    if [ "$LAST_APPLIED_CHARGE_LIMIT" != "$target_current_ua" ]; then
        apply_universal_charging_control "$target_current_ua"
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] [DEBUG] Charging current limit set to $((target_current_ua / 1000))mA (batt=${batt_temp}°C pred=${predicted_temp}°C slope=${EMA_SLOPE} soc=${batt_level}% state=$CHARGE_STATE fast=$is_fast)" >> /data/local/tmp/thermalai_verbose.log 2>/dev/null
        LAST_APPLIED_CHARGE_LIMIT="$target_current_ua"
        LAST_ENFORCE_TIME="$NOW_TIME"
    else
        if [ $((NOW_TIME - LAST_ENFORCE_TIME)) -ge 30 ]; then
            apply_universal_charging_control "$target_current_ua"
            LAST_ENFORCE_TIME="$NOW_TIME"
        fi
    fi
}

restore_charging_control() {
    apply_universal_charging_control "5000000"
    log_info "Charging limits restored to hardware default"
}

# ─── Prioritized Hardware Application ─────────────────────────────────────────
apply_universal_charging_control() {
    local target_ua="$1"

    # Priority 1: Qualcomm Max Constant Charge Current
    local p1="/sys/class/power_supply/battery/constant_charge_current_max"
    if [ -w "$p1" ]; then echo "$target_ua" > "$p1" 2>/dev/null; return; fi

    # Priority 2: Standard Constant Charge Current
    local p2="/sys/class/power_supply/battery/constant_charge_current"
    if [ -w "$p2" ]; then echo "$target_ua" > "$p2" 2>/dev/null; return; fi

    # Priority 3: Main/BMS fallback
    local p3_a="/sys/class/power_supply/main/constant_charge_current_max"
    local p3_b="/sys/class/power_supply/bms/constant_charge_current_max"
    if [ -w "$p3_a" ]; then echo "$target_ua" > "$p3_a" 2>/dev/null; return; fi
    if [ -w "$p3_b" ]; then echo "$target_ua" > "$p3_b" 2>/dev/null; return; fi

    # Priority 4: USB Input limits (Often controls wall draw, not battery limit, so it's a fallback)
    local p4_a="/sys/class/power_supply/usb/current_max"
    local p4_b="/sys/class/power_supply/usb/input_current_limit"
    if [ -w "$p4_a" ]; then echo "$target_ua" > "$p4_a" 2>/dev/null; fi
    if [ -w "$p4_b" ]; then echo "$target_ua" > "$p4_b" 2>/dev/null; fi
}
