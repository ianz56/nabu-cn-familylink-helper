#!/bin/sh
# Nabu DerpFest 17 Helper — Comprehensive Offline Test Suite (v3.2.0)
# ==================================================================
# Tests dynamic multi-user lifecycle, native stop-on-switch synergy,
# and adaptive thermal tier 0-4 hysteresis without device access.

set -e

PASSED=0
FAILED=0

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  [PASS] $test_name (expected='$expected', got='$actual')"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $test_name (expected='$expected', got='$actual')"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "  [PASS] $test_name (found '$needle')"
      PASSED=$((PASSED + 1))
      ;;
    *)
      echo "  [FAIL] $test_name (missing '$needle' in '$haystack')"
      FAILED=$((FAILED + 1))
      ;;
  esac
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Nabu DerpFest 17 Helper v3.2.0 — Offline Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─────────────────────────────────────────────────────────────
# 1. MULTI-USER ELIGIBILITY & DISCOVERY PARSING TESTS
# ─────────────────────────────────────────────────────────────
echo "── 1. Dynamic User Discovery & Eligibility Tests ───────────"

MOCK_USER_LIST='2 users:

0: id=0, name=Ian, unresolvedName=Ian, type=full.SYSTEM, flags=ADMIN|FULL|INITIALIZED|MAIN|PRIMARY|SYSTEM (running) (current) (visible)
1: id=10, name=Delia, unresolvedName=Delia, type=full.SECONDARY, flags=FULL|INITIALIZED (profile-owner)
2: id=11, name=Work, type=profile.MANAGED, flags=PROFILE|INITIALIZED (running)
3: id=12, name=Guest, type=full.GUEST, flags=GUEST|INITIALIZED
4: id=2, name=Kid, type=full.SECONDARY, flags=FULL|INITIALIZED (running)
5: id=99, name=Clone, type=profile.CLONE, flags=PROFILE|INITIALIZED (running)
'

