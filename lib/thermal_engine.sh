#!/system/bin/sh
# Nabu DerpFest 17 Helper — Adaptive Thermal Engine Library
# =========================================================
# Reusable, sourceable POSIX shell library for Adaptive Thermal Tier 0-4,
# dynamic sensor validation, runtime baseline capture, ownership-aware
# limit application, and fail-closed hardware restoration.

# ── Hardware Node Paths (Configurable for Test / Mocking) ──
: "${CPU_P0_MAX:=/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq}"
: "${CPU_P4_MAX:=/sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq}"
: "${CPU_P7_MAX:=/sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq}"
: "${GPU_MAX_CLK:=/sys/class/kgsl/kgsl-3d0/max_gpuclk}"
: "${STATE_DIR:=/data/adb/modules/nabu-derpfest-helper/state}"
: "${BASELINE_FILE:=$STATE_DIR/thermal_baseline.conf}"
: "${OWNERSHIP_FILE:=$STATE_DIR/thermal_ownership.conf}"
case "$STATE_DIR" in
  */*) : "${GUARD_FILE:=${STATE_DIR%/*}/.thermal_boot_guard}" ;;
  *)   : "${GUARD_FILE:=/data/adb/modules/nabu-derpfest-helper/.thermal_boot_guard}" ;;
esac
: "${THERMAL_SYSFS_DIR:=/sys/class/thermal}"
: "${BASELINE_SAMPLE_DELAY:=1}"

# ── In-Memory State Variables ──
THERMAL_ENABLED=0
THERMAL_ZONE_PATH=""
THERMAL_ZONE_TYPE=""
CURRENT_TIER=0
RECOVERY_PENDING=0
BASELINE_VALID=0

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

# ── Helper: Clamp Frequency to Baseline ──
clamp_limit() {
  local target="$1"
  local base="$2"
  if [ -n "$base" ] && [ "$base" -gt 0 ] 2>/dev/null && [ "$target" -gt "$base" ] 2>/dev/null; then
    echo "$base"
  else
    echo "$target"
  fi
}

# ── Sensor Sample Validation ──
# Validates a single thermal reading against strict physical bounds:
# 15,000 m°C <= temperature <= 65,000 m°C (15.0°C to 65.0°C).
# Rejects empty, nonnumeric, negative, or out-of-range values.
validate_sensor_sample() {
  local raw_val="$1"
  local sensor_type="${2:-quiet_therm}"
  local sensor_path="${3:-none}"

  if [ -z "$raw_val" ]; then
    echo "EMPTY_READING"
    return 1
  fi

  case "$raw_val" in
    ''|*[!0-9]*)
      echo "NON_NUMERIC_READING"
      return 1
      ;;
  esac

  if [ "$raw_val" -lt 15000 ]; then
    echo "OUT_OF_RANGE_LOW"
    return 1
  fi

  if [ "$raw_val" -gt 65000 ]; then
    echo "OUT_OF_RANGE_HIGH"
    return 1
  fi

  echo "VALID_SAMPLE"
  return 0
}

# ── Runtime Sensor Sampling with Fail-Closed Validation ──
# Reads current temperature from THERMAL_ZONE_PATH/temp and validates sample.
# If valid: prints temperature in m°C, returns 0.
# If invalid or sensor disappeared: prints validation reason, returns 1.
sample_thermal_sensor() {
  local zone_path="${1:-$THERMAL_ZONE_PATH}"
  if [ -z "$zone_path" ] || [ ! -f "$zone_path/temp" ]; then
    echo "SENSOR_DISAPPEARED"
    return 1
  fi

  local raw_val
  raw_val=$(cat "$zone_path/temp" 2>/dev/null)
  local val_res
  val_res=$(validate_sensor_sample "$raw_val" "quiet_therm" "$zone_path")
  if [ "$val_res" = "VALID_SAMPLE" ]; then
    echo "$raw_val"
    return 0
  else
    echo "$val_res"
    return 1
  fi
}

# ── Sensor Resolution & Initial Validation ──
# On Xiaomi Pad 5 (nabu), quiet_therm is calibrated for external surface/skin temperature.
# Fallback semantics:
# - cpu_therm: measures SoC junction/die temp (typically 15-30°C higher than skin).
#   Applying skin 36-42°C thresholds to cpu_therm would cause perpetual unwarranted throttling.
# - battery: measures battery pack with high thermal inertia and lower max safe limits.
# - xo_therm: measures crystal oscillator temperature.
# Policy: If quiet_therm is absent, do not silently apply the skin curve to mismatched thermistors.
# Disable adaptive thermal safely unless a validated sensor is resolved.
find_thermal_sensor() {
  local cand tz t_type t_temp v_res
  for tz in "$THERMAL_SYSFS_DIR"/thermal_zone*; do
    if [ -f "$tz/type" ] && [ -f "$tz/temp" ]; then
      t_type=$(cat "$tz/type" 2>/dev/null)
      if [ "$t_type" = "quiet_therm" ]; then
        t_temp=$(cat "$tz/temp" 2>/dev/null)
        v_res=$(validate_sensor_sample "$t_temp" "quiet_therm" "$tz")
        if [ "$v_res" = "VALID_SAMPLE" ]; then
          THERMAL_ZONE_PATH="$tz"
          THERMAL_ZONE_TYPE="quiet_therm"
          THERMAL_ENABLED=1
          command -v log >/dev/null 2>&1 && log "Validated skin thermal sensor: $tz (quiet_therm, temp=${t_temp}mC)" "INFO"
          return 0
        else
          command -v log >/dev/null 2>&1 && log "Notice: quiet_therm found at $tz but initial sample invalid ($v_res, raw='$t_temp')" "WARN"
        fi
      fi
    fi
  done

  # Fallback investigation: log presence but refuse silent curve mismatch
  for cand in cpu_therm battery xo_therm; do
    for tz in "$THERMAL_SYSFS_DIR"/thermal_zone*; do
      if [ -f "$tz/type" ] && [ "$(cat "$tz/type" 2>/dev/null)" = "$cand" ]; then
        command -v log >/dev/null 2>&1 && log "Notice: Sensor '$cand' detected at $tz, but skin-curve thresholds (36-42°C) are incompatible. Adaptive thermal disabled for safety." "WARN"
      fi
    done
  done

  THERMAL_ENABLED=0
  command -v log >/dev/null 2>&1 && log "WARNING: Validated skin thermal sensor (quiet_therm) unavailable. Adaptive thermal disabled." "WARN"
  return 1
}

# ── Strict Baseline Frequency Validation ──
validate_baseline_value() {
  local val="$1"
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$val" -le 0 ] 2>/dev/null; then
    return 1
  fi
  return 0
}

# ── Boot-Scoped Initialization Guard ──
is_same_boot_guard_active() {
  local cur_boot="$1"
  if [ -z "$cur_boot" ] || [ "$cur_boot" = "unknown_boot" ]; then
    return 1
  fi
  if [ -f "$GUARD_FILE" ]; then
    local guard_boot
    guard_boot=$(grep "^BOOT_ID=" "$GUARD_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ -n "$guard_boot" ] && [ "$guard_boot" = "$cur_boot" ]; then
      return 0
    fi
  fi
  return 1
}

write_boot_guard() {
  local cur_boot="$1"
  if [ -z "$cur_boot" ] || [ "$cur_boot" = "unknown_boot" ]; then
    return 1
  fi
  local guard_dir
  case "$GUARD_FILE" in
    */*) guard_dir="${GUARD_FILE%/*}" ;;
    *)   guard_dir="." ;;
  esac
  mkdir -p "$guard_dir" 2>/dev/null

  local tmp_g="${GUARD_FILE}.tmp.$$"
  cat <<EOF > "$tmp_g" 2>/dev/null
