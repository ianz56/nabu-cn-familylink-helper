# 📚 DOKUMENTASI LENGKAP PROYEK: NABU CN SYSTEM & FAMILY LINK HELPER

**Nama Perangkat:** Xiaomi Pad 5 (Codename: `nabu`)  
**Versi ROM:** Xiaomi HyperOS / MIUI China ROM (`WNSCNXM`, Android 14 / SDK 34)  
**Versi Modul Terakhir:** `v1.0.42` (VersionCode: `43`)  
**Repository GitHub:** `https://github.com/ianz56/nabu-cn-familylink-helper.git`  
**Lokasi Kode Lokal:** `C:\Users\ianpe\kill-users-nabu`  

---

## 🎯 1. LATAR BELAKANG & TUJUAN UTAMA PROYEK

Tablet Xiaomi Pad 5 menjalankan ROM China yang memiliki banyak pembatasan sistem bawaan (*Chinese ROM Restrictions*). Proyek ini dibuat sebagai **Modul Magisk All-in-One** untuk menyelesaikan masalah-masalah utama berikut:

1. **Multi-User Management & Auto-Kill**:
   - Di Android multi-user (User 0 = Orang Tua, User 11 = Anak), user di latar belakang yang tidak aktif memakan RAM & baterai secara agresif.
   - Diperlukan fitur **Stop-User-on-Switch** otomatis agar saat berpindah user (misal ke User 0), User 11 langsung dimatikan total (*killed*).
   - Diperlukan fitur **Auto-Switch ke User 0 saat Layar Mati** (*Screen Off*) demi keamanan dan menghemat baterai.

2. **Dukungan Penuh Google Play Services (GMS) & GSF di ROM China**:
   - ROM China membatasi fitur GMS, GSF ID, dan Google Advertising ID (AAID).
   - Perbaikan masalah sertifikasi Play Protect, Google Checkin, dan penghindaran konflik update GMS.

3. **Family Link & Supervision Sebagai Aplikasi Sistem Privilese (*Privileged System Apps*)**:
   - Memasukkan `FamilyLink`, `FamilyLinkHelper`, dan `Supervision` ke dalam `/system/product/priv-app/` dengan `privapp-permissions.xml` dan `default-permissions.xml` lengkap.
   - Mengaktifkan izin hak akses sistem `OBSERVE_APP_USAGE`, `CHANGE_APP_IDLE_STATE`, `PACKAGE_USAGE_STATS`, `SYSTEM_ALERT_WINDOW`, `USE_FULL_SCREEN_INTENT` (AppOps 133), dan `SCHEDULE_EXACT_ALARM` agar pemantauan batas waktu layar (*screen time*) dan *auto-lock* Family Link berfungsi 100% tanpa stuck di 0 menit.
   - Mempertahankan agar Play Store tetap bebas meng-update aplikasi Family Link/Supervision tanpa menghapus status privilese sistem.

4. **Pengunci Refresh-Rate & Bahasa Space Anak**:
   - Mengunci *refresh rate* layar secara permanen di 60Hz.
   - Mengatur preferensi Bahasa Indonesia (`id-ID`) untuk Space Anak (User 11).

5. **Play Integrity Spoofing (`MEETS_DEVICE_INTEGRITY`)**:
   - Menyamarkan properti Bootloader Unlocked (`verifiedbootstate=green`, `flash.locked=1`) agar lulus `MEETS_DEVICE_INTEGRITY`.

---

## 🛠️ 2. ARSITEKTUR & FILE UTAMA MODUL MAGISK

Semua file modul tersimpan di `C:\Users\ianpe\kill-users-nabu`:

