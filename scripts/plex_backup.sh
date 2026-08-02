#!/usr/bin/env bash
#
# plex_backup.sh - Back up Plex Media Server settings/metadata to a USB drive.
# Run this ON THE SOURCE SYSTEM as root: sudo ./plex_backup.sh
#
# Backs up the whole Plex "Application Support" data directory (databases,
# Preferences.xml, metadata, plug-ins) while the service is stopped, so the
# SQLite library databases can't be caught mid-write. Regenerable junk
# (Cache, Crash Reports, Logs, Codecs) is skipped to keep the archive small.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config "$SCRIPT_DIR"

BACKUP_DEST_ROOT="${BACKUP_DEST_MOUNT}/${BACKUP_DEST_SUBDIR}"

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root (sudo $0)" >&2
    exit 1
fi

if [[ ! -d "$PLEX_DATA_DIR" ]]; then
    echo "Plex data directory not found: $PLEX_DATA_DIR" >&2
    exit 1
fi

update_plex_package

if ! mountpoint -q "$(dirname "$BACKUP_DEST_ROOT")" 2>/dev/null && [[ ! -d "$(dirname "$BACKUP_DEST_ROOT")" ]]; then
    echo "Backup destination parent not found/mounted: $(dirname "$BACKUP_DEST_ROOT")" >&2
    exit 1
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
WORKDIR="${BACKUP_DEST_ROOT}/${TIMESTAMP}"
ARCHIVE="${WORKDIR}/plex_backup_${TIMESTAMP}.tar.gz"
MANIFEST="${WORKDIR}/manifest.txt"
CHECKSUM="${ARCHIVE}.sha256"

mkdir -p "$WORKDIR"

# Rough free-space sanity check: require at least as much free space as the
# source directory currently occupies (compressed archive will be smaller,
# but better to be conservative before we start).
SRC_SIZE_KB=$(du -sk "$PLEX_DATA_DIR" | cut -f1)
DEST_AVAIL_KB=$(df -Pk "$BACKUP_DEST_ROOT" | awk 'NR==2 {print $4}')
if (( DEST_AVAIL_KB < SRC_SIZE_KB / 2 )); then
    echo "Warning: destination free space (${DEST_AVAIL_KB}KB) looks low vs source size (${SRC_SIZE_KB}KB)." >&2
    echo "Continuing anyway since excluded dirs (Cache/Media/etc) should shrink this a lot, but keep an eye on it." >&2
fi

SERVICE_WAS_ACTIVE=false
if systemctl is-active --quiet "$PLEX_SERVICE"; then
    SERVICE_WAS_ACTIVE=true
fi

restart_plex() {
    if [[ "$SERVICE_WAS_ACTIVE" == "true" ]]; then
        log "Restarting $PLEX_SERVICE..."
        systemctl start "$PLEX_SERVICE" || echo "WARNING: failed to restart $PLEX_SERVICE - start it manually." >&2
    fi
}
trap restart_plex EXIT

log "Stopping $PLEX_SERVICE for a consistent backup..."
systemctl stop "$PLEX_SERVICE"

# Give the DB a moment to fully release file locks after shutdown.
sleep 2

EXCLUDES=(
    --exclude='Cache'
    --exclude='Crash Reports'
    --exclude='Logs'
    --exclude='Diagnostics'
    --exclude='Codecs'
)
if [[ "$INCLUDE_GENERATED_MEDIA" != "true" ]]; then
    EXCLUDES+=(--exclude='Media')
fi

log "Archiving Plex data directory to $ARCHIVE ..."
tar "${EXCLUDES[@]}" -czf "$ARCHIVE" -C "$(dirname "$PLEX_DATA_DIR")" "$(basename "$PLEX_DATA_DIR")"

log "Writing checksum..."
sha256sum "$ARCHIVE" > "$CHECKSUM"

log "Writing manifest..."
{
    echo "# This file lists this machine's hostname and every attached disk's"
    echo "# UUID/label - useful for troubleshooting your own migration, but"
    echo "# don't paste it unredacted into a public forum post or bug report."
    echo ""
    echo "backup_timestamp=$TIMESTAMP"
    echo "hostname=$(hostname)"
    echo "arch=$(uname -m)"
    echo "os=$(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "plex_version=$(dpkg-query -W -f='${Version}' plexmediaserver 2>/dev/null || echo unknown)"
    echo "source_data_dir=$PLEX_DATA_DIR"
    echo "included_generated_media=$INCLUDE_GENERATED_MEDIA"
    echo "archive_sha256=$(cut -d' ' -f1 "$CHECKSUM")"
    echo ""
    echo "--- lsblk -f ---"
    lsblk -f
    echo ""
    echo "--- /etc/fstab ---"
    cat /etc/fstab
} > "$MANIFEST"

log "Backup complete: $ARCHIVE"
log "Manifest: $MANIFEST"

# Prune old backups beyond retention count (oldest first, keep RETENTION_COUNT)
log "Pruning old backups (keeping newest $RETENTION_COUNT)..."
mapfile -t OLD_BACKUPS < <(find "$BACKUP_DEST_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
COUNT=${#OLD_BACKUPS[@]}
if (( COUNT > RETENTION_COUNT )); then
    TO_DELETE=$((COUNT - RETENTION_COUNT))
    for ((i=0; i<TO_DELETE; i++)); do
        log "Removing old backup: ${OLD_BACKUPS[$i]}"
        rm -rf "${OLD_BACKUPS[$i]}"
    done
fi

log "Done."
