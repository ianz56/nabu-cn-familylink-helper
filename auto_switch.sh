#!/system/bin/sh
# Nabu Global Auto-Switch & Display Helper — Auto Switch Daemon
# =============================================================
# Background daemon that monitors screen state and foreground user
# changes. It aggressively re-applies a 60Hz refresh-rate lock for
# all users/current foreground user, and when the screen is off on a
# secondary user it waits for a configurable timeout and then auto-
# switches back to user 0.
# Combined with 'am set-stop-user-on-switch true', this effectively
# kills the secondary user automatically.
#
# This saves battery + RAM when you forget to switch back to your
# primary user before locking the screen.

MODDIR="${0%/*}"
LOGFILE="$MODDIR/auto_switch.log"

# ── Configuration ──────────────────────────────────────────────────
# Refresh rate to enforce.
REFRESH_RATE=60

# Native panel mode for Xiaomi Pad 5 / nabu.
# Used only as a best-effort display-service poke. If unsupported by
# the ROM, the command fails silently and settings-based locking remains.
DISPLAY_WIDTH=1600
DISPLAY_HEIGHT=2560

# Timeout in seconds before auto-switch (default: 10 minutes = 600s)
# You can change this value to suit your preference.
TIMEOUT=600

# How often to check screen state / active user (in seconds)
POLL_INTERVAL=5

# Re-apply the refresh lock periodically while the daemon is alive.
# This helps when MIUI/HyperOS rewrites refresh-rate state after user switch.
REFRESH_REAPPLY_INTERVAL=30
# ───────────────────────────────────────────────────────────────────

log() {
  # Keep log file from growing too large (max ~50KB)
  if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE" 2>/dev/null)" -gt 51200 ]; then
    tail -n 100 "$LOGFILE" > "$LOGFILE.tmp"
    mv "$LOGFILE.tmp" "$LOGFILE"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOGFILE"
}

get_screen_state() {
  # Returns: Awake, Asleep, or Dozing
  dumpsys power 2>/dev/null | grep 'mWakefulness=' | head -1 | sed 's/.*mWakefulness=//'
}

get_current_user() {
  am get-current-user 2>/dev/null
}

poke_display_mode() {
  # Best effort: ask Android DisplayManager to prefer the 60Hz native mode.
  # Not all ROMs expose this shell command, so failure is intentionally silent.
  if cmd display set-user-preferred-display-mode "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT" "$REFRESH_RATE" >/dev/null 2>&1; then
    log "Display mode preference poked (${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${REFRESH_RATE})"
  fi
  # Directly force SurfaceFlinger Hardware Display Mode to Mode 1 (60Hz)
  service call SurfaceFlinger 1035 i32 1 >/dev/null 2>&1
}

apply_global_refresh_lock() {
  # Some display state is cached globally by the framework/vendor service,
  # so write global keys too. Unknown keys are harmless on ROMs that ignore them.
  settings put global peak_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings put global min_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings put global user_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  settings put global miui_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1

  poke_display_mode
}

apply_refresh_lock() {
  USER_ID="$1"

  [ -z "$USER_ID" ] && return 1

  # AOSP-ish keys
  settings --user "$USER_ID" put system peak_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings --user "$USER_ID" put system min_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings --user "$USER_ID" put system user_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1

  # MIUI/HyperOS-ish keys
  settings --user "$USER_ID" put system miui_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  settings --user "$USER_ID" put secure user_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1

  apply_global_refresh_lock

  PEAK_RATE=$(settings --user "$USER_ID" get system peak_refresh_rate 2>/dev/null)
  MIN_RATE=$(settings --user "$USER_ID" get system min_refresh_rate 2>/dev/null)
  USER_RATE=$(settings --user "$USER_ID" get system user_refresh_rate 2>/dev/null)
  MIUI_RATE=$(settings --user "$USER_ID" get system miui_refresh_rate 2>/dev/null)
  SECURE_USER_RATE=$(settings --user "$USER_ID" get secure user_refresh_rate 2>/dev/null)
  GLOBAL_PEAK=$(settings get global peak_refresh_rate 2>/dev/null)

  log "Refresh lock applied for user $USER_ID (peak=$PEAK_RATE, min=$MIN_RATE, user=$USER_RATE, miui=$MIUI_RATE, secure_user=$SECURE_USER_RATE, global_peak=$GLOBAL_PEAK)"
}

apply_refresh_all_users() {
  log "Applying refresh lock for all users..."

  pm list users 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *UserInfo*) ;;
      *) continue ;;
    esac

    USER_ID=$(echo "$line" | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p')
    [ -n "$USER_ID" ] && apply_refresh_lock "$USER_ID"
  done
}

