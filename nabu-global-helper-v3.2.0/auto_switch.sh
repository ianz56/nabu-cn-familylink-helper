#!/system/bin/sh
# Nabu DerpFest 17 Helper — Dynamic Multi-User & Adaptive Thermal Daemon (v3.2.0)
# ==============================================================================
# Dynamic multi-user lifecycle management with fail-closed eligibility validation,
# native stop-on-switch synergy, and Adaptive Thermal Tier 0-4 with hysteresis.

set -u

MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/nabu-derpfest-helper"

LOG_FILE="$MODDIR/auto_switch.log"
PID_FILE="$MODDIR/auto_switch.pid"
STATE_DIR="$MODDIR/state"
BASELINE_FILE="$STATE_DIR/thermal_baseline.conf"
OWNERSHIP_FILE="$STATE_DIR/thermal_ownership.conf"

TIMEOUT=600                 # Screen-off countdown: 600 seconds
POLL_INTERVAL=5             # Polling loop cycle: 5 seconds
SWITCH_WAIT_TIMEOUT=15      # Max seconds to wait for switch-user 0
STOP_TRANSITION_TIMEOUT=10  # Max seconds to wait for STOPPING transition
HEARTBEAT_INTERVAL=300      # Heartbeat log every 5 minutes
MAX_LOG_SIZE=65536          # 64 KB log cap

mkdir -p "$STATE_DIR" 2>/dev/null

# ── Logging System with Size-Capped Rotation ──
rotate_log_if_needed() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
      mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null
      echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Log rotated (exceeded ${MAX_LOG_SIZE}B)" > "$LOG_FILE"
    fi
  fi
}

log() {
  local msg="$1"
  local lvl="${2:-INFO}"
  rotate_log_if_needed
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'RUNTIME')"
  echo "$ts [$lvl] $msg" >> "$LOG_FILE"
}

# ── Singleton Process Management & Idempotent Trap ──
MY_PID="$$"
echo "$MY_PID" > "$PID_FILE" 2>/dev/null || true

CLEANUP_RUNNING=0
cleanup_on_exit() {
  # Idempotency guard: prevent recursion if exit is called inside cleanup
  if [ "$CLEANUP_RUNNING" -eq 1 ]; then
    return 0
  fi
  CLEANUP_RUNNING=1
  trap - EXIT INT TERM HUP
  log "Daemon shutdown initiated (PID: $MY_PID)" "INFO"
  restore_hardware_baseline "DAEMON_SHUTDOWN"
  rm -f "$PID_FILE" 2>/dev/null
  exit 0
}
trap cleanup_on_exit EXIT INT TERM HUP

# ── Suspend-Safe Monotonic Clock ──
get_boottime_seconds() {
  local uptime_raw
  uptime_raw=$(cat /proc/uptime 2>/dev/null)
  if [ -n "$uptime_raw" ]; then
    local sec="${uptime_raw%%.*}"
    case "$sec" in
      ''|*[!0-9]*) ;;
      *) echo "$sec"; return 0 ;;
    esac
  fi
  # Fallback to date seconds
  date +%s 2>/dev/null || echo 0
}

# ── Multi-Signal Fail-Closed Display State Detection ──
# Accepts ONLY confirmed physical display OFF.
# Rejects DOZE, ON, UNKNOWN, or conflicting readings.
is_display_off() {
  # Signal 1: Hardware Backlight Brightness
  local bl_path="/sys/class/backlight/panel0-backlight/brightness"
  if [ -f "$bl_path" ]; then
    local bl_val
    bl_val=$(cat "$bl_path" 2>/dev/null)
    case "$bl_val" in
      ''|*[!0-9]*) return 1 ;;
      0) ;; # Confirmed zero
      *) return 1 ;; # Backlight active
    esac
  fi

  # Signal 2: PowerManager Wakefulness
  local wake_dump wakefulness
  wake_dump=$(dumpsys power 2>/dev/null)
  [ -z "$wake_dump" ] && return 1

  wakefulness=$(echo "$wake_dump" | grep -m1 "mWakefulness=" | tr -d '[:space:]')
  case "$wakefulness" in
    mWakefulness=Asleep|mWakefulness=Dozing) ;;
    *) return 1 ;;
  esac

  # Signal 3: SurfaceFlinger Built-in Display Power Mode
  local sf_dump sf_state
  sf_dump=$(dumpsys SurfaceFlinger 2>/dev/null)
  [ -z "$sf_dump" ] && return 1

  sf_state=$(echo "$sf_dump" | awk '/Display [0-9]+ \(built-in\):/ {
    while (getline line) {
      if (line ~ /powerMode:/) {
        if (line ~ /powerMode: OFF|powerMode: 0/) { print "OFF"; exit }
        else { print "ON"; exit }
      }
    }
  }')
  [ "$sf_state" != "OFF" ] && return 1

  return 0
}

