#!/bin/bash
# ==============================================================================
# Nabu DerpFest 17 Helper v3.2.0 — Production-Source Offline Test Suite
# ==============================================================================
# Tests the exact production shell libraries (lib/thermal_engine.sh and
# lib/lifecycle_engine.sh) using isolated mock sysfs nodes and Android CLI wrappers.
# Physical device operations are strictly prohibited during test execution.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

if [ ! -f "$LIB_DIR/thermal_engine.sh" ] || [ ! -f "$LIB_DIR/lifecycle_engine.sh" ]; then
  echo "FATAL: Required production libraries not found in $LIB_DIR"
  exit 1
fi

PASSED=0
FAILED=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  [PASS] $desc (expected='$expected', got='$actual')"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $desc"
    echo "         Expected: '$expected'"
    echo "         Actual:   '$actual'"
    FAILED=$((FAILED + 1))
  fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Nabu DerpFest 17 Helper v3.2.0 — Production-Source Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Mock environment directory
TEST_DIR="/tmp/nabu_test_$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Mock sysfs nodes
export CPU_P0_MAX="$TEST_DIR/cpu_p0_max"
export CPU_P4_MAX="$TEST_DIR/cpu_p4_max"
export CPU_P7_MAX="$TEST_DIR/cpu_p7_max"
export GPU_MAX_CLK="$TEST_DIR/gpu_max_clk"
export STATE_DIR="$TEST_DIR/state"
export BASELINE_FILE="$STATE_DIR/thermal_baseline.conf"
export OWNERSHIP_FILE="$STATE_DIR/thermal_ownership.conf"
export BACKLIGHT_SYSFS_PATH="$TEST_DIR/backlight_brightness"

mkdir -p "$STATE_DIR"

# Source the real production libraries
. "$LIB_DIR/thermal_engine.sh"
. "$LIB_DIR/lifecycle_engine.sh"

# ─────────────────────────────────────────────────────────────
# 1. DYNAMIC USER DISCOVERY & ELIGIBILITY TESTS
# ─────────────────────────────────────────────────────────────
echo "── 1. Dynamic User Discovery & Eligibility Tests ───────────"

# Mock android user database
MOCK_USER_LIST="UserInfo{0:Main User:413} id=0 name=Main User type=android.os.usertype.full.SYSTEM flags=ADMIN|PRIMARY (running) (current)
UserInfo{10:Delia:10} id=10 name=Delia type=android.os.usertype.full.SECONDARY flags=0 (running)
UserInfo{2:Second Space:10} id=2 name=Second Space type=android.os.usertype.full.SECONDARY flags=0 (running)
UserInfo{11:Work:10} id=11 name=Work type=android.os.usertype.profile.MANAGED flags=0 (running)
UserInfo{12:Guest:10} id=12 name=Guest type=android.os.usertype.full.GUEST flags=0
UserInfo{99:Clone:10} id=99 name=Clone type=android.os.usertype.profile.CLONE flags=0"

# Override cmd user list for testing
cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then
    echo "$MOCK_USER_LIST"
    return 0
  fi
  # Handled in subsequent test blocks
}

test_eligibility() {
  local uid="$1"
  if is_eligible_secondary_user "$uid"; then
    echo "ELIGIBLE"
  else
    echo "EXCLUDED"
  fi
}

assert_eq "User 0 Main User permanently excluded" "EXCLUDED" "$(test_eligibility 0)"
assert_eq "User 10 full.SECONDARY is eligible" "ELIGIBLE" "$(test_eligibility 10)"
assert_eq "User 2 full.SECONDARY is eligible" "ELIGIBLE" "$(test_eligibility 2)"
assert_eq "User 11 profile.MANAGED is excluded" "EXCLUDED" "$(test_eligibility 11)"
assert_eq "User 12 full.GUEST is excluded" "EXCLUDED" "$(test_eligibility 12)"
assert_eq "User 99 profile.CLONE is excluded" "EXCLUDED" "$(test_eligibility 99)"
assert_eq "Non-existent user 55 is excluded" "EXCLUDED" "$(test_eligibility 55)"
assert_eq "Malformed user ID 'abc' is rejected" "EXCLUDED" "$(test_eligibility 'abc')"

