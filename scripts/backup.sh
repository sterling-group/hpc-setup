#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Script: backup.sh
# Description:
#   Backs up local data to remote storage via rclone.
#   - Daily incremental backups
#   - Weekly snapshots (Sundays)
#   - Prunes local logs older than 30 days
#   - Prunes remote snapshots older than 28 days
#   - Uploads logs to remote
# Usage:
#   backup.sh  (override settings via environment variables as needed)
#
# Configuration (env overrides):
#   DATA_DIR           Local directory to back up (default: /groups/.../$USER)
#   REMOTE_ROOT        Remote root for backups (default: box:cluster-backup)
#   RCLONE_BIN         Path to rclone binary (default: rclone-v1.69.1)
#   LOG_DIR            Directory for local logs (default: $HOME/logs)
#
# Author: Markus G. S. Weiss
# Date:   2025-05-05
# ------------------------------------------------------------------------------
set -euo pipefail

# --- Configuration (override via env if desired) ------------------------------
: "${DATA_DIR:=/groups/sterling/mfshome/$USER}"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            
: "${REMOTE_ROOT:=box:cluster-backup}"
: "${RCLONE_BIN:=/groups/sterling/software-tools/rclone/rclone-v1.69.1-linux-amd64/rclone}"
: "${LOG_DIR:=$HOME/logs}"

DATE_STR=$(date +%F)
LOCK_FILE="$HOME/.backup_${USER}.lock"

# Common rclone options
RCLONE_OPTS="--fast-list --checksum --log-level WARNING"

# Retry settings
MAX_RETRIES=3
RETRY_DELAY=10

# Snapshot retention (days)
REMOTE_RETENTION_DAYS=28

# --- Setup --------------------------------------------------------------------
# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Prevent overlapping runs
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "[$(date '+%F %T')] Another backup is already running. Exiting." >> "$LOG_DIR/backup-$DATE_STR.log"
  exit 1
}

# --- Utility: retry wrapper ---------------------------------------------------
retry() {
  local n=1 cmd="$*"
  until eval "$cmd"; do
    if (( n >= MAX_RETRIES )); then
      echo "[$(date '+%F %T')] ERROR: Command failed after $MAX_RETRIES attempts: $cmd" >> "$LOG_DIR/backup-$DATE_STR.log"
      return 1
    fi  
    echo "[$(date '+%F %T')] WARN: Command failed (attempt $n/$MAX_RETRIES). Retrying in $RETRY_DELAY s..." >> "$LOG_DIR/backup-$DATE_STR.log"
    sleep $RETRY_DELAY
    ((n++))
  done
}

# --- 1) Prune local logs older than N days ------------------------------------
prune_local_logs() {
  local retention_days=30 logf="$LOG_DIR/backup-$DATE_STR.log"
  echo "[$(date '+%F %T')] Pruning local logs older than $retention_days days..." >> "$logf"
  find "$LOG_DIR" -type f -name '*.log' -mtime +$retention_days -delete
  echo "[$(date '+%F %T')] Pruning local logs completed." >> "$logf"
}

# --- 2) Prune old remote snapshots --------------------------------------------
prune_remote_snapshots() {
  local logf="$LOG_DIR/backup-$DATE_STR.log"
  echo "[$(date '+%F %T')] Pruning remote snapshots older than $REMOTE_RETENTION_DAYS days..." >> "$logf"
  retry "$RCLONE_BIN delete '$REMOTE_ROOT/archive' --min-age ${REMOTE_RETENTION_DAYS}d $RCLONE_OPTS" >> "$logf"
  echo "[$(date '+%F %T')] Pruned remote snapshots." >> "$logf"
}

# --- 3) Daily incremental backup ----------------------------------------------
backup_daily() {
  local src="$DATA_DIR" dest="$REMOTE_ROOT/daily" logf="$LOG_DIR/backup-$DATE_STR.log"
  echo "[$(date '+%F %T')] Starting daily backup from $src to $dest..." >> "$logf"
  retry "$RCLONE_BIN sync '$src' '$dest' $RCLONE_OPTS --exclude '.envs/**' --log-file '$logf'"
  echo "[$(date '+%F %T')] Daily backup completed." >> "$logf"
}

# --- 4) Weekly snapshot (Sundays) --------------------------------------------
snapshot_weekly() {
  if [[ "$(date +%u)" == "7" ]]; then
    local src="$DATA_DIR" dest="$REMOTE_ROOT/archive/$DATE_STR" logf="$LOG_DIR/snapshot-$DATE_STR.log"
    echo "[$(date '+%F %T')] Starting weekly snapshot from $src to $dest..." >> "$logf"
    retry "$RCLONE_BIN copy '$src' '$dest' $RCLONE_OPTS --exclude '.envs/**' --log-file '$logf'"
    echo "[$(date '+%F %T')] Weekly snapshot completed." >> "$logf"
  fi  
}

# --- 5) Upload logs ----------------------------------------------------------
upload_logs() {
  local src="$LOG_DIR" dest="$REMOTE_ROOT/logs" logf="$LOG_DIR/backup-$DATE_STR.log"
  echo "[$(date '+%F %T')] Uploading logs from $src to $dest..." >> "$logf"
  retry "$RCLONE_BIN sync '$src' '$dest' $RCLONE_OPTS --log-file '$logf'"
  echo "[$(date '+%F %T')] Log upload completed." >> "$logf"
}

# --- Main --------------------------------------------------------------------
main() {
  prune_local_logs
  prune_remote_snapshots
  backup_daily
  snapshot_weekly
  upload_logs
  echo "[$(date '+%F %T')] Script finished successfully." >> "$LOG_DIR/backup-$DATE_STR.log"
}

main "$@"

# ---Log Rotation (optional) -------------------------------------------------
# For home-directory logs, add ~/.config/logrotate/backup:
# $HOME/logs/*.log {
#   daily
#   rotate 30
#   compress
#   missingok
#   notifempty
#   copytruncate
# }