# ── Dynamic User Discovery & Strict Eligibility ──
# Main user (User 0) is immutable and protected.
# Eligible targets: independent android.os.usertype.full.SECONDARY users only.
# Profiles (MANAGED, CLONE, PRIVATE), SYSTEM, ADMIN, and GUEST are strictly excluded.
is_eligible_secondary_user() {
  local target_id="$1"
  [ -z "$target_id" ] && return 1
  case "$target_id" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$target_id" -eq 0 ] && return 1

  cmd user list -v 2>/dev/null | awk -v tgt="$target_id" '
    match($0, /id=([0-9]+)/) {
      uid = substr($0, RSTART+3, RLENGTH-3) + 0
      if (uid == tgt + 0) {
        if (match($0, /type=([a-zA-Z0-9_\.]+)/)) {
          utype = substr($0, RSTART+5, RLENGTH-5)
          if (utype ~ /full\.SECONDARY/) {
            # Ensure not a system or admin flag
            if ($0 ~ /SYSTEM/ || $0 ~ /ADMIN/ || $0 ~ /GUEST/) {
              exit 1
            }
            found = 1
            exit 0
          }
        }
      }
    }
    END { if (!found) exit 1 }
  '
}

# Discover all currently running eligible secondary users
get_running_eligible_secondary_users() {
  cmd user list -v 2>/dev/null | awk '
    match($0, /id=([0-9]+)/) {
      uid = substr($0, RSTART+3, RLENGTH-3) + 0
      if (uid == 0) next
      if (match($0, /type=([a-zA-Z0-9_\.]+)/)) {
        utype = substr($0, RSTART+5, RLENGTH-5)
        if (utype ~ /full\.SECONDARY/) {
          if ($0 !~ /SYSTEM/ && $0 !~ /ADMIN/ && $0 !~ /GUEST/) {
            if ($0 ~ /\(running\)/) {
              print uid
            }
          }
        }
      }
    }
  '
}

# Lifecycle classification for a specific user ID
check_user_lifecycle_state() {
  local uid="$1"
  [ -z "$uid" ] && { echo "UNKNOWN"; return; }

  local is_stopped
  is_stopped=$(cmd activity is-user-stopped "$uid" 2>/dev/null)
  if [ "$is_stopped" = "true" ]; then
    echo "STOPPED"
    return
  fi

  local user_state
  user_state=$(cmd activity get-started-user-state "$uid" 2>/dev/null)
  case "$user_state" in
    RUNNING_UNLOCKED) echo "RUNNING_UNLOCKED" ;;
    RUNNING_LOCKED)   echo "RUNNING_LOCKED" ;;
    STOPPING)         echo "STOPPING" ;;
    *not*started*|*does*not*exist*) echo "STOPPED" ;;
    *)
      if [ "$is_stopped" = "false" ]; then
        echo "RUNNING_LOCKED"
      else
        echo "UNKNOWN"
      fi
      ;;
  esac
}

get_current_user() {
  local cur
  cur=$(cmd activity get-current-user 2>/dev/null)
  case "$cur" in
    ''|*[!0-9]*) echo "-1" ;;
    *) echo "$cur" ;;
  esac
}

# ── Adaptive Thermal Engine (Second Space Shared Hardware) ──
CPU_P0_MAX="/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
CPU_P4_MAX="/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq"
CPU_P7_MAX="/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq"
GPU_MAX_CLK="/sys/class/kgsl/kgsl-3d0/max_gpuclk"

THERMAL_ENABLED=0
THERMAL_ZONE_PATH=""
THERMAL_ZONE_TYPE=""
CURRENT_TIER=0

BASE_P0=""
BASE_P4=""
BASE_P7=""
BASE_GPU=""

APPLIED_P0="NONE"
READBACK_P0="NONE"
STATUS_P0="BASELINE"

APPLIED_P4="NONE"
READBACK_P4="NONE"
STATUS_P4="BASELINE"

APPLIED_P7="NONE"
READBACK_P7="NONE"
STATUS_P7="BASELINE"

APPLIED_GPU="NONE"
READBACK_GPU="NONE"
STATUS_GPU="BASELINE"