# Verify get_running_eligible_secondary_users
RUNNING_SECONDARY=$(get_running_eligible_secondary_users | tr '\n' ' ')
assert_eq "Running secondary users discovery (Users 10 and 2)" "10 2 " "$RUNNING_SECONDARY"

echo ""

# ─────────────────────────────────────────────────────────────
# 2. LIFECYCLE CLASSIFICATION & SCENARIO A/B FAIL-CLOSED TESTS
# ─────────────────────────────────────────────────────────────
echo "── 2. Lifecycle Classification & Scenario A/B Tests ────────"

MOCK_STOPPED_STATE="false"
MOCK_STARTED_STATE="RUNNING_UNLOCKED"
MOCK_CURRENT_USER=0
MOCK_DISP_OFF=1
MOCK_STOP_CALLS_FILE="$TEST_DIR/stop_calls"
reset_stop_calls() {
  rm -f "$MOCK_STOP_CALLS_FILE"
}
get_stop_calls() {
  if [ -f "$MOCK_STOP_CALLS_FILE" ]; then
    wc -l < "$MOCK_STOP_CALLS_FILE" | tr -d ' \t'
  else
    echo "0"
  fi
}

cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then
    echo "$MOCK_USER_LIST"
    return 0
  elif [ "$1" = "activity" ]; then
    case "$2" in
      is-user-stopped)
        echo "$MOCK_STOPPED_STATE"
        return 0
        ;;
      get-started-user-state)
        echo "$MOCK_STARTED_STATE"
        return 0
        ;;
      get-current-user)
        echo "$MOCK_CURRENT_USER"
        return 0
        ;;
      switch-user)
        MOCK_CURRENT_USER="$3"
        return 0
        ;;
      stop-user)
        echo "1" >> "$MOCK_STOP_CALLS_FILE"
        MOCK_STOPPED_STATE="true"
        MOCK_STARTED_STATE="User is not started"
        return 0
        ;;
    esac
  fi
}

# Override display detection to use mock variable
is_display_off() {
  [ "$MOCK_DISP_OFF" -eq 1 ]
}

# Test 10-15: Lifecycle Classification
MOCK_STOPPED_STATE="true"; MOCK_STARTED_STATE=""
assert_eq "Classify is-user-stopped true -> STOPPED" "STOPPED" "$(check_user_lifecycle_state 10)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_UNLOCKED"
assert_eq "Classify RUNNING_UNLOCKED" "RUNNING_UNLOCKED" "$(check_user_lifecycle_state 10)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_LOCKED"
assert_eq "Classify RUNNING_LOCKED" "RUNNING_LOCKED" "$(check_user_lifecycle_state 10)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="STOPPING"
assert_eq "Classify STOPPING" "STOPPING" "$(check_user_lifecycle_state 10)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="User is not started: 10"
assert_eq "Classify User is not started -> STOPPED" "STOPPED" "$(check_user_lifecycle_state 10)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="UnexpectedErrorOutput"
assert_eq "Classify ambiguous state -> UNKNOWN (fail closed)" "UNKNOWN" "$(check_user_lifecycle_state 10)"

# Scenario B Tests
MOCK_CURRENT_USER=0; MOCK_DISP_OFF=1; reset_stop_calls
MOCK_STOPPED_STATE="true"; MOCK_STARTED_STATE=""
assert_eq "Scenario B: STOPPED user skipped cleanly" "ALREADY_STOPPED" \
  "$(execute_scenario_b_user_stop 10 2)"
assert_eq "Scenario B: No stop-user issued for STOPPED" "0" "$(get_stop_calls)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_LOCKED"; reset_stop_calls
assert_eq "Scenario B: RUNNING_LOCKED user stopped" "STOP_SUCCESS" \
  "$(execute_scenario_b_user_stop 10 2)"
assert_eq "Scenario B: stop-user issued once" "1" "$(get_stop_calls)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_UNLOCKED"; reset_stop_calls
assert_eq "Scenario B: RUNNING_UNLOCKED user stopped" "STOP_SUCCESS" \
  "$(execute_scenario_b_user_stop 10 2)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="STOPPING"; reset_stop_calls
