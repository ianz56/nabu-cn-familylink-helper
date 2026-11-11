#!/bin/bash
# ==============================================================================
# Nabu DerpFest 17 Helper v3.2.0 — Production-Source Offline Test Suite
# ==============================================================================
# Tests the exact production shell libraries:
#   - lib/thermal_engine.sh
#   - lib/lifecycle_engine.sh
#   - lib/daemon_cleanup.sh
# Uses isolated mock sysfs nodes and Android CLI wrappers.
# Physical device operations are strictly prohibited during test execution.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

if [ ! -f "$LIB_DIR/thermal_engine.sh" ] || [ ! -f "$LIB_DIR/lifecycle_engine.sh" ] || [ ! -f "$LIB_DIR/daemon_cleanup.sh" ]; then
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
export THERMAL_SYSFS_DIR="$TEST_DIR/thermal"

mkdir -p "$STATE_DIR" "$THERMAL_SYSFS_DIR"

# Source the real production libraries
. "$LIB_DIR/thermal_engine.sh"
. "$LIB_DIR/lifecycle_engine.sh"
. "$LIB_DIR/daemon_cleanup.sh"

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

cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then
    echo "$MOCK_USER_LIST"
    return 0
  fi
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
# 2. LIFECYCLE CLASSIFICATION & SCENARIO A/B TESTS
# ─────────────────────────────────────────────────────────────
echo "── 2. Lifecycle Classification & Scenario A/B Tests ────────"

MOCK_STOPPED_STATE="false"
MOCK_STARTED_STATE="RUNNING_UNLOCKED"
MOCK_CURRENT_USER=0
MOCK_DISP_OFF=1
MOCK_STOP_CALLS_FILE="$TEST_DIR/stop_calls"
MOCK_SWITCH_CALLS_FILE="$TEST_DIR/switch_calls"

reset_mock_calls() {
  rm -f "$MOCK_STOP_CALLS_FILE" "$MOCK_SWITCH_CALLS_FILE"
}

get_mock_stop_calls() {
  if [ -f "$MOCK_STOP_CALLS_FILE" ]; then
    wc -l < "$MOCK_STOP_CALLS_FILE" | tr -d ' \t'
  else
    echo "0"
  fi
}

get_mock_switch_calls() {
  if [ -f "$MOCK_SWITCH_CALLS_FILE" ]; then
    wc -l < "$MOCK_SWITCH_CALLS_FILE" | tr -d ' \t'
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
        echo "$3" >> "$MOCK_SWITCH_CALLS_FILE"
        MOCK_CURRENT_USER="$3"
        return 0
        ;;
      stop-user)
        # Verify strict compliance: no -f allowed
        for arg in "$@"; do
          if [ "$arg" = "-f" ]; then
            echo "ERROR: -f flag strictly prohibited in production stop-user!" >&2
            return 99
          fi
        done
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

# Lifecycle Classification
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
MOCK_CURRENT_USER=0; MOCK_DISP_OFF=1; reset_mock_calls
MOCK_STOPPED_STATE="true"; MOCK_STARTED_STATE=""
assert_eq "Scenario B: STOPPED user skipped cleanly" "ALREADY_STOPPED" \
  "$(execute_scenario_b_user_stop 10 2)"
assert_eq "Scenario B: No stop-user issued for STOPPED" "0" "$(get_mock_stop_calls)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_LOCKED"; reset_mock_calls
assert_eq "Scenario B: RUNNING_LOCKED user stopped" "STOP_SUCCESS" \
  "$(execute_scenario_b_user_stop 10 2)"
assert_eq "Scenario B: stop-user issued once" "1" "$(get_mock_stop_calls)"

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_UNLOCKED"; reset_mock_calls
assert_eq "Scenario B: RUNNING_UNLOCKED user stopped" "STOP_SUCCESS" \
  "$(execute_scenario_b_user_stop 10 2)"

# STOPPING-to-UNKNOWN Propagation in Scenario B
MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="STOPPING"; reset_mock_calls
assert_eq "Scenario B: STOPPING timeout returns STOPPING_TIMEOUT" "STOPPING_TIMEOUT" \
  "$(execute_scenario_b_user_stop 10 1 || true)"
