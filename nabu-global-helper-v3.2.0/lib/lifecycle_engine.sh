#!/system/bin/sh
# Nabu DerpFest 17 Helper — Multi-User Lifecycle Engine Library
# ==============================================================
# Reusable, sourceable POSIX shell library for dynamic user discovery,
# strict eligibility validation, fail-closed lifecycle classification,
# native stop-on-switch synergy, and Scenarios A & B execution.

# ── Clock & Time Helper ──
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
  date +%s 2>/dev/null || echo 0
}

# ── Dynamic User Discovery & Strict Eligibility ──
# Main user (User 0) is immutable, permanent, and protected.
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

# Query Android foreground user ID
get_current_user() {
  local cur
  cur=$(cmd activity get-current-user 2>/dev/null)
  case "$cur" in
    ''|*[!0-9]*) echo "-1" ;;
    *) echo "$cur" ;;
  esac
}

# ── Multi-Signal Fail-Closed Display State Detection ──
# Accepts ONLY confirmed physical display OFF.
# Rejects DOZE, ON, UNKNOWN, or conflicting readings.
is_display_off() {
  # Signal 1: Hardware Backlight Brightness
  local bl_path="${BACKLIGHT_SYSFS_PATH:-/sys/class/backlight/panel0-backlight/brightness}"
  if [ -f "$bl_path" ]; then
    local bl_val
    bl_val=$(cat "$bl_path" 2>/dev/null)
    case "$bl_val" in
      ''|*[!0-9]*) return 1 ;;
      0) ;; # Confirmed zero brightness
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

# ── Lifecycle Classification for Specific User ID ──
# Distinguishes STOPPED, RUNNING_LOCKED, RUNNING_UNLOCKED, STOPPING, UNKNOWN.
# Fails closed to UNKNOWN if state cannot be deterministically verified.
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
      # Unrecognized or ambiguous state: FAIL CLOSED
      echo "UNKNOWN"
      ;;
  esac
}