save_ownership_records() {
  local cur_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")
  local tmp_file="${STATE_DIR}/thermal_ownership.tmp.$$"
  cat <<EOF > "$tmp_file"
BOOT_ID="$cur_boot"
APPLIED_P0="$APPLIED_P0"
READBACK_P0="$READBACK_P0"
STATUS_P0="$STATUS_P0"
APPLIED_P4="$APPLIED_P4"
READBACK_P4="$READBACK_P4"
STATUS_P4="$STATUS_P4"
APPLIED_P7="$APPLIED_P7"
READBACK_P7="$READBACK_P7"
STATUS_P7="$STATUS_P7"
APPLIED_GPU="$APPLIED_GPU"
READBACK_GPU="$READBACK_GPU"
STATUS_GPU="$STATUS_GPU"
EOF
  mv -f "$tmp_file" "$OWNERSHIP_FILE" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
}

load_ownership_records() {
  local cur_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")
  if [ -f "$OWNERSHIP_FILE" ]; then
    local stored_boot
    stored_boot=$(grep "^BOOT_ID=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ "$stored_boot" = "$cur_boot" ] && [ "$stored_boot" != "unknown_boot" ]; then
      . "$OWNERSHIP_FILE" 2>/dev/null || true
    else
      rm -f "$OWNERSHIP_FILE" 2>/dev/null
      APPLIED_P0="NONE"; READBACK_P0="NONE"; STATUS_P0="BASELINE"
      APPLIED_P4="NONE"; READBACK_P4="NONE"; STATUS_P4="BASELINE"
      APPLIED_P7="NONE"; READBACK_P7="NONE"; STATUS_P7="BASELINE"
      APPLIED_GPU="NONE"; READBACK_GPU="NONE"; STATUS_GPU="BASELINE"
    fi
  fi
}

# Dynamic Sensor Discovery & Validation
find_thermal_sensor() {
  local cand tz t_type t_temp
  # Original priority: quiet_therm -> cpu_therm -> battery -> xo_therm
  for cand in quiet_therm cpu_therm battery xo_therm; do
    for tz in /sys/class/thermal/thermal_zone*; do
      if [ -f "$tz/type" ] && [ -f "$tz/temp" ]; then
        t_type=$(cat "$tz/type" 2>/dev/null)
        if [ "$t_type" = "$cand" ]; then
          t_temp=$(cat "$tz/temp" 2>/dev/null)
          # Validate temperature range: 15°C to 65°C (15000 to 65000 m°C)
          case "$t_temp" in
            ''|*[!0-9]*) continue ;;
          esac
          if [ "$t_temp" -ge 15000 ] && [ "$t_temp" -le 65000 ]; then
            THERMAL_ZONE_PATH="$tz"
            THERMAL_ZONE_TYPE="$cand"
            THERMAL_ENABLED=1
            log "Thermal sensor resolved & validated: $tz ($cand, temp=${t_temp}mC)" "INFO"
            return 0
          fi
        fi
      fi
    done
  done

  THERMAL_ENABLED=0
  log "WARNING: No valid thermal sensor matched plausible temperature range. Adaptive thermal disabled." "WARN"
  return 1
}

# Runtime Baseline Capture (Per-Boot Identity Enforced)
capture_baseline_frequencies() {
  local current_boot_id stored_boot_id
  current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")

  # If baseline file exists, verify matching boot_id
  if [ -f "$BASELINE_FILE" ]; then
    stored_boot_id=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ "$stored_boot_id" = "$current_boot_id" ] && [ "$stored_boot_id" != "unknown_boot" ]; then
      . "$BASELINE_FILE"
      if [ -n "$BASE_P0" ] && [ -n "$BASE_P4" ] && [ -n "$BASE_P7" ] && [ -n "$BASE_GPU" ]; then
        log "Loaded valid baseline for boot $current_boot_id: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU" "INFO"
        return 0
      fi
    else
      log "Stale baseline file detected from different boot ($stored_boot_id vs $current_boot_id). Purging." "INFO"
      rm -f "$BASELINE_FILE"
    fi
  fi

  # Capture multiple samples to verify stability
  local s1_p0 s1_p4 s1_p7 s1_gpu
  local s2_p0 s2_p4 s2_p7 s2_gpu
  s1_p0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  s1_p4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  s1_p7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  s1_gpu=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  sleep 1

  s2_p0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  s2_p4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  s2_p7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  s2_gpu=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  if [ "$s1_p0" = "$s2_p0" ] && [ "$s1_p4" = "$s2_p4" ] && [ "$s1_p7" = "$s2_p7" ] && [ "$s1_gpu" = "$s2_gpu" ] && [ -n "$s1_p0" ]; then
    BASE_P0="$s1_p0"
    BASE_P4="$s1_p4"
    BASE_P7="$s1_p7"
    BASE_GPU="$s1_gpu"

    cat <<EOF > "$BASELINE_FILE"