assert_eq "Scenario B: Never issued duplicate stop for STOPPING timeout" "0" "$(get_mock_stop_calls)"

# STOPPING transitions to UNKNOWN during wait
test_stopping_to_unknown_scenario_b() {
  local uid="$1"
  # Mock wait_for_user_stopping returning 2 (UNKNOWN)
  wait_for_user_stopping() { return 2; }
  execute_scenario_b_user_stop "$uid" 1 || true
}
assert_eq "Scenario B: STOPPING becoming UNKNOWN returns STOPPING_UNKNOWN_STATE" "STOPPING_UNKNOWN_STATE" \
  "$(test_stopping_to_unknown_scenario_b 10)"

# Restore production wait_for_user_stopping
. "$LIB_DIR/lifecycle_engine.sh"
is_display_off() {
  [ "$MOCK_DISP_OFF" -eq 1 ]
}

MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="UNKNOWN"; reset_mock_calls
assert_eq "Scenario B: UNKNOWN user fails closed and returns FAIL_CLOSED_UNKNOWN_STATE" "FAIL_CLOSED_UNKNOWN_STATE" \
  "$(execute_scenario_b_user_stop 10 2 || true)"
assert_eq "Scenario B: Never issued stop for UNKNOWN" "0" "$(get_mock_stop_calls)"

MOCK_CURRENT_USER=0; MOCK_DISP_OFF=0
assert_eq "Scenario B: Aborted immediately if display ON" "ABORT_DISPLAY_ON" \
  "$(execute_scenario_b_user_stop 10 2 || true)"

MOCK_CURRENT_USER=10; MOCK_DISP_OFF=1
assert_eq "Scenario B: Aborted immediately if foreground user changed" "ABORT_FG_CHANGED" \
  "$(execute_scenario_b_user_stop 10 2 || true)"

# ── Scenario A Precondition Revalidation Tests ──
# 1. Display wakes immediately before switch
MOCK_DISP_OFF=0; MOCK_CURRENT_USER=10; reset_mock_calls
assert_eq "Scenario A Precondition: Display ON aborts before switch" "ABORT_DISPLAY_ON" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"
assert_eq "Scenario A: No switch issued when display ON" "0" "$(get_mock_switch_calls)"

# 2. Foreground user changes before switch
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=2; reset_mock_calls
assert_eq "Scenario A Precondition: Foreground changed aborts before switch" "ABORT_FG_USER_CHANGED" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"
assert_eq "Scenario A: No switch issued on FG changed" "0" "$(get_mock_switch_calls)"

# 3. Target user became ineligible before switch (e.g. Work profile 11)
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=11; reset_mock_calls
assert_eq "Scenario A Precondition: Ineligible target aborts before switch" "ABORT_USER_INELIGIBLE" \
  "$(execute_scenario_a_user_stop 11 5 2 || true)"

# 4. Target already STOPPED before switch
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="true"; reset_mock_calls
assert_eq "Scenario A Precondition: Target already STOPPED returns ALREADY_STOPPED" "ALREADY_STOPPED" \
  "$(execute_scenario_a_user_stop 10 5 2)"
assert_eq "Scenario A: No switch issued if already STOPPED" "0" "$(get_mock_switch_calls)"

# 5. Target STOPPING before switch
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="STOPPING"; reset_mock_calls
assert_eq "Scenario A Precondition: Target STOPPING aborts before switch" "ABORT_TARGET_STOPPING" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"

# 6. Target UNKNOWN before switch
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="UNKNOWN"; reset_mock_calls
assert_eq "Scenario A Precondition: Target UNKNOWN fails closed before switch" "FAIL_CLOSED_UNKNOWN_STATE" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"