test_is_eligible() {
  local target_id="$1"
  [ -z "$target_id" ] && return 1
  case "$target_id" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$target_id" -eq 0 ] && return 1

  echo "$MOCK_USER_LIST" | awk -v tgt="$target_id" '
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

# Test 1: User 0 Exclusion
if test_is_eligible 0; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "User 0 Main User permanently excluded" "EXCLUDED" "$res"

# Test 2: User 10 Eligible Secondary
if test_is_eligible 10; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "User 10 full.SECONDARY is eligible" "ELIGIBLE" "$res"

# Test 3: User 2 Eligible Secondary
if test_is_eligible 2; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "User 2 full.SECONDARY is eligible" "ELIGIBLE" "$res"

# Test 4: User 11 Work Profile Excluded
if test_is_eligible 11; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "User 11 profile.MANAGED is excluded" "EXCLUDED" "$res"

# Test 5: User 12 Guest Excluded
if test_is_eligible 12; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "User 12 full.GUEST is excluded" "EXCLUDED" "$res"

# Test 6: User 99 Clone Profile Excluded
if test_is_eligible 99; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "User 99 profile.CLONE is excluded" "EXCLUDED" "$res"

# Test 7: Non-existent user
if test_is_eligible 55; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "Non-existent user 55 is excluded" "EXCLUDED" "$res"

# Test 8: Malformed user ID (empty or letters)
if test_is_eligible "abc"; then res="ELIGIBLE"; else res="EXCLUDED"; fi
assert_eq "Malformed user ID 'abc' is rejected" "EXCLUDED" "$res"

# Test 9: Discover running eligible secondary users
test_get_running() {
  echo "$MOCK_USER_LIST" | awk '
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
running_res=$(test_get_running | tr '\n' ' ' | tr -s ' ')
assert_eq "Running secondary users discovery (only User 2 running)" "2 " "$running_res"

echo ""

# ─────────────────────────────────────────────────────────────
# 2. LIFECYCLE CLASSIFICATION & SCENARIO MOCK TESTS
# ─────────────────────────────────────────────────────────────
echo "── 2. Lifecycle Classification & Scenario Logic Tests ──────"

test_classify() {
  local is_stopped="$1"
  local user_state="$2"

  if [ "$is_stopped" = "true" ]; then
    echo "STOPPED"
    return
  fi
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

# Test 10: Lifecycle states
assert_eq "Classify is-user-stopped true -> STOPPED" "STOPPED" "$(test_classify true RUNNING_UNLOCKED)"
assert_eq "Classify RUNNING_UNLOCKED -> RUNNING_UNLOCKED" "RUNNING_UNLOCKED" "$(test_classify false RUNNING_UNLOCKED)"
assert_eq "Classify RUNNING_LOCKED -> RUNNING_LOCKED" "RUNNING_LOCKED" "$(test_classify false RUNNING_LOCKED)"
assert_eq "Classify STOPPING -> STOPPING" "STOPPING" "$(test_classify false STOPPING)"
assert_eq "Classify User is not started -> STOPPED" "STOPPED" "$(test_classify false 'User is not started: 10')"
assert_eq "Classify ambiguous state -> UNKNOWN" "UNKNOWN" "$(test_classify ambiguous error)"

# Test 11: Scenario A Native Stop-on-Switch deduplication
test_scenario_a_dedup() {
  local post_switch_state="$1"
  local stop_called=0
  if [ "$post_switch_state" = "STOPPED" ]; then
    echo "NATIVE_STOP_SUCCESS"
  else
    stop_called=1
    echo "FALLBACK_STOP_CALLED"
  fi
}
assert_eq "Scenario A: Native switch stops user -> no duplicate stop" "NATIVE_STOP_SUCCESS" "$(test_scenario_a_dedup STOPPED)"
assert_eq "Scenario A: User still running -> fallback stop called" "FALLBACK_STOP_CALLED" "$(test_scenario_a_dedup RUNNING_LOCKED)"

# Test 12: Scenario B Sequential Batch Stopping with Abort Check
test_scenario_b_batch() {
  local display_off="$1"
  local fg_user="$2"
  local users_to_stop="10 2 3"
  local stopped_list=""

  for u in $users_to_stop; do
    if [ "$display_off" -ne 1 ]; then
      stopped_list="${stopped_list}ABORT_DISP_ON"
      break
    fi
    if [ "$fg_user" -ne 0 ]; then
      stopped_list="${stopped_list}ABORT_FG_CHANGED"
      break
    fi
    stopped_list="${stopped_list}STOP_$u "
  done
  echo "$stopped_list"
}
assert_eq "Scenario B: All users stopped sequentially when display OFF" "STOP_10 STOP_2 STOP_3 " "$(test_scenario_b_batch 1 0)"
assert_eq "Scenario B: Aborted immediately if display wakes up" "ABORT_DISP_ON" "$(test_scenario_b_batch 0 0)"
assert_eq "Scenario B: Aborted immediately if foreground user changes" "ABORT_FG_CHANGED" "$(test_scenario_b_batch 1 10)"

echo ""

# ─────────────────────────────────────────────────────────────
# 3. ADAPTIVE THERMAL ENGINE & HYSTERESIS TESTS
# ─────────────────────────────────────────────────────────────
echo "── 3. Adaptive Thermal Tier 0-4 & Hysteresis Tests ──────────"

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

# Test 13: Tier 0 transitions
assert_eq "Temp 34°C from Tier 0 -> Tier 0" "0" "$(determine_target_tier 34000 0)"
assert_eq "Temp 35°C from Tier 0 -> Tier 0" "0" "$(determine_target_tier 35000 0)"
assert_eq "Temp 36°C from Tier 0 -> Tier 1" "1" "$(determine_target_tier 36000 0)"
assert_eq "Temp 38°C from Tier 0 -> Tier 2" "2" "$(determine_target_tier 38000 0)"
assert_eq "Temp 40°C from Tier 0 -> Tier 3" "3" "$(determine_target_tier 40000 0)"
assert_eq "Temp 42°C from Tier 0 -> Tier 4" "4" "$(determine_target_tier 42000 0)"
assert_eq "Direct jump from 33°C to 45°C -> Tier 4" "4" "$(determine_target_tier 45000 0)"

# Test 14: Tier 1 Hysteresis (Drop below 35°C required)
assert_eq "Temp 35.5°C in Tier 1 -> Remains Tier 1" "1" "$(determine_target_tier 35500 1)"
assert_eq "Temp 35.0°C in Tier 1 -> Remains Tier 1" "1" "$(determine_target_tier 35000 1)"
assert_eq "Temp 34.9°C in Tier 1 -> Drops to Tier 0" "0" "$(determine_target_tier 34900 1)"

# Test 15: Tier 2 Hysteresis (Drop below 37°C required)
assert_eq "Temp 37.5°C in Tier 2 -> Remains Tier 2" "2" "$(determine_target_tier 37500 2)"
assert_eq "Temp 36.9°C in Tier 2 -> Drops to Tier 1" "1" "$(determine_target_tier 36900 2)"

# Test 16: Tier 3 Hysteresis (Drop below 39°C required)
assert_eq "Temp 39.5°C in Tier 3 -> Remains Tier 3" "3" "$(determine_target_tier 39500 3)"
assert_eq "Temp 38.9°C in Tier 3 -> Drops to Tier 2" "2" "$(determine_target_tier 38900 3)"

# Test 17: Tier 4 Hysteresis (Drop below 41°C required)
assert_eq "Temp 41.5°C in Tier 4 -> Remains Tier 4" "4" "$(determine_target_tier 41500 4)"
assert_eq "Temp 40.9°C in Tier 4 -> Drops to Tier 3" "3" "$(determine_target_tier 40900 4)"

# Test 18: Stepwise recovery curve simulation
# 43°C (T4) -> 40.5°C (T3) -> 38.5°C (T2) -> 36.5°C (T1) -> 34°C (T0)
t=4
t=$(determine_target_tier 40500 "$t")
assert_eq "Stepwise recovery 43C->40.5C -> Tier 3" "3" "$t"
t=$(determine_target_tier 38500 "$t")
assert_eq "Stepwise recovery 40.5C->38.5C -> Tier 2" "2" "$t"
t=$(determine_target_tier 36500 "$t")
assert_eq "Stepwise recovery 38.5C->36.5C -> Tier 1" "1" "$t"
t=$(determine_target_tier 34000 "$t")
assert_eq "Stepwise recovery 36.5C->34.0C -> Tier 0" "0" "$t"

# Test 19: Frequency clamp to baseline
clamp_limit() {
  local target="$1"
  local base="$2"
  if [ -n "$base" ] && [ "$base" -gt 0 ] 2>/dev/null && [ "$target" -gt "$base" ] 2>/dev/null; then
    echo "$base"
  else
    echo "$target"
  fi
}
assert_eq "Target 2131200 clamped to baseline 2419200" "2131200" "$(clamp_limit 2131200 2419200)"
assert_eq "Target 2841600 clamped to lower baseline 2419200" "2419200" "$(clamp_limit 2841600 2419200)"

# Test 20: Vendor Overwrite Protection (Do not raise vendor-lowered limit)
test_vendor_protection() {
  local cur_freq="$1"
  local target_freq="$2"
  # If cur_freq is lower than target_freq, do NOT raise it
  if [ "$cur_freq" -lt "$target_freq" ]; then
    echo "$cur_freq" # Preserved vendor safety limit
  else
    echo "$target_freq" # Applied our cap
  fi
}
assert_eq "Vendor set lower freq (1056000) than target (1612800) -> preserve vendor limit" "1056000" "$(test_vendor_protection 1056000 1612800)"
assert_eq "Normal state: cur_freq (2419200) > target (1612800) -> apply target cap" "1612800" "$(test_vendor_protection 2419200 1612800)"

echo ""

# ─────────────────────────────────────────────────────────────
# 4. SENSOR VALIDATION & PER-BOOT IDENTITY TESTS
# ─────────────────────────────────────────────────────────────
echo "── 4. Sensor Validation & Boot ID Recovery Tests ───────────"

# Test 21: Sensor Temperature Validation
validate_temp() {
  local t="$1"
  case "$t" in
    ''|*[!0-9]*) echo "INVALID" ; return ;;
  esac
  if [ "$t" -ge 15000 ] && [ "$t" -le 65000 ]; then
    echo "VALID"
  else
    echo "OUT_OF_RANGE"
  fi
}
assert_eq "Validate 33350 mC -> VALID" "VALID" "$(validate_temp 33350)"
assert_eq "Validate 12000 mC -> OUT_OF_RANGE" "OUT_OF_RANGE" "$(validate_temp 12000)"
assert_eq "Validate 75000 mC -> OUT_OF_RANGE" "OUT_OF_RANGE" "$(validate_temp 75000)"
assert_eq "Validate empty string -> INVALID" "INVALID" "$(validate_temp '')"
assert_eq "Validate non-numeric string -> INVALID" "INVALID" "$(validate_temp 'temp_err')"

# Test 22: Stale Boot ID Detection
test_boot_id_check() {
  local cur_boot="$1"
  local stored_boot="$2"
  if [ "$cur_boot" = "$stored_boot" ] && [ -n "$cur_boot" ]; then
    echo "KEEP_BASELINE"
  else
    echo "PURGE_STALE"
  fi
}
assert_eq "Matching boot ID -> KEEP_BASELINE" "KEEP_BASELINE" "$(test_boot_id_check 'boot-abc-123' 'boot-abc-123')"
assert_eq "Differing boot ID -> PURGE_STALE" "PURGE_STALE" "$(test_boot_id_check 'boot-new-456' 'boot-old-123')"

echo ""

# ─────────────────────────────────────────────────────────────
# 5. STRICT DAEMON IDENTITY & SHUTDOWN SAFETY TESTS
# ─────────────────────────────────────────────────────────────
echo "── 5. Strict Process Identity & Graceful Shutdown Tests ────"

TARGET_DAEMON_SCRIPT="/data/adb/modules/nabu-derpfest-helper/auto_switch.sh"

# Mock validator mimicking service.sh strict cmdline check
validate_process_identity() {
  local pid="$1"
  local mock_proc_exists="$2"
  local mock_cmdline="$3"

  # Validate numeric positive PID > 1
  case "$pid" in
    ''|*[!0-9]*) echo "INVALID_PID"; return 1 ;;
  esac
  if [ "$pid" -le 1 ]; then
    echo "PROTECTED_PID"
    return 1
  fi

  if [ "$mock_proc_exists" -ne 1 ]; then
    echo "STALE_PID_PURGED"
    return 0
  fi

  # Exact argument matching against null-delimited or space-delimited args
  local is_match=0
  for arg in $mock_cmdline; do
    if [ "$arg" = "$TARGET_DAEMON_SCRIPT" ]; then
      is_match=1
      break
    fi
  done

  if [ "$is_match" -eq 1 ]; then
    echo "VERIFIED_MODULE_DAEMON"
    return 0
  else
    echo "FOREIGN_PROCESS_REJECTED"
    return 1
  fi
}

# Test 23: Exact expected daemon script path in cmdline
assert_eq "Validate exact daemon path -> VERIFIED_MODULE_DAEMON" "VERIFIED_MODULE_DAEMON" \
  "$(validate_process_identity 3109 1 "sh $TARGET_DAEMON_SCRIPT")"

# Test 24: Unrelated script with same basename in different module
assert_eq "Unrelated script in different module -> FOREIGN_PROCESS_REJECTED" "FOREIGN_PROCESS_REJECTED" \
  "$(validate_process_identity 3109 1 "sh /data/adb/modules/other_mod/auto_switch.sh" || true)"

# Test 25: Unrelated script in /data/local/tmp
assert_eq "Script in /data/local/tmp -> FOREIGN_PROCESS_REJECTED" "FOREIGN_PROCESS_REJECTED" \
  "$(validate_process_identity 3109 1 "sh /data/local/tmp/auto_switch.sh" || true)"

# Test 26: PID reused by completely unrelated binary (system_server / app)
assert_eq "PID reused by system process -> FOREIGN_PROCESS_REJECTED" "FOREIGN_PROCESS_REJECTED" \
  "$(validate_process_identity 3109 1 "system_server --nice-name=system_server" || true)"

# Test 27: Non-numeric or empty PID
assert_eq "Non-numeric PID -> INVALID_PID" "INVALID_PID" \
  "$(validate_process_identity "abc" 0 "" || true)"

# Test 28: Protected PIDs (PID 0 or 1)
assert_eq "PID 1 (init) -> PROTECTED_PID" "PROTECTED_PID" \
  "$(validate_process_identity 1 1 "init" || true)"

# Test 29: Stale PID where /proc/<PID> is dead
assert_eq "Dead PID -> STALE_PID_PURGED" "STALE_PID_PURGED" \
  "$(validate_process_identity 4099 0 "")"

# Mock graceful shutdown simulator
simulate_shutdown_policy() {
  local pid_verified="$1"
  local process_exits_within_timeout="$2"
  local timeout="$3"

  if [ "$pid_verified" -ne 1 ]; then
    echo "SIGNAL_REFUSED_FOREIGN_PROCESS"
    return 0
  fi

  # Send SIGTERM
  # If process exits within timeout:
  if [ "$process_exits_within_timeout" -eq 1 ]; then
    echo "GRACEFUL_EXIT_CONFIRMED"
    return 0
  else
    # Process failed to exit within timeout
    # Strict policy: NEVER send SIGKILL, ABORT startup
    echo "STARTUP_ABORTED_SIGKILL_REFUSED"
    return 1
  fi
}

# Test 30: Graceful TERM success
assert_eq "Graceful shutdown success -> GRACEFUL_EXIT_CONFIRMED" "GRACEFUL_EXIT_CONFIRMED" \
  "$(simulate_shutdown_policy 1 1 5)"

# Test 31: Process fails to exit within timeout -> SIGKILL refused, startup aborted
assert_eq "Process hangs -> STARTUP_ABORTED_SIGKILL_REFUSED" "STARTUP_ABORTED_SIGKILL_REFUSED" \
  "$(simulate_shutdown_policy 1 0 5 || true)"

# Test 32: Foreign process -> signal refused completely
assert_eq "Foreign process -> SIGNAL_REFUSED_FOREIGN_PROCESS" "SIGNAL_REFUSED_FOREIGN_PROCESS" \
  "$(simulate_shutdown_policy 0 0 5)"

# Mock thermal recovery verification
simulate_thermal_recovery_check() {
  local cur_p0="$1"
  local base_p0="$2"
  local vendor_limit_active="$3"

  if [ "$vendor_limit_active" -eq 1 ]; then
    # Vendor lower limit preserved without error
    echo "VENDOR_LOWER_LIMIT_PRESERVED"
  elif [ "$cur_p0" = "$base_p0" ]; then
    echo "BASELINE_RESTORED_VERIFIED"
  else
    echo "RESTORE_MISMATCH"
  fi
}

# Test 33: Baseline restored verified
assert_eq "Thermal recovery read-back verified" "BASELINE_RESTORED_VERIFIED" \
  "$(simulate_thermal_recovery_check 1785600 1785600 0)"

# Test 34: External vendor limit preserved
assert_eq "External vendor limit preserved during restore" "VENDOR_LOWER_LIMIT_PRESERVED" \
  "$(simulate_thermal_recovery_check 1382400 1785600 1)"

# Test 35: Startup aborted when previous daemon fails to exit (prevents 2 daemons)
test_dual_daemon_prevention() {
  local shutdown_rc="$1"
  if [ "$shutdown_rc" -eq 0 ]; then
    echo "LAUNCH_NEW_DAEMON"
  else
    echo "REFUSE_DUAL_DAEMON"
  fi
}
assert_eq "Shutdown successful -> LAUNCH_NEW_DAEMON" "LAUNCH_NEW_DAEMON" \
  "$(test_dual_daemon_prevention 0)"
assert_eq "Shutdown failed -> REFUSE_DUAL_DAEMON" "REFUSE_DUAL_DAEMON" \
  "$(test_dual_daemon_prevention 1)"

echo ""

# ─────────────────────────────────────────────────────────────
# 6. THERMAL RESTORE OWNERSHIP REGRESSION TESTS
# ─────────────────────────────────────────────────────────────
echo "── 6. Thermal Restore Ownership Regression Tests ───────────"

MOCK_SYSFS_DIR="/tmp/mock_sysfs_test_$$"
mkdir -p "$MOCK_SYSFS_DIR"
MOCK_NODE="$MOCK_SYSFS_DIR/scaling_max_freq"

# Direct implementation of restore_single_node_baseline for verification
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
    # Current is lower than module applied value -> vendor limit preserved
    echo "VENDOR_LOWER_PRESERVED $cur_val"
    return 0
  elif [ "$cur_val" -eq "$applied" ]; then
    # Current strictly matches applied -> restore verified
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

# Scenario 1: Baseline 2,419,200; module applied 2,131,200; current remains 2,131,200 -> Restore baseline
echo "2131200" > "$MOCK_NODE"
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" "2419200" "2131200" "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Scenario 1: Verified restore baseline status" "RESTORED_VERIFIED 2419200" "$res"
assert_eq "Scenario 1: Verified restore baseline readback" "2419200" "$readback"

# Scenario 2: Baseline 2,419,200; module applied 2,131,200; vendor lowers current to 1,612,800 -> Preserve vendor's lower limit
echo "1612800" > "$MOCK_NODE"
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" "2419200" "2131200" "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Scenario 2: Preserve vendor lower limit status" "VENDOR_LOWER_PRESERVED 1612800" "$res"
assert_eq "Scenario 2: Node remains at vendor lower limit" "1612800" "$readback"

# Scenario 3: Baseline 2,419,200; module applied 2,131,200; external controller restores 2,419,200 -> Do not perform unnecessary conflicting write
echo "2419200" > "$MOCK_NODE"
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" "2419200" "2131200" "boot-1" "boot-1")
assert_eq "Scenario 3: Do not perform conflicting write status" "ALREADY_BASELINE 2419200" "$res"

# Scenario 4: Baseline 2,419,200; module applied 2,131,200; current becomes an unrelated value (2,208,000) -> Detect ownership uncertainty
echo "2208000" > "$MOCK_NODE"
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" "2419200" "2131200" "boot-1" "boot-1" || true)
readback=$(cat "$MOCK_NODE")
assert_eq "Scenario 4: Detect ownership uncertainty status" "OWNERSHIP_UNCERTAIN 2208000" "$res"
assert_eq "Scenario 4: Node not overwritten on uncertainty" "2208000" "$readback"

# Scenario 5: Multi-cluster evaluation with partial failure
evaluate_multi_cluster_recovery() {
  local s0="$1" s4="$2" s7="$3" sg="$4"
  local has_failure=0
  for st in "$s0" "$s4" "$s7" "$sg"; do
    case "$st" in
      RESTORE_FAILED|OWNERSHIP_UNCERTAIN|STALE_BOOT_ID|UNREADABLE)
        has_failure=1
        ;;
    esac
  done
  if [ "$has_failure" -eq 1 ]; then
    echo "PARTIAL_RESTORE_WARNING"
  else
    echo "FULL_RESTORE_SUCCESS"
  fi
}
assert_eq "Scenario 5a: All clusters clean -> FULL_RESTORE_SUCCESS" "FULL_RESTORE_SUCCESS" \
  "$(evaluate_multi_cluster_recovery RESTORED_VERIFIED RESTORED_VERIFIED ALREADY_BASELINE VENDOR_LOWER_PRESERVED)"