# ── Adaptive Thermal Throttling for Second Space ──────────────────
# Discovers thermal sensor dynamically (quiet_therm -> cpu_therm -> battery)
# Captures runtime stock frequencies as baseline (never hardcoded)
# Controls CPU scaling_max_freq and GPU max_gpuclk with hysteresis.

CPU_P0_MAX="/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
CPU_P4_MAX="/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
CPU_P7_MAX="/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq"
GPU_MAX_CLK="/sys/class/kgsl/kgsl-3d0/max_gpuclk"
BASELINE_FILE="/data/local/tmp/nabu_thermal_baseline.conf"

THERMAL_ZONE_PATH=""
THERMAL_ZONE_TYPE=""

find_thermal_sensor() {
  local cand
  for cand in quiet_therm cpu_therm battery xo_therm; do
    for tz in /sys/class/thermal/thermal_zone*; do
      if [ -f "$tz/type" ] && [ "$(cat "$tz/type" 2>/dev/null)" = "$cand" ]; then
        THERMAL_ZONE_PATH="$tz"
        THERMAL_ZONE_TYPE="$cand"
        log "Thermal sensor resolved: $tz ($cand)"
        return 0
      fi
    done
  done

  # Fallback to thermal_zone0 if none matched
  if [ -d /sys/class/thermal/thermal_zone0 ]; then
    THERMAL_ZONE_PATH="/sys/class/thermal/thermal_zone0"
    THERMAL_ZONE_TYPE="$(cat /sys/class/thermal/thermal_zone0/type 2>/dev/null)"
    log "Thermal sensor fallback: $THERMAL_ZONE_PATH ($THERMAL_ZONE_TYPE)"
    return 0
  fi

  log "WARNING: No thermal sensor found!"
  return 1
}

# Baseline variables captured once per daemon startup
BASE_P0=""
BASE_P4=""
BASE_P7=""
BASE_GPU=""
CURRENT_TIER=0

capture_baseline_frequencies() {
  # Always capture fresh runtime limits directly from sysfs on startup (never reuse previous boot state)
  [ -f "$CPU_P0_MAX" ] && BASE_P0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  [ -f "$CPU_P4_MAX" ] && BASE_P4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  [ -f "$CPU_P7_MAX" ] && BASE_P7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  [ -f "$GPU_MAX_CLK" ] && BASE_GPU=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  # Fallback to cpuinfo_max_freq only if scaling_max_freq was completely empty
  [ -z "$BASE_P0" ] && [ -f "/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq" ] && BASE_P0=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)
  [ -z "$BASE_P4" ] && [ -f "/sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq" ] && BASE_P4=$(cat /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq 2>/dev/null)
  [ -z "$BASE_P7" ] && [ -f "/sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq" ] && BASE_P7=$(cat /sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq 2>/dev/null)

  if [ -n "$BASE_P0" ] && [ -n "$BASE_P4" ] && [ -n "$BASE_P7" ]; then
    cat <<EOF > "$BASELINE_FILE"
BASE_P0="$BASE_P0"
BASE_P4="$BASE_P4"
BASE_P7="$BASE_P7"
BASE_GPU="$BASE_GPU"
EOF
    log "Runtime baseline captured & saved for current boot: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU"
  else
    log "ERROR: Failed to capture complete frequency baseline!"
  fi
}

clamp_limit() {
  local target="$1"
  local base="$2"
  # Never allow target to exceed baseline
  if [ -n "$base" ] && [ "$base" -gt 0 ] && [ "$target" -gt "$base" ]; then
    echo "$base"
  else
    echo "$target"
  fi
}

restore_baseline_frequencies() {
  if [ -z "$BASE_P0" ] || [ -z "$BASE_P4" ] || [ -z "$BASE_P7" ]; then
    capture_baseline_frequencies
  fi

  local cur_p0 cur_p4 cur_p7 cur_gpu modified=0
  cur_p0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  cur_p4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  cur_p7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  [ -f "$GPU_MAX_CLK" ] && cur_gpu=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  if [ "$cur_p0" != "$BASE_P0" ] && [ -n "$BASE_P0" ]; then
    echo "$BASE_P0" > "$CPU_P0_MAX" 2>/dev/null
    modified=1
  fi
  if [ "$cur_p4" != "$BASE_P4" ] && [ -n "$BASE_P4" ]; then
    echo "$BASE_P4" > "$CPU_P4_MAX" 2>/dev/null
    modified=1
  fi
  if [ "$cur_p7" != "$BASE_P7" ] && [ -n "$BASE_P7" ]; then
    echo "$BASE_P7" > "$CPU_P7_MAX" 2>/dev/null
    modified=1
  fi
  if [ -f "$GPU_MAX_CLK" ] && [ "$cur_gpu" != "$BASE_GPU" ] && [ -n "$BASE_GPU" ]; then
    echo "$BASE_GPU" > "$GPU_MAX_CLK" 2>/dev/null
    modified=1
  fi

  if [ "$modified" -eq 1 ] || [ "$CURRENT_TIER" -ne 0 ]; then
    log "Restored frequencies to runtime baseline (P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU)"
  fi
  CURRENT_TIER=0
}