BOOT_ID="$current_boot_id"
BASE_P0="$BASE_P0"
BASE_P4="$BASE_P4"
BASE_P7="$BASE_P7"
BASE_GPU="$BASE_GPU"
EOF
    log "Runtime baseline captured & saved: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU (boot: $current_boot_id)" "INFO"
    return 0
  fi

  log "ERROR: Frequency nodes unstable or unreadable during baseline capture. Deferring capture." "WARN"
  return 1
}

clamp_limit() {
  local target="$1"
  local base="$2"
  if [ -n "$base" ] && [ "$base" -gt 0 ] 2>/dev/null && [ "$target" -gt "$base" ] 2>/dev/null; then
    echo "$base"
  else
    echo "$target"
  fi
}

# Determine Tier using exact original HyperOS lite-global hysteresis
# Tier 0: <=35°C (Baseline)
# Tier 1: >=36°C (recovery <35°C)
# Tier 2: >=38°C (recovery <37°C)
# Tier 3: >=40°C (recovery <39°C)
# Tier 4: >=42°C (recovery <41°C)
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

# ── Single-Node Thermal Limit Application with Read-Back Verification ──
apply_single_node_limit() {
  local node_name="$1"
  local node_path="$2"
  local target="$3"
  local base="$4"
  local cur_applied="$5"

  # 1. Missing node check
  if [ ! -f "$node_path" ]; then
    echo "NODE_MISSING NONE NONE"
    return 1
  fi

  # 2. Read current hardware value
  local cur_val
  cur_val=$(cat "$node_path" 2>/dev/null)
  case "$cur_val" in
    ''|*[!0-9]*)
      echo "UNREADABLE NONE NONE"
      return 1
      ;;
  esac

  # 3. Target clamped to baseline
  target=$(clamp_limit "$target" "$base")

  # 4. If current value is already equal to target and was applied by module
  if [ "$cur_val" = "$target" ] && [ "$cur_applied" = "$target" ]; then
    echo "ALREADY_APPLIED $target $cur_val"
    return 0
  fi

  # 5. Vendor overwrite protection on apply:
  # If current hardware frequency is lower than target, external vendor has imposed a lower limit
  if [ "$cur_val" -lt "$target" ]; then
    # Do NOT raise vendor safety limit! Preserve it.
    echo "VENDOR_LOWER_PRESERVED $cur_applied $cur_val"
    return 0
  fi

  # 6. Apply cap (cur_val >= target)
  echo "$target" > "$node_path" 2>/dev/null
  local readback
  readback=$(cat "$node_path" 2>/dev/null)

  # 7. Read-back verification
  if [ "$readback" = "$target" ]; then
    echo "APPLIED_VERIFIED $target $readback"
    return 0
  elif [ -n "$readback" ] && [ "$readback" -lt "$target" ] 2>/dev/null; then
    # Hardware or vendor clamped to a lower frequency
    echo "VENDOR_CLAMPED $readback $readback"
    return 0
  else
    echo "WRITE_FAILED $cur_applied $readback"
    return 1
  fi
}