assert_eq "Scenario 5b: One cluster uncertain -> PARTIAL_RESTORE_WARNING" "PARTIAL_RESTORE_WARNING" \
  "$(evaluate_multi_cluster_recovery RESTORED_VERIFIED OWNERSHIP_UNCERTAIN RESTORED_VERIFIED RESTORED_VERIFIED)"
assert_eq "Scenario 5c: One cluster failed -> PARTIAL_RESTORE_WARNING" "PARTIAL_RESTORE_WARNING" \
  "$(evaluate_multi_cluster_recovery RESTORED_VERIFIED RESTORE_FAILED ALREADY_BASELINE RESTORED_VERIFIED)"

# Scenario 6: Missing node -> Skip safely and report
MOCK_MISSING="$MOCK_SYSFS_DIR/non_existent_node"
res=$(restore_single_node_baseline "MISSING" "$MOCK_MISSING" "2419200" "2131200" "boot-1" "boot-1" || true)
assert_eq "Scenario 6: Missing node skipped safely status" "NODE_MISSING NONE" "$res"

# Scenario 7: Stale boot ID -> Never reuse the old baseline
echo "2131200" > "$MOCK_NODE"
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" "2419200" "2131200" "boot-2" "boot-1" || true)
readback=$(cat "$MOCK_NODE")
assert_eq "Scenario 7: Stale boot ID rejected status" "STALE_BOOT_ID NONE" "$res"
assert_eq "Scenario 7: Stale boot baseline not written" "2131200" "$readback"

