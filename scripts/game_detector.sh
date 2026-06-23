#!/system/bin/sh
# ThermalAI - Gaming Context Detector v3.0
# Device: POCO F6 (peridot) / AOSP Android 16 / GlaciumKernel
#
# ══════════════════════════════════════════════════════════════
# ARCHITECTURE CHANGE v3.0: dumpsys FULLY REPLACED
# ══════════════════════════════════════════════════════════════
# Root cause of all previous failures:
#   dumpsys window/SurfaceFlinger output format is unstable across
#   Android versions, immersive fullscreen mode, and ROM builds.
#   Every approach that parses dumpsys string output will eventually
#   break on some edge case.
#
# New primary method: /proc/<pid>/oom_score_adj
#   Android kernel GUARANTEES: the foreground app process always has
#   oom_score_adj = 0 (FOREGROUND_APP_ADJ).
#   Background cached apps = 700-906. Services = 200-500.
#   This is a kernel-level invariant — immune to ROM changes.
#
# Detection pipeline (3 independent layers, any one sufficient):
#
#   LAYER 1 — oom_score_adj scan (PRIMARY, kernel-guaranteed)
#     Scan /proc/*/oom_score_adj for value = 0
#     Read /proc/*/cmdline to get package name
#     Match against known game list → gaming=true + latch
#
#   LAYER 2 — RenderThread process scan (GPU ACTIVITY)
#     Scan ALL app_process64 PIDs (not just foreground PID)
#     Check /proc/<pid>/task/*/comm for "RenderThread"
#     If found AND gpu_load ≥ threshold → gaming=true + latch
#     Works even when foreground detection fails (loading screen, etc.)
#
#   LAYER 3 — Latch holdover
#     Once game confirmed, hold gaming=true for GAME_LATCH_SEC
#     Survives: app switches, Recents, loading screens, brief GPU dips
#     Resets only after GAME_LATCH_SEC seconds of no re-confirmation
#
#   LAYER 4 — dumpsys fallback (last resort only)
#     Only runs if layers 1+2 found nothing AND cache expired
#     Limited to 2 fast targeted commands, not full dumpsys dump
#
# App-switch / Recents behaviour:
#   When user goes to Recents: CODM oom_score_adj rises to 700
#   (cached process). Latch keeps gaming=true for GAME_LATCH_SEC secs.
#   When user returns to CODM: oom_score_adj drops back to 0 within
#   the next kernel scheduler cycle → detected on next 1s poll.

MODDIR="${0%/*}/.."
GAME_LIST_FILE="$MODDIR/config/game_list.conf"

# ─── Tunables ─────────────────────────────────────────────────────────────────
GPU_GAMING_THRESHOLD="${GPU_GAMING_THRESHOLD:-20}"
GAME_LATCH_SEC="${GAME_LATCH_SEC:-45}"        # raised: loading screens can be 30-40s
PKG_CACHE_TTL="${PKG_CACHE_TTL:-5}"
PROC_SCAN_INTERVAL="${PROC_SCAN_INTERVAL:-3}" # /proc scan runs every 3s max

# ─── State ────────────────────────────────────────────────────────────────────
_GAME_LATCH_UNTIL=0
_CONFIRMED_GAME_PKG=""          # last confirmed game package name
_LAST_PROC_SCAN=0               # epoch of last /proc scan
_LAST_PKG_CACHE_TIME=0
_CACHED_PKG=""

# ─── GPU Load ─────────────────────────────────────────────────────────────────
get_gpu_load() {
    local load

    # 1. Standard kgsl Adreno
    load=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print int($1)}')
    [ -n "$load" ] && echo "$load" && return

    # 2. Universal GPU busy kernel node
    load=$(cat /sys/kernel/gpu/gpu_busy 2>/dev/null | tr -d '% ')
    [ -n "$load" ] && echo "$load" && return

    # 3. Devfreq (Mali, older Adreno, custom kernels without kgsl)
    for devfreq_load in /sys/class/devfreq/1c00000.qcom,kgsl-3d0/load \
                        /sys/class/kgsl/kgsl-3d0/devfreq/load \
                        /sys/class/devfreq/gpufreq/load \
                        /sys/devices/platform/g3d/devfreq/g3d/load; do
        if [ -f "$devfreq_load" ]; then
            load=$(cat "$devfreq_load" 2>/dev/null | cut -d@ -f1 | tr -d ' ' | awk '{print int($1)}')
            [ -n "$load" ] && echo "$load" && return
        fi
    done

    echo "0"
}

