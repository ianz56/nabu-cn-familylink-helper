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

# ── In-Memory State Variables ──
THERMAL_ENABLED=0
THERMAL_ZONE_PATH=""
THERMAL_ZONE_TYPE=""
CURRENT_TIER=0
RECOVERY_PENDING=0

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

# ── Sensor Resolution & Plausibility Validation ──
# On Xiaomi Pad 5 (nabu), quiet_therm is calibrated for external surface/skin temperature.
# Fallback semantics:
# - cpu_therm: measures SoC junction/die temp (typically 15-30°C higher than skin).
#   Applying skin 36-42°C thresholds to cpu_therm would cause perpetual unwarranted throttling.
# - battery: measures battery pack with high thermal inertia and lower max safe limits.
# - xo_therm: measures crystal oscillator temperature.
# Policy: If quiet_therm is absent, do not silently apply the skin curve to mismatched thermistors.
# Disable adaptive thermal safely unless a validated sensor is resolved.
find_thermal_sensor() {
  local cand tz t_type t_temp
  for tz in /sys/class/thermal/thermal_zone*; do
    if [ -f "$tz/type" ] && [ -f "$tz/temp" ]; then
      t_type=$(cat "$tz/type" 2>/dev/null)
      if [ "$t_type" = "quiet_therm" ]; then
        t_temp=$(cat "$tz/temp" 2>/dev/null)
        case "$t_temp" in
          ''|*[!0-9]*) continue ;;
        esac
        # Plausible skin range: 15°C to 65°C (15000 to 65000 m°C)
        if [ "$t_temp" -ge 15000 ] && [ "$t_temp" -le 65000 ]; then
          THERMAL_ZONE_PATH="$tz"
          THERMAL_ZONE_TYPE="quiet_therm"
          THERMAL_ENABLED=1
          [ "$(type log 2>/dev/null)" = "function" ] && log "Validated skin thermal sensor: $tz (quiet_therm, temp=${t_temp}mC)" "INFO"
          return 0
        fi
      fi
    fi
  done

  # Fallback investigation: log presence but refuse silent curve mismatch
  for cand in cpu_therm battery xo_therm; do
    for tz in /sys/class/thermal/thermal_zone*; do
      if [ -f "$tz/type" ] && [ "$(cat "$tz/type" 2>/dev/null)" = "$cand" ]; then
        [ "$(type log 2>/dev/null)" = "function" ] && log "Notice: Sensor '$cand' detected at $tz, but skin-curve thresholds (36-42°C) are incompatible. Adaptive thermal disabled for safety." "WARN"
      fi
    done
  done

  THERMAL_ENABLED=0
  [ "$(type log 2>/dev/null)" = "function" ] && log "WARNING: Validated skin thermal sensor (quiet_therm) unavailable. Adaptive thermal disabled." "WARN"
  return 1
}

