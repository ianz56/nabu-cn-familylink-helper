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

# ── Source Reusable Production Engines ──
LIB_DIR="$MODDIR/lib"
if [ -f "$LIB_DIR/thermal_engine.sh" ]; then
  . "$LIB_DIR/thermal_engine.sh"
else
  log "FATAL: lib/thermal_engine.sh not found at $LIB_DIR/thermal_engine.sh" "ERROR"
  exit 1
fi

if [ -f "$LIB_DIR/lifecycle_engine.sh" ]; then
  . "$LIB_DIR/lifecycle_engine.sh"
else
  log "FATAL: lib/lifecycle_engine.sh not found at $LIB_DIR/lifecycle_engine.sh" "ERROR"
  exit 1
fi

if [ -f "$LIB_DIR/daemon_cleanup.sh" ]; then
  . "$LIB_DIR/daemon_cleanup.sh"
else
  log "FATAL: lib/daemon_cleanup.sh not found at $LIB_DIR/daemon_cleanup.sh" "ERROR"
  exit 1
fi

# ── Singleton Process Management & Trap Registration ──
MY_PID="$$"
echo "$MY_PID" > "$PID_FILE" 2>/dev/null || true
setup_daemon_signals

# ── Daemon-Level Thermal Application Wrapper ──
apply_adaptive_thermal() {
  # Baseline must be strictly valid before any thermal enforcement or node evaluation
  if [ "${BASELINE_VALID:-0}" -ne 1 ] || ! validate_baseline_integrity; then
    BASELINE_VALID=0
    return 0
  fi

  # Dynamic runtime sensor recovery: if disabled or path lost, attempt revalidation
  if [ "$THERMAL_ENABLED" -eq 0 ] || [ -z "$THERMAL_ZONE_PATH" ]; then
    find_thermal_sensor || return 0
  fi

  local raw_temp
  raw_temp=$(sample_thermal_sensor "$THERMAL_ZONE_PATH")
  local sample_rc=$?

  if [ "$sample_rc" -ne 0 ]; then
    log "Adaptive thermal sensor sample invalid ($raw_temp) at $THERMAL_ZONE_PATH. Disabling thermal enforcement and restoring hardware baseline." "WARN"
    THERMAL_ENABLED=0
    THERMAL_ZONE_PATH=""
    restore_hardware_baseline "SENSOR_SAMPLE_INVALID"
    return 1
  fi

  local target_tier
  target_tier=$(determine_target_tier "$raw_temp" "$CURRENT_TIER")

  if [ "$target_tier" -eq 0 ]; then
    if [ "$CURRENT_TIER" -ne 0 ] || [ "$RECOVERY_PENDING" -eq 1 ]; then
      restore_hardware_baseline "TIER_0_RESTORE"
    fi
    return 0
  fi

  local cur_boot stored_boot
  cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown_boot")
  stored_boot=""
  [ -f "$BASELINE_FILE" ] && stored_boot=$(grep "^BOOT_ID=" "$BASELINE_FILE" 2>/dev/null | cut -d'"' -f2)

  local freqs
  freqs=$(get_tier_frequencies "$target_tier" "$BASE_P0" "$BASE_P4" "$BASE_P7" "$BASE_GPU")
  local target_p0 target_p4 target_p7 target_gpu
  target_p0=$(echo "$freqs" | awk '{print $1}')
  target_p4=$(echo "$freqs" | awk '{print $2}')
  target_p7=$(echo "$freqs" | awk '{print $3}')
  target_gpu=$(echo "$freqs" | awk '{print $4}')

  load_ownership_records

  local res_p0 res_p4 res_p7 res_gpu
  res_p0=$(apply_single_node_limit "CPU_P0" "$CPU_P0_MAX" "$target_p0" "$BASE_P0" "$APPLIED_P0" "$cur_boot" "$stored_boot")
  res_p4=$(apply_single_node_limit "CPU_P4" "$CPU_P4_MAX" "$target_p4" "$BASE_P4" "$APPLIED_P4" "$cur_boot" "$stored_boot")
  res_p7=$(apply_single_node_limit "CPU_P7" "$CPU_P7_MAX" "$target_p7" "$BASE_P7" "$APPLIED_P7" "$cur_boot" "$stored_boot")
  res_gpu=$(apply_single_node_limit "GPU" "$GPU_MAX_CLK" "$target_gpu" "$BASE_GPU" "$APPLIED_GPU" "$cur_boot" "$stored_boot")

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

# ── Daemon Initialization ──
log "Auto-switch daemon started (version=v3.2.0, timeout=${TIMEOUT}s, target=DYNAMIC_MULTI_USER, LIVE_EXECUTION=ENABLED)" "INFO"

find_thermal_sensor
if capture_baseline_frequencies; then
  BASELINE_VALID=1
  log "Hardware baseline captured and validated successfully (P0=$BASE_P0, P4=$BASE_P4, P7=$BASE_P7, GPU=$BASE_GPU)." "INFO"
else
  BASELINE_VALID=0
  THERMAL_ENABLED=0
  log "WARNING: Hardware baseline validation failed during startup. Adaptive thermal enforcement disabled for system safety. Multi-user lifecycle management remains active." "WARN"
fi

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
    # Ensure baseline is intact or retry pending recovery
    if [ "$CURRENT_TIER" -ne 0 ] || [ "$RECOVERY_PENDING" -eq 1 ]; then
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
              b_res=$(execute_scenario_b_user_stop "$target_uid" "$STOP_TRANSITION_TIMEOUT")
              log "[Scenario B] Action result for user $target_uid: $b_res" "INFO"

              case "$b_res" in
                ABORT_DISPLAY_ON)
                  log "[Scenario B] Display turned ON during batch stop; aborting remaining targets" "INFO"
                  break
                  ;;
                ABORT_FG_CHANGED)
                  log "[Scenario B] Foreground user changed during batch stop; aborting remaining targets" "INFO"
                  break
                  ;;
                FAIL_CLOSED_UNKNOWN_STATE|STOPPING_UNKNOWN_STATE|STOP_UNKNOWN_STATE)
                  log "[Scenario B] ABORT: Target user $target_uid entered UNKNOWN state ($b_res). Aborting batch stop for system safety." "WARN"
                  break
                  ;;
              esac
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
          log "[Scenario A] Deadline reached (elapsed=${ELAPSED}s >= ${TIMEOUT}s) — executing switch and stop..." "INFO"
          TARGET_TO_STOP="$CURRENT_USER"

          a_res=$(execute_scenario_a_user_stop "$TARGET_TO_STOP" "$SWITCH_WAIT_TIMEOUT" "$STOP_TRANSITION_TIMEOUT")
          log "[Scenario A] Result for user $TARGET_TO_STOP: $a_res" "INFO"

          if [ "$(get_current_user)" -eq 0 ]; then
            LAST_USER="0"
            restore_hardware_baseline "USER_0_RESTORED_POST_SWITCH"
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