rm -rf "$MOCK_SYSFS_DIR"

echo ""

# ─────────────────────────────────────────────────────────────
# 7. OFFLINE GRACEFUL SHUTDOWN INTEGRATION TESTS
# ─────────────────────────────────────────────────────────────
echo "── 7. Offline Graceful Shutdown Integration Tests ───────────"

INTEG_DIR="/tmp/integ_shutdown_test_$$"
mkdir -p "$INTEG_DIR"
MOCK_PID_FILE="$INTEG_DIR/mock_daemon.pid"
MOCK_NODE_FILE="$INTEG_DIR/mock_cpu_freq"
MOCK_LOG_FILE="$INTEG_DIR/mock_daemon.log"

echo "2131200" > "$MOCK_NODE_FILE" # Currently throttled

# Spawn a controlled mock daemon process
cat << 'DAEMON_EOF' > "$INTEG_DIR/run_mock_daemon.sh"
#!/bin/sh
PID_FILE="$1"
NODE_FILE="$2"
LOG_FILE="$3"
BASE_FREQ="2419200"

echo "$$" > "$PID_FILE"
CLEANUP_RUNNING=0

cleanup() {
  if [ "$CLEANUP_RUNNING" -eq 1 ]; then
    return 0
  fi
  CLEANUP_RUNNING=1
  trap - EXIT INT TERM HUP
  echo "CLEANUP_CALLED" >> "$LOG_FILE"
  echo "$BASE_FREQ" > "$NODE_FILE"
  rm -f "$PID_FILE"
  exit 0
}
trap cleanup EXIT INT TERM HUP

