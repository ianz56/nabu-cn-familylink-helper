#!/system/bin/sh
# Kill Users on Switch — Action Button
# ======================================
# This script runs when you tap the "Action" button in Magisk Manager.
# It re-enables stop-on-switch, aggressively re-applies the 60Hz lock,
# then stops all users except the primary user (user 0).

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Nabu Global Auto-Switch & Display"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

REFRESH_RATE=60
DISPLAY_WIDTH=1600
DISPLAY_HEIGHT=2560
CURRENT_USER=$(am get-current-user 2>/dev/null)

poke_display_mode() {
  if cmd display set-user-preferred-display-mode "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT" "$REFRESH_RATE" >/dev/null 2>&1; then
    echo "    -> Display mode preference poked: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}@${REFRESH_RATE}"
  fi
  # SurfaceFlinger setDesiredDisplayModeSpecs override (Mode 1 = 60Hz)
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

  echo "    User $USER_ID -> peak=$(settings --user "$USER_ID" get system peak_refresh_rate 2>/dev/null), min=$(settings --user "$USER_ID" get system min_refresh_rate 2>/dev/null), secure=$(settings --user "$USER_ID" get secure user_refresh_rate 2>/dev/null)"
}

apply_refresh_all_users() {
  pm list users 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *UserInfo*) ;;
      *) continue ;;
    esac

    USER_ID=$(echo "$line" | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p')
    [ -n "$USER_ID" ] && apply_refresh_lock "$USER_ID"
  done
}

# Ensure stop-on-switch is enabled
RESULT=$(am set-stop-user-on-switch true 2>&1)
echo "[*] am set-stop-user-on-switch true"
echo "    -> $RESULT"
echo ""

echo "[*] Lock refresh rate ke ${REFRESH_RATE}Hz untuk semua user"
apply_refresh_all_users
echo ""

# Get list of running user IDs (exclude user 0)
echo "[*] Scanning for running background users..."
echo ""

# Parse 'pm list users' output to find running users
# Format: UserInfo{ID:Name:flags} running
pm list users 2>/dev/null | while IFS= read -r line; do
  # Skip lines that don't contain UserInfo
  case "$line" in
    *UserInfo*) ;;
    *) continue ;;
  esac

  # Extract user ID
  USER_ID=$(echo "$line" | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p')

  # Skip if we couldn't parse the ID or if it's user 0
  [ -z "$USER_ID" ] && continue
  [ "$USER_ID" = "0" ] && continue

  # Check if this user is running
  case "$line" in
    *running*)
      echo "    User $USER_ID is running — stopping..."
      STOP_RESULT=$(am stop-user "$USER_ID" 2>&1)
      echo "    -> $STOP_RESULT"
      ;;
    *)
      echo "    User $USER_ID is already stopped"
      ;;
  esac
done

echo ""
echo "[*] Re-apply refresh lock after stopping users"
if [ -n "$CURRENT_USER" ]; then
  apply_refresh_lock "$CURRENT_USER"
fi
apply_refresh_lock 0
echo ""

# Restore CPU/GPU frequencies to baseline
MODDIR="${0%/*}"
BASELINE_FILE="/data/local/tmp/nabu_thermal_baseline.conf"
[ ! -f "$BASELINE_FILE" ] && [ -f "$MODDIR/thermal_baseline.conf" ] && BASELINE_FILE="$MODDIR/thermal_baseline.conf"

if [ -f "$BASELINE_FILE" ]; then
  . "$BASELINE_FILE"
fi

# Fallback to cpuinfo_max_freq if baseline variables are empty
[ -z "$BASE_P0" ] && [ -f "/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq" ] && BASE_P0=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)
[ -z "$BASE_P4" ] && [ -f "/sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq" ] && BASE_P4=$(cat /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_max_freq 2>/dev/null)
[ -z "$BASE_P7" ] && [ -f "/sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq" ] && BASE_P7=$(cat /sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq 2>/dev/null)
[ -z "$BASE_GPU" ] && BASE_GPU=675000000

echo "[*] Restoring CPU & GPU frequencies to runtime baseline..."
[ -n "$BASE_P0" ] && echo "$BASE_P0" > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
[ -n "$BASE_P4" ] && echo "$BASE_P4" > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null
[ -n "$BASE_P7" ] && echo "$BASE_P7" > /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq 2>/dev/null
[ -n "$BASE_GPU" ] && [ -f "/sys/class/kgsl/kgsl-3d0/max_gpuclk" ] && echo "$BASE_GPU" > /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null
echo "    -> Restored (P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU)"
echo ""

echo "[*] Current user status:"
pm list users 2>/dev/null | while IFS= read -r line; do
  echo "    $line"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
