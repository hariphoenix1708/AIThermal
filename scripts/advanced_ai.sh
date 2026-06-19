#!/system/bin/sh
# ThermalAI - Advanced Intelligence Features

# Context-Aware Variables
WIFI_STATE_PATH="/sys/class/net/wlan0/operstate"
BRIGHTNESS_PATH="/sys/class/backlight/panel0-backlight/brightness"
GAME_PROFILES_DIR="/data/local/tmp/thermalai.game_profiles"
mkdir -p "$GAME_PROFILES_DIR"

# Smoothing factor for EMA (Exponential Moving Average)
EMA_ALPHA=0.3
EMA_TEMP_HISTORY=""

# Calculate EMA
update_ema() {
    local new_val="$1"
    if [ -z "$EMA_TEMP_HISTORY" ]; then
        EMA_TEMP_HISTORY="$new_val"
    else
        # EMA_today = (Value_today * Alpha) + (EMA_yesterday * (1 - Alpha))
        # Since we are using integer arithmetic, we scale by 100
        local scaled_alpha=30
        local scaled_one_minus_alpha=$((100 - scaled_alpha))

        local term1=$((new_val * scaled_alpha))
        local term2=$((EMA_TEMP_HISTORY * scaled_one_minus_alpha))

        EMA_TEMP_HISTORY=$(((term1 + term2) / 100))
    fi
}

get_context_score() {
    local context_score=0

    # WiFi / Mobile Data
    local wifi_state="down"
    if [ -f "$WIFI_STATE_PATH" ]; then
        wifi_state=$(cat "$WIFI_STATE_PATH" 2>/dev/null)
    fi
    if [ "$wifi_state" != "up" ]; then
        # Mobile data typically generates more heat, add conservative weight
        context_score=$((context_score - 10))
    fi

    # Brightness Check (approximation, assuming max is around 255-4095 depending on panel)
    local brightness=0
    if [ -f "$BRIGHTNESS_PATH" ]; then
        brightness=$(cat "$BRIGHTNESS_PATH" 2>/dev/null || echo 0)
    fi
    if [ "$brightness" -gt 1000 ]; then
         # High brightness contributes to heat
         context_score=$((context_score - 10))
    fi

    # Ambient Temperature Check via IIO Sensor
    local ambient_node=$(ls /sys/bus/iio/devices/iio:device*/in_temp_input 2>/dev/null | head -1)
    if [ -n "$ambient_node" ] && [ -f "$ambient_node" ]; then
        local raw_ambient=$(cat "$ambient_node" 2>/dev/null || echo 0)
        local ambient_temp=$((raw_ambient / 1000))
        if [ "$ambient_temp" -gt 35 ]; then
            context_score=$((context_score - 20))
            log_debug "Ambient temp high (${ambient_temp}°C), applied -20 context penalty."
        elif [ "$ambient_temp" -gt 32 ]; then
            context_score=$((context_score - 10))
            log_debug "Ambient temp warm (${ambient_temp}°C), applied -10 context penalty."
        fi
    fi

    echo "$context_score"
}

# Per-Game Profiles
load_game_profile() {
    local game_pkg="$1"
    local profile_file="$GAME_PROFILES_DIR/$game_pkg.conf"

    if [ -f "$profile_file" ]; then
        # Load custom thresholds if they exist
        . "$profile_file"
        log_debug "Loaded specific profile for $game_pkg"
    else
        # Default behavior, but start tracking session
        echo "SESSION_START=$(date +%s)" > "$profile_file"
        echo "MAX_TEMP=0" >> "$profile_file"
    fi
}

update_game_profile() {
    local game_pkg="$1"
    local current_temp="$2"
    local profile_file="$GAME_PROFILES_DIR/$game_pkg.conf"

    if [ -f "$profile_file" ]; then
        # Check max temp reached
        local max_temp=$(grep MAX_TEMP "$profile_file" | cut -d= -f2)
        if [ "$current_temp" -gt "$max_temp" ]; then
            sed -i "s/MAX_TEMP=$max_temp/MAX_TEMP=$current_temp/" "$profile_file"

            # If temp exceeds 46, mark it as KNOWN_HOT for future runs
            if [ "$current_temp" -gt 46 ]; then
                if grep -q "KNOWN_HOT=" "$profile_file"; then
                    sed -i "s/KNOWN_HOT=.*/KNOWN_HOT=true/" "$profile_file"
                else
                    echo "KNOWN_HOT=true" >> "$profile_file"
                fi
            fi
        fi
    fi
}