# Wait for a user currently in STOPPING state to reach STOPPED
wait_for_user_stopping() {
  local uid="$1"
  local max_wait="${2:-10}"
  local elapsed=0
  local st

  while [ "$elapsed" -lt "$max_wait" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    st=$(check_user_lifecycle_state "$uid")
    if [ "$st" = "STOPPED" ]; then
      return 0
    elif [ "$st" = "UNKNOWN" ]; then
      return 2 # Ambiguous state error
    fi
  done
  return 1 # Timed out while still stopping
}

# ── Scenario B: Multi-User Background Stop Execution ──
# Called when User 0 is Foreground and Screen is OFF after deadline.
# Evaluates a single target user with strict pre-conditions, STOPPING transitions,
# and fail-closed abortion on UNKNOWN.
execute_scenario_b_user_stop() {
  local target_uid="$1"
  local transition_timeout="${2:-10}"

  # 1. Pre-stop environment validation
  if ! is_display_off; then
    echo "ABORT_DISPLAY_ON"
    return 1
  fi

  if [ "$(get_current_user)" -ne 0 ]; then
    echo "ABORT_FG_CHANGED"
    return 1
  fi

  if ! is_eligible_secondary_user "$target_uid"; then
    echo "SKIP_INELIGIBLE"
    return 0
  fi

  # 2. Lifecycle state evaluation
  local u_state
  u_state=$(check_user_lifecycle_state "$target_uid")

  case "$u_state" in
    STOPPED)
      echo "ALREADY_STOPPED"
      return 0
      ;;
    STOPPING)
      # User is already transitioning: wait up to timeout, NEVER issue duplicate stop
      wait_for_user_stopping "$target_uid" "$transition_timeout"
      local w_rc=$?
      case "$w_rc" in
        0) echo "STOPPING_TRANSITION_SUCCESS"; return 0 ;;
        2) echo "STOPPING_UNKNOWN_STATE"; return 2 ;;
        *) echo "STOPPING_TIMEOUT"; return 1 ;;
      esac
      ;;
    UNKNOWN)
      # Ambiguous state: FAIL CLOSED, abort remaining batch
      echo "FAIL_CLOSED_UNKNOWN_STATE"
      return 2
      ;;
    RUNNING_LOCKED|RUNNING_UNLOCKED)
      # Valid running state. Immediate pre-command revalidation:
      if ! is_display_off; then
        echo "ABORT_DISPLAY_ON"
        return 1
      fi
      if [ "$(get_current_user)" -ne 0 ]; then
        echo "ABORT_FG_CHANGED"
        return 1
      fi

      # Recheck state immediately before stop
      local pre_cmd_state
      pre_cmd_state=$(check_user_lifecycle_state "$target_uid")
      case "$pre_cmd_state" in
        STOPPED)
          echo "ALREADY_STOPPED"
          return 0
          ;;
        STOPPING)
          wait_for_user_stopping "$target_uid" "$transition_timeout"
          local w_rc=$?
          case "$w_rc" in
            0) echo "STOPPING_TRANSITION_SUCCESS"; return 0 ;;
            2) echo "STOPPING_UNKNOWN_STATE"; return 2 ;;
            *) echo "STOPPING_TIMEOUT"; return 1 ;;
          esac
          ;;
        RUNNING_LOCKED|RUNNING_UNLOCKED)
          # Confirmed: execute stop command
          cmd activity stop-user -w "$target_uid" >/dev/null 2>&1
          local post_state
          post_state=$(check_user_lifecycle_state "$target_uid")
          if [ "$post_state" = "STOPPED" ]; then
            echo "STOP_SUCCESS"
            return 0
          elif [ "$post_state" = "STOPPING" ]; then
            wait_for_user_stopping "$target_uid" "$transition_timeout"
            local post_w_rc=$?
            case "$post_w_rc" in
              0) echo "STOP_SUCCESS"; return 0 ;;
              2) echo "STOP_UNKNOWN_STATE"; return 2 ;;
              *) echo "STOP_TIMEOUT_STOPPING"; return 1 ;;
            esac
          else
            echo "STOP_FAILED_${post_state}"
            return 1
          fi
          ;;
        *)
          echo "FAIL_CLOSED_UNKNOWN_STATE"
          return 2
          ;;
      esac
      ;;
  esac
}