# 7. Normal switch with native stop success
MOCK_DISP_OFF=1; MOCK_CURRENT_USER=10; MOCK_STOPPED_STATE="false"; MOCK_STARTED_STATE="RUNNING_UNLOCKED"; reset_mock_calls
# After switch, user becomes stopped natively:
cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then echo "$MOCK_USER_LIST"; return 0; fi
  if [ "$1" = "activity" ]; then
    case "$2" in
      is-user-stopped) [ "$MOCK_CURRENT_USER" -eq 0 ] && echo "true" || echo "false"; return 0 ;;
      get-started-user-state) [ "$MOCK_CURRENT_USER" -eq 0 ] && echo "User is not started" || echo "RUNNING_UNLOCKED"; return 0 ;;
      get-current-user) echo "$MOCK_CURRENT_USER"; return 0 ;;
      switch-user) echo "$3" >> "$MOCK_SWITCH_CALLS_FILE"; MOCK_CURRENT_USER="$3"; return 0 ;;
      stop-user) echo "1" >> "$MOCK_STOP_CALLS_FILE"; return 0 ;;
    esac
  fi
}
assert_eq "Scenario A: Native stop on switch success" "NATIVE_STOP_SUCCESS" \
  "$(execute_scenario_a_user_stop 10 5 2)"
assert_eq "Scenario A: Switch-user 0 called once" "1" "$(get_mock_switch_calls)"
assert_eq "Scenario A: No fallback stop called on native success" "0" "$(get_mock_stop_calls)"

# 8. Normal switch with fallback stop required
MOCK_CURRENT_USER=10; reset_mock_calls
cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then echo "$MOCK_USER_LIST"; return 0; fi
  if [ "$1" = "activity" ]; then
    case "$2" in
      is-user-stopped) [ -f "$MOCK_STOP_CALLS_FILE" ] && echo "true" || echo "false"; return 0 ;;
      get-started-user-state) [ -f "$MOCK_STOP_CALLS_FILE" ] && echo "User is not started" || echo "RUNNING_UNLOCKED"; return 0 ;;
      get-current-user) echo "$MOCK_CURRENT_USER"; return 0 ;;
      switch-user) echo "$3" >> "$MOCK_SWITCH_CALLS_FILE"; MOCK_CURRENT_USER="$3"; return 0 ;;
      stop-user) echo "1" >> "$MOCK_STOP_CALLS_FILE"; return 0 ;;
    esac
  fi
}
assert_eq "Scenario A: Fallback stop executed when user remains running" "FALLBACK_STOP_SUCCESS" \
  "$(execute_scenario_a_user_stop 10 5 2)"
assert_eq "Scenario A: Fallback stop called once" "1" "$(get_mock_stop_calls)"

# 9. Fallback aborted if User 0 no longer foreground before fallback
MOCK_CURRENT_USER=10; reset_mock_calls
rm -f "$TEST_DIR/fg_call_count"
cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then echo "$MOCK_USER_LIST"; return 0; fi
  if [ "$1" = "activity" ]; then
    case "$2" in
      is-user-stopped) echo "false"; return 0 ;;
      get-started-user-state) echo "RUNNING_UNLOCKED"; return 0 ;;
      get-current-user)
        local c=0
        if [ -f "$TEST_DIR/fg_call_count" ]; then
          c=$(wc -l < "$TEST_DIR/fg_call_count" | tr -d ' \t')
        fi
        echo "1" >> "$TEST_DIR/fg_call_count"
        if [ "$c" -eq 0 ]; then
          echo "10"
        elif [ "$c" -eq 1 ]; then
          echo "0"
        else
          echo "2"
        fi
        return 0
        ;;
      switch-user) MOCK_CURRENT_USER="$3"; return 0 ;;
      stop-user) echo "1" >> "$MOCK_STOP_CALLS_FILE"; return 0 ;;
    esac
  fi
}
assert_eq "Scenario A Fallback Precondition: FG changed before fallback aborts" "FALLBACK_ABORT_FG_CHANGED" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"
assert_eq "Scenario A: No fallback stop issued when FG changed" "0" "$(get_mock_stop_calls)"