| Nama File / Folder | Fungsi & Rincian Deskripsi |
| :--- | :--- |
| **`module.prop`** | Metadata modul Magisk (`id=nabu-cn-familylink-helper`, `version=v1.0.30`, `versionCode=31`). |
| **`service.sh`** | Skrip utama *late-start service* yang berjalan setiap booting. Menjalankan `am set-stop-user-on-switch true`, memberikan izin *root pm grant* & *AppOps*, mengeksekusi `resetprop` Play Integrity, dan mengaktifkan DroidGuard/GMS. |
| **`auto_switch.sh`** | Skrip latar belakang daemon yang memantau status layar & pergantian user. Berjalan saat beralih user untuk memastikan izin Family Link, AppOps, dan pengunci 60Hz tetap aktif di User 0 dan User 11. |
| **`system.prop`** | Properti sistem yang diinjeksi saat booting: memperbolehkan GMS (`ro.miui.support_gms=1`), Google ClientID (`android-google`), Ad ID (`ro.com.google.gms.ad_id=1`), dan Play Integrity Spoofing (`ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`). |
| **`customize.sh`** | Skrip instalasi Magisk yang berjalan saat modul di-flash di Magisk Manager. |
| **`build.py`** | Skrip Python builder untuk mengonversi newline LF (`\n`) otomatis pada skrip `.sh` dan memaketkan ZIP rilis (`nabu-cn-familylink-helper-v1.0.30.zip`). |
| **`system/product/priv-app/`** | Berisi APK sistem bawaan modul: `FamilyLink`, `FamilyLinkHelper`, `Supervision`, `Phonesky` (Play Store), `GooglePackageInstaller`. |
| **`system/product/etc/permissions/`** | XML Izin Privilese: `privapp-permissions-familylink.xml`, `privapp-permissions-supervision.xml`, `cn.google.services.xml`. |
| **`system/product/etc/default-permissions/`** | `default-permissions-familylink.xml` untuk memberikan izin default secara otomatis. |

---

## 📜 3. RIWAYAT PERJALANAN & EVOLUSI PERBAIKAN (V1.0.19 - V1.0.30)

Berikut ringkasan kronologis perbaikan dari awal hingga versi terbaru:

### 🔹 v1.0.19 - v1.0.22 (Pemberian Izin Sistem & Penanganan Update Play Store)
- **Family Link Screen Time Stuck 0**: Mengidentifikasi bahwa saat Play Store meng-update Supervision/Family Link ke `/data/app/`, izin privilese `OBSERVE_APP_USAGE` terlepas. Menambahkan `privapp-permissions-familylink.xml` dan otomatisasi `pm grant` di `service.sh` & `auto_switch.sh`.
- **Mempertahankan Auto-Update**: Menghapus pembersihan otomatis folder `/data/app/` Family Link agar aplikasi dapat terus diperbarui oleh Play Store tanpa merusak pemantauan layar.
- **Google Advertising ID (AAID) Fix**: Menambahkan fitur `AD_ID` ke `cn.google.services.xml` dan membuat otomatisasi file `ad_id.xml` di shared_prefs GMS.

### 🔹 v1.0.23 - v1.0.26 (Eksperimen GSF, Penanganan GMS Preview, & Revert `gservices.db`)
- **Penyebab GMS Rusak/Hilang**: Ditemukan bahwa Play Store sempat mengunduh update `com.google.android.gms` versi Preview Beta Android 16 (`versionCode=262931035`, `minSdk=35`). Karena tablet menggunakan Android 14, GMS mengalami *crash* & hilang.
- **Eksperimen `gservices.db` & Pemulihan (`v1.0.26`)**: Pembuatan file `gservices.db` tiruan manual sempat menyebabkan `IOException` saat login Google. Pembuatan database buatan tersebut telah **dihapus total di v1.0.26**, mengembalikan autentikasi GSF murni.
- **Stabilisasi GMS**: Menghapus skrip pembersih yang menyebabkan loop penghapusan GMS, memulihkan GMS stabil bawaan sistem (`PrebuiltGmsCoreVic.apk`, `v253434035`) secara permanen di User 0 dan User 11.

### 🔹 v1.0.27 - v1.0.29 (Izin Lanjutan & Fitur Layar Penuh)
- **Stabilisasi GMS Permanen (`v1.0.27`)**: Memastikan GMS tidak pernah terhapus lagi saat booting.
- **Izin `WRITE_SETTINGS` (`v1.0.28`)**: Mengaktifkan izin `android.permission.WRITE_SETTINGS` dan AppOps-nya untuk GMS di semua user.
- **Izin `USE_FULL_SCREEN_INTENT` & `SCHEDULE_EXACT_ALARM` (`v1.0.29`)**: Memberikan izin `USE_FULL_SCREEN_INTENT` (AppOps 133) dan `SCHEDULE_EXACT_ALARM` untuk Supervision, Family Link, dan GMS agar popup penguncian layar penuh dan alarm batas waktu tepat waktu.

### 🔹 v1.0.30 (Play Integrity `MEETS_DEVICE_INTEGRITY` Spoofing)
- **Spoofing Status Bootloader**: Menambahkan properti penyamaran bootloader (`ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`, `ro.boot.veritymode=enforcing`, dll.) via `system.prop` dan `resetprop` di `service.sh` untuk meningkatkan Play Integrity dari *Basic* ke **`MEETS_DEVICE_INTEGRITY`**.