# ── Single-Node Restoration Decision with Ownership Verification ──
restore_single_node_baseline() {
  local node_name="$1"
  local node_path="$2"
  local base="$3"
  local applied="$4"
  local cur_boot="$5"
  local stored_boot="$6"

  # 1. Missing node check
  if [ ! -f "$node_path" ]; then
    echo "NODE_MISSING NONE"
    return 2
  fi

  # 2. Check boot ID and baseline validity
  if [ -z "$cur_boot" ] || [ "$cur_boot" != "$stored_boot" ] || [ "$cur_boot" = "unknown_boot" ]; then
    echo "STALE_BOOT_ID NONE"
    return 1
  fi
  case "$base" in
    ''|*[!0-9]*)
      echo "INVALID_BASELINE NONE"
      return 1
      ;;
  esac

  # 3. Read current hardware value
  local cur_val
  cur_val=$(cat "$node_path" 2>/dev/null)
  case "$cur_val" in
    ''|*[!0-9]*)
      echo "UNREADABLE NONE"
      return 1
      ;;
  esac

  # 4. Check if current is already at baseline
  if [ "$cur_val" = "$base" ]; then
    # Already at baseline; no write needed
    echo "ALREADY_BASELINE $cur_val"
    return 0
  fi

  # 5. Check module ownership: did module apply a cap?
  case "$applied" in
    ''|'NONE'|*[!0-9]*)
      # Module never applied a cap or has no record of having throttled this node
      # But cur_val != base. An external controller or vendor set cur_val.
      # Ownership uncertain: fail closed!
      echo "OWNERSHIP_UNCERTAIN $cur_val"
      return 1
      ;;
  esac

  if [ "$applied" -eq "$base" ]; then
    echo "OWNERSHIP_UNCERTAIN $cur_val"
    return 1
  fi

  # 6. Module did apply a cap ($applied != $base). Compare current against applied:
  if [ "$cur_val" -lt "$applied" ]; then
    # Scenario 2: Current is LOWER than module's applied value!
    # External vendor imposed a stronger limit than module cap. Preserve it!
    echo "VENDOR_LOWER_PRESERVED $cur_val"
    return 0
  elif [ "$cur_val" -eq "$applied" ]; then
    # Scenario 1: Current strictly equals module's applied value.
    # Positive ownership verified! Restore baseline.
    echo "$base" > "$node_path" 2>/dev/null
    local readback
    readback=$(cat "$node_path" 2>/dev/null)
    if [ "$readback" = "$base" ]; then
      echo "RESTORED_VERIFIED $readback"
      return 0
    elif [ -n "$readback" ] && [ "$readback" -lt "$base" ] 2>/dev/null; then
      # Restored write was accepted but clamped by vendor limit
      echo "PARTIAL_RESTORE_VENDOR_CLAMP $readback"
      return 0
    else
      echo "RESTORE_FAILED $readback"
      return 1
    fi
  else
    # Scenario 4: cur_val != applied and cur_val > applied and cur_val != base
    # An external controller changed the node to an unrelated value!
    # Ownership uncertain: fail closed!
    echo "OWNERSHIP_UNCERTAIN $cur_val"
    return 1
  fi
}

apply_adaptive_thermal() {
  [ "$THERMAL_ENABLED" -eq 0 ] && return 0
  [ -z "$THERMAL_ZONE_PATH" ] && return 0

  local raw_temp
  raw_temp=$(cat "$THERMAL_ZONE_PATH/temp" 2>/dev/null)
  case "$raw_temp" in
    ''|*[!0-9]*) return 0 ;;
  esac

  local target_tier
  target_tier=$(determine_target_tier "$raw_temp")

  if [ "$target_tier" -eq 0 ]; then
    if [ "$CURRENT_TIER" -ne 0 ]; then
      restore_hardware_baseline "TIER_0_RESTORE"
    fi
    return 0
  fi

  local target_p0 target_p4 target_p7 target_gpu
  case "$target_tier" in
    1)
      target_p0="$BASE_P0"
      target_p4=2131200
      target_p7=2131200
      target_gpu=585000000
      ;;
    2)
      target_p0=1632000
      target_p4=1920000
      target_p7=1920000
      target_gpu=499200000
      ;;
    3)
      target_p0=1478400
      target_p4=1612800
      target_p7=1612800
      target_gpu=427000000
      ;;
    4)
      target_p0=1382400
      target_p4=1401600
      target_p7=1401600
      target_gpu=345000000
      ;;
  esac

  load_ownership_records

  local res_p0 res_p4 res_p7 res_gpu
  res_p0=$(apply_single_node_limit "CPU_P0" "$CPU_P0_MAX" "$target_p0" "$BASE_P0" "$APPLIED_P0")
  res_p4=$(apply_single_node_limit "CPU_P4" "$CPU_P4_MAX" "$target_p4" "$BASE_P4" "$APPLIED_P4")
  res_p7=$(apply_single_node_limit "CPU_P7" "$CPU_P7_MAX" "$target_p7" "$BASE_P7" "$APPLIED_P7")
  res_gpu=$(apply_single_node_limit "GPU" "$GPU_MAX_CLK" "$target_gpu" "$BASE_GPU" "$APPLIED_GPU")

  STATUS_P0=$(echo "$res_p0" | awk '{print $1}')
  APPLIED_P0=$(echo "$res_p0" | awk '{print $2}')
  READBACK_P0=$(echo "$res_p0" | awk '{print $3}')

  STATUS_P4=$(echo "$res_p4" | awk '{print $1}')
  APPLIED_P4=$(echo "$res_p4" | awk '{print $2}')
  READBACK_P4=$(echo "$res_p4" | awk '{print $3}')

  STATUS_P7=$(echo "$res_p7" | awk '{print $1}')
  APPLIED_P7=$(echo "$res_p7" | awk '{print $2}')
  READBACK_P7=$(echo "$res_p7" | awk '{print $3}')

  STATUS_GPU=$(echo "$res_gpu" | awk '{print $1}')
  APPLIED_GPU=$(echo "$res_gpu" | awk '{print $2}')
  READBACK_GPU=$(echo "$res_gpu" | awk '{print $3}')

  save_ownership_records

  if [ "$target_tier" != "$CURRENT_TIER" ]; then
    local temp_c=$((raw_temp / 1000))
    log "Adaptive Thermal (Tier $target_tier, Temp=${temp_c}°C): P0=$APPLIED_P0($READBACK_P0), P4=$APPLIED_P4($READBACK_P4), P7=$APPLIED_P7($READBACK_P7), GPU=$APPLIED_GPU($READBACK_GPU)" "INFO"
  fi

  CURRENT_TIER="$target_tier"
}