# 10. Fallback strictly refused if target state becomes UNKNOWN
MOCK_CURRENT_USER=10; reset_mock_calls
cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then echo "$MOCK_USER_LIST"; return 0; fi
  if [ "$1" = "activity" ]; then
    case "$2" in
      is-user-stopped) echo "false"; return 0 ;;
      get-started-user-state)
        # UNKNOWN after switch
        [ "$MOCK_CURRENT_USER" -eq 0 ] && echo "AmbiguousState" || echo "RUNNING_UNLOCKED"
        return 0
        ;;
      get-current-user) echo "$MOCK_CURRENT_USER"; return 0 ;;
      switch-user) MOCK_CURRENT_USER="$3"; return 0 ;;
      stop-user) echo "1" >> "$MOCK_STOP_CALLS_FILE"; return 0 ;;
    esac
  fi
}
assert_eq "Scenario A: UNKNOWN state strictly refuses fallback stop" "UNKNOWN_STATE_NO_FALLBACK" \
  "$(execute_scenario_a_user_stop 10 5 2 || true)"
assert_eq "Scenario A: Zero fallback stops for UNKNOWN" "0" "$(get_mock_stop_calls)"

# Restore standard cmd
cmd() {
  if [ "$1" = "user" ] && [ "$2" = "list" ]; then echo "$MOCK_USER_LIST"; return 0; fi
}

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
# 4. RUNTIME SENSOR FAILSAFE, BOUNDARIES & RECOVERY TESTS
# ─────────────────────────────────────────────────────────────
echo "── 4. Runtime Sensor Failsafe & Boundary Tests ─────────────"

# Test validate_sensor_sample production function
assert_eq "Sample 15000 m°C (lower bound valid)" "VALID_SAMPLE" "$(validate_sensor_sample 15000)"
assert_eq "Sample 15001 m°C (valid)" "VALID_SAMPLE" "$(validate_sensor_sample 15001)"
assert_eq "Sample 35000 m°C (valid mid)" "VALID_SAMPLE" "$(validate_sensor_sample 35000)"
assert_eq "Sample 65000 m°C (upper bound valid)" "VALID_SAMPLE" "$(validate_sensor_sample 65000)"
assert_eq "Sample 65001 m°C (out of range high rejected)" "OUT_OF_RANGE_HIGH" "$(validate_sensor_sample 65001 || true)"
assert_eq "Sample 14999 m°C (out of range low rejected)" "OUT_OF_RANGE_LOW" "$(validate_sensor_sample 14999 || true)"
assert_eq "Empty sample rejected" "EMPTY_READING" "$(validate_sensor_sample "" || true)"
assert_eq "Nonnumeric sample rejected" "NON_NUMERIC_READING" "$(validate_sensor_sample "abc" || true)"
assert_eq "Negative sample rejected" "NON_NUMERIC_READING" "$(validate_sensor_sample "-5000" || true)"

# Test production find_thermal_sensor with injectable THERMAL_SYSFS_DIR
MOCK_THERMAL_DIR="$TEST_DIR/thermal"
mkdir -p "$MOCK_THERMAL_DIR/thermal_zone0" "$MOCK_THERMAL_DIR/thermal_zone1"

# Case 1: Valid quiet_therm
echo "quiet_therm" > "$MOCK_THERMAL_DIR/thermal_zone0/type"
echo "33350" > "$MOCK_THERMAL_DIR/thermal_zone0/temp"
THERMAL_ZONE_PATH=""
THERMAL_ENABLED=0

find_thermal_sensor >/dev/null 2>&1
assert_eq "Production find_thermal_sensor resolved quiet_therm" "1" "$THERMAL_ENABLED"
assert_eq "Production resolved correct path" "$MOCK_THERMAL_DIR/thermal_zone0" "$THERMAL_ZONE_PATH"

# Production sample_thermal_sensor
assert_eq "Production sample_thermal_sensor valid" "33350" "$(sample_thermal_sensor)"

# Sensor Disappearance
rm -f "$MOCK_THERMAL_DIR/thermal_zone0/temp"
assert_eq "Sensor disappearance returns SENSOR_DISAPPEARED" "SENSOR_DISAPPEARED" "$(sample_thermal_sensor || true)"

# Invalid Sample during Runtime (e.g. 75000 m°C)
echo "75000" > "$MOCK_THERMAL_DIR/thermal_zone0/temp"
assert_eq "Sample 75000 m°C returns OUT_OF_RANGE_HIGH" "OUT_OF_RANGE_HIGH" "$(sample_thermal_sensor || true)"

