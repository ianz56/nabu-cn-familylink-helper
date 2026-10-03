#!/usr/bin/env python3
"""Build script for Nabu CN System & Family Link Helper Magisk Module.

Packages all module files into a ZIP with correct directory structure.
Automatically converts CRLF to LF for all .sh files so they work on Android.
"""

import os
import sys
import zipfile

MODULE_NAME = "nabu-global-helper"
VERSION = "v2.0.2"

# Extensions that need CRLF -> LF conversion for Android
SHELL_EXTENSIONS = {".sh"}

# Root-level files to include
ROOT_FILES = [
    "module.prop",
    "service.sh",
    "action.sh",
    "auto_switch.sh",
    "customize.sh",
    "system.prop",
    os.path.join("META-INF", "com", "google", "android", "update-binary"),
    os.path.join("META-INF", "com", "google", "android", "updater-script"),
]


def add_file(zf, local_path, archive_path):
    """Add a file to the ZIP archive.

    Shell scripts (.sh) are read as binary and have CRLF converted to LF.
    All other files are added as-is.
    """
    _, ext = os.path.splitext(local_path)
    if ext in SHELL_EXTENSIONS:
        with open(local_path, "rb") as f:
            content = f.read().replace(b"\r\n", b"\n")
        zf.writestr(archive_path, content)
        print(f"  + {archive_path} (LF converted)")
    else:
        zf.write(local_path, archive_path)
        print(f"  + {archive_path}")


def collect_system_files():
    """Recursively collect all files under the 'system' directory."""
    system_files = []
    if os.path.isdir("system"):
        for root, _dirs, files in os.walk("system"):
            for fname in files:
                system_files.append(os.path.join(root, fname))
    return system_files


def main():
    zip_name = f"{MODULE_NAME}-{VERSION}.zip"
    zip_path = os.path.join(os.getcwd(), zip_name)

    # Remove old zip if it exists
    if os.path.exists(zip_path):
        os.remove(zip_path)
        print(f"Removed old {zip_name}")

    print(f"Building {zip_name} ...")

    # Collect all files
    files_to_include = list(ROOT_FILES) + collect_system_files()

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for file_path in files_to_include:
            if not os.path.exists(file_path):
                print(f"  ! SKIPPED (not found): {file_path}", file=sys.stderr)
                continue
            # ZIP entry paths always use forward slashes
            archive_path = file_path.replace(os.sep, "/")
            add_file(zf, file_path, archive_path)

    if os.path.exists(zip_path):
        size = os.path.getsize(zip_path)
        print()
        print(f"Build successful!")
        print(f"Output: {zip_name} ({size:,} bytes)")
    else:
        print("Build failed!", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