restore_hardware_baseline() {
  local reason="${1:-USER_TRANSITION}"
  local cur_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")

  local stored_boot=""
  if [ -f "$BASELINE_FILE" ]; then
    stored_boot=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
  fi

  if [ -z "$BASE_P0" ] || [ -z "$BASE_P4" ] || [ -z "$BASE_P7" ] || [ -z "$BASE_GPU" ]; then
    capture_baseline_frequencies || {
      log "WARNING: Cannot restore hardware baseline: baseline capture failed or unreadable." "WARN"
      return 1
    }
  fi

  load_ownership_records

  local res_p0 res_p4 res_p7 res_gpu
  res_p0=$(restore_single_node_baseline "CPU_P0" "$CPU_P0_MAX" "$BASE_P0" "$APPLIED_P0" "$cur_boot" "$stored_boot")
  res_p4=$(restore_single_node_baseline "CPU_P4" "$CPU_P4_MAX" "$BASE_P4" "$APPLIED_P4" "$cur_boot" "$stored_boot")
  res_p7=$(restore_single_node_baseline "CPU_P7" "$CPU_P7_MAX" "$BASE_P7" "$APPLIED_P7" "$cur_boot" "$stored_boot")
  res_gpu=$(restore_single_node_baseline "GPU" "$GPU_MAX_CLK" "$BASE_GPU" "$APPLIED_GPU" "$cur_boot" "$stored_boot")

  local stat_p0 val_p0 stat_p4 val_p4 stat_p7 val_p7 stat_gpu val_gpu
  stat_p0=$(echo "$res_p0" | awk '{print $1}')
  val_p0=$(echo "$res_p0" | awk '{print $2}')
  stat_p4=$(echo "$res_p4" | awk '{print $1}')
  val_p4=$(echo "$res_p4" | awk '{print $2}')
  stat_p7=$(echo "$res_p7" | awk '{print $1}')
  val_p7=$(echo "$res_p7" | awk '{print $2}')
  stat_gpu=$(echo "$res_gpu" | awk '{print $1}')
  val_gpu=$(echo "$res_gpu" | awk '{print $2}')

  STATUS_P0="$stat_p0"
  if [ "$stat_p0" = "RESTORED_VERIFIED" ] || [ "$stat_p0" = "ALREADY_BASELINE" ]; then
    APPLIED_P0="NONE"; READBACK_P0="$val_p0"
  fi

  STATUS_P4="$stat_p4"
  if [ "$stat_p4" = "RESTORED_VERIFIED" ] || [ "$stat_p4" = "ALREADY_BASELINE" ]; then
    APPLIED_P4="NONE"; READBACK_P4="$val_p4"
  fi

  STATUS_P7="$stat_p7"
  if [ "$stat_p7" = "RESTORED_VERIFIED" ] || [ "$stat_p7" = "ALREADY_BASELINE" ]; then
    APPLIED_P7="NONE"; READBACK_P7="$val_p7"
  fi

  STATUS_GPU="$stat_gpu"
  if [ "$stat_gpu" = "RESTORED_VERIFIED" ] || [ "$stat_gpu" = "ALREADY_BASELINE" ]; then
    APPLIED_GPU="NONE"; READBACK_GPU="$val_gpu"
  fi

  save_ownership_records
  CURRENT_TIER=0

  # Evaluate overall restoration health
  local has_failure=0
  for st in "$stat_p0" "$stat_p4" "$stat_p7" "$stat_gpu"; do
    case "$st" in
      RESTORE_FAILED|OWNERSHIP_UNCERTAIN|STALE_BOOT_ID|UNREADABLE)
        has_failure=1
        ;;
    esac
  done

  if [ "$has_failure" -eq 1 ]; then
    log "PARTIAL_RESTORE_WARNING: Hardware restoration incomplete or uncertain (reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu). Refusing false success report." "WARN"
    return 1
  else
    log "Hardware restoration completed successfully (reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu)." "INFO"
    return 0
  fi
}