### 🔹 v1.0.31 (Perbaikan Play Store Installation & Update App/WhatsApp)
- **Privileged Permissions Play Store (`com.android.vending`)**: Menambahkan `privapp-permissions-vending.xml` dan permission exceptions di `default-permissions-familylink.xml` (`INSTALL_PACKAGES`, `DELETE_PACKAGES`, `MANAGE_EXTERNAL_STORAGE`, `ALLOCATE_AGGRESSIVE_BUBBLE_COUNT`, dll.).
- **Bypass Proteksi Verifikasi Installer Xiaomi**: Menambahkan konfigurasi `verify_market_app=0`, `package_verifier_enable=0`, `package_verifier_include_adb=0` di `service.sh` & `auto_switch.sh` agar ROM China tidak memblokir update silent dari Play Store untuk aplikasi tertentu seperti WhatsApp.

### 🔹 v1.0.32 (Fix Split Install / Dynamic Feature Loop TikTok & Games)
- **Fix Dynamic Feature Download Loop (`SplitInstallService` Stuck 194/PENDING)**: Menambahkan izin privilese sistem `UPDATE_PACKAGES_WITHOUT_USER_ACTION`, `INSTALL_DYNAMIC_SYSTEM`, `MANAGE_APP_OPS_MODES`, `LOADER_USAGE_STATS`, dan `UPDATE_APP_OPS_STATS` ke `privapp-permissions-vending.xml` & `default-permissions-familylink.xml`.

### 🔹 v1.0.34 (Fix Sistemik Universal MIUI Installer Block & APK Upload Verifier)
- **Permanent Universal Disabling MIUI Package Verifier**: Menambahkan properti sistem `ro.miui.secure_install=0`, `persist.sys.miui.install_verify=0`, `persist.sys.package_verifier_enable=0`, dan `persist.sys.upload_apk_enable=0` di `system.prop`, `service.sh`, dan `auto_switch.sh`.
- **Menghilangkan Verifikasi Sampel APK MIUI**: Mematikan fitur `upload_apk_enable` milik Xiaomi Security Daemon yang menghadang dan membuat `SplitInstallService` Play Store tertahan di status `legacy_status_code=190/194` saat mengunduh split APK untuk aplikasi apapun (TikTok, Games, dll.).

### 🔹 v1.0.40 (Revert Fingerprint Spoofing & Re-stabilization)
- **Revert Build Fingerprint Spoofing**: Menghapus seluruh perintah penyamaran fingerprint bawaan yang dapat memicu ketidakcocokan framework OS (SDK/Release Mismatch Exception).
- **Stabilisasi Play Store**: Mengembalikan Play Store ke konfigurasi stabil bawaan sistem dan mempertahankan spoofing bootloader murni (`verifiedbootstate=green`, `flash.locked=1`) untuk kelulusan `MEETS_BASIC_INTEGRITY`.

### 🔹 v1.0.41 (Fix Family Link Screen Time & Auto Lock)
- **Fix Pemantauan Layar & Penggunaan Anak**: Mengidentifikasi bahwa MIUI secara agresif mencabut `OBSERVE_APP_USAGE` dan `PACKAGE_USAGE_STATS`. Menambahkan izin krusial ini ke dalam *loop* eksekusi `pm grant` di `service.sh` dan `auto_switch.sh` sehingga penggunaan aplikasi dapat tercatat akurat dan fitur *auto-lock* kembali bekerja 100%.
- **Perbaikan AppOps**: Mengoreksi mapping `PACKAGE_USAGE_STATS` menjadi `GET_USAGE_STATS` dan menerapkan eksekusi yang lebih aman (`safe_appops_set`) untuk iterasi hak akses.

### 🔹 v2.0.0 (Lite Global Edition - Tanpa Family Link & GMS Hack)
- **Migrasi ke ROM Global**: Karena perangkat telah beralih ke ROM Global (di mana GMS dan Family Link sudah terintegrasi dan berjalan normal bawaan sistem tanpa batasan ROM China), seluruh bundle aplikasi priv-app (`FamilyLink`, `FamilyLinkHelper`, `Supervision`, `Phonesky`, `GooglePackageInstaller`), XML permissions, AppOps looping, dan bypass installer MIUI dipangkas tuntas.
- **Fokus Fitur Inti**:
  1. **Multi-User Management**: `am set-stop-user-on-switch true` & background daemon `auto_switch.sh` (auto-switch ke User 0 saat screen off) untuk mematikan secondary user secara otomatis.
  2. **Display Refresh Rate Lock**: Pengunci 60Hz stabil di semua user.
  3. **Play Integrity Spoofing**: `verifiedbootstate=green`, `flash.locked=1`, `veritymode=enforcing`, dll. via `system.prop` & `resetprop`.

