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

log "Auto-switch daemon started (refresh=${REFRESH_RATE}Hz, timeout=${TIMEOUT}s, poll=${POLL_INTERVAL}s, reapply=${REFRESH_REAPPLY_INTERVAL}s)"

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
        SWITCH_RESULT=$(am switch-user 0 2>&1)
        log "am switch-user 0 → $SWITCH_RESULT"

        # Wait a moment then verify
        sleep 5
        NEW_USER=$(get_current_user)
        log "Current user is now: $NEW_USER"
        if [ "$NEW_USER" = "0" ]; then
          apply_refresh_lock "$NEW_USER"
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
