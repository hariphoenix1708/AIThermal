#!/system/bin/sh
# ThermalAI - Core AI Daemon v3.0
# Device: POCO F6 (peridot) / AOSP Android 16 / GlaciumKernel
#
# Changes vs v2.0:
#  [FIX-1] Trend clamp raised ±30→±50; contribution /5→/4 (more signal)
#  [FIX-2] Performance threshold lowered 65→55 (reachable at 36°C without gaming)
#  [FIX-3] Performance also reachable at very low temps (<40°C) with positive trend
#  [FIX-4] Gaming confirmed pkg name logged in every AI line for traceability
#  [FIX-5] Score logged with component breakdown (temp/pred/gaming/trend) for debug
#  [FIX-6] GPU load > 40% with gaming=false now logs a warning (helps diagnose)

MODDIR="${0%/*}/.."
. "$MODDIR/scripts/logger.sh"
. "$MODDIR/scripts/game_detector.sh"
. "$MODDIR/scripts/governor_tuner.sh"
. "$MODDIR/scripts/charge_control.sh"
. "$MODDIR/scripts/game_tweaks.sh"
. "$MODDIR/scripts/advanced_ai.sh"
. "$MODDIR/scripts/state_manager.sh"
. "$MODDIR/scripts/thermal_policy.sh"

CFG="$MODDIR/config/profiles.conf"
[ -f "$CFG" ] && . "$CFG"

# ─── Config ───────────────────────────────────────────────────────────────────
POLL_INTERVAL="${POLL_INTERVAL:-2}"
GAME_POLL_INTERVAL="${GAME_POLL_INTERVAL:-1}"
TEMP_HISTORY_SIZE="${TEMP_HISTORY_SIZE:-10}"
PREDICTION_WINDOW="${PREDICTION_WINDOW:-5}"
POLICY_DEBOUNCE_SEC="${POLICY_DEBOUNCE_SEC:-10}"
GAMING_SCORE_BOOST="${GAMING_SCORE_BOOST:-35}"
GPU_GAMING_THRESHOLD="${GPU_GAMING_THRESHOLD:-20}"
LOG_ROTATE_MIN="${LOG_ROTATE_MIN:-60}"

# Base threshold definitions (can be modified by self-calibration)
BASE_TEMP_COOL="${TEMP_COOL:-42}"
BASE_TEMP_WARM="${TEMP_WARM:-48}"
BASE_TEMP_HOT="${TEMP_HOT:-58}"
BASE_TEMP_POWERSAVE="${TEMP_POWERSAVE:-68}"
BASE_TEMP_CRITICAL="${TEMP_CRITICAL:-75}"

TEMP_COOL="$BASE_TEMP_COOL"
TEMP_WARM="$BASE_TEMP_WARM"
TEMP_HOT="$BASE_TEMP_HOT"
TEMP_POWERSAVE="$BASE_TEMP_POWERSAVE"
TEMP_CRITICAL="$BASE_TEMP_CRITICAL"

CALIBRATION_FILE="/data/local/tmp/thermalai.calibration"

# ─── State ────────────────────────────────────────────────────────────────────
TEMP_HISTORY=""
TEMP_HISTORY_COUNT=0
TREND_SCORE=0
CURRENT_POLICY="balanced"
LAST_POLICY_CHANGE=0
WATCHDOG_FAILURES=0
WATCHDOG_LIMIT=5

# ─── Thermal zones ────────────────────────────────────────────────────────────
_zone_weight() {
    case "$1" in
        cpuss-*)             echo 10 ;;
        gpuss-*)             echo 9  ;;
        cpu-[0-9]-[0-9]-*)  echo 8  ;;
        xo-therm|cpu_therm) echo 7  ;;
        quiet_therm)         echo 6  ;;
        battery)             echo 5  ;;
        ddr)                 echo 4  ;;
        aoss-*)              echo 3  ;;
        mdmss-*)             echo 2  ;;
        sub1_*|mmw*|sdr0_pa|mmw_ific*) echo 0 ;;
        *)                   echo 2  ;;
    esac
}