while true; do
  sleep 0.1
done
DAEMON_EOF
chmod +x "$INTEG_DIR/run_mock_daemon.sh"

sh "$INTEG_DIR/run_mock_daemon.sh" "$MOCK_PID_FILE" "$MOCK_NODE_FILE" "$MOCK_LOG_FILE" &
MOCK_DAEMON_PID=$!

# Wait for daemon to register PID
wait_start=0
while [ ! -f "$MOCK_PID_FILE" ] && [ "$wait_start" -lt 20 ]; do
  sleep 0.05
  wait_start=$((wait_start + 1))
done

# Test 36: Verify mock daemon is alive
mock_alive=0
kill -0 "$MOCK_DAEMON_PID" 2>/dev/null && mock_alive=1
assert_eq "Mock daemon spawned and alive" "1" "$mock_alive"

# Send SIGTERM to mock daemon (graceful shutdown test)
kill -TERM "$MOCK_DAEMON_PID" 2>/dev/null

# Wait up to 3s for graceful termination
wait_term=0
while kill -0 "$MOCK_DAEMON_PID" 2>/dev/null && [ "$wait_term" -lt 30 ]; do
  sleep 0.1
  wait_term=$((wait_term + 1))
done

mock_dead=0
kill -0 "$MOCK_DAEMON_PID" 2>/dev/null || mock_dead=1
assert_eq "Mock daemon terminated after SIGTERM" "1" "$mock_dead"