# Determine tier with hysteresis:
# Tier 0: Normal (<=35°C)
# Tier 1: Mild (>=36°C)
# Tier 2: Moderate (>=38°C)
# Tier 3: Aggressive (>=40°C)
# Tier 4: Strict (>=42°C)
# Hysteresis recovery margin: 1°C (1000 m°C)
determine_target_tier() {
  local temp="$1"
  local cur="$CURRENT_TIER"
  local target="$cur"

  case "$cur" in
    0)
      if [ "$temp" -ge 42000 ]; then target=4
      elif [ "$temp" -ge 40000 ]; then target=3
      elif [ "$temp" -ge 38000 ]; then target=2
      elif [ "$temp" -ge 36000 ]; then target=1
      fi
      ;;
    1)
      if [ "$temp" -ge 42000 ]; then target=4
      elif [ "$temp" -ge 40000 ]; then target=3
      elif [ "$temp" -ge 38000 ]; then target=2
      elif [ "$temp" -lt 35000 ]; then target=0
      fi
      ;;
    2)
      if [ "$temp" -ge 42000 ]; then target=4
      elif [ "$temp" -ge 40000 ]; then target=3
      elif [ "$temp" -lt 37000 ]; then target=1
      fi
      ;;
    3)
      if [ "$temp" -ge 42000 ]; then target=4
      elif [ "$temp" -lt 39000 ]; then target=2
      fi
      ;;
    4)
      if [ "$temp" -lt 41000 ]; then target=3
      fi
      ;;
    *)
      target=0
      ;;
  esac
  echo "$target"
}

apply_second_space_thermal() {
  [ -z "$THERMAL_ZONE_PATH" ] && return 0

  local raw_temp
  raw_temp=$(cat "$THERMAL_ZONE_PATH/temp" 2>/dev/null)
  [ -z "$raw_temp" ] && return 0

  local target_tier
  target_tier=$(determine_target_tier "$raw_temp")

  if [ "$target_tier" -eq 0 ]; then
    if [ "$CURRENT_TIER" -ne 0 ]; then
      restore_baseline_frequencies
    fi
    return 0
  fi

  local target_p0 target_p4 target_p7 target_gpu
  case "$target_tier" in
    1)
      # Mild: shave off excessive turbo boost
      target_p0="$BASE_P0"
      target_p4=2131200
      target_p7=2131200
      target_gpu=585000000
      ;;
    2)
      # Moderate: stable thermal balance
      target_p0=1632000
      target_p4=1920000
      target_p7=1920000
      target_gpu=499200000
      ;;
    3)
      # Aggressive: actively arrest thermal rise
      target_p0=1478400
      target_p4=1612800
      target_p7=1612800
      target_gpu=427000000
      ;;
    4)
      # Strict: prevent extreme heat while maintaining operability
      target_p0=1382400
      target_p4=1401600
      target_p7=1401600
      target_gpu=345000000
      ;;
  esac

  # Ensure targets do not exceed baseline
  target_p0=$(clamp_limit "$target_p0" "$BASE_P0")
  target_p4=$(clamp_limit "$target_p4" "$BASE_P4")
  target_p7=$(clamp_limit "$target_p7" "$BASE_P7")
  [ -n "$BASE_GPU" ] && target_gpu=$(clamp_limit "$target_gpu" "$BASE_GPU")

  # Apply limits if currently different (or re-enforce if vendor overwritten)
  local cur_p0 cur_p4 cur_p7 cur_gpu changed=0
  cur_p0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  cur_p4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  cur_p7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  [ -f "$GPU_MAX_CLK" ] && cur_gpu=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  if [ "$cur_p0" != "$target_p0" ] && [ -n "$target_p0" ]; then
    echo "$target_p0" > "$CPU_P0_MAX" 2>/dev/null
    changed=1
  fi
  if [ "$cur_p4" != "$target_p4" ] && [ -n "$target_p4" ]; then
    echo "$target_p4" > "$CPU_P4_MAX" 2>/dev/null
    changed=1
  fi
  if [ "$cur_p7" != "$target_p7" ] && [ -n "$target_p7" ]; then
    echo "$target_p7" > "$CPU_P7_MAX" 2>/dev/null
    changed=1
  fi
  if [ -f "$GPU_MAX_CLK" ] && [ "$cur_gpu" != "$target_gpu" ] && [ -n "$target_gpu" ]; then
    echo "$target_gpu" > "$GPU_MAX_CLK" 2>/dev/null
    changed=1
  fi

  if [ "$target_tier" != "$CURRENT_TIER" ] || [ "$changed" -eq 1 ]; then
    local temp_c=$((raw_temp / 1000))
    log "Second Space Thermal (Tier $target_tier, Temp=${temp_c}°C): P0=$target_p0, P4=$target_p4, P7=$target_p7, GPU=$target_gpu"
  fi

  CURRENT_TIER="$target_tier"
}

