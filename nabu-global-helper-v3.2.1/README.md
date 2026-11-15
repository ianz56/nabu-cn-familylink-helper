# Nabu DerpFest 17 Helper v3.2.0

**Target Device:** Xiaomi Pad 5 (`nabu` / `nabu_global`)<br>
**Target Platform:** DerpFest 17 / Android 17 / API 37 (`CP2A.260605.016`)<br>
**Kernel:** Linux 4.14.357-g0848039c6f79 (Qualcomm Snapdragon 860 / `sm8150`)<br>
**Root Provider:** KernelSU 3.3.0 (uapi: 2)<br>
**Version:** v3.2.0 (versionCode `320`)<br>

---

## Overview

Nabu DerpFest 17 Helper v3.2.0 provides autonomous dynamic secondary user lifecycle management and Second Space adaptive thermal throttling for the Xiaomi Pad 5 running DerpFest 17.

### Core Capabilities

1. **Dynamic Multi-User Lifecycle Management:**
   * **User 0 (Main User):** Permanently immutable and protected. Never stopped, never switched away from automatically, and never subject to thermal throttling.
   * **Dynamic Secondary Users:** Discovers eligible full secondary users (`android.os.usertype.full.SECONDARY`, e.g. User 1, 2, 10, 11) at runtime via `cmd user list -v`. No user IDs, names, or serials are hardcoded.
   * **Strict Profile Exclusion:** Work profiles (`profile.MANAGED`), dual-app clone profiles (`profile.CLONE`), Android 15+ private space (`profile.PRIVATE`), system accounts, and guest profiles are strictly excluded from independent lifecycle stops.

2. **Native Stop-on-Switch Synergy:**
   * Automatically initializes `cmd activity set-stop-user-on-switch true` via `service.sh` upon boot completion.
   * In **Scenario A** (Secondary User Foreground), when the 600-second display-off deadline is reached, the daemon switches to User 0 (`switch-user 0`). It checks if native switch policy has already stopped the user; duplicate stop commands are bypassed. Fallback `stop-user -w` is issued only if needed.
   * In **Scenario B** (User 0 Foreground), background-running secondary users are discovered and stopped sequentially after a 600-second display-off period, with display-off and User 0 state revalidated before each operation.

3. **Multi-Signal Fail-Closed Display State Detection:**
   * Validates hardware backlight brightness (`0`), PowerManager wakefulness (`Asleep` / `Dozing`), and SurfaceFlinger built-in display state (`OFF`).
   * Any ambiguity or display wake-up instantaneously cancels armed countdown timers.

4. **Second Space Adaptive Thermal Tier 0–4 (Shared Hardware Governance):**
   * Operates on shared physical Snapdragon 860 CPU (Kryo 485) and Adreno 640 GPU hardware.
   * Activated only when an eligible secondary user is foreground.
   * Dynamically resolves chassis skin thermistor `quiet_therm` with strict runtime sample validation (`15,000 <= temp_mC <= 65,000`). If a sensor sample is invalid or the sensor disappears, adaptive thermal is disabled and hardware baseline is restored safely.
   * Features exact original HyperOS `lite-global` hysteresis curve:
     * **Tier 0 (<=35°C):** Baseline (P0=1.78GHz, P4=2.42GHz, P7=2.84GHz, GPU=675MHz)
     * **Tier 1 (>=36°C / drop <35°C):** P0=Base, P4=2.13GHz, P7=2.13GHz, GPU=585MHz
     * **Tier 2 (>=38°C / drop <37°C):** P0=1.63GHz, P4=1.92GHz, P7=1.92GHz, GPU=499MHz
     * **Tier 3 (>=40°C / drop <39°C):** P0=1.48GHz, P4=1.61GHz, P7=1.61GHz, GPU=427MHz
     * **Tier 4 (>=42°C / drop <41°C):** P0=1.38GHz, P4=1.40GHz, P7=1.40GHz, GPU=345MHz
   * **Power HAL & libperfmgr Governance:** Reads sysfs values before writing; never overwrites vendor-imposed lower safety limits; distinguishes module ownership from external clamps; tracks external overwrites to avoid thrashing.
   * **Safe Baseline Restoration:** Runtime baseline captured fresh per-boot (verified via `/proc/sys/kernel/random/boot_id`). Restored immediately whenever User 0 is foreground, when secondary user is stopped, upon runtime sensor error, or upon daemon shutdown (trapped `EXIT`, `INT`, `TERM`).
   * **Stop-User Command:** Strictly uses `cmd activity stop-user -w "$target_uid"` without `-f`. Does not force-stop related profiles or bypass profile safety.

5. **Diagnostic Action Button:**
   * Operates in strictly non-destructive diagnostic mode.
   * Displays dynamic user discovery, native switch state, display signals, thermal telemetry, and CPU/GPU frequencies.