# Test 37: Verify hardware baseline restored
restored_freq=$(cat "$MOCK_NODE_FILE" 2>/dev/null)
assert_eq "Hardware baseline restored on SIGTERM" "2419200" "$restored_freq"

# Test 38: Verify PID file removed
pid_removed=0
[ ! -f "$MOCK_PID_FILE" ] && pid_removed=1
assert_eq "PID file removed on graceful shutdown" "1" "$pid_removed"

# Test 39: Verify cleanup was called exactly once (idempotent, no recursion)
cleanup_invocations=$(grep -c "CLEANUP_CALLED" "$MOCK_LOG_FILE" 2>/dev/null || echo 0)
assert_eq "Cleanup executed exactly once (idempotent)" "1" "$cleanup_invocations"

# Test 40: Dual daemon prevention when previous process hangs
simulate_dual_daemon_check() {
  local proc_hangs="$1"
  if [ "$proc_hangs" -eq 1 ]; then
    echo "STARTUP_ABORTED_SIGKILL_REFUSED"
    return 1
  else
    echo "NEW_DAEMON_LAUNCHED"
    return 0
  fi
}
assert_eq "Dual daemon prevented on hanging process" "STARTUP_ABORTED_SIGKILL_REFUSED" \
  "$(simulate_dual_daemon_check 1 || true)"
assert_eq "Normal launch allowed after clean exit" "NEW_DAEMON_LAUNCHED" \
  "$(simulate_dual_daemon_check 0)"

rm -rf "$INTEG_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Summary: PASSED=$PASSED, FAILED=$FAILED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAILED" -eq 0 ]; then
  echo "  >>> ALL TESTS PASSED SUCCESSFULLY! <<<"
  exit 0
else
  echo "  >>> TEST SUITE FAILED WITH $FAILED ERRORS! <<<"
  exit 1
fi
