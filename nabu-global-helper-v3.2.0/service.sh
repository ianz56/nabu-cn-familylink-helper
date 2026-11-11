#!/system/bin/sh
# Nabu DerpFest 17 Helper — Late-Start Service (v3.2.0)
# =====================================================
# Executes on boot completion under KernelSU late-start service trigger.
# Enforces strict daemon process identity verification, bounded graceful shutdown,
# native stop-on-switch policy, and launches auto_switch daemon singleton safely.

MODDIR="${0%/*}"
LOG_FILE="$MODDIR/service.log"
PID_FILE="$MODDIR/auto_switch.pid"
DAEMON_SCRIPT="$MODDIR/auto_switch.sh"
GRACEFUL_SHUTDOWN_TIMEOUT=5

log() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'BOOT')"
  echo "$timestamp [INFO] $1" >> "$LOG_FILE"
}

log_err() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'BOOT')"
  echo "$timestamp [ERROR] $1" >> "$LOG_FILE"
}

# 1. Wait for Android Boot Completion
log "Nabu DerpFest Helper service started (version=v3.2.0), waiting for boot_completed..."
BOOT_WAIT=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  sleep 2
  BOOT_WAIT=$((BOOT_WAIT + 2))
  if [ "$BOOT_WAIT" -ge 120 ]; then
    log_err "Timeout waiting for sys.boot_completed (120s). Aborting startup."
    exit 1
  fi
done
log "Boot completed after ~${BOOT_WAIT}s."

# 2. Configure Native Stop-On-Switch Policy
log "Applying native stop-on-switch policy..."
STOP_ON_SWITCH_OUT=$(cmd activity set-stop-user-on-switch true 2>&1)
STOP_ON_SWITCH_RC=$?

if [ "$STOP_ON_SWITCH_RC" -eq 0 ]; then
  VERIFY_STATE=$(dumpsys activity users 2>/dev/null | grep -i "mStopUserOnSwitch" | head -n 1 | tr -d '[:space:]')
  log "Native stop-on-switch applied successfully: '$STOP_ON_SWITCH_OUT' (State: $VERIFY_STATE)"
else
  log_err "Failed to execute 'cmd activity set-stop-user-on-switch true' (rc=$STOP_ON_SWITCH_RC, out='$STOP_ON_SWITCH_OUT')"
fi

# 3. Strict Identity Verification & Graceful Daemon Singleton Management
terminate_existing_daemon() {
  if [ ! -f "$PID_FILE" ]; then
    return 0
  fi

  local old_pid
  old_pid=$(cat "$PID_FILE" 2>/dev/null)

  # Validate numeric positive PID > 1
  case "$old_pid" in
    ''|*[!0-9]*)
      log "Warning: Stale PID file contained non-numeric value '$old_pid'. Purging."
      rm -f "$PID_FILE" 2>/dev/null
      return 0
      ;;
  esac

  if [ "$old_pid" -le 1 ]; then
    log "Warning: Stale PID file contained protected PID '$old_pid'. Purging."
    rm -f "$PID_FILE" 2>/dev/null
    return 0
  fi

  # Check if process is alive
  if [ ! -d "/proc/$old_pid" ]; then
    log "Stale PID file found (PID $old_pid is not running). Purging."
    rm -f "$PID_FILE" 2>/dev/null
    return 0
  fi

  # Strict cmdline identity verification against exact canonical module path
  local canonical_script
  canonical_script="$(readlink -f "$DAEMON_SCRIPT" 2>/dev/null || echo "$DAEMON_SCRIPT")"

  local is_match=0
  for arg in $(tr '\0' '\n' < "/proc/$old_pid/cmdline" 2>/dev/null); do
    if [ "$arg" = "$DAEMON_SCRIPT" ] || [ "$arg" = "$canonical_script" ]; then
      is_match=1
      break
    fi
  done

  if [ "$is_match" -ne 1 ]; then
    log_err "PID $old_pid is active but its command line does not match $DAEMON_SCRIPT. PID reuse detected! Refusing to signal foreign process."
    rm -f "$PID_FILE" 2>/dev/null
    return 0
  fi

  # Verified daemon process: request graceful shutdown via SIGTERM
  log "Found active verified daemon instance (PID: $old_pid). Requesting graceful termination (SIGTERM)..."
  kill -TERM "$old_pid" 2>/dev/null || true

  local waited=0
  while [ "$waited" -lt "$GRACEFUL_SHUTDOWN_TIMEOUT" ]; do
    sleep 1
    waited=$((waited + 1))
    if [ ! -d "/proc/$old_pid" ]; then
      log "Previous daemon (PID: $old_pid) exited gracefully after ~${waited}s."
      rm -f "$PID_FILE" 2>/dev/null
      return 0
    fi
  done

  # Process failed to terminate gracefully — DO NOT send SIGKILL, DO NOT spawn competing daemon
  log_err "CRITICAL: Previous daemon (PID: $old_pid) failed to exit gracefully within ${GRACEFUL_SHUTDOWN_TIMEOUT}s."
  log_err "Startup aborted: Refusing to send SIGKILL or launch competing second daemon."
  return 1
}

if ! terminate_existing_daemon; then
  log_err "Singleton pre-flight failed. Service startup aborted to protect system stability."
  exit 1
fi

# 4. Launch Auto-Switch & Thermal Daemon
if [ -f "$DAEMON_SCRIPT" ]; then
  chmod 0755 "$DAEMON_SCRIPT"
  nohup sh "$DAEMON_SCRIPT" >> "$LOG_FILE" 2>&1 &
  NEW_PID=$!
  log "Auto-switch & thermal daemon launched (PID: $NEW_PID)"
else
  log_err "CRITICAL: Daemon script not found at $DAEMON_SCRIPT"
  exit 1
fi

exit 0
