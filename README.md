# ThermalAI — Intelligent Thermal Management Module

An AI-driven Magisk/KernelSU module that replaces reactive thermal throttling with
predictive, context-aware thermal management — preserving gaming performance while
keeping your device safe.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        ThermalAI Flow                           │
│                                                                 │
│  Sensors ──► History Buffer ──► Trend Analysis (LSQ) ──►       │
│                                                                 │
│  ──► Prediction ──► Confidence Score ──► AI Scoring Matrix ──► │
│                                                                 │
│  ──► Policy Decision ──► Hardware Enforcement                   │
│         (debounced)          CPU/GPU/IO/VM                      │
└─────────────────────────────────────────────────────────────────┘
```

### The 5 Policies

| Policy        | Temp Range | Gaming Behavior                          |
|---------------|-----------|-------------------------------------------|
| performance   | < 45°C    | Full CPU/GPU headroom, fast schedutil     |
| balanced      | 45–55°C   | Normal operation, adaptive GPU governor   |
| conservative  | 55–65°C   | Throttle BG tasks, preserve FG frames    |
| powersave     | 65–72°C   | Cap big/prime cores, reduce GPU levels   |
| emergency_cool| > 72°C    | Maximum throttle, prevent thermal shutdown|

### Key Features

- **Predictive**: Uses linear regression on 10-sample temp history to predict
  temperature 10 seconds ahead — acts *before* throttle kicks in.
- **Gaming-aware**: Detects foreground app package, GPU load, and RenderThread
  presence — auto-biases toward performance and activates Touch/Network tweaks during gameplay.
- **Battery-aware Charging**: Throttles fast charging if the device or battery exceeds safe temperatures to prolong battery lifespan.
- **Self-Calibration**: Learns if your device runs hot and dynamically adjusts thermal thresholds safely down by 2°C over time.
- **Bootloop & Crash Protection**: Safely aborts module startup if a system crash is detected within 2 minutes of boot. Watchdog resets to stock thermal if sensors fail.
- **Suspend Cooling**: Drops CPU and GPU to absolute minimal power states instantly when the screen is turned off.
- **Background isolation**: Pushes non-game processes to little cores via cpuset during gaming conserve/powersave modes.

### Changelog v2.3.0
- Fixed critical charging heating issue by drastically reducing charge current when battery hits 41C.
- Added universal kernel compatibility fallbacks for TCP, CPU, GPU, and Charging across generic Android trees (Mediatek, Exynos, custom Snapdragons).

### Changelog v2.2.0
- Implemented App-Switch Transition Engine with Residual State Cleaner to prevent lag when switching games.
- Added Dynamic Post-Game Cool-Down Profile.
- Added Memory-Pressure & Frame-Stutter Monitoring.
- Built Auto-Blacklist sysfs wrapper to safely ignore failing paths without rebooting.

### Changelog v2.1.0
- Implemented advanced predictive heat forecasting using EMA and thermal inertia.
- Added Dynamic Policy Weighting for context-aware intelligence.
- Session Learning Engine & Per-Game Adaptive Profiles.
- Advanced full state snapshot and restore mechanisms.
- Network and Thermal Comfort awareness added.
- Log file automatically cleared on module install/update.

### Changelog v2.0.0
- Added bootloop protection and thermal sensor watchdog.
- Added self-calibration module to adapt to device cooling capabilities.
- Added battery temperature-aware and SOC-aware smart charging controls.
- Added temporary Touch/Network (BBR TCP) boosts during active gaming.
- Added Suspend policy for screen-off instant cooling.
- Fixed UI overheating by finding WALT "sweet spots" instead of 100% boosts.
- Refactored `thermalair status` CLI for cleaner reporting.
- Improved game detection subshell bug.

---

## Installation

1. Download `ThermalAI.zip`
2. Flash via Magisk Manager / KernelSU Manager
3. Reboot

---

## CLI Usage (via ADB or terminal)

```bash
# View current status and temps
thermalair status

# Watch live logs
thermalair logs 100

# Check if gaming is detected
thermalair gaming

# Force a specific policy
thermalair policy performance

# Stop/start daemon
thermalair stop
thermalair start
```

---

## Configuration

Edit `/data/adb/modules/thermalai/config/profiles.conf` to tune thresholds.
Edit `/data/adb/modules/thermalai/config/game_list.conf` to add your games.

---

## Compatibility

- **Root**: Magisk 24+ or KernelSU
- **Android**: 10–15
- **SoC**: Qualcomm (Snapdragon), MediaTek, Exynos (partial)
- **Arch**: ARM64

---

## Logs

Logs are written to `/data/local/tmp/thermalai.log` and `logcat` (tag: ThermalAI).
Set `THERMALAI_LOG_LEVEL=DEBUG` in `profiles.conf` for verbose output.

---

## Disclaimer

This module replaces the stock thermal engine. While designed to be safe, use at
your own risk. The module automatically restores stock thermal management if removed
via Magisk/KernelSU.