ACTIVE_ZONES=""
init_thermal_zones() {
    log_info "Building weighted thermal zone map..."
    local count=0 skipped=0
    for zone_path in /sys/class/thermal/thermal_zone*/; do
        local ztype
        ztype=$(cat "${zone_path}type" 2>/dev/null) || continue
        local zone_id="${zone_path##*thermal_zone}"; zone_id="${zone_id%/}"
        local weight; weight=$(_zone_weight "$ztype")
        [ "$weight" -eq 0 ] && skipped=$((skipped+1)) && continue
        local raw_temp
        raw_temp=$(cat "${zone_path}temp" 2>/dev/null) || continue
        [ "$raw_temp" -lt 0 ] 2>/dev/null && skipped=$((skipped+1)) && continue
        ACTIVE_ZONES="$ACTIVE_ZONES ${zone_id}:${weight}"
        count=$((count+1))
    done
    ACTIVE_ZONES="${ACTIVE_ZONES# }"
    log_info "Active zones: $count used, $skipped skipped"
}

get_composite_temp() {
    local tw=0 wt=0
    for entry in $ACTIVE_ZONES; do
        local zid="${entry%%:*}" w="${entry##*:}"
        local t
        t=$(cat "/sys/class/thermal/thermal_zone${zid}/temp" 2>/dev/null) || continue
        [ "$t" -gt 1000 ] 2>/dev/null && t=$((t/1000))
        [ "$t" -lt 0 ] 2>/dev/null && continue
        [ "$t" -gt 120 ] 2>/dev/null && continue
        tw=$((tw + t*w)); wt=$((wt + w))
    done
    [ "$wt" -eq 0 ] && echo "45" && return
    echo $((tw/wt))
}

get_gpu_load() {
    local l
    l=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print int($1)}')
    [ -n "$l" ] && echo "$l" && return
    l=$(cat /sys/kernel/gpu/gpu_busy 2>/dev/null | tr -d '% ')
    [ -n "$l" ] && echo "$l" && return
    echo "0"
}

# ─── History ──────────────────────────────────────────────────────────────────
update_history() {
    TEMP_HISTORY="$TEMP_HISTORY $1"
    TEMP_HISTORY_COUNT=$((TEMP_HISTORY_COUNT+1))
    if [ "$TEMP_HISTORY_COUNT" -gt "$TEMP_HISTORY_SIZE" ]; then
        TEMP_HISTORY=$(echo "$TEMP_HISTORY" | awk '{for(i=2;i<=NF;i++)printf "%s%s",$i,(i==NF?"\n":" ")}')
        TEMP_HISTORY_COUNT=$((TEMP_HISTORY_COUNT-1))
    fi
}

calculate_trend() {
    local n; n=$(echo "$1" | awk '{print NF}')
    [ "$n" -lt 2 ] && echo "0" && return
    echo "$1" | awk '{
        n=NF;sx=0;sy=0;sxy=0;sx2=0
        for(i=1;i<=n;i++){sx+=i;sy+=$i;sxy+=i*$i;sx2+=i*i}
        d=n*sx2-sx*sx
        print (d==0)?0:int((n*sxy-sx*sy)*100/d)
    }'
}

# ─── Asymmetric EMA [FIX-1: clamp raised to ±50] ────────────────────────────
update_trend_ema() {
    local s="$1"

    # NEW: Heavily penalize sudden huge temperature spikes to act faster
    if [ "$s" -gt 15 ] && [ "$s" -gt "$TREND_SCORE" ]; then
        # Huge spike detected, fast-track the EMA upward
        TREND_SCORE=$((TREND_SCORE*40/100 + s*60/100))
    elif [ "$s" -gt "$TREND_SCORE" ]; then
        TREND_SCORE=$((TREND_SCORE*75/100 + s*25/100))
    else
        TREND_SCORE=$((TREND_SCORE*45/100 + s*55/100))
    fi

    [ "$TREND_SCORE" -gt  50 ] && TREND_SCORE=50   # was ±30
    [ "$TREND_SCORE" -lt -50 ] && TREND_SCORE=-50
}

predict_temp() {
    local p=$(($1 + $2*$3/100))
    [ "$2" -gt 50 ] && p=$((p*85/100))
    [ "$p" -gt 100 ] && p=100; [ "$p" -lt 20 ] && p=20; echo "$p"
}

calculate_confidence() {
    local n="$TEMP_HISTORY_COUNT"
    local b=$((n*100/TEMP_HISTORY_SIZE))
    if [ "$n" -ge 3 ]; then
        local v; v=$(echo "$TEMP_HISTORY" | awk '{
            s=0;for(i=2;i<=NF;i++)s+=($i>$(i-1)?$i-$(i-1):$(i-1)-$i)
            print int(s/(NF-1))}')
        [ "$v" -gt 5 ] && b=$((b*70/100))
    fi
    [ "$b" -gt 100 ] && b=100; echo "$b"
}