# ── Runtime Baseline Capture (Per-Boot Identity Enforced) ──
capture_baseline_frequencies() {
  local current_boot_id stored_boot_id
  current_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")

  mkdir -p "$STATE_DIR" 2>/dev/null

  # Verify existing baseline file against current boot UUID
  if [ -f "$BASELINE_FILE" ]; then
    stored_boot_id=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
    if [ "$stored_boot_id" = "$current_boot_id" ] && [ "$stored_boot_id" != "unknown_boot" ]; then
      . "$BASELINE_FILE"
      if [ -n "$BASE_P0" ] && [ -n "$BASE_P4" ] && [ -n "$BASE_P7" ] && [ -n "$BASE_GPU" ]; then
        [ "$(type log 2>/dev/null)" = "function" ] && log "Loaded valid baseline for boot $current_boot_id: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU" "INFO"
        return 0
      fi
    else
      [ "$(type log 2>/dev/null)" = "function" ] && log "Stale baseline file detected from different boot ($stored_boot_id vs $current_boot_id). Purging." "INFO"
      rm -f "$BASELINE_FILE"
    fi
  fi

  # Double-sampling stability check
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

    local tmp_b="${BASELINE_FILE}.tmp.$$"
    cat <<EOF > "$tmp_b"
BOOT_ID="$current_boot_id"
BASE_P0="$BASE_P0"
BASE_P4="$BASE_P4"
BASE_P7="$BASE_P7"
BASE_GPU="$BASE_GPU"
EOF
    mv -f "$tmp_b" "$BASELINE_FILE" 2>/dev/null || rm -f "$tmp_b" 2>/dev/null
    [ "$(type log 2>/dev/null)" = "function" ] && log "Runtime baseline captured: P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU (boot: $current_boot_id)" "INFO"
    return 0
  fi

  [ "$(type log 2>/dev/null)" = "function" ] && log "ERROR: Frequency nodes unstable or unreadable during baseline capture. Deferring." "WARN"
  return 1
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
      echo "VENDOR_CLAMPED $readback $readback"
      return 0
    else
      echo "WRITE_FAILED $cur_applied $readback"
      return 1
    fi
  fi

  # Current value does NOT match cur_applied.
  # Case B: Current is LOWER than target
  if [ "$cur_val" -lt "$target" ]; then
    # Current frequency is lower than requested target, and not owned by our cur_applied.
    # Treat as external vendor limit: preserve it and never raise it!
    echo "VENDOR_LOWER_PRESERVED $cur_applied $cur_val"
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
      echo "VENDOR_CLAMPED $readback $readback"
      return 0
    else
      echo "WRITE_FAILED $cur_applied $readback"
      return 1
    fi
  fi

  # Case D: Current is between cur_applied and base, or an unrelated value
  # External controller modified the node. Ownership uncertain -> fail closed!
  echo "OWNERSHIP_UNCERTAIN $cur_applied $cur_val"
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
      # Module never applied a cap or has no record of having throttled this node.
      # But cur_val != base. An external controller or vendor set cur_val.
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
    echo "VENDOR_LOWER_PRESERVED $cur_val"
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

  local stored_boot=""
  if [ -f "$BASELINE_FILE" ]; then
    stored_boot=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)
  fi

  if [ -z "$BASE_P0" ] || [ -z "$BASE_P4" ] || [ -z "$BASE_P7" ] || [ -z "$BASE_GPU" ]; then
    capture_baseline_frequencies || {
      [ "$(type log 2>/dev/null)" = "function" ] && log "WARNING: Cannot restore hardware baseline: baseline capture unreadable." "WARN"
      RECOVERY_PENDING=1
      return 1
    }
    stored_boot="$cur_boot"
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

  # Update per-node ownership status
  STATUS_P0="$stat_p0"
  if [ "$stat_p0" = "RESTORED_VERIFIED" ] || [ "$stat_p0" = "ALREADY_BASELINE" ]; then
    APPLIED_P0="NONE"; READBACK_P0="$val_p0"
  elif [ "$stat_p0" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_p0" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    READBACK_P0="$val_p0"
  fi

  STATUS_P4="$stat_p4"
  if [ "$stat_p4" = "RESTORED_VERIFIED" ] || [ "$stat_p4" = "ALREADY_BASELINE" ]; then
    APPLIED_P4="NONE"; READBACK_P4="$val_p4"
  elif [ "$stat_p4" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_p4" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    READBACK_P4="$val_p4"
  fi

  STATUS_P7="$stat_p7"
  if [ "$stat_p7" = "RESTORED_VERIFIED" ] || [ "$stat_p7" = "ALREADY_BASELINE" ]; then
    APPLIED_P7="NONE"; READBACK_P7="$val_p7"
  elif [ "$stat_p7" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_p7" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
    READBACK_P7="$val_p7"
  fi

  STATUS_GPU="$stat_gpu"
  if [ "$stat_gpu" = "RESTORED_VERIFIED" ] || [ "$stat_gpu" = "ALREADY_BASELINE" ]; then
    APPLIED_GPU="NONE"; READBACK_GPU="$val_gpu"
  elif [ "$stat_gpu" = "VENDOR_LOWER_PRESERVED" ] || [ "$stat_gpu" = "PARTIAL_RESTORE_VENDOR_CLAMP" ]; then
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
      VENDOR_LOWER_PRESERVED|PARTIAL_RESTORE_VENDOR_CLAMP)
        fully_restored=0
        safe_vendor=1
        ;;
      RESTORE_FAILED|OWNERSHIP_UNCERTAIN|STALE_BOOT_ID|UNREADABLE|INVALID_BASELINE|NODE_MISSING)
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
    [ "$(type log 2>/dev/null)" = "function" ] && log "Hardware restoration complete ($aggregate_outcome, reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu)." "INFO"
    return 0
  elif [ "$aggregate_outcome" = "SAFE_EXTERNAL_LIMITS_PRESERVED" ]; then
    [ "$(type log 2>/dev/null)" = "function" ] && log "Hardware safe limits preserved ($aggregate_outcome, reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu)." "INFO"
    return 0
  else
    [ "$(type log 2>/dev/null)" = "function" ] && log "Hardware restoration warning ($aggregate_outcome, reason: $reason, P0=$stat_p0/$val_p0, P4=$stat_p4/$val_p4, P7=$stat_p7/$val_p7, GPU=$stat_gpu/$val_gpu). Recovery remains pending." "WARN"
    return 1
  fi
}