# Thermal Comfort & Power Budget Awareness
SKIN_TEMP_PATH="/sys/class/thermal/thermal_zone48/temp" # quiet_therm / skin temp approximation
BATT_TEMP_PATH="/sys/class/power_supply/battery/temp"

get_thermal_comfort_score() {
    local skin_temp=0
    local batt_temp=0
    local comfort_penalty=0

    if [ -f "$SKIN_TEMP_PATH" ]; then
        skin_temp=$(cat "$SKIN_TEMP_PATH" 2>/dev/null || echo 0)
        skin_temp=$((skin_temp / 1000))
    fi

    if [ -f "$BATT_TEMP_PATH" ]; then
        batt_temp=$(cat "$BATT_TEMP_PATH" 2>/dev/null || echo 0)
        batt_temp=$((batt_temp / 10))
    fi

    # Skin temp comfort penalty
    if [ "$skin_temp" -gt 40 ]; then
        comfort_penalty=$((comfort_penalty - 15))
    elif [ "$skin_temp" -gt 38 ]; then
        comfort_penalty=$((comfort_penalty - 5))
    fi

    # Battery heat coupling
    if [ "$batt_temp" -gt 40 ]; then
        comfort_penalty=$((comfort_penalty - 20))
    fi

    echo "$comfort_penalty"
}

get_game_profile_modifier() {
    local game_pkg="$1"
    local profile_file="$GAME_PROFILES_DIR/$game_pkg.conf"
    local modifier=0

    if [ -f "$profile_file" ]; then
        local known_hot=$(grep KNOWN_HOT "$profile_file" 2>/dev/null | cut -d= -f2)
        if [ "$known_hot" = "true" ]; then
             echo "-12"
             return
        fi

        local max_temp=$(grep MAX_TEMP "$profile_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$max_temp" ] && [ "$max_temp" -gt 45 ]; then
             # If game is known to run hot, pre-emptively be more conservative to prevent runaway
             modifier=$((modifier - 10))
        fi

        # Calculate session duration
        local start_time=$(grep SESSION_START "$profile_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$start_time" ]; then
             local current_time=$(date +%s)
             local duration=$((current_time - start_time))

             # Over 30 mins gaming, slight penalty to allow sustained play without overheating
             if [ "$duration" -gt 1800 ]; then
                 modifier=$((modifier - 5))
             fi
        fi
    fi
    echo "$modifier"
}

get_cooling_efficiency() {
    # If temp is dropping rapidly while load is high, there is likely external cooling
    # Returning a positive boost score to allow more performance
    local efficiency_boost=0

    if [ -n "$EMA_TEMP_HISTORY" ]; then
         local temp_diff=$(($1 - EMA_TEMP_HISTORY))
         local gpu_load=$2

         if [ "$temp_diff" -lt -2 ] && [ "$gpu_load" -gt 50 ]; then
             efficiency_boost=15 # Cooling present, boost performance
             log_debug "Cooling efficiency detected, adding score boost."
         fi
    fi
    echo "$efficiency_boost"
}

get_foreground_priority() {
    # Increase scores for critical games / foreground tasks
    local game_pkg="$1"
    local priority_boost=0

    # Priority boosting for certain heavy games
    case "$game_pkg" in
        com.miHoYo.*|com.HoYoverse.*|*genshin*|*honkai*|*starrail*)
            priority_boost=15
            ;;
        com.tencent.ig|com.tencent.tmgp.*|com.pubg.*)
            priority_boost=10
            ;;
    esac

    echo "$priority_boost"
}

detect_frame_stutter() {
    local game_pkg="$1"
    [ -z "$game_pkg" ] && echo "false" && return

    # Find PID of the game process
    local game_pid=""
    for pid_cmdline in /proc/[0-9]*/cmdline; do
        local pid="${pid_cmdline%/cmdline}"
        pid="${pid##*/proc/}"
        local pkg
        pkg=$(cat "$pid_cmdline" 2>/dev/null | tr '\0' '\n' | head -1)
        [ "$pkg" = "$game_pkg" ] && game_pid="$pid" && break
    done
    [ -z "$game_pid" ] && echo "false" && return

    # schedstat field 2 = total wait time in nanoseconds
    local wait_ns
    wait_ns=$(awk '{print $2}' /proc/$game_pid/schedstat 2>/dev/null || echo "0")

    # Threshold: >50ms accumulated wait this tick = scheduling starvation
    if [ "$wait_ns" -gt 50000000 ]; then
        log_debug "Stutter detected: game=$game_pkg wait=${wait_ns}ns"
        echo "true"
        return
    fi
    echo "false"
}