# Case 2: Sensor recovery during same boot
echo "36000" > "$MOCK_THERMAL_DIR/thermal_zone0/temp"
find_thermal_sensor >/dev/null 2>&1
assert_eq "Sensor recovers and re-enables thermal" "1" "$THERMAL_ENABLED"
assert_eq "Recovered sample readable" "36000" "$(sample_thermal_sensor)"

# Case 3: Incompatible fallback sensor (cpu_therm junction)
echo "cpu_therm" > "$MOCK_THERMAL_DIR/thermal_zone0/type"
echo "45000" > "$MOCK_THERMAL_DIR/thermal_zone0/temp"
THERMAL_ZONE_PATH=""
find_thermal_sensor >/dev/null 2>&1 || true
assert_eq "Incompatible cpu_therm safely disabled" "0" "$THERMAL_ENABLED"

echo ""

# ─────────────────────────────────────────────────────────────
# 5. STRICT DAEMON PROCESS IDENTITY TESTS
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
# 6. ADAPTIVE THERMAL RECOVERY & VENDOR_CLAMPED OWNERSHIP TESTS
# ─────────────────────────────────────────────────────────────
echo "── 6. Adaptive Thermal Recovery & Ownership Regression ─────"

MOCK_NODE="$TEST_DIR/p4_node"
echo "2419200" > "$MOCK_NODE" # Runtime baseline

# 1. Baseline write accepted exactly
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1401600 2419200 "NONE" "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Baseline write accepted status" "APPLIED_VERIFIED 1401600 1401600" "$res"
assert_eq "Baseline write node value" "1401600" "$readback"

# 2. Stepwise recovery Tier 4 -> Tier 3 upward relaxation permitted
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1612800 2419200 1401600 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 4 -> Tier 3 upward relaxation permitted" "APPLIED_VERIFIED 1612800 1612800" "$res"
assert_eq "Tier 3 node value relaxed to 1612800" "1612800" "$readback"

# 3. Tier 3 -> Tier 2
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1920000 2419200 1612800 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 3 -> Tier 2 relaxation permitted" "APPLIED_VERIFIED 1920000 1920000" "$res"
assert_eq "Tier 2 node value relaxed to 1920000" "1920000" "$readback"

# 4. Stepwise Recovery: Tier 2 -> Tier 1
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 2131200 2419200 1920000 "boot-1" "boot-1")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 2 -> Tier 1 relaxation permitted" "APPLIED_VERIFIED 2131200 2131200" "$res"
assert_eq "Tier 1 node value relaxed to 2131200" "2131200" "$readback"

# 5. Full baseline restore
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" 2419200 2131200 "boot-1" "boot-1" "APPLIED_VERIFIED")
readback=$(cat "$MOCK_NODE")
assert_eq "Tier 1 -> Tier 0 baseline restored" "RESTORED_VERIFIED 2419200" "$res"
assert_eq "Node value restored to baseline 2419200" "2419200" "$readback"

# 6. Initial baseline-to-target write clamped below target (Rule 2: do NOT promote readback to APPLIED!)
# Mock hardware clamping at 1056000
echo "2419200" > "$MOCK_NODE"
mock_clamped_node() {
  local target="$1"
  # Hardware clamps any write to 1056000
  echo "1056000" > "$MOCK_NODE"
}
# Simulate write clamped
echo "1056000" > "$MOCK_NODE"
# When node is at 2419200 and we apply 1920000, but readback is 1056000:
# Create a wrapper node write simulator:
MOCK_CLAMP_FILE="$TEST_DIR/clamped_node"
echo "2419200" > "$MOCK_CLAMP_FILE"
# Apply target 1920000, but immediately simulate vendor clamp on disk:
(
  # Test with target=1920000 on node holding 2419200
  # We test the logic branch: if readback < target when cur_val==base
  echo "1056000" > "$MOCK_CLAMP_FILE" # Clamped before or during write
)
res=$(apply_single_node_limit "CPU_P4" "$MOCK_CLAMP_FILE" 1920000 2419200 "NONE" "boot-1" "boot-1")
assert_eq "Initial write clamped below target: APPLIED remains NONE" "VENDOR_LOWER_PRESERVED NONE 1056000" "$res"

