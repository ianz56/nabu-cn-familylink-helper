# Nabu Global Auto-Switch & Display Helper

Magisk module for Xiaomi Pad 5 (nabu) running MIUI / HyperOS Global ROMs. This lightweight module automatically kills background secondary users on switch, auto-switches back to User 0 on screen off, enforces a 60Hz display refresh-rate lock, and provides Play Integrity spoofing.

## Features

1. **Multi-User Background Management**:
   - Automatically executes `am set-stop-user-on-switch true` so background secondary users are killed upon user switch.
   - Background daemon (`auto_switch.sh`) monitors screen state and automatically switches back to User 0 if a secondary user remains inactive while the screen is off (default timeout: 10 minutes).

2. **Display Refresh Rate Lock**:
   - Permanently locks the screen refresh rate to 60Hz across all user spaces (User 0 and secondary users).
   - Periodically re-applies the display rate to prevent MIUI/HyperOS reset glitches.

4. **Second Space Adaptive Thermal Profile**:
   - Dynamic adaptive throttling based on body/skin temperature (`quiet_therm`) exclusively when inside Second Space.
   - Stepped cooling curve (36°C, 38°C, 40°C, 42°C+) with 1°C hysteresis to prevent clock oscillating.
   - Dynamic baseline capture (no hardcoded frequencies) and zero modification to kernel hardware safety trips.
   - Automatically restores to 100% stock frequencies immediately upon switching back to Main Space (User 0).

## Installation

1. Build or download `nabu-global-helper-v2.1.0.zip`.
2. Flash the ZIP file via Magisk Manager, KernelSU, or APatch.
3. Reboot your device.

## Author

Created & maintained by **Ian Perdiansah**.