# ─── Package Name Matching ────────────────────────────────────────────────────
is_known_game_package() {
    local pkg="$1"
    [ -z "$pkg" ] && echo "false" && return

    # User-defined list (highest priority)
    if [ -f "$GAME_LIST_FILE" ]; then
        while IFS= read -r line; do
            case "$line" in \#*|"") continue ;; esac
            case "$pkg" in *"$line"*) echo "true" && return ;; esac
        done < "$GAME_LIST_FILE"
    fi

    case "$pkg" in
        # ── Call of Duty Mobile (all variants + short tokens) ──────────────
        com.activision.callofduty.shooter) echo "true" && return ;;
        com.activision.callofduty.*)       echo "true" && return ;;
        com.activision.*)                  echo "true" && return ;;
        *callofduty*|*codmobile*|*codm*)   echo "true" && return ;;

        # ── HoYoverse ───────────────────────────────────────────────────────
        com.miHoYo.*|com.HoYoverse.*)     echo "true" && return ;;
        *genshin*|*honkai*|*starrail*)     echo "true" && return ;;

        # ── Tencent ─────────────────────────────────────────────────────────
        com.tencent.ig|com.tencent.tmgp.*) echo "true" && return ;;
        com.tencent.*)                      echo "true" && return ;;

        # ── PUBG ────────────────────────────────────────────────────────────
        com.krafton.*|com.pubg.*)           echo "true" && return ;;

        # ── EA / Epic / Supercell / Garena ──────────────────────────────────
        com.ea.*|com.epicgames.*|com.supercell.*|com.garena.*) echo "true" && return ;;

        # ── NetEase / Mojang / Roblox / Gameloft / Riot ─────────────────────
        com.netease.*|com.mojang.*|com.roblox.*|com.gameloft.*|com.riot.*) echo "true" && return ;;

        # ── Bandai / Square / Sega / YoStar / Level Infinite / Kuro ─────────
        com.bandainamcoent.*|com.square_enix.*|com.sega.*) echo "true" && return ;;
        com.YoStarEN.*|com.YoStarJP.*|com.levelinfinite.*|com.kuro.*) echo "true" && return ;;

        # ── Other known studios ──────────────────────────────────────────────
        com.madfingergames.*|com.kabam.*|com.dena.*|com.ludia.*) echo "true" && return ;;

        # ── Generic heuristic ────────────────────────────────────────────────
        *.game|*.games|*gaming*) echo "maybe" && return ;;
    esac

    echo "false"
}

