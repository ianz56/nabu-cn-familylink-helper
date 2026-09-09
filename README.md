# Nabu Global Auto-Switch & Display Helper

Magisk module for Xiaomi Pad 5 (nabu) running MIUI / HyperOS Global ROMs. This lightweight module automatically kills background secondary users on switch, auto-switches back to User 0 on screen off, enforces a 60Hz display refresh-rate lock, and provides Play Integrity spoofing.

## Features

1. **Multi-User Background Management**:
   - Automatically executes `am set-stop-user-on-switch true` so background secondary users are killed upon user switch.
   - Background daemon (`auto_switch.sh`) monitors screen state and automatically switches back to User 0 if a secondary user remains inactive while the screen is off (default timeout: 10 minutes).

2. **Display Refresh Rate Lock**:
   - Permanently locks the screen refresh rate to 60Hz across all user spaces (User 0 and secondary users).
   - Periodically re-applies the display rate to prevent MIUI/HyperOS reset glitches.

3. **Play Integrity Spoofing**:
   - Injects verified bootloader and locked properties (`ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`, etc.) via `system.prop` and `resetprop` in `service.sh` to help achieve `MEETS_DEVICE_INTEGRITY`.

## Installation

1. Build or download `nabu-global-helper-v2.0.0.zip`.
2. Flash the ZIP file via Magisk Manager or KernelSU.
3. Reboot your device.

## Author

Created & maintained by **Ian Perdiansah**.