# ─── AI Scoring ───────────────────────────────────────────────────────────────
ai_decide_policy() {
    local cur="$1" gpu="$2" gaming="$3" pred="$4" conf="$5"
    local s=0 s_temp=0 s_pred=0 s_game=0 s_trend=0

    # Temp component
    if   [ "$cur" -lt "$TEMP_COOL" ];      then s_temp=40
    elif [ "$cur" -lt "$TEMP_WARM" ];      then s_temp=20
    elif [ "$cur" -lt "$TEMP_HOT" ];       then s_temp=-20
    elif [ "$cur" -lt "$TEMP_POWERSAVE" ]; then s_temp=-50
    else                                        s_temp=-80
    fi

    # Prediction component
    if [ "$conf" -gt 50 ]; then
        local delta=$((pred - cur))
        if   [ "$delta" -gt 10 ]; then s_pred=-35
        elif [ "$delta" -gt  5 ]; then s_pred=-18
        elif [ "$delta" -gt  2 ]; then s_pred=-8
        elif [ "$delta" -lt -5 ]; then s_pred=20
        elif [ "$delta" -lt -2 ]; then s_pred=10
        fi
    fi

    # Gaming boost
    if $gaming; then
        s_game=$GAMING_SCORE_BOOST
        [ "$gpu" -gt 90 ] && s_game=$((s_game - 15))
        [ "$gpu" -gt 70 ] && [ "$gpu" -le 90 ] && s_game=$((s_game - 8))
    fi

    # Trend [FIX-1: /4 instead of /5 — more weight now clamp is ±50]
    s_trend=$((TREND_SCORE / 4))

    s=$((s_temp + s_pred + s_game + s_trend))

    # Incorporate dynamic context weighting
    local context_weight=$(get_context_score)
    local comfort_weight=$(get_thermal_comfort_score 2>/dev/null || echo 0)
    s=$((s + comfort_weight))
    s=$((s + context_weight))

    if $gaming; then
        local game_pkg=$(get_current_game)
        if [ -n "$game_pkg" ]; then
            local game_mod=$(get_game_profile_modifier "$game_pkg")
            s=$((s + game_mod))
            local fg_boost=$(get_foreground_priority "$game_pkg")
            s=$((s + fg_boost))
        fi
    fi

    local cooling_boost=$(get_cooling_efficiency "$cur" "$gpu")
    s=$((s + cooling_boost))

    [ "$s" -gt  100 ] && s=100
    [ "$s" -lt -100 ] && s=-100

    # Hysteresis policy mapping [FIX-2: performance threshold 65→55]
    local policy=""
    case "$CURRENT_POLICY" in
        performance)
            [ "$s" -lt 45 ] && policy="balanced" || policy="performance" ;;
        balanced)
            if   [ "$s" -ge 55 ]; then policy="performance"   # was 65
            elif [ "$s" -lt 15 ]; then policy="conservative"
            else                       policy="balanced"
            fi ;;
        conservative)
            if   [ "$s" -ge 25 ]; then policy="balanced"
            elif [ "$s" -lt -15 ]; then policy="powersave"
            else                        policy="conservative"
            fi ;;
        powersave)
            if   [ "$s" -ge -5  ]; then policy="conservative"
            elif [ "$s" -lt -55 ]; then policy="emergency_cool"
            else                        policy="powersave"
            fi ;;
        emergency_cool)
            [ "$s" -ge -45 ] && policy="powersave" || policy="emergency_cool" ;;
        *)
            if   [ "$s" -ge 55 ]; then policy="performance"
            elif [ "$s" -ge 20 ]; then policy="balanced"
            elif [ "$s" -ge -10 ]; then policy="conservative"
            elif [ "$s" -ge -50 ]; then policy="powersave"
            else                        policy="emergency_cool"
            fi ;;
    esac

    # Debounce (emergency bypasses)
    if [ "$policy" != "$CURRENT_POLICY" ] && [ "$policy" != "emergency_cool" ]; then
        local now; now=$(date +%s)
        local since=$((now - LAST_POLICY_CHANGE))
        if [ "$since" -lt "$POLICY_DEBOUNCE_SEC" ]; then
            log_debug "Debounce: $CURRENT_POLICY->$policy (${since}s)"
            policy="$CURRENT_POLICY"
        fi
    fi

    # Diagnostic: warn if high GPU but gaming=false (detection suspect)
    if [ "$gpu" -ge 40 ] && ! $gaming; then
        log_debug "WARN: gpu=${gpu}% but gaming=false — check detector"
    fi

    # [FIX-4] Include confirmed game pkg in log line
    local game_pkg; game_pkg=$(get_current_game)
    log_info "AI: cur=${cur}°C pred=${pred}°C gpu=${gpu}% gaming=${gaming}(${game_pkg}) t=${s_temp} p=${s_pred} g=${s_game} tr=${s_trend} ctx=${context_weight} comf=${comfort_weight} score=${s} -> ${policy}"
    echo "$policy"
}