# ══════════════════════════════════════════════════════════════════════════════
# LAYER 1: /proc oom_score_adj scan — PRIMARY METHOD
# Reads /proc/*/oom_score_adj for value = 0 (foreground guarantee from kernel)
# Then reads /proc/*/cmdline to get actual package name
# Fastest when game is clearly foreground (normal gameplay)
# ══════════════════════════════════════════════════════════════════════════════
_scan_oom_for_game() {
    log_debug "Detector: Starting Layer 1 (oom_score_adj) scan..."
    local found_count=0
    for oom_path in /proc/[0-9]*/oom_score_adj; do
        # Read oom_score_adj — skip if not 0 (not foreground)
        local oom_val
        oom_val=$(cat "$oom_path" 2>/dev/null) || continue
        [ "$oom_val" = "0" ] || continue

        # Get pid from path
        local pid="${oom_path%/oom_score_adj}"
        pid="${pid##*/proc/}"

        # Read cmdline (package name is first null-delimited token)
        # Fallback to status Name: field if cmdline is restricted (e.g., KernelSU isolation)
        local cmdline_path="/proc/$pid/cmdline"
        local pkg=""
        if [ -f "$cmdline_path" ]; then
            pkg=$(cat "$cmdline_path" 2>/dev/null | tr '\0' '\n' | head -1)
        fi

        if [ -z "$pkg" ] && [ -f "/proc/$pid/status" ]; then
            pkg=$(grep "^Name:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        fi

        [ -z "$pkg" ] && continue

        # Skip kernel threads, zygote, system processes
        case "$pkg" in
            zygote*|system_server|/system/*|/apex/*|com.android.phone) continue ;;
            android.*|*:*) continue ;;   # skip process forks (com.pkg:service)
        esac

        # Skip if it's a system UI / launcher
        case "$pkg" in
            com.android.systemui|com.android.launcher*|*.launcher*) continue ;;
            com.google.android.apps.nexuslauncher) continue ;;
        esac

        found_count=$((found_count + 1))

        # Match against game list
        local result
        result=$(is_known_game_package "$pkg")
        if [ "$result" = "true" ]; then
            log_debug "Layer1(oom): foreground game=$pkg pid=$pid"
            _CONFIRMED_GAME_PKG="$pkg"
            _LAST_DETECTION_RESULT="true"
            return
        fi

        # Log what we actually found (helps debug future games not in list)
        log_debug "Layer1(oom): foreground pkg=$pkg (not a known game)"
    done
    log_debug "Detector: Layer 1 finished. Checked $found_count foreground processes, no game found."
    _LAST_DETECTION_RESULT="false"
}

# ══════════════════════════════════════════════════════════════════════════════
# LAYER 2: RenderThread scan across ALL app processes
# Doesn't need to know which app is foreground — just detects if ANY
# app process has an active RenderThread (= actively rendering frames)
# Combined with GPU load, this is a reliable game-running signal.
# Works during: loading screens, cutscenes, Recents transitions.
# ══════════════════════════════════════════════════════════════════════════════
_scan_renderthreads_for_game() {
    local gpu_load
    gpu_load=$(get_gpu_load)

    # Layer 2 only useful when GPU is actually active
    if [ "$gpu_load" -lt "$GPU_GAMING_THRESHOLD" ]; then
        log_debug "Detector: Skipping Layer 2. GPU load ${gpu_load}% is below threshold (${GPU_GAMING_THRESHOLD}%)."
        _LAST_DETECTION_RESULT="false"
        return
    fi

    log_debug "Detector: Starting Layer 2 (RenderThread) scan. GPU is ${gpu_load}%."
    local found_count=0

    # Scan all app_process64 / app_process32 processes
    for status_path in /proc/[0-9]*/status; do
        local pid="${status_path%/status}"
        pid="${pid##*/proc/}"

        # Check if it's an Android app (Name contains app_process)
        local proc_name
        proc_name=$(head -1 "$status_path" 2>/dev/null | awk '{print $2}')
        case "$proc_name" in app_process*) ;; *) continue ;; esac

        # Get package name from cmdline
        local pkg
        pkg=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' '\n' | head -1)
        [ -z "$pkg" ] && continue

        # Skip system/service processes
        case "$pkg" in
            zygote*|system_server|com.android.phone|*:*) continue ;;
            com.android.systemui|com.android.launcher*) continue ;;
        esac

        found_count=$((found_count + 1))

        # Check if this process has a RenderThread
        local task_dir="/proc/$pid/task"
        [ -d "$task_dir" ] || continue
        local all_comms
        all_comms=$(cat "$task_dir"/*/comm 2>/dev/null | tr '\n' '|')
        case "$all_comms" in
            *RenderThread*|*GLThread*|*UnityMain*|*mali-*|*GPU*)
                # Has RenderThread + GPU is busy → likely game
                local game_result
                game_result=$(is_known_game_package "$pkg")
                if [ "$game_result" = "true" ] || [ "$game_result" = "maybe" ]; then
                    log_debug "Layer2(render): game=$pkg gpu=${gpu_load}% pid=$pid"
                    _CONFIRMED_GAME_PKG="$pkg"
                    _LAST_DETECTION_RESULT="true"
                    return
                fi
                # Unknown package with RenderThread + high GPU — still flag it
                if [ "$gpu_load" -ge 40 ]; then
                    log_debug "Layer2(render): unknown+highgpu pkg=$pkg gpu=${gpu_load}%"
                    _CONFIRMED_GAME_PKG="$pkg"
                    _LAST_DETECTION_RESULT="true"
                    return
                fi
                ;;
        esac
    done
    log_debug "Detector: Layer 2 finished. Checked $found_count app processes, no game found."
    _LAST_DETECTION_RESULT="false"
}

# ══════════════════════════════════════════════════════════════════════════════
# LAYER 4: dumpsys fallback (only when latch expired and proc scan found nothing)
# Limited to single targeted cmd — NOT the full "dumpsys window windows" dump
# ══════════════════════════════════════════════════════════════════════════════
_dumpsys_fallback() {
    log_debug "Detector: Starting Layer 4 (dumpsys) fallback..."
    local now
    now=$(date +%s)
    local age=$((now - _LAST_PKG_CACHE_TIME))
    [ "$age" -lt "$PKG_CACHE_TTL" ] && [ -n "$_CACHED_PKG" ] && {
        log_debug "Detector: Using cached pkg=$_CACHED_PKG (age=${age}s < ${PKG_CACHE_TTL}s ttl)"
        _LAST_DETECTION_RESULT=$(is_known_game_package "$_CACHED_PKG")
        [ "$_LAST_DETECTION_RESULT" = "maybe" ] && _LAST_DETECTION_RESULT="true"
        return
    }

    # Fastest reliable dumpsys on Android 16: activity activities | topResumedActivity
    # Research shows topResumedActivity/mResumedActivity works on all AOSP A10-16
    local pkg=""
    pkg=$(dumpsys activity activities 2>/dev/null \
          | grep -m1 -E "topResumedActivity|mResumedActivity" \
          | grep -oE "[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_])+" \
          | grep -v "^android$\|ActivityRecord\|token" \
          | head -1)

    # Fallback: cmd activity top (fastest single-activity query)
    [ -z "$pkg" ] && pkg=$(cmd activity top 2>/dev/null \
          | grep -m1 "^  ACTIVITY " \
          | awk '{print $2}' | cut -d'/' -f1)

    if [ -n "$pkg" ]; then
        _CACHED_PKG="$pkg"
        _LAST_PKG_CACHE_TIME="$now"
        log_debug "Layer4(dumpsys): pkg=$pkg"
        _LAST_DETECTION_RESULT=$(is_known_game_package "$pkg")
        [ "$_LAST_DETECTION_RESULT" = "maybe" ] && _LAST_DETECTION_RESULT="true"
        return
    fi
    log_debug "Detector: Layer 4 finished. No game found via dumpsys."
    _LAST_DETECTION_RESULT="false"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════
# Note: Relies on $NOW_TIME global variable from the main loop to avoid forks.
detect_gaming_context() {
    # ── Realtime Check Rate-Limiting (CPU-intensive) ───────────────────────
    # If the latch is active, only verify the game is still running every 5 seconds.
    # If the latch is inactive, check normally based on PROC_SCAN_INTERVAL.
    local scan_interval="$PROC_SCAN_INTERVAL"

    if [ "$NOW_TIME" -lt "$_GAME_LATCH_UNTIL" ]; then
        # Latch is active. Only do real-time verification every 5s.
        scan_interval=5
    fi

    local since_scan=$((NOW_TIME - _LAST_PROC_SCAN))

    if [ "$since_scan" -ge "$scan_interval" ]; then
        _LAST_PROC_SCAN="$NOW_TIME"

        # Layer 1: oom_score_adj (foreground pkg detection)
        _scan_oom_for_game
        if [ "$_LAST_DETECTION_RESULT" = "true" ]; then
            _GAME_LATCH_UNTIL=$((NOW_TIME + GAME_LATCH_SEC))
            _REALTIME_GAMING="true"
            log_info "Gaming confirmed (L1/oom): ${_CONFIRMED_GAME_PKG} latch=${GAME_LATCH_SEC}s"
            return
        fi

        # Layer 2: RenderThread + GPU scan
        _scan_renderthreads_for_game
        if [ "$_LAST_DETECTION_RESULT" = "true" ]; then
            _GAME_LATCH_UNTIL=$((NOW_TIME + GAME_LATCH_SEC))
            _REALTIME_GAMING="true"
            log_info "Gaming confirmed (L2/render+gpu): ${_CONFIRMED_GAME_PKG} latch=${GAME_LATCH_SEC}s"
            return
        fi

        # If we got here during a scan, real-time gaming is definitely false.
        _REALTIME_GAMING="false"
    fi

    # ── Latch check (Layer 3) ──────────────────────────────────────────────
    # If we didn't scan this tick, or if the scan failed but the latch is still alive:
    if [ "$NOW_TIME" -lt "$_GAME_LATCH_UNTIL" ]; then
        local remaining=$((_GAME_LATCH_UNTIL - NOW_TIME))
        log_debug "Latch active: ${remaining}s remaining (${_CONFIRMED_GAME_PKG})"
        _LAST_DETECTION_RESULT="true"
        return
    fi

    # Layer 4: dumpsys fallback (infrequent, only when latch expired)
    _dumpsys_fallback
    if [ "$_LAST_DETECTION_RESULT" = "true" ]; then
        _GAME_LATCH_UNTIL=$((NOW_TIME + GAME_LATCH_SEC))
        _REALTIME_GAMING="true"
        log_info "Gaming confirmed (L4/dumpsys): ${_CACHED_PKG} latch=${GAME_LATCH_SEC}s"
        return
    fi

    log_debug "No game detected"
    _LAST_DETECTION_RESULT="false"
    _REALTIME_GAMING="false"
}
