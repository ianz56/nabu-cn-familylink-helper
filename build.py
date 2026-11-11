#!/usr/bin/env python3
"""Canonical Build Script for Nabu DerpFest 17 Helper v3.2.0.

Packages module files strictly from the Canonical Distribution Source:
  /home/ianperd/Project/kill-users-nabu/nabu-global-helper-v3.2.0

Produces deterministic Magisk/KernelSU ZIP packages:
  - nabu-derpfest-helper-v3.2.0.zip
Converts CRLF to LF for shell scripts.
Computes SHA-256 hashes for all packaged files.
"""

import hashlib
import os
import shutil
import sys
import zipfile

MODULE_NAME = "nabu-derpfest-helper"
VERSION = "v3.2.0"

WORKSPACE_ROOT = "/home/ianperd/Project/kill-users-nabu"
CANONICAL_SOURCE_DIR = os.path.join(WORKSPACE_ROOT, "nabu-global-helper-v3.2.0")

SHELL_EXTENSIONS = {".sh"}

# Strictly the 10 production release files
PRODUCTION_FILES = [
    "module.prop",
    "service.sh",
    "action.sh",
    "auto_switch.sh",
    "customize.sh",
    "README.md",
    os.path.join("lib", "thermal_engine.sh"),
    os.path.join("lib", "lifecycle_engine.sh"),
    os.path.join("META-INF", "com", "google", "android", "update-binary"),
    os.path.join("META-INF", "com", "google", "android", "updater-script"),
]

# Fixed release timestamp for deterministic/reproducible archive creation
DETERMINISTIC_TIMESTAMP = (2026, 11, 11, 12, 0, 0)


def sha256_file(filepath):
    """Compute SHA-256 checksum of a file."""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def add_file(zf, local_path, archive_path):
    """Add a file to the ZIP archive with deterministic timestamp and LF conversion."""
    _, ext = os.path.splitext(local_path)
    with open(local_path, "rb") as f:
        content = f.read()

    if ext in SHELL_EXTENSIONS:
        content = content.replace(b"\r\n", b"\n")

    zinfo = zipfile.ZipInfo(archive_path, date_time=DETERMINISTIC_TIMESTAMP)
    zinfo.compress_type = zipfile.ZIP_DEFLATED
    if ext in SHELL_EXTENSIONS or "update-binary" in archive_path:
        zinfo.external_attr = 0o755 << 16
    else:
        zinfo.external_attr = 0o644 << 16

    zf.writestr(zinfo, content)
    tag = " (LF normalized)" if ext in SHELL_EXTENSIONS else ""
    print(f"  + {archive_path}{tag}")


def main():
    print("==================================================")
    print(f"BUILDER: {MODULE_NAME} {VERSION}")
    print(f"CANONICAL SOURCE: {CANONICAL_SOURCE_DIR}")
    print("==================================================")

    if not os.path.isdir(CANONICAL_SOURCE_DIR):
        print(f"[FATAL ERROR] Canonical source dir not found: {CANONICAL_SOURCE_DIR}", file=sys.stderr)
        sys.exit(1)

    missing_files = []
    for rel_path in PRODUCTION_FILES:
        full_path = os.path.join(CANONICAL_SOURCE_DIR, rel_path)
        if not os.path.isfile(full_path):
            missing_files.append(rel_path)

    if missing_files:
        print(f"[FATAL ERROR] Missing required production files: {missing_files}", file=sys.stderr)
        sys.exit(1)

    zip_name = f"{MODULE_NAME}-{VERSION}.zip"
    output_zip_canonical = os.path.join(CANONICAL_SOURCE_DIR, zip_name)
    output_zip_root = os.path.join(WORKSPACE_ROOT, zip_name)

    for zp in [output_zip_canonical, output_zip_root]:
        if os.path.exists(zp):
            os.remove(zp)
            print(f"Removed previous archive: {zp}")

    print(f"\nPackaging canonical release archive: {zip_name} ...")
    print("--------------------------------------------------")

    included_files = []
    with zipfile.ZipFile(output_zip_canonical, "w", zipfile.ZIP_DEFLATED) as zf:
        for rel_path in PRODUCTION_FILES:
            local_path = os.path.join(CANONICAL_SOURCE_DIR, rel_path)
            archive_path = rel_path.replace(os.sep, "/")
            add_file(zf, local_path, archive_path)
            included_files.append((archive_path, local_path))

    shutil.copy2(output_zip_canonical, output_zip_root)
    print(f"\nSynchronized release ZIP to workspace root: {output_zip_root}")

    canonical_size = os.path.getsize(output_zip_canonical)
    canonical_sha = sha256_file(output_zip_canonical)
    root_sha = sha256_file(output_zip_root)

    print("--------------------------------------------------")
    print(f"Build SUCCESS: {zip_name} ({canonical_size:,} bytes)")
    print(f"Canonical ZIP SHA-256: {canonical_sha}")
    print(f"Workspace ZIP SHA-256: {root_sha}")
    assert canonical_sha == root_sha, "ZIP checksum mismatch after copy!"

    print("\nPackaged Production Files SHA-256 Checksums:")
    for arc_name, loc_path in included_files:
        file_sha = sha256_file(loc_path)
        print(f"  {file_sha}  {arc_name}")
    print("--------------------------------------------------\n")


if __name__ == "__main__":
    main()