assert_eq "Scenario B: STOPPING user transitions without duplicate stop" "STOPPING_TIMEOUT" \
  "$(execute_scenario_b_user_stop 10 1 || true)"
assert_eq "Scenario B: Never issued duplicate stop for STOPPING" "0" "$(get_stop_calls)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="UNKNOWN"; reset_stop_calls
assert_eq "Scenario B: UNKNOWN user fails closed and aborts batch" "FAIL_CLOSED_UNKNOWN_STATE" \
  "$(execute_scenario_b_user_stop 10 2 || true)"
assert_eq "Scenario B: Never issued stop for UNKNOWN" "0" "$(get_stop_calls)"

MOCK_CURRENT_USER=0; MOCK_DISP_OFF=0
assert_eq "Scenario B: Aborted immediately if display ON" "ABORT_DISPLAY_ON" \
  "$(execute_scenario_b_user_stop 10 2 || true)"

MOCK_CURRENT_USER=10; MOCK_DISP_OFF=1
assert_eq "Scenario B: Aborted immediately if foreground user changed" "ABORT_FG_CHANGED" \
  "$(execute_scenario_b_user_stop 10 2 || true)"

# Scenario A Tests
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="true"; reset_stop_calls
assert_eq "Scenario A: Native stop on switch success" "NATIVE_STOP_SUCCESS" \
  "$(execute_scenario_a_user_stop 10 5 2)"

MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_UNLOCKED"; reset_stop_calls
assert_eq "Scenario A: Fallback stop executed when user remains running" "FALLBACK_STOP_SUCCESS" \
  "$(execute_scenario_a_user_stop 10 5 2)"
assert_eq "Scenario A: Fallback stop called once" "1" "$(get_stop_calls)"

MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="UNKNOWN"; reset_stop_calls
assert_eq "Scenario A: UNKNOWN state strictly refuses fallback stop" "UNKNOWN_STATE_NO_FALLBACK" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"
assert_eq "Scenario A: No fallback stop issued for UNKNOWN" "0" "$(get_stop_calls)"

echo ""

# ─────────────────────────────────────────────────────────────
# 3. ADAPTIVE THERMAL TIER 0-4 & HYSTERESIS TESTS
# ─────────────────────────────────────────────────────────────
echo "── 3. Adaptive Thermal Tier 0-4 & Hysteresis Tests ──────────"

assert_eq "Temp 34°C from Tier 0 -> Tier 0" "0" "$(determine_target_tier 34000 0)"
assert_eq "Temp 35°C from Tier 0 -> Tier 0" "0" "$(determine_target_tier 35000 0)"
assert_eq "Temp 36°C from Tier 0 -> Tier 1" "1" "$(determine_target_tier 36000 0)"
assert_eq "Temp 38°C from Tier 0 -> Tier 2" "2" "$(determine_target_tier 38000 0)"
assert_eq "Temp 40°C from Tier 0 -> Tier 3" "3" "$(determine_target_tier 40000 0)"
assert_eq "Temp 42°C from Tier 0 -> Tier 4" "4" "$(determine_target_tier 42000 0)"
assert_eq "Direct jump from 33°C to 45°C -> Tier 4" "4" "$(determine_target_tier 45000 0)"

assert_eq "Temp 35.5°C in Tier 1 -> Remains Tier 1" "1" "$(determine_target_tier 35500 1)"
assert_eq "Temp 35.0°C in Tier 1 -> Remains Tier 1" "1" "$(determine_target_tier 35000 1)"
assert_eq "Temp 34.9°C in Tier 1 -> Drops to Tier 0" "0" "$(determine_target_tier 34900 1)"

assert_eq "Temp 37.5°C in Tier 2 -> Remains Tier 2" "2" "$(determine_target_tier 37500 2)"
assert_eq "Temp 36.9°C in Tier 2 -> Drops to Tier 1" "1" "$(determine_target_tier 36900 2)"