### 🔹 v2.1.0 (Second Space Adaptive Thermal Profile & Hysteresis)
- **Profil Thermal Khusus Second Space**: Menerapkan adaptive thermal throttling dinamis yang aktif hanya ketika perangkat berada di Second Space (User != 0), dan otomatis kembali ke baseline stok saat berpindah ke Main Space (User 0).
- **Dynamic Baseline Capture (Tanpa Hardcode)**: Saat modul/daemon mulai berjalan, nilai runtime riil `scaling_max_freq` CPU (LITTLE, BIG, PRIME) dan `max_gpuclk` GPU dicatat sebagai baseline pemulihan (*no hardcoding*).
- **Sensor Resolving Dinamis**: Mendeteksi sensor suhu secara dinamis via sysfs (`quiet_therm` untuk skin/chassis temperature Xiaomi Pad 5 nabu, dengan fallback ke `cpu_therm`/`battery`), bukan hardcode index.
- **Hysteresis Multi-Tier (1°C Margin)**:
  - Tier 0 (<= 35°C): Baseline Normal / Stock (100% performa).
  - Tier 1 (>= 36°C): Mild reduction (memotong boost turbo tertinggi yang memboroskan daya & suhu).
  - Tier 2 (>= 38°C): Moderate throttle (keseimbangan suhu stabil untuk game Minecraft/Roblox + YouTube floating).
  - Tier 3 (>= 40°C): Aggressive throttle (menahan laju kenaikan suhu).
  - Tier 4 (>= 42°C): Strict limit (menjaga kestabilan suhu & mencegah overheating).
  - Pemulihan bertahap saat suhu mendingin dengan margin 1°C (misal turun ke Tier 3 hanya jika suhu < 41°C) untuk mencegah fluktuasi frekuensi naik-turun cepat.
- **Integritas Sistem & Safety Kernel**: Berjalan terintegrasi pada background daemon `auto_switch.sh` dengan interval polling 5 detik tanpa daemon tambahan. Driver hardware/kernel thermal trip (LMh) tetap 100% utuh tanpa intervensi.

---

## 🔑 4. STATUS FITUR SAAT INI (VERIFIKASI TERAKHIR - v2.1.0)

| Fitur | Status | Catatan Teknis |
| :--- | :---: | :--- |
| **Stop User On Switch** | ✅ AKTIF | `am set-stop-user-on-switch true` berjalan otomatis di booting. Secondary user langsung mati saat beralih. |
| **Auto Switch Screen Off** | ✅ AKTIF | Pindah otomatis ke User 0 saat layar dimatikan (*screen off*, timeout 10 menit). |
| **Refresh Rate Lock** | ✅ AKTIF | Layar terkunci secara hardware & sistemik di 60Hz (SurfaceFlinger Mode 1). Kebal terhadap user switch. |
| **Second Space Adaptive Thermal** | ✅ AKTIF | Adaptive throttling bertahap (36°C, 38°C, 40°C, 42°C+) dengan hysteresis & dynamic baseline. Khusus Second Space. |
| **Play Integrity** | ✅ AKTIF | Konfigurasi integritas stabil bawaan sistem tanpa risiko mismatch. |
| **Family Link & GMS** | ⚡ NATIVE | Ditangani langsung secara native & resmi oleh ROM Global tanpa modifikasi modul. |

---

## 🚀 5. PANDUAN PENGEMBANGAN / KELANJUTAN (UNTUK CHAT BARU)

Jika Anda memulai perbincangan di **Chat Baru (New Conversation)**, berikan petunjuk singkat berikut ke AI:

> *"Saya ingin melanjutkan pengembangan modul Magisk `nabu-global-helper` (v2.1.0 branch `lite-global`) di `kill-users-nabu`. Modul ini berfokus pada auto-switch multi-user, 60Hz lock, dan Second Space adaptive thermal profile untuk Xiaomi Pad 5 (nabu) ROM Global."*

### Perintah Penting untuk Build & Flash:
1. **Build Modul Baru**:
   ```bash
   python3 build.py
   ```
2. **Flash Modul ke Tablet via ADB**:
   ```bash
   adb push nabu-global-helper-v2.1.0.zip /data/local/tmp/
   adb shell "su -c 'magisk --install-module /data/local/tmp/nabu-global-helper-v2.1.0.zip'"
   ```
3. **Push ke GitHub**:
   ```bash
   git add .
   git commit -m "Pesan commit"
   git pull --rebase
   git push origin lite-global
   ```
