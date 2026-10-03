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

enforce_supervision_permissions() {
  echo "[*] Whitelisting Family Link & Supervision from Doze/Battery saver..."
  dumpsys deviceidle whitelist +com.google.android.gms.supervision >/dev/null 2>&1
  dumpsys deviceidle whitelist +com.google.android.apps.kids.familylinkhelper >/dev/null 2>&1
  dumpsys deviceidle whitelist +com.google.android.gms >/dev/null 2>&1
  dumpsys deviceidle whitelist +com.google.android.apps.wellbeing >/dev/null 2>&1

  echo "[*] Granting Overlay & UsageStats AppOps for all users..."
  pm list users 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *UserInfo*) ;;
      *) continue ;;
    esac
    UID_NUM=$(echo "$line" | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p')
    [ -z "$UID_NUM" ] && continue

    pm grant --user "$UID_NUM" com.google.android.gms.supervision android.permission.PACKAGE_USAGE_STATS >/dev/null 2>&1
    pm grant --user "$UID_NUM" com.google.android.gms.supervision android.permission.SYSTEM_ALERT_WINDOW >/dev/null 2>&1
    pm grant --user "$UID_NUM" com.google.android.gms.supervision android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
    pm grant --user "$UID_NUM" com.google.android.apps.kids.familylinkhelper android.permission.SYSTEM_ALERT_WINDOW >/dev/null 2>&1
    pm grant --user "$UID_NUM" com.google.android.apps.kids.familylinkhelper android.permission.POST_NOTIFICATIONS >/dev/null 2>&1

    appops set --user "$UID_NUM" com.google.android.gms.supervision SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
    appops set --user "$UID_NUM" com.google.android.gms.supervision GET_USAGE_STATS allow >/dev/null 2>&1
    appops set --user "$UID_NUM" com.google.android.gms.supervision SCHEDULE_EXACT_ALARM allow >/dev/null 2>&1
    appops set --user "$UID_NUM" com.google.android.gms.supervision AUTO_REVOKE_PERMISSIONS_IF_UNUSED ignore >/dev/null 2>&1

    appops set --user "$UID_NUM" com.google.android.apps.kids.familylinkhelper SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
    appops set --user "$UID_NUM" com.google.android.apps.kids.familylinkhelper GET_USAGE_STATS allow >/dev/null 2>&1
    appops set --user "$UID_NUM" com.google.android.apps.kids.familylinkhelper AUTO_REVOKE_PERMISSIONS_IF_UNUSED ignore >/dev/null 2>&1

    for op in 10007 10008 10020 10021 10022 10023 10033; do
      appops set --user "$UID_NUM" com.google.android.gms.supervision "$op" allow >/dev/null 2>&1
      appops set --user "$UID_NUM" com.google.android.apps.kids.familylinkhelper "$op" allow >/dev/null 2>&1
    done
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

enforce_supervision_permissions
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

echo "[*] Current user status:"
pm list users 2>/dev/null | while IFS= read -r line; do
  echo "    $line"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