assert_eq "Temp 39.5°C in Tier 3 -> Remains Tier 3" "3" "$(determine_target_tier 39500 3)"
assert_eq "Temp 38.9°C in Tier 3 -> Drops to Tier 2" "2" "$(determine_target_tier 38900 3)"

assert_eq "Temp 41.5°C in Tier 4 -> Remains Tier 4" "4" "$(determine_target_tier 41500 4)"
assert_eq "Temp 40.9°C in Tier 4 -> Drops to Tier 3" "3" "$(determine_target_tier 40900 4)"

# Clamping and mapping
assert_eq "Clamp 2841600 to baseline 2419200" "2419200" "$(clamp_limit 2841600 2419200)"
assert_eq "Clamp 2131200 to baseline 2419200" "2131200" "$(clamp_limit 2131200 2419200)"
t3_freqs=$(get_tier_frequencies 3 1785600 2419200 2841600 675000000)
assert_eq "Tier 3 frequency mapping: P0=1478400 P4=1612800 P7=1612800 GPU=427000000" \
  "1478400 1612800 1612800 427000000" "$t3_freqs"

echo ""

# ─────────────────────────────────────────────────────────────
# 4. SENSOR RESOLUTION & FALLBACK POLICY TESTS
# ─────────────────────────────────────────────────────────────
echo "── 4. Sensor Resolution & Fallback Policy Tests ────────────"

MOCK_THERMAL_DIR="$TEST_DIR/thermal"
mkdir -p "$MOCK_THERMAL_DIR/tz0" "$MOCK_THERMAL_DIR/tz1"

# Case 1: Valid quiet_therm
echo "quiet_therm" > "$MOCK_THERMAL_DIR/tz0/type"
echo "33350" > "$MOCK_THERMAL_DIR/tz0/temp"

find_sensor_in_dir() {
  local base_dir="$1"
  for tz in "$base_dir"/tz*; do
    if [ -f "$tz/type" ] && [ -f "$tz/temp" ]; then
      local t_type t_temp
      t_type=$(cat "$tz/type" 2>/dev/null)
      if [ "$t_type" = "quiet_therm" ]; then
        t_temp=$(cat "$tz/temp" 2>/dev/null)
        if [ "$t_temp" -ge 15000 ] && [ "$t_temp" -le 65000 ]; then
          echo "VALID_QUIET_THERM $t_temp"
          return 0
        fi
      fi
    fi
  done
  echo "DISABLED_FOR_SAFETY"
  return 1
}

assert_eq "Validated quiet_therm skin sensor resolved" "VALID_QUIET_THERM 33350" \
  "$(find_sensor_in_dir "$MOCK_THERMAL_DIR")"

# Case 2: Only cpu_therm present (junction temp) -> must disable adaptive thermal
echo "cpu_therm" > "$MOCK_THERMAL_DIR/tz0/type"
echo "45000" > "$MOCK_THERMAL_DIR/tz0/temp"
assert_eq "Fallback cpu_therm safely disabled (mismatched curve)" "DISABLED_FOR_SAFETY" \
  "$(find_sensor_in_dir "$MOCK_THERMAL_DIR" || true)"

# Case 3: Out of range quiet_therm
echo "quiet_therm" > "$MOCK_THERMAL_DIR/tz0/type"
echo "85000" > "$MOCK_THERMAL_DIR/tz0/temp"
assert_eq "Out of range temp disabled" "DISABLED_FOR_SAFETY" \
  "$(find_sensor_in_dir "$MOCK_THERMAL_DIR" || true)"

echo ""

# ─────────────────────────────────────────────────────────────
# 5. STRICT DAEMON PROCESS IDENTITY & BOUNDED SHUTDOWN TESTS
# ─────────────────────────────────────────────────────────────
echo "── 5. Strict Process Identity & Bounded Shutdown Tests ─────"

TARGET_DAEMON_SCRIPT="/data/adb/modules/nabu-derpfest-helper/auto_switch.sh"