# ─── Log Rotation ─────────────────────────────────────────────────────────────
start_log_rotation() {
    local sec=$((LOG_ROTATE_MIN * 60))
    (while true; do
        # Property-based override (Tasker / ADB / automation)
        local forced_policy
        forced_policy=$(getprop thermalai.force_policy 2>/dev/null)
        if [ -n "$forced_policy" ] && [ "$forced_policy" != "none" ]; then
            case "$forced_policy" in
                performance|balanced|conservative|powersave|emergency_cool)
                    log_info "Property override: thermalai.force_policy=$forced_policy"
                    apply_thermal_policy "$forced_policy" "$gaming" "$temp"
                    CURRENT_POLICY="$forced_policy"
                    LAST_POLICY_CHANGE=$(date +%s)
                    setprop thermalai.force_policy "none" 2>/dev/null
                    ;;
                *)
                    log_warn "Invalid thermalai.force_policy value: $forced_policy"
                    setprop thermalai.force_policy "none" 2>/dev/null
                    ;;
            esac
        fi
        sleep "$sec"
        local now; now=$(date "+%Y-%m-%d %H:%M:%S")
        local buf; buf=$(tail -200 "$LOG_FILE" 2>/dev/null)
        printf "[$now] [INFO] ── Log rotated (every ${LOG_ROTATE_MIN}min) ──\n" > "$LOG_FILE"
        echo "$buf" >> "$LOG_FILE"
        log_info "Log rotated"
    done) &
    log_info "Log rotation started (every ${LOG_ROTATE_MIN} min)"
}

# ─── Self-Calibration ─────────────────────────────────────────────────────────
# Automatically adjust thresholds based on how often the device overheats
perform_self_calibration() {
    local current_temp="$1"

    # Simple logic: track consecutive minutes above 'powersave' threshold.
    # If the phone runs too hot for too long, permanently shift thresholds down slightly.
    if [ "$current_temp" -ge "$BASE_TEMP_POWERSAVE" ]; then
        if [ ! -f "$CALIBRATION_FILE" ]; then
            echo "1" > "$CALIBRATION_FILE"
        else
            local count=$(cat "$CALIBRATION_FILE" 2>/dev/null || echo "0")
            count=$((count + 1))
            echo "$count" > "$CALIBRATION_FILE"

            if [ "$count" -ge 60 ]; then # E.g., device was > 68C for roughly 60 ticks (2 mins)
                log_warn "Self-Calibration: Device running hot for extended period. Lowering thresholds by 2°C to protect hardware."

                # Apply dynamic shift
                TEMP_COOL=$((BASE_TEMP_COOL - 2))
                TEMP_WARM=$((BASE_TEMP_WARM - 2))
                TEMP_HOT=$((BASE_TEMP_HOT - 2))
                TEMP_POWERSAVE=$((BASE_TEMP_POWERSAVE - 2))
                TEMP_CRITICAL=$((BASE_TEMP_CRITICAL - 2))

                # Reset counter so we don't infinitely scale
                echo "0" > "$CALIBRATION_FILE"
            fi
        fi
    else
        # If cool, slowly decay the calibration counter back to normal
        if [ -f "$CALIBRATION_FILE" ]; then
             local count=$(cat "$CALIBRATION_FILE" 2>/dev/null || echo "0")
             if [ "$count" -gt 0 ]; then
                 count=$((count - 1))
                 echo "$count" > "$CALIBRATION_FILE"
             elif [ "$TEMP_COOL" -ne "$BASE_TEMP_COOL" ]; then
                 # If counter is 0 and we shifted, device has cooled completely. Restore thresholds.
                 log_info "Self-Calibration: Device has recovered. Restoring original temperature thresholds."
                 TEMP_COOL="$BASE_TEMP_COOL"
                 TEMP_WARM="$BASE_TEMP_WARM"
                 TEMP_HOT="$BASE_TEMP_HOT"
                 TEMP_POWERSAVE="$BASE_TEMP_POWERSAVE"
                 TEMP_CRITICAL="$BASE_TEMP_CRITICAL"
             fi
        fi
    fi
}

