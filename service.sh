#!/system/bin/sh
# Nabu Global Auto-Switch & Display Helper — Magisk Module
# =========================================================
# This script runs at the 'late_start' service trigger on every boot.
# It waits until the system is fully booted, then enables the
# stop-user-on-switch setting so that background users are automatically
# stopped (killed) whenever you switch to a different user.
#
# Without this module you would have to run the command manually
# after every reboot:
#   am set-stop-user-on-switch true

MODDIR="${0%/*}"
LOGFILE="$MODDIR/service.log"
MAX_LOG_SIZE=65536

rotate_logs() {
  [ ! -f "$LOGFILE" ] && return 0
  local cur_size
  cur_size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$cur_size" -ge "$MAX_LOG_SIZE" ]; then
    [ -f "${LOGFILE}.1" ] && rm -f "${LOGFILE}.1" 2>/dev/null
    mv -f "$LOGFILE" "${LOGFILE}.1" 2>/dev/null || true
    touch "$LOGFILE" 2>/dev/null && chmod 0644 "$LOGFILE" 2>/dev/null || true
  fi
}

log() {
  local level="INFO"
  local msg="$1"
  if [ -n "$2" ]; then
    level="$1"
    msg="$2"
  else
    case "$msg" in
      ERROR*|FAILED*|Failed*) level="ERROR" ;;
      WARN*|WARNING*) level="WARN" ;;
    esac
  fi
  rotate_logs
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" >> "$LOGFILE" 2>/dev/null || true
}

MOD_VER="unknown"
[ -f "$MODDIR/module.prop" ] && MOD_VER=$(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2)

# --- Wait for the system to finish booting ---
# The Activity Manager isn't available until boot completes, so we poll
# the 'sys.boot_completed' property before attempting our command.
log "INFO" "Nabu Global Helper service started (version=$MOD_VER), waiting for boot to complete..."

MAX_WAIT=120   # seconds
WAITED=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
  WAITED=$((WAITED + 2))
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    log "ERROR" "Timed out waiting for boot_completed after ${MAX_WAIT}s"
    exit 1
  fi
done

log "INFO" "Boot completed after ~${WAITED}s — applying settings..."

# --- Apply the setting ---
RESULT=$(am set-stop-user-on-switch true 2>&1)
log "INFO" "am set-stop-user-on-switch true → $RESULT"


# --- Refresh Rate Enforcement (60Hz) helper on boot ---
REFRESH_RATE=60
DISPLAY_WIDTH=1600
DISPLAY_HEIGHT=2560

poke_display_mode() {
  cmd display set-user-preferred-display-mode "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT" "$REFRESH_RATE" >/dev/null 2>&1 || true
  # SurfaceFlinger setDesiredDisplayModeSpecs / setDisplayMode override (Mode 1 = 60Hz on Xiaomi Pad 5)
  service call SurfaceFlinger 1035 i32 1 >/dev/null 2>&1
}

apply_global_refresh_lock() {
  settings put global peak_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings put global min_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings put global user_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  settings put global miui_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  poke_display_mode
}

apply_refresh_lock() {
  USER_ID="$1"
  [ -z "$USER_ID" ] && return 1

  settings --user "$USER_ID" put system peak_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings --user "$USER_ID" put system min_refresh_rate "${REFRESH_RATE}.0" >/dev/null 2>&1
  settings --user "$USER_ID" put system user_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  settings --user "$USER_ID" put system miui_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  settings --user "$USER_ID" put secure user_refresh_rate "$REFRESH_RATE" >/dev/null 2>&1
  apply_global_refresh_lock
}

apply_refresh_all_users() {
  log "Applying refresh lock (${REFRESH_RATE}Hz) for all users..."
  pm list users 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *UserInfo*) ;;
      *) continue ;;
    esac
    USER_ID=$(echo "$line" | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p')
    [ -n "$USER_ID" ] && apply_refresh_lock "$USER_ID"
  done
}

apply_refresh_all_users

# --- Verify ---
# Small delay to let the setting take effect, then log the user list
# so we can confirm everything looks right.
sleep 3
USERS=$(pm list users 2>&1)
log "Current users after setting applied:"
echo "$USERS" | while IFS= read -r line; do
  log "  $line"
done

log "Done ✓"

# --- Start auto-switch daemon ---
# Monitors screen state and auto-switches to user 0
# when screen is off for too long on a secondary user.
if [ -f "$MODDIR/auto_switch.sh" ]; then
  log "Starting auto-switch daemon..."
  sh "$MODDIR/auto_switch.sh" &
  log "Auto-switch daemon launched (PID: $!)"
fi
