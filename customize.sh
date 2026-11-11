#!/system/bin/sh
# Nabu DerpFest 17 Helper — Module Installer Script (v3.2.0)
# ==========================================================
# Strict pre-installation environment and hardware assertion checks.

ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Nabu DerpFest 17 Helper v3.2.0"
ui_print "  Pre-Installation Safety Verification"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print ""

# 1. Device Hardware Assertion (Strict Fail-Closed)
DEVICE=$(getprop ro.product.device 2>/dev/null)
[ -z "$DEVICE" ] && DEVICE=$(getprop ro.build.product 2>/dev/null)

if [ "$DEVICE" != "nabu" ] && [ "$DEVICE" != "nabu_global" ]; then
  ui_print "  [FATAL ERROR] Incompatible device: '$DEVICE'."
  ui_print "  This module is strictly built for Xiaomi Pad 5 (nabu)."
  ui_print "  Installation aborted."
  abort "Device mismatch failure."
fi
ui_print "  [✓] Hardware verified: Xiaomi Pad 5 ($DEVICE)"

# 2. Android API Level Assertion (Target: Android 17 / SDK 37)
SDK_VER=$(getprop ro.build.version.sdk 2>/dev/null)
if [ "$SDK_VER" != "37" ]; then
  ui_print "  [FATAL ERROR] Incompatible Android SDK: '$SDK_VER'."
  ui_print "  This module requires Android 17 (API level 37 / DerpFest 17)."
  ui_print "  Installation aborted."
  abort "Android SDK mismatch failure."
fi
ui_print "  [✓] Android version verified: Android 17 (SDK $SDK_VER)"

# 3. File Completeness Assertion
for req_file in "$MODPATH/service.sh" "$MODPATH/auto_switch.sh" "$MODPATH/action.sh" "$MODPATH/module.prop"; do
  if [ ! -f "$req_file" ]; then
    ui_print "  [FATAL ERROR] Missing required file: $req_file"
    abort "Module file structure incomplete."
  fi
done
ui_print "  [✓] All required module files confirmed present."

# 4. Strict Permissions Enforcement
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/auto_switch.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/module.prop" 0 0 0644

ui_print ""
ui_print "  Safety Status:"
ui_print "  - Target: Dynamically discovered full.SECONDARY users."
ui_print "  - Protected: User 0 (Main User) is permanently immutable."
ui_print "  - Non-destructive: Work/Clone profiles and system users excluded."
ui_print "  - Adaptive Thermal: Tier 0-4 with hysteresis on shared SoC."
ui_print ""
ui_print "  ✓ Pre-installation checks passed successfully."
ui_print ""