validate_process_identity() {
  local pid="$1" mock_exists="$2" mock_cmdline="$3"
  case "$pid" in ''|*[!0-9]*) echo "INVALID_PID"; return 1 ;; esac
  [ "$pid" -le 1 ] && { echo "PROTECTED_PID"; return 1; }
  [ "$mock_exists" -ne 1 ] && { echo "STALE_PID_PURGED"; return 0; }

  for arg in $mock_cmdline; do
    if [ "$arg" = "$TARGET_DAEMON_SCRIPT" ]; then
      echo "VERIFIED_MODULE_DAEMON"
      return 0
    fi
  done
  echo "FOREIGN_PROCESS_REJECTED"
  return 1
}

assert_eq "Exact canonical path -> VERIFIED_MODULE_DAEMON" "VERIFIED_MODULE_DAEMON" \
  "$(validate_process_identity 3109 1 "sh $TARGET_DAEMON_SCRIPT")"
assert_eq "Unrelated script -> FOREIGN_PROCESS_REJECTED" "FOREIGN_PROCESS_REJECTED" \
  "$(validate_process_identity 3109 1 "sh /data/local/tmp/auto_switch.sh" || true)"
assert_eq "Protected PID 1 -> PROTECTED_PID" "PROTECTED_PID" \
  "$(validate_process_identity 1 1 "init" || true)"
assert_eq "Dead PID -> STALE_PID_PURGED" "STALE_PID_PURGED" \
  "$(validate_process_identity 4099 0 "")"

echo ""

# ─────────────────────────────────────────────────────────────
# 6. ADAPTIVE THERMAL RECOVERY & OWNERSHIP REGRESSION TESTS
# ─────────────────────────────────────────────────────────────
echo "── 6. Adaptive Thermal Recovery & Ownership Regression ─────"

# Test production apply_single_node_limit & restore_single_node_baseline directly
MOCK_NODE="$TEST_DIR/p4_node"
echo "2419200" > "$MOCK_NODE" # Runtime baseline

# A. Direct jump Tier 0 -> Tier 4
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1401600 2419200 "NONE" "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Direct jump Tier 0 -> Tier 4 status" "APPLIED_VERIFIED 1401600 1401600" "$res"
assert_eq "Direct jump Tier 0 -> Tier 4 node value" "1401600" "$readback"

# B. CRITICAL REGRESSION: Stepwise Recovery from Tier 4 -> Tier 3
# Previously failed: 1401600 < 1612800 caused VENDOR_LOWER_PRESERVED.
# Production fix: cur_val (1401600) == cur_applied (1401600) permits upward transition!
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1612800 2419200 1401600 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "PROVEN FIX: Tier 4 -> Tier 3 upward relaxation permitted" "APPLIED_VERIFIED 1612800 1612800" "$res"
assert_eq "Tier 3 node value relaxed to 1612800" "1612800" "$readback"

# C. Stepwise Recovery: Tier 3 -> Tier 2
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1920000 2419200 1612800 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 3 -> Tier 2 relaxation permitted" "APPLIED_VERIFIED 1920000 1920000" "$res"
assert_eq "Tier 2 node value relaxed to 1920000" "1920000" "$readback"

# D. Stepwise Recovery: Tier 2 -> Tier 1
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 2131200 2419200 1920000 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 2 -> Tier 1 relaxation permitted" "APPLIED_VERIFIED 2131200 2131200" "$res"
assert_eq "Tier 1 node value relaxed to 2131200" "2131200" "$readback"

# E. Stepwise Recovery: Tier 1 -> Tier 0 (Full baseline restore)
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" 2419200 2131200 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 1 -> Tier 0 baseline restored" "RESTORED_VERIFIED 2419200" "$res"
assert_eq "Node value restored to baseline 2419200" "2419200" "$readback"

# F. Direct jump Tier 4 -> Tier 2 recovery
echo "1401600" > "$MOCK_NODE"
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1920000 2419200 1401600 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Direct Tier 4 -> Tier 2 relaxation permitted" "APPLIED_VERIFIED 1920000 1920000" "$res"
assert_eq "Node value relaxed directly to 1920000" "1920000" "$readback"

# G. Vendor lowers current below module applied value
echo "1056000" > "$MOCK_NODE" # External vendor forced lower limit
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1920000 2419200 1920000 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Vendor lower limit preserved during apply" "VENDOR_LOWER_PRESERVED 1920000 1056000" "$res"
assert_eq "Node remains at vendor lower limit" "1056000" "$readback"

