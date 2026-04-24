#!/usr/bin/env bash
set -euo pipefail



export TZ="${TZ:-Europe/Moscow}"

SRC="${SRC_REMOTE:-r2:source-bucket/}"
DST_BUCKET="${DST_REMOTE:-s3:backup-bucket}"

KEEP_DAYS="${KEEP_DAYS:-3}"

RCLONE_CFG="${RCLONE_CFG:-/etc/rclone/rclone.conf}"
LOG_DIR="${LOG_DIR:-/var/log/rclone}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/cloud-backup-sync.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/cloud-backup-sync.lock}"

mkdir -p "$LOG_DIR"


exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "Another backup is running, exiting." >>"$LOG_FILE"
  exit 0
fi

DATE_TAG="$(date +%d.%m.%Y)"
DST="${DST_BUCKET}/${DATE_TAG}/"

echo "=== $(date -Is) START backup to ${DST} ===" >>"$LOG_FILE"


rclone copy \
  "$SRC" \
  "$DST" \
  --config "$RCLONE_CFG" \
  --log-file "$LOG_FILE" \
  --log-level INFO \
  --stats 60s \
  --fast-list \
  --transfers 8 \
  --checkers 16 \
  -P


CUTOFF_EPOCH="$(date -d "today - $((KEEP_DAYS - 1)) days" +%s)"

mapfile -t DIRS < <(
  rclone lsf "$DST_BUCKET/" \
    --config "$RCLONE_CFG" \
    --dirs-only 2>/dev/null || true
)

for dir in "${DIRS[@]}"; do
  name="${dir%/}"


  if [[ ! "$name" =~ ^[0-3][0-9]\.[01][0-9]\.[0-9]{4}$ ]]; then
    continue
  fi

  IFS='.' read -r dd mm yyyy <<<"$name"
  iso="${yyyy}-${mm}-${dd}"

  folder_epoch="$(date -d "$iso" +%s 2>/dev/null || true)"

  if [[ -z "${folder_epoch}" ]]; then
    continue
  fi

  if (( folder_epoch < CUTOFF_EPOCH )); then
    echo "=== $(date -Is) PURGE old backup folder: ${name} ===" >>"$LOG_FILE"

    rclone purge \
      "${DST_BUCKET}/${name}/" \
      --config "$RCLONE_CFG" \
      --log-file "$LOG_FILE" \
      --log-level INFO
  fi
done

echo "=== $(date -Is) DONE ===" >>"$LOG_FILE"
