#!/system/bin/sh
MODDIR="${0%/*}"

# Fix Google Family Link SecurityException on Second Space (User 11)
# Ensures Profile Owner has isPoOrganizationOwnedDevice="true" so that
# getAutoTimeEnabled() / setAutoTimeEnabled() does not throw SecurityException.
PO_FILE="/data/system/users/11/profile_owner.xml"
if [ -f "$PO_FILE" ] && [ -x "/system/bin/abx2xml" ] && [ -x "/system/bin/xml2abx" ]; then
  TMP_DIR="/data/local/tmp"
  TMP_XML="$TMP_DIR/po_11.xml"
  TMP_ABX="$TMP_DIR/po_11.abx"

  if abx2xml "$PO_FILE" "$TMP_XML" 2>/dev/null; then
    if ! grep -q "isPoOrganizationOwnedDevice" "$TMP_XML"; then
      [ ! -f "$PO_FILE.orig" ] && cp -p "$PO_FILE" "$PO_FILE.orig"
      sed -i 's|<profile-owner |<profile-owner isPoOrganizationOwnedDevice="true" |g' "$TMP_XML"
      if xml2abx "$TMP_XML" "$TMP_ABX" 2>/dev/null; then
        cp "$TMP_ABX" "$PO_FILE"
        chown system:system "$PO_FILE"
        chmod 600 "$PO_FILE"
        chcon u:object_r:system_data_file:s0 "$PO_FILE" 2>/dev/null || true
      fi
    fi
    rm -f "$TMP_XML" "$TMP_ABX"
  fi
fi
