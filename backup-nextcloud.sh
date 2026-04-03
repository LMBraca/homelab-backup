#!/bin/bash
set -euo pipefail

MAIN_SERVER="luis@100.87.156.88"

BACKUP_DIR="/home/luis/nextcloud-backup"
LOG_FILE="/home/luis/backup.log"

STATUS_DIR="/home/luis/backup-dashboard"
LIVE_JSON="${STATUS_DIR}/backup-live.json"
LAST_JSON="${STATUS_DIR}/backup-last.json"

LOCK_FILE="/tmp/nextcloud-backup.lock"

DATA_SRC="/var/snap/nextcloud/common/nextcloud/data/"
CONF_SRC="/var/snap/nextcloud/current/nextcloud/config/"
DB_DIR="${BACKUP_DIR}/database"

mkdir -p "$BACKUP_DIR/data" "$BACKUP_DIR/config" "$DB_DIR" "$STATUS_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

json_escape() {
  echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# live state fields (updated during run)
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
STARTED_AT_EPOCH="$(date +%s)"
STEP="starting"
CURRENT_FILE=""

# rsync live progress
RSYNC_PERCENT=""
RSYNC_SPEED=""
RSYNC_ETA=""

# noisy summary
NOISY_APPDATA_PREVIEW=0
NOISY_APPDATA_OTHER=0
LAST_NOISY_SAMPLE=""

# write rate limiting
LAST_WRITE_EPOCH=0
WRITE_EVERY_SECONDS=1

write_state() {
  local step="$1"
  local current="${2:-$CURRENT_FILE}"

  local now_epoch
  now_epoch="$(date +%s)"
  if (( now_epoch - LAST_WRITE_EPOCH < WRITE_EVERY_SECONDS )); then
    return 0
  fi
  LAST_WRITE_EPOCH="$now_epoch"

  cat > "${LIVE_JSON}.tmp" <<EOF
{
  "inProgress": true,
  "step": "$(json_escape "$step")",
  "startedAt": "$STARTED_AT",
  "startedAtEpoch": $STARTED_AT_EPOCH,
  "updatedAt": "$(date '+%Y-%m-%d %H:%M:%S')",
  "updatedAtEpoch": $now_epoch,
  "currentFile": "$(json_escape "$current")",
  "transferPercent": "$(json_escape "$RSYNC_PERCENT")",
  "transferSpeed": "$(json_escape "$RSYNC_SPEED")",
  "transferEta": "$(json_escape "$RSYNC_ETA")",
  "noisyAppdataPreview": $NOISY_APPDATA_PREVIEW,
  "noisyAppdataOther": $NOISY_APPDATA_OTHER,
  "noisySample": "$(json_escape "$LAST_NOISY_SAMPLE")"
}
EOF
  mv "${LIVE_JSON}.tmp" "$LIVE_JSON"
}

write_last() {
  local result="$1"
  local duration="$2"
  local error_line="${3:-}"
  local db_dest="$4"
  local db_size="${5:-}"

  cat > "${LAST_JSON}.tmp" <<EOF
{
  "result": "$(json_escape "$result")",
  "finishedAt": "$(date '+%Y-%m-%d %H:%M:%S')",
  "finishedAtEpoch": $(date +%s),
  "durationSeconds": $duration,
  "errorLine": "$(json_escape "$error_line")",
  "dbDest": "$(json_escape "$db_dest")",
  "dbSize": "$(json_escape "$db_size")",
  "noisyAppdataPreview": $NOISY_APPDATA_PREVIEW,
  "noisyAppdataOther": $NOISY_APPDATA_OTHER
}
EOF
  mv "${LAST_JSON}.tmp" "$LAST_JSON"
}

clear_state() {
  rm -f "$LIVE_JSON"
}

# ----- lock -----
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Backup already running — exiting."
  exit 0
fi

RUN_START_EPOCH="$(date +%s)"
trap clear_state EXIT

log "========================================"
log "Starting Nextcloud backup..."
write_state "starting"

parse_progress2() {
  local line="$1"
  if [[ "$line" =~ ([0-9,]+)[[:space:]]+([0-9]{1,3})%[[:space:]]+([0-9.]+[A-Za-z]+/s)[[:space:]]+([0-9:]{1,8}) ]]; then
    RSYNC_PERCENT="${BASH_REMATCH[2]}%"
    RSYNC_SPEED="${BASH_REMATCH[3]}"
    RSYNC_ETA="${BASH_REMATCH[4]}"
  fi
}

handle_file_line() {
  local path="$1"
  [[ -z "$path" ]] && return 0

  if [[ "$path" == appdata_* ]]; then
    LAST_NOISY_SAMPLE="$path"
    if [[ "$path" == appdata_*/preview/* ]]; then
      ((NOISY_APPDATA_PREVIEW++)) || true
      CURRENT_FILE="appdata_*/preview (files: $NOISY_APPDATA_PREVIEW)"
    else
      ((NOISY_APPDATA_OTHER++)) || true
      CURRENT_FILE="appdata_* (files: $NOISY_APPDATA_OTHER)"
    fi
  else
    CURRENT_FILE="$path"
  fi
}

run_rsync() {
  local label="$1"
  local src="$2"
  local dst="$3"

  STEP="$label"
  RSYNC_PERCENT=""
  RSYNC_SPEED=""
  RSYNC_ETA=""
  CURRENT_FILE=""
  write_state "$STEP"

  log "[$label] starting..."

  rsync -avz --delete \
    --timeout=60 \
    --rsync-path="sudo -n rsync" \
    --out-format="%n" \
    --info=progress2 \
    "$MAIN_SERVER:$src" \
    "$dst" 2>&1 | while IFS= read -r line; do
      log "$line"
      parse_progress2 "$line"
      if [[ "$line" != *"to-chk="* ]] && [[ "$line" != *"(xfr#"* ]]; then
        handle_file_line "$line"
      fi
      write_state "$STEP"
    done

  log "[$label] completed."
  write_state "$STEP"
}

# ---------- DATA RSYNC ----------
run_rsync "rsync data" "$DATA_SRC" "$BACKUP_DIR/data/"

# ---------- CONFIG RSYNC ----------
run_rsync "rsync config" "$CONF_SRC" "$BACKUP_DIR/config/"

# ---------- DATABASE ----------
STEP="export database"
CURRENT_FILE="running nextcloud.export on main server"
write_state "$STEP" "$CURRENT_FILE"
log "[export database] starting..."

# Run nextcloud.export on main server — it saves to /var/snap/nextcloud/common/backups/
EXPORT_PATH=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$MAIN_SERVER" \
  "sudo -n nextcloud.export -abc 2>&1 | grep 'Successfully exported' | awk '{print \$NF}'" 2>> "$LOG_FILE")

if [ -z "$EXPORT_PATH" ]; then
  ERROR_LINE="Database export failed — could not get export path from main server"
  log "$ERROR_LINE"
  write_last "failed" "$(($(date +%s) - RUN_START_EPOCH))" "$ERROR_LINE" "" ""
  exit 1
fi

log "[export database] export created at: $EXPORT_PATH"

# Rsync the export directory from main server to backup server
DATESTAMP=$(date +%Y%m%d-%H%M%S)
DB_DEST="${DB_DIR}/${DATESTAMP}"
mkdir -p "$DB_DEST"

CURRENT_FILE="rsyncing $EXPORT_PATH"
write_state "$STEP" "$CURRENT_FILE"

rsync -avz \
  --rsync-path="sudo -n rsync" \
  "$MAIN_SERVER:${EXPORT_PATH}/" \
  "$DB_DEST/" >> "$LOG_FILE" 2>&1

if [ -d "$DB_DEST" ] && [ "$(ls -A "$DB_DEST")" ]; then
  DB_SIZE_H=$(du -sh "$DB_DEST" | awk '{print $1}')
  log "[export database] synced successfully: $DB_DEST ($DB_SIZE_H)"

  # Clean up the export from main server to free space
  ssh -o BatchMode=yes "$MAIN_SERVER" \
    "sudo -n rm -rf '$EXPORT_PATH'" >> "$LOG_FILE" 2>&1 || \
    log "Warning: could not clean up $EXPORT_PATH on main server (non-fatal)"

  # Keep only last 7 database backups
  find "$DB_DIR" -maxdepth 1 -mindepth 1 -type d | sort | head -n -7 | xargs rm -rf 2>/dev/null || true

else
  ERROR_LINE="Database rsync failed — destination empty after transfer"
  log "$ERROR_LINE"
  write_last "failed" "$(($(date +%s) - RUN_START_EPOCH))" "$ERROR_LINE" "" ""
  exit 1
fi

RUN_END_EPOCH="$(date +%s)"
DURATION=$((RUN_END_EPOCH - RUN_START_EPOCH))

write_last "success" "$DURATION" "" "$DB_DEST" "$DB_SIZE_H"

log "Backup completed in ${DURATION}s"
log "========================================"
