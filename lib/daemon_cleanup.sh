#!/system/bin/sh
# Nabu DerpFest 17 Helper — Production Daemon Cleanup Library
# ==========================================================
# Reusable, sourceable POSIX shell library for graceful daemon shutdown,
# signal trapping, hardware baseline restoration, and PID file cleanup.

: "${PID_FILE:=/data/adb/modules/nabu-derpfest-helper/auto_switch.pid}"
: "${LOG_FILE:=/data/adb/modules/nabu-derpfest-helper/auto_switch.log}"

CLEANUP_RUNNING=0

# ── Production Cleanup Handler ──
# Handles SIGTERM, SIGINT, SIGHUP, and process EXIT.
# Idempotent: protected by CLEANUP_RUNNING recursion guard.
# Unlinks PID file ONLY after hardware restoration completes.
production_cleanup_on_exit() {
  if [ "$CLEANUP_RUNNING" -eq 1 ]; then
    return 0
  fi
  CLEANUP_RUNNING=1
  trap - EXIT INT TERM HUP

  if command -v log >/dev/null 2>&1; then
    log "Shutdown signal received; initiating production hardware cleanup..." "INFO"
  fi

  # 1. Restore hardware baseline using production thermal engine
  local restore_rc=0
  local has_thermal_fn=1
  if command -v restore_hardware_baseline >/dev/null 2>&1; then
    restore_rc=0
    restore_hardware_baseline "DAEMON_SHUTDOWN" || restore_rc=$?
  else
    has_thermal_fn=0
    restore_rc=1
    RECOVERY_PENDING=1
  fi

  # 2. Check outcome: must check BOTH restore_rc and RECOVERY_PENDING
  local cleanup_success=0
  if [ "$has_thermal_fn" -eq 1 ] && [ "$restore_rc" -eq 0 ] && [ "${RECOVERY_PENDING:-0}" -eq 0 ]; then
    cleanup_success=1
  fi

  # 3. Log appropriate outcome
  if [ "$cleanup_success" -eq 1 ]; then
    if command -v log >/dev/null 2>&1; then
      log "CLEANUP_SUCCESS: Production daemon cleanup completed successfully (baseline restored or safe external limits preserved)." "INFO"
    fi
  else
    if command -v log >/dev/null 2>&1; then
      if [ "$has_thermal_fn" -eq 0 ]; then
        log "CLEANUP_RECOVERY_PENDING: restore_hardware_baseline function unavailable; hardware restoration incomplete during shutdown." "WARN"
      else
        log "CLEANUP_RECOVERY_PENDING: Hardware baseline restoration incomplete during shutdown (rc=$restore_rc, RECOVERY_PENDING=${RECOVERY_PENDING:-1}, P0=${STATUS_P0:-UNKNOWN}/${READBACK_P0:-NONE}, P4=${STATUS_P4:-UNKNOWN}/${READBACK_P4:-NONE}, P7=${STATUS_P7:-UNKNOWN}/${READBACK_P7:-NONE}, GPU=${STATUS_GPU:-UNKNOWN}/${READBACK_GPU:-NONE})." "WARN"
      fi
    fi
  fi

  # 4. Unlink PID file ONLY after restoration finishes
  if [ -n "$PID_FILE" ] && [ -f "$PID_FILE" ]; then
    rm -f "$PID_FILE" 2>/dev/null || true
  fi

  exit 0
}

# ── Signal Trap Registration ──
setup_daemon_signals() {
  CLEANUP_RUNNING=0
  trap production_cleanup_on_exit EXIT INT TERM HUP
}