BOOT_ID="$cur_boot"
INITIALIZED_AT="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'RUNTIME')"
STATUS="INITIALIZED"
EOF
  if [ ! -s "$tmp_g" ]; then
    rm -f "$tmp_g" 2>/dev/null
    return 1
  fi
  mv -f "$tmp_g" "$GUARD_FILE" 2>/dev/null || {
    rm -f "$tmp_g" 2>/dev/null
    return 1
  }
  return 0
}

# ── Same-Boot Active Ownership Check ──
has_same_boot_active_ownership() {
  local cur_boot="$1"
  if [ -z "$cur_boot" ] || [ "$cur_boot" = "unknown_boot" ]; then
    return 1
  fi

  if [ -f "$OWNERSHIP_FILE" ]; then
    local owner_boot
    owner_boot=$(grep "^BOOT_ID=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ -n "$owner_boot" ] && [ "$owner_boot" = "$cur_boot" ]; then
      local rec_pending cur_tier
      rec_pending=$(grep "^RECOVERY_PENDING=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
      cur_tier=$(grep "^CURRENT_TIER=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
      if [ "$rec_pending" = "1" ] || { [ -n "$cur_tier" ] && [ "$cur_tier" -gt 0 ] 2>/dev/null; }; then
        return 0
      fi
      local ap0 ap4 ap7 apgpu
      ap0=$(grep "^APPLIED_P0=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
      ap4=$(grep "^APPLIED_P4=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
      ap7=$(grep "^APPLIED_P7=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
      apgpu=$(grep "^APPLIED_GPU=" "$OWNERSHIP_FILE" 2>/dev/null | cut -d'"' -f2)
      for ap in "$ap0" "$ap4" "$ap7" "$apgpu"; do
        case "$ap" in
          ''|'NONE'|*[!0-9]*) ;;
          *) return 0 ;;
        esac
      done
    fi
  fi

  # In-memory check only applies if in-memory boot ID matches current boot
  if [ "${IN_MEMORY_BOOT_ID:-}" = "$cur_boot" ]; then
    if [ "${RECOVERY_PENDING:-0}" -eq 1 ] || { [ -n "$CURRENT_TIER" ] && [ "$CURRENT_TIER" -gt 0 ] 2>/dev/null; }; then
      return 0
    fi
    for ap in "$APPLIED_P0" "$APPLIED_P4" "$APPLIED_P7" "$APPLIED_GPU"; do
      case "$ap" in
        ''|'NONE'|*[!0-9]*) ;;
        *) return 0 ;;
      esac
    done
  fi

  return 1
}

# ── Baseline Integrity Validation (Disk & Memory) ──
validate_baseline_integrity() {
  local cur_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")
  if [ -z "$cur_boot" ] || [ "$cur_boot" = "unknown_boot" ]; then
    return 1
  fi

  if [ -f "$BASELINE_FILE" ]; then
    local b_boot b_p0 b_p4 b_p7 b_gpu
    b_boot=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ "$b_boot" = "$cur_boot" ] && [ "$b_boot" != "unknown_boot" ]; then
      b_p0=$(grep "^BASE_P0=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
      b_p4=$(grep "^BASE_P4=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
      b_p7=$(grep "^BASE_P7=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
      b_gpu=$(grep "^BASE_GPU=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)

      if validate_baseline_value "$b_p0" && \
         validate_baseline_value "$b_p4" && \
         validate_baseline_value "$b_p7" && \
         validate_baseline_value "$b_gpu"; then
        BASE_P0="$b_p0"
        BASE_P4="$b_p4"
        BASE_P7="$b_p7"
        BASE_GPU="$b_gpu"
        BASELINE_VALID=1
        return 0
      fi
    fi
  fi

  return 1
}

# ── Runtime Baseline Capture (Per-Boot Identity & Fail-Closed Guards) ──
capture_baseline_frequencies() {
  local current_boot_id stored_boot_id
  current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")

  if [ -z "$current_boot_id" ] || [ "$current_boot_id" = "unknown_boot" ]; then
    command -v log >/dev/null 2>&1 && log "ERROR: Invalid boot ID; baseline capture aborted." "ERROR"
    BASELINE_VALID=0
    return 1
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null

  # Purge stale guard and ownership from older boots
  if [ -f "$GUARD_FILE" ]; then
    local guard_boot
    guard_boot=$(grep "^BOOT_ID=" "$GUARD_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ "$guard_boot" != "$current_boot_id" ]; then
      command -v log >/dev/null 2>&1 && log "Stale boot guard detected from older boot ($guard_boot vs $current_boot_id). Purging." "INFO"
      rm -f "$GUARD_FILE" 2>/dev/null
    fi
  fi

  if [ "${IN_MEMORY_BOOT_ID:-}" != "$current_boot_id" ]; then
    RECOVERY_PENDING=0
    CURRENT_TIER=0
    APPLIED_P0="NONE"; READBACK_P0="NONE"; STATUS_P0="BASELINE"
    APPLIED_P4="NONE"; READBACK_P4="NONE"; STATUS_P4="BASELINE"
    APPLIED_P7="NONE"; READBACK_P7="NONE"; STATUS_P7="BASELINE"
    APPLIED_GPU="NONE"; READBACK_GPU="NONE"; STATUS_GPU="BASELINE"
    IN_MEMORY_BOOT_ID="$current_boot_id"
  fi
  load_ownership_records

  # 1. Verify existing baseline file against current boot UUID
  if [ -f "$BASELINE_FILE" ]; then
    stored_boot_id=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ "$stored_boot_id" = "$current_boot_id" ] && [ "$stored_boot_id" != "unknown_boot" ]; then
      local f_p0 f_p4 f_p7 f_gpu
      f_p0=$(grep "^BASE_P0=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
      f_p4=$(grep "^BASE_P4=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
      f_p7=$(grep "^BASE_P7=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
      f_gpu=$(grep "^BASE_GPU=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)

      if validate_baseline_value "$f_p0" && \
         validate_baseline_value "$f_p4" && \
         validate_baseline_value "$f_p7" && \
         validate_baseline_value "$f_gpu"; then
        BASE_P0="$f_p0"
        BASE_P4="$f_p4"
        BASE_P7="$f_p7"
        BASE_GPU="$f_gpu"
        BASELINE_VALID=1
        write_boot_guard "$current_boot_id"
        command -v log >/dev/null 2>&1 && log "Loaded and verified valid baseline for boot $current_boot_id: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU" "INFO"
        return 0
      else
        command -v log >/dev/null 2>&1 && log "ERROR: Same-boot baseline file $BASELINE_FILE contains invalid frequencies (P0='$f_p0', P4='$f_p4', P7='$f_p7', GPU='$f_gpu'). Rejecting without silent overwrite." "ERROR"
        BASELINE_VALID=0
        return 1
      fi
    else
      command -v log >/dev/null 2>&1 && log "Stale baseline file detected from different boot ($stored_boot_id vs $current_boot_id). Purging." "INFO"
      rm -f "$BASELINE_FILE" 2>/dev/null
    fi
  fi

  # 2. Check boot-scoped guard and active ownership: re-capture forbidden if already initialized this boot
  if is_same_boot_guard_active "$current_boot_id"; then
    command -v log >/dev/null 2>&1 && log "ERROR: Baseline capture refused: boot guard indicates baseline was already established during boot $current_boot_id. Re-capture forbidden to prevent capturing modified frequencies." "ERROR"
    BASELINE_VALID=0
    return 1
  fi

  if has_same_boot_active_ownership "$current_boot_id"; then
    command -v log >/dev/null 2>&1 && log "ERROR: Baseline capture refused: active module ownership or recovery pending recorded for boot $current_boot_id. Re-capture forbidden." "ERROR"
    BASELINE_VALID=0
    return 1
  fi

  # 3. Double-sampling stability and validity check on actual hardware nodes
  local s1_p0 s1_p4 s1_p7 s1_gpu
  local s2_p0 s2_p4 s2_p7 s2_gpu
  s1_p0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  s1_p4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  s1_p7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  s1_gpu=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  if ! validate_baseline_value "$s1_p0" || \
     ! validate_baseline_value "$s1_p4" || \
     ! validate_baseline_value "$s1_p7" || \
     ! validate_baseline_value "$s1_gpu"; then
    command -v log >/dev/null 2>&1 && log "ERROR: Initial frequency sample unreadable or invalid (P0='$s1_p0', P4='$s1_p4', P7='$s1_p7', GPU='$s1_gpu'). Baseline capture aborted." "WARN"
    BASELINE_VALID=0
    return 1
  fi

  if [ -n "$BASELINE_SAMPLE_DELAY" ] && [ "$BASELINE_SAMPLE_DELAY" != "0" ]; then
    sleep "$BASELINE_SAMPLE_DELAY" 2>/dev/null || sleep 1
  fi

  s2_p0=$(cat "$CPU_P0_MAX" 2>/dev/null)
  s2_p4=$(cat "$CPU_P4_MAX" 2>/dev/null)
  s2_p7=$(cat "$CPU_P7_MAX" 2>/dev/null)
  s2_gpu=$(cat "$GPU_MAX_CLK" 2>/dev/null)

  if ! validate_baseline_value "$s2_p0" || \
     ! validate_baseline_value "$s2_p4" || \
     ! validate_baseline_value "$s2_p7" || \
     ! validate_baseline_value "$s2_gpu"; then
    command -v log >/dev/null 2>&1 && log "ERROR: Second frequency sample unreadable or invalid (P0='$s2_p0', P4='$s2_p4', P7='$s2_p7', GPU='$s2_gpu'). Baseline capture aborted." "WARN"
    BASELINE_VALID=0
    return 1
  fi

  if [ "$s1_p0" != "$s2_p0" ] || [ "$s1_p4" != "$s2_p4" ] || [ "$s1_p7" != "$s2_p7" ] || [ "$s1_gpu" != "$s2_gpu" ]; then
    command -v log >/dev/null 2>&1 && log "ERROR: Frequency nodes unstable during baseline capture double-sampling (s1='$s1_p0 $s1_p4 $s1_p7 $s1_gpu', s2='$s2_p0 $s2_p4 $s2_p7 $s2_gpu'). Baseline capture aborted." "WARN"
    BASELINE_VALID=0
    return 1
  fi

  # All 4 samples valid and stable!
  BASE_P0="$s1_p0"
  BASE_P4="$s1_p4"
  BASE_P7="$s1_p7"
  BASE_GPU="$s1_gpu"

  # 4. Atomic write of baseline file
  local tmp_b="${BASELINE_FILE}.tmp.$$"
  cat <<EOF > "$tmp_b" 2>/dev/null
BOOT_ID="$current_boot_id"
BASE_P0="$BASE_P0"
BASE_P4="$BASE_P4"
BASE_P7="$BASE_P7"
BASE_GPU="$BASE_GPU"
EOF
  if [ ! -s "$tmp_b" ]; then
    rm -f "$tmp_b" 2>/dev/null
    command -v log >/dev/null 2>&1 && log "ERROR: Failed to write temporary baseline file $tmp_b." "ERROR"
    BASELINE_VALID=0
    return 1
  fi

  if ! mv -f "$tmp_b" "$BASELINE_FILE" 2>/dev/null; then
    rm -f "$tmp_b" 2>/dev/null
    command -v log >/dev/null 2>&1 && log "ERROR: Failed to move baseline file into place at $BASELINE_FILE." "ERROR"
    BASELINE_VALID=0
    return 1
  fi

  # 5. Atomic write of boot guard file
  if ! write_boot_guard "$current_boot_id"; then
    command -v log >/dev/null 2>&1 && log "ERROR: Failed to write boot guard file $GUARD_FILE. Purging baseline for consistency." "ERROR"
    rm -f "$BASELINE_FILE" 2>/dev/null
    BASELINE_VALID=0
    return 1
  fi

  BASELINE_VALID=1
  command -v log >/dev/null 2>&1 && log "Runtime baseline captured: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU (boot: $current_boot_id)" "INFO"
  return 0
}

# ── Atomic Ownership Records Persistence ──
save_ownership_records() {
  local cur_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")
  mkdir -p "$STATE_DIR" 2>/dev/null
  local tmp_file="${OWNERSHIP_FILE}.tmp.$$"
  cat <<EOF > "$tmp_file"
BOOT_ID="$cur_boot"
RECOVERY_PENDING="$RECOVERY_PENDING"
CURRENT_TIER="$CURRENT_TIER"
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
      RECOVERY_PENDING=0
      CURRENT_TIER=0
      APPLIED_P0="NONE"; READBACK_P0="NONE"; STATUS_P0="BASELINE"
      APPLIED_P4="NONE"; READBACK_P4="NONE"; STATUS_P4="BASELINE"
      APPLIED_P7="NONE"; READBACK_P7="NONE"; STATUS_P7="BASELINE"
      APPLIED_GPU="NONE"; READBACK_GPU="NONE"; STATUS_GPU="BASELINE"
    fi
  fi
}

# ── Original Adaptive Thermal Hysteresis (Tier 0-4) ──
determine_target_tier() {
  local temp="$1"
  local cur="$2"
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

# Map tier to cluster frequencies
get_tier_frequencies() {
  local tier="$1"
  local base_p0="$2" base_p4="$3" base_p7="$4" base_gpu="$5"
  local tp0 tp4 tp7 tgpu

  case "$tier" in
    1)
      tp0="$base_p0"
      tp4=2131200
      tp7=2131200
      tgpu=585000000
      ;;
    2)
      tp0=1632000
      tp4=1920000
      tp7=1920000
      tgpu=499200000
      ;;
    3)
      tp0=1478400
      tp4=1612800
      tp7=1612800
      tgpu=427000000
      ;;
    4)
      tp0=1382400
      tp4=1401600
      tp7=1401600
      tgpu=345000000
      ;;
    *)
      tp0="$base_p0"
      tp4="$base_p4"
      tp7="$base_p7"
      tgpu="$base_gpu"
      ;;
  esac

  tp0=$(clamp_limit "$tp0" "$base_p0")
  tp4=$(clamp_limit "$tp4" "$base_p4")
  tp7=$(clamp_limit "$tp7" "$base_p7")
  tgpu=$(clamp_limit "$tgpu" "$base_gpu")

  echo "$tp0 $tp4 $tp7 $tgpu"
}

# ── Single-Node Thermal Limit Application with Ownership Verification ──
# Corrects Tier 4 -> Tier 3 recovery problem by recognizing current == cur_applied
# as positive evidence of module ownership, permitting upward relaxation during cooldown.
apply_single_node_limit() {
  local node_name="$1"
  local node_path="$2"
  local target="$3"
  local base="$4"
  local cur_applied="$5"
  local cur_boot="$6"
  local stored_boot="$7"

  # 1. Missing node check
  if [ ! -f "$node_path" ]; then
    echo "NODE_MISSING NONE NONE"
    return 1
  fi

  # 2. Boot identity validation
  if [ -z "$cur_boot" ] || [ "$cur_boot" != "$stored_boot" ] || [ "$cur_boot" = "unknown_boot" ]; then
    echo "STALE_BOOT_ID NONE NONE"
    return 1
  fi

  # 3. Read current hardware value
  local cur_val
  cur_val=$(cat "$node_path" 2>/dev/null)
  case "$cur_val" in
    ''|*[!0-9]*)
      echo "UNREADABLE NONE NONE"
      return 1
      ;;
  esac

  # 4. Clamp target to runtime baseline
  target=$(clamp_limit "$target" "$base")

  # 5. Already at target value and verified
  if [ "$cur_val" = "$target" ] && [ "$cur_applied" = "$target" ]; then
    echo "ALREADY_APPLIED $target $cur_val"
    return 0
  fi

  # ── OWNERSHIP EVALUATION ──
  local has_module_ownership=0
  if [ -n "$cur_applied" ] && [ "$cur_applied" != "NONE" ] && [ "$cur_val" = "$cur_applied" ]; then
    # Case A: Current hardware value strictly matches what this module applied!
    # Positive evidence of ownership: module set this cap and may safely transition it,
    # including relaxing/raising the frequency when temperature cools down.
    has_module_ownership=1
  fi

  if [ "$has_module_ownership" -eq 1 ]; then
    # Safely apply new target
    echo "$target" > "$node_path" 2>/dev/null
    local readback
    readback=$(cat "$node_path" 2>/dev/null)
    if [ "$readback" = "$target" ]; then
      echo "APPLIED_VERIFIED $target $readback"
      return 0
    elif [ -n "$readback" ] && [ "$readback" -lt "$target" ] 2>/dev/null; then
      # Write was clamped below target by vendor!
      if [ "$readback" = "$cur_applied" ]; then
        # Rule 1: Retain previous trusted module ownership record because it remains
        # valid evidence of ownership (node stayed at cur_applied).
        echo "VENDOR_CLAMPED $cur_applied $readback"
      else
        # Rule 2: Unexplained lower read-back (readback != cur_applied).
        # Do NOT promote unexplained lower read-back to APPLIED!
        echo "VENDOR_CLAMPED NONE $readback"
      fi
      return 0
    else
      echo "WRITE_FAILED NONE $readback"
      return 1
    fi
  fi

  # Current value does NOT match cur_applied.
  # Case B: Current is LOWER than target
  if [ "$cur_val" -lt "$target" ]; then
    # Current frequency is lower than requested target, and not owned by our cur_applied.
    # Treat as external vendor limit: preserve it and never raise it!
    # Do NOT promote cur_val to APPLIED. APPLIED is NONE.
    echo "VENDOR_LOWER_PRESERVED NONE $cur_val"
    return 0
  fi

  # Case C: Current is at baseline, and module requests throttling ($target < $base)
  if [ "$cur_val" = "$base" ]; then
    if [ "$target" = "$base" ]; then
      echo "ALREADY_BASELINE $base $cur_val"
      return 0
    fi
    echo "$target" > "$node_path" 2>/dev/null
    local readback
    readback=$(cat "$node_path" 2>/dev/null)
    if [ "$readback" = "$target" ]; then
      echo "APPLIED_VERIFIED $target $readback"
      return 0
    elif [ -n "$readback" ] && [ "$readback" -lt "$target" ] 2>/dev/null; then
      # Initial baseline-to-target write is clamped below target.
      # cur_applied was NONE / baseline. We did NOT apply readback.
      # Do NOT promote unexplained lower readback to APPLIED!
      echo "VENDOR_CLAMPED NONE $readback"
      return 0
    else
      echo "WRITE_FAILED NONE $readback"
      return 1
    fi
  fi

  # Case D: Current is between cur_applied and base, or an unrelated value
  # External controller modified the node. Ownership uncertain -> fail closed!
  echo "OWNERSHIP_UNCERTAIN NONE $cur_val"
  return 1
}

# ── Single-Node Restoration Decision with Ownership Verification ──
restore_single_node_baseline() {
  local node_name="$1"
  local node_path="$2"
  local base="$3"
  local applied="$4"
  local cur_boot="$5"
  local stored_boot="$6"
  local last_status="${7:-BASELINE}"

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
    echo "ALREADY_BASELINE $cur_val"
    return 0
  fi

  # 5. Check module ownership
  case "$applied" in
    ''|'NONE'|*[!0-9]*)
      if [ "$last_status" = "VENDOR_CLAMPED" ] || [ "$last_status" = "VENDOR_LOWER_PRESERVED" ] || [ "$last_status" = "SAFE_EXTERNAL_LIMIT_PRESERVED" ] || [ "$last_status" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
        if [ "$cur_val" -lt "$base" ] 2>/dev/null; then
          # Never write baseline or probe unowned clamp! Preserve external limit exactly.
          echo "SAFE_EXTERNAL_LIMIT_PRESERVED $cur_val"
          return 0
        fi
      fi
      # Otherwise, external controller set an unrelated value without module involvement:
      echo "OWNERSHIP_UNCERTAIN $cur_val"
      return 1
      ;;
  esac

  if [ "$applied" -eq "$base" ]; then
    echo "OWNERSHIP_UNCERTAIN $cur_val"
    return 1
  fi

  # 6. Compare current against module applied value
  if [ "$cur_val" -lt "$applied" ]; then
    # Current is lower than module applied value -> vendor limit preserved
    echo "SAFE_EXTERNAL_LIMIT_PRESERVED $cur_val"
    return 0
  elif [ "$cur_val" -eq "$applied" ]; then
    # Current strictly matches applied -> restore baseline
    echo "$base" > "$node_path" 2>/dev/null
    local readback
    readback=$(cat "$node_path" 2>/dev/null)
    if [ "$readback" = "$base" ]; then
      echo "RESTORED_VERIFIED $readback"
      return 0
    elif [ -n "$readback" ] && [ "$readback" -lt "$base" ] 2>/dev/null; then
      echo "PARTIAL_RESTORE_VENDOR_CLAMP $readback"
      return 0
    else
      echo "RESTORE_FAILED $readback"
      return 1
    fi
  else
    # Current is unrelated or higher than applied -> ownership uncertain
    echo "OWNERSHIP_UNCERTAIN $cur_val"
    return 1
  fi
}

# ── Multi-Cluster Restoration Aggregator & Recovery State ──
restore_hardware_baseline() {
  local reason="${1:-USER_TRANSITION}"
  local cur_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")

  load_ownership_records

  # Strictly require valid baseline for current boot; NEVER call capture_baseline_frequencies() during restoration!
  if ! validate_baseline_integrity; then
    RECOVERY_PENDING=1
    save_ownership_records
    command -v log >/dev/null 2>&1 && log "ERROR: Cannot restore hardware baseline: baseline missing, invalid, or stale boot ID (reason: $reason). Zero sysfs writes performed; recovery remains pending." "ERROR"
    return 1
  fi

  local stored_boot=""
  if [ -f "$BASELINE_FILE" ]; then
    stored_boot=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
  fi

  local res_p0 res_p4 res_p7 res_gpu
  res_p0=$(restore_single_node_baseline "CPU_P0" "$CPU_P0_MAX" "$BASE_P0" "$APPLIED_P0" "$cur_boot" "$stored_boot" "$STATUS_P0")
  res_p4=$(restore_single_node_baseline "CPU_P4" "$CPU_P4_MAX" "$BASE_P4" "$APPLIED_P4" "$cur_boot" "$stored_boot" "$STATUS_P4")
  res_p7=$(restore_single_node_baseline "CPU_P7" "$CPU_P7_MAX" "$BASE_P7" "$APPLIED_P7" "$cur_boot" "$stored_boot" "$STATUS_P7")
  res_gpu=$(restore_single_node_baseline "GPU" "$GPU_MAX_CLK" "$BASE_GPU" "$APPLIED_GPU" "$cur_boot" "$stored_boot" "$STATUS_GPU")

  local stat_p0 val_p0 stat_p4 val_p4 stat_p7 val_p7 stat_gpu val_gpu
  stat_p0=$(echo "$res_p0" | awk '{print $1}')
  val_p0=$(echo "$res_p0" | awk '{print $2}')
  stat_p4=$(echo "$res_p4" | awk '{print $1}')
  val_p4=$(echo "$res_p4" | awk '{print $2}')
  stat_p7=$(echo "$res_p7" | awk '{print $1}')
  val_p7=$(echo "$res_p7" | awk '{print $2}')
  stat_gpu=$(echo "$res_gpu" | awk '{print $1}')
  val_gpu=$(echo "$res_gpu" | awk '{print $2}')

  # Update per-node ownership status
  STATUS_P0="$stat_p0"
  if [ "$stat_p0" = "RESTORED_VERIFIED" ] || [ "$stat_p0" = "ALREADY_BASELINE" ]; then
    STATUS_P0="BASELINE"; APPLIED_P0="NONE"; READBACK_P0="$val_p0"
  elif [ "$stat_p0" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_p0" = "SAFE_EXTERNAL_LIMIT_PRESERVED" ] || [ "$stat_p0" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    STATUS_P0="$stat_p0"; APPLIED_P0="NONE"; READBACK_P0="$val_p0"
  else
    READBACK_P0="$val_p0"
  fi

  STATUS_P4="$stat_p4"
  if [ "$stat_p4" = "RESTORED_VERIFIED" ] || [ "$stat_p4" = "ALREADY_BASELINE" ]; then
    STATUS_P4="BASELINE"; APPLIED_P4="NONE"; READBACK_P4="$val_p4"
  elif [ "$stat_p4" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_p4" = "SAFE_EXTERNAL_LIMIT_PRESERVED" ] || [ "$stat_p4" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    STATUS_P4="$stat_p4"; APPLIED_P4="NONE"; READBACK_P4="$val_p4"
  else
    READBACK_P4="$val_p4"
  fi

  STATUS_P7="$stat_p7"
  if [ "$stat_p7" = "RESTORED_VERIFIED" ] || [ "$stat_p7" = "ALREADY_BASELINE" ]; then
    STATUS_P7="BASELINE"; APPLIED_P7="NONE"; READBACK_P7="$val_p7"
  elif [ "$stat_p7" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_p7" = "SAFE_EXTERNAL_LIMIT_PRESERVED" ] || [ "$stat_p7" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    STATUS_P7="$stat_p7"; APPLIED_P7="NONE"; READBACK_P7="$val_p7"
  else
    READBACK_P7="$val_p7"
  fi

  STATUS_GPU="$stat_gpu"
  if [ "$stat_gpu" = "RESTORED_VERIFIED" ] || [ "$stat_gpu" = "ALREADY_BASELINE" ]; then
    STATUS_GPU="BASELINE"; APPLIED_GPU="NONE"; READBACK_GPU="$val_gpu"
  elif [ "$stat_gpu" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_gpu" = "SAFE_EXTERNAL_LIMIT_PRESERVED" ] || [ "$stat_gpu" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    STATUS_GPU="$stat_gpu"; APPLIED_GPU="NONE"; READBACK_GPU="$val_gpu"
  else
    READBACK_GPU="$val_gpu"
  fi

  # Classify overall recovery state
  local fully_restored=1
  local safe_vendor=0
  local has_failure=0

  for st in "$stat_p0" "$stat_p4" "$stat_p7" "$stat_gpu"; do
    case "$st" in
      RESTORED_VERIFIED|ALREADY_BASELINE)
        ;;
      VENDOR_LOWER_PRESERVED|SAFE_EXTERNAL_LIMIT_PRESERVED|PARTIAL_RESTORE_VENDOR_CLAMP)
        fully_restored=0
        safe_vendor=1
        ;;
      RESTORE_FAILED|OWNERSHIP_UNCERTAIN|STALE_BOOT_ID|UNREADABLE|INVALID_BASELINE|NODE_MISSING|*)
        fully_restored=0
        has_failure=1
        ;;
    esac
  done

  local aggregate_outcome="FULL_BASELINE_RESTORED"
  if [ "$has_failure" -eq 1 ]; then
    aggregate_outcome="PARTIAL_RESTORE_WARNING"
    RECOVERY_PENDING=1
    # Do NOT set CURRENT_TIER=0 unconditionally if restoration failed
  elif [ "$safe_vendor" -eq 1 ]; then
    aggregate_outcome="SAFE_EXTERNAL_LIMITS_PRESERVED"
    CURRENT_TIER=0
    RECOVERY_PENDING=0
  else
    aggregate_outcome="FULL_BASELINE_RESTORED"
    CURRENT_TIER=0
    RECOVERY_PENDING=0
  fi

  save_ownership_records

  if [ "$aggregate_outcome" = "FULL_BASELINE_RESTORED" ]; then
    command -v log >/dev/null 2>&1 && log "Hardware restoration complete ($aggregate_outcome, reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu)." "INFO"
    return 0
  elif [ "$aggregate_outcome" = "SAFE_EXTERNAL_LIMITS_PRESERVED" ]; then
    command -v log >/dev/null 2>&1 && log "Hardware safe limits preserved ($aggregate_outcome, reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu)." "INFO"
    return 0
  else
    command -v log >/dev/null 2>&1 && log "Hardware restoration warning ($aggregate_outcome, reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu). Recovery remains pending." "WARN"
    return 1
  fi
}
