#!/system/bin/sh
MODDIR="${0%/*}"
LOGFILE="$MODDIR/post-fs-data.log"

log() {
  local level="${2:-INFO}"
  # Simple rotation if log reaches 64KB
  if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)" -ge 65536 ]; then
    [ -f "${LOGFILE}.1" ] && rm -f "${LOGFILE}.1" 2>/dev/null
    mv -f "$LOGFILE" "${LOGFILE}.1" 2>/dev/null || true
    touch "$LOGFILE" 2>/dev/null && chmod 0644 "$LOGFILE" 2>/dev/null || true
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $1" >> "$LOGFILE" 2>/dev/null || true
}

# Fix Google Family Link SecurityException on Second Space (User 11)
# Ensures Profile Owner has isPoOrganizationOwnedDevice="true" so that
# getAutoTimeEnabled() / setAutoTimeEnabled() does not throw SecurityException.
PO_FILE="/data/system/users/11/profile_owner.xml"

if [ ! -d "/data/system/users/11" ]; then
  # Second Space is not created yet — nothing to do
  exit 0
fi

if [ ! -f "$PO_FILE" ]; then
  log "Second Space (User 11) exists but profile_owner.xml not found. Skipping." "INFO"
  exit 0
fi

if [ ! -x "/system/bin/abx2xml" ] || [ ! -x "/system/bin/xml2abx" ]; then
  log "Missing /system/bin/abx2xml or /system/bin/xml2abx! Cannot process profile_owner.xml." "ERROR"
  exit 1
fi

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
      log "Successfully injected isPoOrganizationOwnedDevice=\"true\" into $PO_FILE (backup created: ${PO_FILE}.orig)" "INFO"
    else
      log "Failed to convert modified XML back to ABX! Original file untouched." "ERROR"
    fi
  else
    log "Verification: isPoOrganizationOwnedDevice already present in $PO_FILE" "INFO"
  fi
  rm -f "$TMP_XML" "$TMP_ABX"
else
  log "Failed to convert $PO_FILE to XML via abx2xml!" "ERROR"
fi