# ─── Display State ────────────────────────────────────────────────────────────
get_screen_state() {
    local state
    state=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || echo "100")
    if [ "$state" = "0" ]; then
        echo "off"
    else
        echo "on"
    fi
}

# ─── Main Loop ────────────────────────────────────────────────────────────────
main_loop() {
    log_info "════════════════════════════════════════"
    log_info " ThermalAI v3.0 daemon starting"
    log_info " Device : POCO F6 (peridot)"
    log_info " SoC    : Snapdragon 8s Gen 3 (pineapple)"
    log_info " Kernel : $(uname -r)"
    log_info " Config : poll=${POLL_INTERVAL}s game_poll=${GAME_POLL_INTERVAL}s"
    log_info "          debounce=${POLICY_DEBOUNCE_SEC}s latch=${GAME_LATCH_SEC}s"
    log_info "          gpu_thresh=${GPU_GAMING_THRESHOLD}% rotate=${LOG_ROTATE_MIN}min"
    log_info " Detect : oom_score_adj+RenderThread+dumpsys(fallback)"
    log_info "════════════════════════════════════════"

    init_thermal_zones
    discover_cpu_topology
    start_log_rotation
    apply_thermal_policy "balanced" "false" "40"

    while true; do
        # Property-based override (Tasker / ADB / automation)
        local forced_policy
        forced_policy=$(getprop thermalai.force_policy 2>/dev/null)
        if [ -n "$forced_policy" ] && [ "$forced_policy" != "none" ]; then
            case "$forced_policy" in
                performance|balanced|conservative|powersave|emergency_cool)
                    log_info "Property override: thermalai.force_policy=$forced_policy"
                    apply_thermal_policy "$forced_policy" "$gaming" "$temp"
                    CURRENT_POLICY="$forced_policy"
                    LAST_POLICY_CHANGE=$(date +%s)
                    setprop thermalai.force_policy "none" 2>/dev/null
                    ;;
                *)
                    log_warn "Invalid thermalai.force_policy value: $forced_policy"
                    setprop thermalai.force_policy "none" 2>/dev/null
                    ;;
            esac
        fi
        local temp; temp=$(get_composite_temp)
        local gpu;  gpu=$(get_gpu_load)

        perform_self_calibration "$temp"
        update_ema "$temp"

        # Watchdog Check
        if [ "$temp" -eq 45 ] && [ -z "$ACTIVE_ZONES" ]; then
            WATCHDOG_FAILURES=$((WATCHDOG_FAILURES + 1))
        else
            WATCHDOG_FAILURES=0
        fi

        if [ "$WATCHDOG_FAILURES" -ge "$WATCHDOG_LIMIT" ]; then
            log_error "CRITICAL: Watchdog triggered! Thermal sensors failing to read."
            log_error "Aborting AI daemon and falling back to stock thermal engine."
            restore_stock_thermal
            exit 1
        fi
        local screen_state; screen_state=$(get_screen_state)
        local new_policy

        if [ "$screen_state" = "off" ]; then
            new_policy="suspend"
        else
            new_policy=$(ai_decide_policy "$temp" "$gpu" "$gaming" "$pred" "$conf")
        fi

        # Stutter override: jank during balanced -> force conservative gaming
        if $gaming && [ "$new_policy" = "balanced" ]; then
            local game_pkg
            game_pkg=$(get_current_game)
            local stutter
            stutter=$(detect_frame_stutter "$game_pkg")
            if [ "$stutter" = "true" ]; then
                log_info "Stutter override: balanced -> conservative (jank detected)"
                new_policy="conservative"
            fi
        fi

        if [ "$new_policy" != "$CURRENT_POLICY" ]; then
            apply_thermal_policy "$new_policy" "$gaming" "$temp"
            log_info "Policy change: temp=${cur} gpu=${gpu} gaming=${gaming} -> ${new_policy}"

            CURRENT_POLICY="$new_policy"
            LAST_POLICY_CHANGE=$(date +%s)
        fi

        if [ "$screen_state" = "off" ]; then
            sleep "$((POLL_INTERVAL * 2))" # Poll slower when screen is off
        elif $gaming || [ "$gpu" -ge "$GPU_GAMING_THRESHOLD" ]; then
            sleep "$GAME_POLL_INTERVAL"
        else
            sleep "$POLL_INTERVAL"
        fi
    done
}

main_loop