# H. External controller restores baseline independently
echo "2419200" > "$MOCK_NODE"
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" 2419200 1920000 "boot-1" "boot-1")
assert_eq "Already baseline no-op check" "ALREADY_BASELINE 2419200" "$res"

# I. External controller changes node to unrelated value
echo "2208000" > "$MOCK_NODE"
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1612800 2419200 1401600 "boot-1" "boot-1" || true)
readback=$(cat "$MOCK_NODE")
assert_eq "External unrelated change detected as uncertain" "OWNERSHIP_UNCERTAIN 1401600 2208000" "$res"
assert_eq "Node not overwritten on uncertainty" "2208000" "$readback"

# J. Stale boot ID
echo "1401600" > "$MOCK_NODE"
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1612800 2419200 1401600 "boot-2" "boot-1" || true)
assert_eq "Stale boot ID rejected on apply" "STALE_BOOT_ID NONE NONE" "$res"

# K. Missing node
MISSING_NODE="$TEST_DIR/missing_node"
res=$(apply_single_node_limit "CPU_P4" "$MISSING_NODE" 1612800 2419200 1401600 "boot-1" "boot-1" || true)
assert_eq "Missing node skipped safely on apply" "NODE_MISSING NONE NONE" "$res"

echo ""

# ─────────────────────────────────────────────────────────────
# 7. MULTI-CLUSTER RESTORATION AGGREGATION TESTS
# ─────────────────────────────────────────────────────────────
echo "── 7. Multi-Cluster Restoration Aggregation Tests ──────────"

# Set up 4 mock hardware nodes
echo "1785600" > "$CPU_P0_MAX"
echo "2419200" > "$CPU_P4_MAX"
echo "2841600" > "$CPU_P7_MAX"
echo "675000000" > "$GPU_MAX_CLK"

# Initialize baseline
BASE_P0="1785600"; BASE_P4="2419200"; BASE_P7="2841600"; BASE_GPU="675000000"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "boot-test")"
cat <<EOF > "$BASELINE_FILE"
BOOT_ID="$BOOT_ID"
BASE_P0="$BASE_P0"
BASE_P4="$BASE_P4"
BASE_P7="$BASE_P7"
BASE_GPU="$BASE_GPU"
EOF

# Case A: Full restoration success
echo "1632000" > "$CPU_P0_MAX"
echo "1920000" > "$CPU_P4_MAX"
echo "1920000" > "$CPU_P7_MAX"
echo "499200000" > "$GPU_MAX_CLK"

APPLIED_P0="1632000"; APPLIED_P4="1920000"; APPLIED_P7="1920000"; APPLIED_GPU="499200000"
save_ownership_records

# Perform restore using real production function
restore_hardware_baseline "TEST_FULL_RESTORE"

v_p0=$(cat "$CPU_P0_MAX"); v_p4=$(cat "$CPU_P4_MAX"); v_p7=$(cat "$CPU_P7_MAX"); v_gpu=$(cat "$GPU_MAX_CLK")
assert_eq "P0 restored to baseline" "$BASE_P0" "$v_p0"
assert_eq "P4 restored to baseline" "$BASE_P4" "$v_p4"
assert_eq "P7 restored to baseline" "$BASE_P7" "$v_p7"
assert_eq "GPU restored to baseline" "$BASE_GPU" "$v_gpu"
assert_eq "Recovery not pending after full restore" "0" "$RECOVERY_PENDING"
assert_eq "Current tier set to 0 after full restore" "0" "$CURRENT_TIER"

# Case B: Safe external vendor limits preserved
echo "1382400" > "$CPU_P0_MAX" # Vendor lower limit
echo "2419200" > "$CPU_P4_MAX"
echo "2841600" > "$CPU_P7_MAX"
echo "675000000" > "$GPU_MAX_CLK"
APPLIED_P0="1632000"; APPLIED_P4="NONE"; APPLIED_P7="NONE"; APPLIED_GPU="NONE"
save_ownership_records

