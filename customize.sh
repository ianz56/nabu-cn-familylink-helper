#!/system/bin/sh
# Kill Users on Switch — Installation Script
# =============================================
# This runs during module installation via Magisk Manager / recovery.

# Print banner
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print "  Nabu Global Auto-Switch & Display"
ui_print "  by Ian Perdiansah"
ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ui_print ""
ui_print "  Features included:"
ui_print "  1. Auto-kill background users on switch"
ui_print "  2. Auto-switch to User 0 when screen off"
ui_print "  3. Display refresh-rate lock (60Hz)"
ui_print "  4. Second Space Adaptive Thermal Profile"
ui_print "  5. Second Space Family Link & Supervision Fix"
ui_print ""

# Set proper permissions for scripts
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/auto_switch.sh" 0 0 0755


ui_print "  ✓ Installation complete!"
ui_print "  ✓ Reboot to activate."
ui_print ""