# ── Daemon Initialization ──
log "Auto-switch daemon started (version=v3.2.0, timeout=${TIMEOUT}s, target=DYNAMIC_MULTI_USER, LIVE_EXECUTION=ENABLED)" "INFO"

find_thermal_sensor
capture_baseline_frequencies

LAST_USER=""
SCREEN_OFF_BOOTTIME=0
LAST_HEARTBEAT=$(get_boottime_seconds)

# ── Main Supervisory Loop ──
while true; do
  sleep "$POLL_INTERVAL"

  NOW=$(get_boottime_seconds)
  CURRENT_USER=$(get_current_user)

  # Fail-closed on invalid foreground user read
  if [ "$CURRENT_USER" = "-1" ]; then
    continue
  fi

  # Detect foreground user transitions
  if [ "$CURRENT_USER" != "$LAST_USER" ]; then
    log "Foreground user transitioned from '$LAST_USER' to '$CURRENT_USER'" "INFO"
    LAST_USER="$CURRENT_USER"
    SCREEN_OFF_BOOTTIME=0 # Reset timer on user switch
    if [ "$CURRENT_USER" -eq 0 ]; then
      restore_hardware_baseline "SWITCH_TO_USER_0"
    fi
  fi

  # Routine Heartbeat
  if [ $((NOW - LAST_HEARTBEAT)) -ge "$HEARTBEAT_INTERVAL" ]; then
    disp_status="ON"
    is_display_off && disp_status="OFF"
    log "Heartbeat: daemon active (foreground_user=$CURRENT_USER, thermal_tier=$CURRENT_TIER, display=$disp_status, timer_armed=$SCREEN_OFF_BOOTTIME)" "INFO"
    LAST_HEARTBEAT="$NOW"
  fi

  DISP_IS_OFF=0
  if is_display_off; then
    DISP_IS_OFF=1
  fi

  # ─────────────────────────────────────────────────────────────
  # BRANCH 1: User 0 is Foreground (Scenario B Evaluation)
  # ─────────────────────────────────────────────────────────────
  if [ "$CURRENT_USER" -eq 0 ]; then
    # Ensure baseline is intact
    if [ "$CURRENT_TIER" -ne 0 ]; then
      restore_hardware_baseline "USER_0_ACTIVE"
    fi

    # Discover running eligible secondary users
    RUNNING_SECONDARY=$(get_running_eligible_secondary_users)

    if [ -z "$RUNNING_SECONDARY" ]; then
      # No secondary users running -> idle
      if [ "$SCREEN_OFF_BOOTTIME" -ne 0 ]; then
        log "[Scenario B] No running secondary users remain; timer disarmed" "INFO"
        SCREEN_OFF_BOOTTIME=0
      fi
    else
      # One or more secondary users are running in background
      if [ "$DISP_IS_OFF" -eq 1 ]; then
        if [ "$SCREEN_OFF_BOOTTIME" -eq 0 ]; then
          SCREEN_OFF_BOOTTIME="$NOW"
          log "[Scenario B] Screen OFF with secondary users running ($RUNNING_SECONDARY) — timer started (${TIMEOUT}s deadline)" "INFO"
        else
          ELAPSED=$((NOW - SCREEN_OFF_BOOTTIME))
          if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            log "[Scenario B] Deadline reached (elapsed=${ELAPSED}s >= ${TIMEOUT}s) — evaluating batch stop..." "INFO"

            # Rediscover fresh set of running users at deadline
            FRESH_RUNNING=$(get_running_eligible_secondary_users)
            for target_uid in $FRESH_RUNNING; do
              # Pre-stop validation
              if ! is_display_off; then
                log "[Scenario B] Display turned ON during batch stop; aborting remaining targets" "INFO"
                break
              fi
              if [ "$(get_current_user)" -ne 0 ]; then
                log "[Scenario B] Foreground user changed during batch stop; aborting remaining targets" "INFO"
                break
              fi
              if ! is_eligible_secondary_user "$target_uid"; then
                log "[Scenario B] Target $target_uid failed eligibility revalidation; skipping" "WARN"
                continue
              fi

              u_state=$(check_user_lifecycle_state "$target_uid")
              if [ "$u_state" = "STOPPED" ]; then
                continue
              fi

              log "[Scenario B] Executing stop-user on secondary user $target_uid (state: $u_state)" "INFO"
              cmd activity stop-user -w "$target_uid" >/dev/null 2>&1
              post_state=$(check_user_lifecycle_state "$target_uid")
              log "[Scenario B] Result for user $target_uid: $post_state" "INFO"
            done

            SCREEN_OFF_BOOTTIME=0
          fi
        fi
      else
        # Screen is ON
        if [ "$SCREEN_OFF_BOOTTIME" -ne 0 ]; then
          log "[Scenario B] Display turned ON on User 0 — timer cancelled" "INFO"
          SCREEN_OFF_BOOTTIME=0
        fi
      fi
    fi

  # ─────────────────────────────────────────────────────────────
  # BRANCH 2: Secondary User is Foreground (Scenario A Evaluation)
  # ─────────────────────────────────────────────────────────────
  else
    # Validate eligibility of foreground user
    if ! is_eligible_secondary_user "$CURRENT_USER"; then
      # Unknown or ineligible user (guest, profile, etc.) -> fail closed
      SCREEN_OFF_BOOTTIME=0
      continue
    fi

    # Apply Adaptive Thermal Throttling for active secondary user
    apply_adaptive_thermal

    if [ "$DISP_IS_OFF" -eq 1 ]; then
      if [ "$SCREEN_OFF_BOOTTIME" -eq 0 ]; then
        SCREEN_OFF_BOOTTIME="$NOW"
        log "[Scenario A] Screen OFF on secondary user $CURRENT_USER — timer started (${TIMEOUT}s deadline)" "INFO"
      else
        ELAPSED=$((NOW - SCREEN_OFF_BOOTTIME))
        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
          log "[Scenario A] Deadline reached (elapsed=${ELAPSED}s >= ${TIMEOUT}s) — initiating switch to User 0..." "INFO"

          TARGET_TO_STOP="$CURRENT_USER"

          # Final pre-switch physical display verification
          if ! is_display_off; then
            log "[Scenario A] ABORT: Display turned ON immediately before switch; resetting timer" "WARN"
            SCREEN_OFF_BOOTTIME=0
            continue
          fi

          # Execute asynchronous user switch to User 0
          cmd activity switch-user 0 >/dev/null 2>&1

          # Wait for User 0 to become foreground (bounded polling)
          wait_count=0
          switch_ok=0
          while [ "$wait_count" -lt "$SWITCH_WAIT_TIMEOUT" ]; do
            sleep 1
            wait_count=$((wait_count + 1))
            if [ "$(get_current_user)" -eq 0 ]; then
              switch_ok=1
              break
            fi
          done

          if [ "$switch_ok" -eq 1 ]; then
            log "[Scenario A] User 0 verified as foreground after ${wait_count}s" "INFO"
            LAST_USER="0"
            restore_hardware_baseline "USER_0_RESTORED_POST_SWITCH"

            # Check if native stop-on-switch already stopped the user
            post_switch_state=$(check_user_lifecycle_state "$TARGET_TO_STOP")

            if [ "$post_switch_state" = "STOPPED" ]; then
              log "[Scenario A] [SUCCESS] User $TARGET_TO_STOP stopped automatically via native stop-on-switch policy." "INFO"
            elif [ "$post_switch_state" = "STOPPING" ]; then
              log "[Scenario A] User $TARGET_TO_STOP is STOPPING; waiting for transition..." "INFO"
              trans_wait=0
              while [ "$trans_wait" -lt "$STOP_TRANSITION_TIMEOUT" ]; do
                sleep 1
                trans_wait=$((trans_wait + 1))
                post_switch_state=$(check_user_lifecycle_state "$TARGET_TO_STOP")
                [ "$post_switch_state" = "STOPPED" ] && break
              done
              log "[Scenario A] Transition finished for user $TARGET_TO_STOP: state=$post_switch_state" "INFO"
            else
              # User is still running; execute fallback stop
              log "[Scenario A] Native stop-on-switch did not stop user $TARGET_TO_STOP (state=$post_switch_state); executing fallback stop-user..." "INFO"
              cmd activity stop-user -w "$TARGET_TO_STOP" >/dev/null 2>&1
              final_state=$(check_user_lifecycle_state "$TARGET_TO_STOP")
              log "[Scenario A] Final state for user $TARGET_TO_STOP: $final_state" "INFO"
            fi
          else
            log "[Scenario A] [ERROR] Timeout waiting for User 0 foreground; aborting stop of user $TARGET_TO_STOP" "ERROR"
          fi

          SCREEN_OFF_BOOTTIME=0
        fi
      fi
    else
      # Screen is ON
      if [ "$SCREEN_OFF_BOOTTIME" -ne 0 ]; then
        log "[Scenario A] Display turned ON on user $CURRENT_USER — timer cancelled" "INFO"
        SCREEN_OFF_BOOTTIME=0
      fi
    fi
  fi
done