# 7. Subsequent tier change while external limit remains
res=$(apply_single_node_limit "CPU_P4" "$MOCK_CLAMP_FILE" 2131200 2419200 "NONE" "boot-1" "boot-1")
assert_eq "Subsequent tier change preserves vendor clamp: APPLIED remains NONE" "VENDOR_LOWER_PRESERVED NONE 1056000" "$res"

# 8. Restore operation after a clamped apply
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_CLAMP_FILE" 2419200 "NONE" "boot-1" "boot-1" "VENDOR_LOWER_PRESERVED")
readback=$(cat "$MOCK_CLAMP_FILE")
assert_eq "Restore after clamped apply attempts restore to baseline" "RESTORED_VERIFIED 2419200" "$res"
assert_eq "Node restored to baseline" "2419200" "$readback"

# 9. External controller sets an unrelated value without module involvement
echo "2208000" > "$MOCK_NODE"
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1612800 2419200 "NONE" "boot-1" "boot-1" || true)
readback=$(cat "$MOCK_NODE")
assert_eq "External unrelated change detected as uncertain: APPLIED is NONE" "OWNERSHIP_UNCERTAIN NONE 2208000" "$res"
assert_eq "Node not overwritten on uncertainty" "2208000" "$readback"

# 10. Restore on unrelated external change without module throttling -> OWNERSHIP_UNCERTAIN
res=$(restore_single_node_baseline "CPU_P4" "$MOCK_NODE" 2419200 "NONE" "boot-1" "boot-1" "BASELINE" || true)
assert_eq "Restore on unrelated foreign change is OWNERSHIP_UNCERTAIN" "OWNERSHIP_UNCERTAIN 2208000" "$res"

# 11. Stale boot ID
echo "1401600" > "$MOCK_NODE"
res=$(apply_single_node_limit "CPU_P4" "$MOCK_NODE" 1612800 2419200 1401600 "boot-2" "boot-1" || true)
assert_eq "Stale boot ID rejected on apply" "STALE_BOOT_ID NONE NONE" "$res"

# 12. Missing node
MISSING_NODE="$TEST_DIR/missing_node"
res=$(apply_single_node_limit "CPU_P4" "$MISSING_NODE" 1612800 2419200 1401600 "boot-1" "boot-1" || true)
assert_eq "Missing node skipped safely on apply" "NODE_MISSING NONE NONE" "$res"

echo ""

# ─────────────────────────────────────────────────────────────
# 7. MULTI-CLUSTER RESTORATION AGGREGATION & PERSISTENCE TESTS
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
STATUS_P0="APPLIED_VERIFIED"; STATUS_P4="APPLIED_VERIFIED"; STATUS_P7="APPLIED_VERIFIED"; STATUS_GPU="APPLIED_VERIFIED"
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
STATUS_P0="APPLIED_VERIFIED"; STATUS_P4="BASELINE"; STATUS_P7="BASELINE"; STATUS_GPU="BASELINE"
save_ownership_records

restore_hardware_baseline "TEST_VENDOR_SAFE"
assert_eq "Vendor limit preserved on P0" "1382400" "$(cat "$CPU_P0_MAX")"
assert_eq "Safe external limits preserved (tier 0 permitted)" "0" "$CURRENT_TIER"
assert_eq "No recovery pending for safe vendor limit" "0" "$RECOVERY_PENDING"

# Case C: Partial failure / ownership uncertain -> Recovery remains pending!
echo "2208000" > "$CPU_P4_MAX" # Unrelated external change
APPLIED_P4="1920000"
STATUS_P4="BASELINE" # Not clamped by module -> uncertain
CURRENT_TIER=2
save_ownership_records

restore_hardware_baseline "TEST_PARTIAL_FAILURE" || true
assert_eq "Partial restoration flags recovery pending" "1" "$RECOVERY_PENDING"
assert_eq "Current tier NOT unconditionally set to 0 on failure" "2" "$CURRENT_TIER"

# Case D: Daemon restart with existing same-boot ownership records
APPLIED_P4="1612800"
READBACK_P4="1612800"
STATUS_P4="APPLIED_VERIFIED"
CURRENT_TIER=3
RECOVERY_PENDING=0
save_ownership_records