# ── Scenario A: Secondary User Foreground Stop Execution ──
# Called when an eligible secondary user is foreground and screen turns OFF.
# Handles switch to User 0, native stop validation, bounded STOPPING wait,
# and controlled fallback stop without executing fallback on UNKNOWN.
execute_scenario_a_user_stop() {
  local target_uid="$1"
  local switch_timeout="${2:-15}"
  local transition_timeout="${3:-10}"

  # ── Immediate Pre-Switch Precondition Revalidation ──
  # 1. Physical display must be confirmed OFF
  if ! is_display_off; then
    echo "ABORT_DISPLAY_ON"
    return 1
  fi

  # 2. Foreground user must equal exact target_uid
  local cur_fg
  cur_fg=$(get_current_user)
  if [ "$cur_fg" != "$target_uid" ]; then
    echo "ABORT_FG_USER_CHANGED"
    return 1
  fi

  # 3. Target user must still be an eligible full secondary user
  if ! is_eligible_secondary_user "$target_uid"; then
    echo "ABORT_USER_INELIGIBLE"
    return 1
  fi

  # 4. Target lifecycle state must not be STOPPED, STOPPING, or UNKNOWN
  local pre_switch_state
  pre_switch_state=$(check_user_lifecycle_state "$target_uid")
  case "$pre_switch_state" in
    STOPPED)
      echo "ALREADY_STOPPED"
      return 0
      ;;
    STOPPING)
      echo "ABORT_TARGET_STOPPING"
      return 1
      ;;
    UNKNOWN)
      echo "FAIL_CLOSED_UNKNOWN_STATE"
      return 2
      ;;
    RUNNING_LOCKED|RUNNING_UNLOCKED)
      ;;
    *)
      echo "FAIL_CLOSED_UNKNOWN_STATE"
      return 2
      ;;
  esac

  # ── Execute Asynchronous User Switch to User 0 ──
  cmd activity switch-user 0 >/dev/null 2>&1

  # Wait for User 0 to become foreground
  local wait_count=0
  local switch_ok=0
  while [ "$wait_count" -lt "$switch_timeout" ]; do
    sleep 1
    wait_count=$((wait_count + 1))
    if [ "$(get_current_user)" -eq 0 ]; then
      switch_ok=1
      break
    fi
  done

  if [ "$switch_ok" -ne 1 ]; then
    echo "SWITCH_USER_0_TIMEOUT"
    return 1
  fi

  # ── Evaluate Post-Switch State & Native Stop-On-Switch ──
  local post_switch_state
  post_switch_state=$(check_user_lifecycle_state "$target_uid")

  case "$post_switch_state" in
    STOPPED)
      echo "NATIVE_STOP_SUCCESS"
      return 0
      ;;
    STOPPING)
      # Wait up to transition timeout; never issue duplicate stop
      wait_for_user_stopping "$target_uid" "$transition_timeout"
      local w_rc=$?
      case "$w_rc" in
        0) echo "TRANSITION_STOP_SUCCESS"; return 0 ;;
        2) echo "STOPPING_UNKNOWN_STATE"; return 2 ;;
        *) echo "STOPPING_TIMEOUT"; return 1 ;;
      esac
      ;;
    RUNNING_LOCKED|RUNNING_UNLOCKED)
      # Secondary user remains running. Before fallback stop:
      # 1. Verify User 0 remains foreground
      if [ "$(get_current_user)" -ne 0 ]; then
        echo "FALLBACK_ABORT_FG_CHANGED"
        return 1
      fi

      # 2. Revalidate target eligibility
      if ! is_eligible_secondary_user "$target_uid"; then
        echo "FALLBACK_ABORT_INELIGIBLE"
        return 1
      fi

      # 3. Revalidate display is OFF
      if ! is_display_off; then
        echo "FALLBACK_ABORT_DISPLAY_ON"
        return 1
      fi

      # 4. Revalidate lifecycle state immediately before fallback command
      local pre_fb_state
      pre_fb_state=$(check_user_lifecycle_state "$target_uid")
      case "$pre_fb_state" in
        STOPPED)
          echo "FALLBACK_ALREADY_STOPPED"
          return 0
          ;;
        STOPPING)
          wait_for_user_stopping "$target_uid" "$transition_timeout"
          local fb_w_rc=$?
          case "$fb_w_rc" in
            0) echo "FALLBACK_STOP_SUCCESS"; return 0 ;;
            2) echo "STOPPING_UNKNOWN_STATE"; return 2 ;;
            *) echo "FALLBACK_STOPPING_TIMEOUT"; return 1 ;;
          esac
          ;;
        RUNNING_LOCKED|RUNNING_UNLOCKED)
          # Confirmed: execute fallback stop
          cmd activity stop-user -w "$target_uid" >/dev/null 2>&1
          local final_state
          final_state=$(check_user_lifecycle_state "$target_uid")
          if [ "$final_state" = "STOPPED" ]; then
            echo "FALLBACK_STOP_SUCCESS"
            return 0
          elif [ "$final_state" = "STOPPING" ]; then
            wait_for_user_stopping "$target_uid" "$transition_timeout"
            local fb_post_rc=$?
            case "$fb_post_rc" in
              0) echo "FALLBACK_STOP_SUCCESS"; return 0 ;;
              2) echo "STOP_UNKNOWN_STATE"; return 2 ;;
              *) echo "FALLBACK_STOPPING_TIMEOUT"; return 1 ;;
            esac
          else
            echo "FALLBACK_STOP_FAILED"
            return 1
          fi
          ;;
        UNKNOWN|*)
          echo "UNKNOWN_STATE_NO_FALLBACK"
          return 1
          ;;
      esac
      ;;
    UNKNOWN|*)
      # Unrecognized state: DO NOT issue fallback stop! Leave user untouched.
      echo "UNKNOWN_STATE_NO_FALLBACK"
      return 1
      ;;
  esac
}
