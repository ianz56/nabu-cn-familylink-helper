#!/system/bin/sh
# Nabu DerpFest 17 Helper — KernelSU Action Diagnostic Script (v3.2.0)
# ===================================================================
# STRICTLY NON-DESTRUCTIVE DIAGNOSTIC TOOL.
# Displays dynamic multi-user discovery, native switch policy, display telemetry,
# and adaptive thermal hardware status without executing user lifecycle commands.

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Nabu DerpFest 17 Helper v3.2.0 — System Diagnostic"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  [SAFETY POLICY] Action Button operates in DIAGNOSTIC mode only."
echo "  No user lifecycle modifications or hardware sysfs writes are performed."
echo ""

# ── 1. Device & ROM Compatibility ──
echo "── 1. Device & ROM Compatibility ───────────────────────────"
DEVICE=$(getprop ro.product.device 2>/dev/null)
[ -z "$DEVICE" ] && DEVICE=$(getprop ro.build.product 2>/dev/null)
SDK_VER=$(getprop ro.build.version.sdk 2>/dev/null)
ROM_VER=$(getprop ro.derpfest.version 2>/dev/null)
[ -z "$ROM_VER" ] && ROM_VER=$(getprop ro.build.display.id 2>/dev/null)

echo "  Device Codename:  $DEVICE"
echo "  Android SDK:      $SDK_VER"
echo "  DerpFest Version: $ROM_VER"
if [ "$DEVICE" = "nabu" ] || [ "$DEVICE" = "nabu_global" ]; then
  echo "  [✓] Hardware compatible (Xiaomi Pad 5)"
else
  echo "  [!] Hardware warning: unrecognized device '$DEVICE'"
fi
if [ "$SDK_VER" = "37" ]; then
  echo "  [✓] Framework compatible (Android 17 / API 37)"
else
  echo "  [!] Framework warning: SDK level $SDK_VER"
fi
echo ""

# ── 2. Dynamic User Discovery & Eligibility Audit ──
echo "── 2. Dynamic User Discovery & Eligibility Audit ───────────"
echo "  Configured Android Users:"
cmd user list -v 2>/dev/null | awk '
  match($0, /id=([0-9]+)/) {
    uid = substr($0, RSTART+3, RLENGTH-3) + 0
    name = "unknown"
    utype = "unknown"
    if (match($0, /name=([a-zA-Z0-9_-]+)/)) {
      name = substr($0, RSTART+5, RLENGTH-5)
    }
    if (match($0, /type=([a-zA-Z0-9_.]+)/)) {
      utype = substr($0, RSTART+5, RLENGTH-5)
    }
    is_running = ($0 ~ /\(running\)/) ? "RUNNING" : "STOPPED"
    is_current = ($0 ~ /\(current\)/) ? " [FOREGROUND]" : ""

    # Eligibility evaluation
    status = "EXCLUDED"
    if (uid == 0) {
      status = "PROTECTED (Main User)"
    } else if (utype ~ /full\.SECONDARY/ && $0 !~ /SYSTEM/ && $0 !~ /ADMIN/ && $0 !~ /GUEST/) {
      status = "ELIGIBLE (Managed Secondary)"
    } else if (utype ~ /profile/) {
      status = "EXCLUDED (Profile)"
    } else if (utype ~ /GUEST/) {
      status = "EXCLUDED (Guest)"
    }

    printf("  - User %d: name=%s, type=%s, state=%s%s\n    -> Classification: %s\n", uid, name, utype, is_running, is_current, status)
  }
'
echo ""

# ── 3. Native Stop-On-Switch Policy ──
echo "── 3. Native Stop-On-Switch Policy ─────────────────────────"
STOP_ON_SWITCH_STATE=$(dumpsys activity users 2>/dev/null | grep -i "mStopUserOnSwitch" | head -n 1 | tr -d '[:space:]')
STOP_ON_SWITCH_EN=$(dumpsys activity users 2>/dev/null | grep -i "isStopUserOnSwitchEnabled" | head -n 1 | tr -d '[:space:]')
echo "  mStopUserOnSwitch:         $STOP_ON_SWITCH_STATE"
echo "  isStopUserOnSwitchEnabled: $STOP_ON_SWITCH_EN"
echo ""

