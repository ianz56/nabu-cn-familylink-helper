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
  if command -v restore_hardware_baseline >/dev/null 2>&1; then
    restore_hardware_baseline "DAEMON_SHUTDOWN"
    restore_rc=$?
    if [ "$restore_rc" -ne 0 ]; then
      if command -v log >/dev/null 2>&1; then
        log "WARNING: Hardware restoration during shutdown had partial warning (RECOVERY_PENDING=$RECOVERY_PENDING)." "WARN"
      fi
    fi
  fi

  # 2. Unlink PID file ONLY after restoration finishes
  if [ -n "$PID_FILE" ] && [ -f "$PID_FILE" ]; then
    rm -f "$PID_FILE" 2>/dev/null || true
  fi

  if command -v log >/dev/null 2>&1; then
    log "Production daemon cleanup completed successfully. Exiting." "INFO"
  fi

  exit 0
}

# ── Signal Trap Registration ──
setup_daemon_signals() {
  CLEANUP_RUNNING=0
  trap production_cleanup_on_exit EXIT INT TERM HUP
}