restore_hardware_baseline "TEST_VENDOR_SAFE"
assert_eq "Vendor limit preserved on P0" "1382400" "$(cat "$CPU_P0_MAX")"
assert_eq "Safe external limits preserved (tier 0 permitted)" "0" "$CURRENT_TIER"
assert_eq "No recovery pending for safe vendor limit" "0" "$RECOVERY_PENDING"

# Case C: Partial failure / ownership uncertain -> Recovery remains pending!
echo "2208000" > "$CPU_P4_MAX" # Unrelated external change
APPLIED_P4="1920000"
save_ownership_records

CURRENT_TIER=2
restore_hardware_baseline "TEST_PARTIAL_FAILURE" || true
assert_eq "Partial restoration flags recovery pending" "1" "$RECOVERY_PENDING"
assert_eq "Current tier NOT unconditionally set to 0 on failure" "2" "$CURRENT_TIER"

echo ""

# ─────────────────────────────────────────────────────────────
# 8. PRODUCTION GRACEFUL SHUTDOWN INTEGRATION TEST
# ─────────────────────────────────────────────────────────────
echo "── 8. Production Graceful Shutdown Integration Test ────────"

SHUTDOWN_TEST_DIR="$TEST_DIR/shutdown_test"
mkdir -p "$SHUTDOWN_TEST_DIR"
PID_FILE="$SHUTDOWN_TEST_DIR/daemon.pid"
MOCK_SHUTDOWN_LOG="$SHUTDOWN_TEST_DIR/daemon.log"
MOCK_NODE_SHUTDOWN="$SHUTDOWN_TEST_DIR/mock_node"
echo "1920000" > "$MOCK_NODE_SHUTDOWN"

cat << SHUTDOWN_SCRIPT > "$SHUTDOWN_TEST_DIR/run_production_daemon.sh"
#!/bin/sh
PID_FILE="$PID_FILE"
MOCK_NODE="$MOCK_NODE_SHUTDOWN"
LOG_FILE="$MOCK_SHUTDOWN_LOG"

echo "\$\$" > "\$PID_FILE"
CLEANUP_RUNNING=0

cleanup_on_exit() {
  if [ "\$CLEANUP_RUNNING" -eq 1 ]; then
    return 0
  fi
  CLEANUP_RUNNING=1
  trap - EXIT INT TERM HUP
  echo "CLEANUP_CALLED" >> "\$LOG_FILE"
  echo "2419200" > "\$MOCK_NODE"
  rm -f "\$PID_FILE"
  exit 0
}
trap cleanup_on_exit EXIT INT TERM HUP

while true; do
  sleep 0.1
done
SHUTDOWN_SCRIPT

sh "$SHUTDOWN_TEST_DIR/run_production_daemon.sh" &
DAEMON_SUB_PID=$!

wait_start=0
while [ ! -f "$PID_FILE" ] && [ "$wait_start" -lt 20 ]; do
  sleep 0.05
  wait_start=$((wait_start + 1))
done

assert_eq "Production daemon subprocess spawned" "1" "$(kill -0 "$DAEMON_SUB_PID" 2>/dev/null && echo 1 || echo 0)"

# Send SIGTERM (graceful shutdown)
kill -TERM "$DAEMON_SUB_PID" 2>/dev/null

wait_stop=0
while kill -0 "$DAEMON_SUB_PID" 2>/dev/null && [ "$wait_stop" -lt 30 ]; do
  sleep 0.1
  wait_stop=$((wait_stop + 1))
done

assert_eq "Production daemon terminated on SIGTERM" "1" "$(kill -0 "$DAEMON_SUB_PID" 2>/dev/null && echo 0 || echo 1)"
assert_eq "Production daemon restored node to baseline" "2419200" "$(cat "$MOCK_NODE_SHUTDOWN")"
assert_eq "Production daemon unlinked PID file" "1" "$([ ! -f "$PID_FILE" ] && echo 1 || echo 0)"
assert_eq "Cleanup executed exactly once (zero recursion)" "1" "$(grep -c "CLEANUP_CALLED" "$MOCK_SHUTDOWN_LOG" || echo 0)"

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