# ── 4. Display & Backlight Telemetry ──
echo "── 4. Display & Backlight Telemetry ────────────────────────"
BL_VAL=$(cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || echo "N/A")
WAKE_STATE=$(dumpsys power 2>/dev/null | grep -m1 "mWakefulness=" | tr -d '[:space:]' | cut -d'=' -f2)
SF_STATE=$(dumpsys SurfaceFlinger 2>/dev/null | awk '/Display [0-9]+ \(built-in\):/ {
  while (getline line) {
    if (line ~ /powerMode:/) {
      if (line ~ /powerMode: OFF|powerMode: 0/) { print "OFF"; exit }
      else { print "ON"; exit }
    }
  }
}')

echo "  Backlight Brightness:    $BL_VAL"
echo "  Power Wakefulness:       ${WAKE_STATE:-UNKNOWN}"
echo "  Internal Display State:  ${SF_STATE:-UNKNOWN}"

if [ "$BL_VAL" = "0" ] && [ "$SF_STATE" = "OFF" ] && { [ "$WAKE_STATE" = "Asleep" ] || [ "$WAKE_STATE" = "Dozing" ]; }; then
  echo "  [✓] Multi-signal display evaluation: CONFIRMED OFF"
else
  echo "  [!] Multi-signal display evaluation: ACTIVE / ON"
fi
echo ""

# ── 5. Adaptive Thermal Status & Hardware Mapping ──
echo "── 5. Adaptive Thermal Status & Hardware Mapping ───────────"
MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/nabu-derpfest-helper"
BASELINE_FILE="$MODDIR/state/thermal_baseline.conf"

BASE_P0="N/A"
BASE_P4="N/A"
BASE_P7="N/A"
BASE_GPU="N/A"
[ -f "$BASELINE_FILE" ] && . "$BASELINE_FILE"

CUR_P0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo "N/A")
CUR_P4=$(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null || echo "N/A")
CUR_P7=$(cat /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq 2>/dev/null || echo "N/A")
CUR_GPU=$(cat /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null || echo "N/A")

# Identify active thermal sensor
TZ_PATH=""
TZ_TYPE=""
TZ_TEMP="N/A"
for cand in quiet_therm cpu_therm battery xo_therm; do
  for tz in /sys/class/thermal/thermal_zone*; do
    if [ -f "$tz/type" ] && [ "$(cat "$tz/type" 2>/dev/null)" = "$cand" ]; then
      TZ_PATH="$tz"
      TZ_TYPE="$cand"
      raw_t=$(cat "$tz/temp" 2>/dev/null)
      if [ -n "$raw_t" ]; then
        TZ_TEMP="$((raw_t / 1000))°C ($raw_t m°C)"
      fi
      break 2
    fi
  done
done

echo "  Resolved Thermal Sensor: ${TZ_PATH:-None} (${TZ_TYPE:-None})"
echo "  Current Temperature:     $TZ_TEMP"
echo ""
echo "  Frequency Mapping vs Baseline:"
echo "  - CPU Cluster 0 (Silver, CPUs 0-3): cur=${CUR_P0}kHz, base=${BASE_P0}kHz"
echo "  - CPU Cluster 1 (Gold, CPUs 4-6):   cur=${CUR_P4}kHz, base=${BASE_P4}kHz"
echo "  - CPU Cluster 2 (Prime, CPU 7):     cur=${CUR_P7}kHz, base=${BASE_P7}kHz"
echo "  - Adreno 640 GPU:                   cur=${CUR_GPU}Hz, base=${BASE_GPU}Hz"
echo ""

# ── 6. Daemon Status & Recent Activity ──
echo "── 6. Daemon Status & Recent Activity ──────────────────────"
PID_FILE="$MODDIR/auto_switch.pid"
LOG_FILE="$MODDIR/auto_switch.log"

DAEMON_STATUS="INACTIVE"
DAEMON_PID=""
if [ -f "$PID_FILE" ]; then
  DAEMON_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$DAEMON_PID" ] && [ -d "/proc/$DAEMON_PID" ]; then
    DAEMON_STATUS="ACTIVE (PID: $DAEMON_PID)"
  fi
fi

UPTIME_VAL=$(cat /proc/uptime 2>/dev/null | cut -d'.' -f1 || echo "0")
echo "  Daemon Status:   $DAEMON_STATUS"
echo "  Kernel BOOTTIME: ${UPTIME_VAL}s"
echo ""
echo "  Recent Activity (Last 5 Log Entries):"
if [ -f "$LOG_FILE" ]; then
  tail -n 5 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "  $line"
  done
else
  echo "  (No log file found)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Diagnostic Complete."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