log "Auto-switch daemon started (refresh=${REFRESH_RATE}Hz, timeout=${TIMEOUT}s, poll=${POLL_INTERVAL}s, reapply=${REFRESH_REAPPLY_INTERVAL}s)"

# Initialize hardware baselines and thermal sensor
find_thermal_sensor
capture_baseline_frequencies

# Initial pass: lock every user once after boot/module start.
apply_refresh_all_users

# Track when the screen turned off while on a secondary user
SCREEN_OFF_TIMESTAMP=0
LAST_USER=""
LAST_REFRESH_APPLY=$(date +%s)

while true; do
  SCREEN_STATE=$(get_screen_state)
  CURRENT_USER=$(get_current_user)
  NOW=$(date +%s)

  # Skip if we can't determine state
  if [ -z "$SCREEN_STATE" ] || [ -z "$CURRENT_USER" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [ "$CURRENT_USER" != "$LAST_USER" ]; then
    log "Foreground user changed to $CURRENT_USER — enforcing ${REFRESH_RATE}Hz lock"
    apply_refresh_lock "$CURRENT_USER"

    # If switched back to Main Space (user 0), immediately restore baseline frequencies
    if [ "$CURRENT_USER" = "0" ]; then
      restore_baseline_frequencies
    fi

    LAST_USER="$CURRENT_USER"
    LAST_REFRESH_APPLY="$NOW"
    SCREEN_OFF_TIMESTAMP=0
  else
    if [ $((NOW - LAST_REFRESH_APPLY)) -ge "$REFRESH_REAPPLY_INTERVAL" ]; then
      log "Periodic refresh rate re-apply for user $CURRENT_USER"
      apply_refresh_lock "$CURRENT_USER"
      LAST_REFRESH_APPLY="$NOW"
    fi
  fi

  # ── Thermal Management ──
  # Active ONLY in Second Space (user != 0). Main Space remains 100% on baseline.
  if [ "$CURRENT_USER" != "0" ]; then
    apply_second_space_thermal
  else
    if [ "$CURRENT_TIER" -ne 0 ]; then
      restore_baseline_frequencies
    fi
  fi

  if [ "$SCREEN_STATE" = "Asleep" ] || [ "$SCREEN_STATE" = "Dozing" ]; then
    # ── Screen is OFF ──
    if [ "$CURRENT_USER" != "0" ]; then
      if [ "$SCREEN_OFF_TIMESTAMP" -eq 0 ]; then
        # Just detected screen off on secondary user — start timer
        SCREEN_OFF_TIMESTAMP=$NOW
        log "Screen off on user $CURRENT_USER — timer started (${TIMEOUT}s)"
      fi

      ELAPSED=$((NOW - SCREEN_OFF_TIMESTAMP))

      if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        log "Timeout reached (${ELAPSED}s) — switching to user 0..."
        # Restore stock frequencies before switching
        restore_baseline_frequencies

        SWITCH_RESULT=$(am switch-user 0 2>&1)
        log "am switch-user 0 → $SWITCH_RESULT"

        # Wait a moment then verify
        sleep 5
        NEW_USER=$(get_current_user)
        log "Current user is now: $NEW_USER"
        if [ "$NEW_USER" = "0" ]; then
          apply_refresh_lock "$NEW_USER"
          restore_baseline_frequencies
          LAST_USER="$NEW_USER"
          LAST_REFRESH_APPLY=$(date +%s)
        fi

        # Reset timer
        SCREEN_OFF_TIMESTAMP=0
      fi
    else
      # Screen is off but already on user 0 — no action needed
      SCREEN_OFF_TIMESTAMP=0
    fi
  else
    # ── Screen is ON ──
    if [ "$SCREEN_OFF_TIMESTAMP" -ne 0 ]; then
      log "Screen turned on — timer cancelled (was on user $CURRENT_USER)"
      SCREEN_OFF_TIMESTAMP=0
    fi
  fi

  sleep "$POLL_INTERVAL"
done