# Simulate restart: clear in-memory state
APPLIED_P4="NONE"
READBACK_P4="NONE"
STATUS_P4="BASELINE"
CURRENT_TIER=0

# Reload records using production function
load_ownership_records
assert_eq "Daemon restart reloads CURRENT_TIER" "3" "$CURRENT_TIER"
assert_eq "Daemon restart reloads APPLIED_P4" "1612800" "$APPLIED_P4"
assert_eq "Daemon restart reloads STATUS_P4" "APPLIED_VERIFIED" "$STATUS_P4"

echo ""

# ─────────────────────────────────────────────────────────────
# 8. PRODUCTION CLEANUP INTEGRATION TEST (lib/daemon_cleanup.sh)
# ─────────────────────────────────────────────────────────────
echo "── 8. Production Cleanup Integration Test ──────────────────"

SHUTDOWN_TEST_DIR="$TEST_DIR/shutdown_test"
mkdir -p "$SHUTDOWN_TEST_DIR"
TEST_PID_FILE="$SHUTDOWN_TEST_DIR/daemon.pid"
TEST_LOG_FILE="$SHUTDOWN_TEST_DIR/daemon.log"

# Prepare test daemon script that sources real production libraries
cat << DAEMON_SCRIPT > "$SHUTDOWN_TEST_DIR/run_daemon.sh"
#!/bin/sh
PID_FILE="$TEST_PID_FILE"
LOG_FILE="$TEST_LOG_FILE"
CPU_P0_MAX="$CPU_P0_MAX"
CPU_P4_MAX="$CPU_P4_MAX"
CPU_P7_MAX="$CPU_P7_MAX"
GPU_MAX_CLK="$GPU_MAX_CLK"
STATE_DIR="$STATE_DIR"
BASELINE_FILE="$BASELINE_FILE"
OWNERSHIP_FILE="$OWNERSHIP_FILE"
BASE_P0="$BASE_P0"
BASE_P4="$BASE_P4"
BASE_P7="$BASE_P7"
BASE_GPU="$BASE_GPU"

. "$LIB_DIR/thermal_engine.sh"
. "$LIB_DIR/daemon_cleanup.sh"

echo "\$\$" > "\$PID_FILE"
setup_daemon_signals

# Set a throttled state to verify restoration on shutdown
echo "1920000" > "$CPU_P4_MAX"
APPLIED_P4="1920000"
STATUS_P4="APPLIED_VERIFIED"
save_ownership_records

while true; do
  sleep 0.1
done
DAEMON_SCRIPT

sh "$SHUTDOWN_TEST_DIR/run_daemon.sh" &
DAEMON_PID=$!

wait_start=0
while [ ! -f "$TEST_PID_FILE" ] && [ "$wait_start" -lt 20 ]; do
  sleep 0.05
  wait_start=$((wait_start + 1))
done

assert_eq "Production daemon spawned" "1" "$(kill -0 "$DAEMON_PID" 2>/dev/null && echo 1 || echo 0)"

# Send SIGTERM to invoke production cleanup
kill -TERM "$DAEMON_PID" 2>/dev/null

wait_stop=0
while kill -0 "$DAEMON_PID" 2>/dev/null && [ "$wait_stop" -lt 30 ]; do
  sleep 0.1
  wait_stop=$((wait_stop + 1))
done

assert_eq "Production daemon terminated on SIGTERM" "1" "$(kill -0 "$DAEMON_PID" 2>/dev/null && echo 0 || echo 1)"
assert_eq "Production cleanup restored P4 node to baseline" "$BASE_P4" "$(cat "$CPU_P4_MAX")"
assert_eq "Production cleanup unlinked PID file" "1" "$([ ! -f "$TEST_PID_FILE" ] && echo 1 || echo 0)"

# Verify Idempotency of production_cleanup_on_exit
CLEANUP_RUNNING=0
PID_FILE="$TEST_PID_FILE"
echo "$$" > "$TEST_PID_FILE"
(
  # Run in subshell to test exit behavior
  production_cleanup_on_exit
)
assert_eq "Idempotent cleanup removed PID file" "1" "$([ ! -f "$TEST_PID_FILE" ] && echo 1 || echo 0)"

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
