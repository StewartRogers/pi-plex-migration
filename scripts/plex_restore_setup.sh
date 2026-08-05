#!/usr/bin/env bash
#
# plex_restore_setup.sh - Set up mounts, install Plex, and restore settings
# on a new, fresh destination machine. Run as root: sudo ./plex_restore_setup.sh
#
# Optional argument: path to a specific backup .tar.gz to restore. If
# omitted, the newest backup found under the configured search paths is used.
#
# Steps:
#   1. Add fstab entries for each configured data drive (by UUID) if not
#      present, then mount them - this keeps library paths identical to
#      the source system.
#   2. Configure the firewall (ufw): allow SSH first, then Plex's ports.
#   3. Install (or update to the latest) Plex Media Server from the
#      official Plex apt repo.
#   4. Stop the service before touching its data dir.
#   5. Verify and extract the backup archive over the data directory.
#   6. Fix ownership and start the service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
load_config "$SCRIPT_DIR"

# Where to look for backups if no path is given as $1 (newest *.tar.gz wins).
# Primarily the configured backup destination, but every configured drive's
# same subdirectory is also checked as a fallback in case that setting
# changed between the backup and restore runs.
BACKUP_SEARCH_DIRS=("${BACKUP_DEST_MOUNT}/${BACKUP_DEST_SUBDIR}")
for entry in "${DRIVES[@]}"; do
    parse_drive_entry "$entry"
    candidate="${DRIVE_MOUNT}/${BACKUP_DEST_SUBDIR}"
    if [[ "$candidate" != "${BACKUP_SEARCH_DIRS[0]}" ]]; then
        BACKUP_SEARCH_DIRS+=("$candidate")
    fi
done

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root (sudo $0)" >&2
    exit 1
fi

setup_logging "restore" "$(date '+%Y%m%d_%H%M%S')"
trap stop_logging EXIT

### 0. Ensure required packages are present ------------------------------------
# A fresh Raspberry Pi OS Lite image may not have curl/gnupg/ca-certificates
# preinstalled, and its apt package index may be stale from image-build time.

log "Refreshing apt package index..."
apt-get update -qq

log "Installing prerequisite packages (curl, gnupg, ca-certificates)..."
apt-get install -y curl gnupg ca-certificates >/dev/null

### 1. fstab entries + mounts -------------------------------------------------

ensure_fstab_entry() {
    local uuid="$1" mount_point="$2" fstype="$3"
    # Anchored on word boundaries so this can't false-match a UUID that's
    # merely a substring of another entry (or of a comment).
    if grep -qE "(^|[[:space:]])${uuid}([[:space:]]|$)" /etc/fstab; then
        log "fstab already has an entry for UUID $uuid, skipping."
        return
    fi
    log "Adding fstab entry for UUID $uuid -> $mount_point"
    mkdir -p "$mount_point"
    cp /etc/fstab "/etc/fstab.bak.$(date '+%Y%m%d_%H%M%S')"
    # 'nofail' keeps a missing/misidentified drive from hanging boot.
    echo "/dev/disk/by-uuid/${uuid}    ${mount_point}         ${fstype}    defaults,nofail   0   0" >> /etc/fstab
}

for entry in "${DRIVES[@]}"; do
    parse_drive_entry "$entry"
    ensure_fstab_entry "$DRIVE_UUID" "$DRIVE_MOUNT" "$DRIVE_FSTYPE"
done

log "Mounting all fstab entries..."
mount -a

for entry in "${DRIVES[@]}"; do
    parse_drive_entry "$entry"
    if ! mountpoint -q "$DRIVE_MOUNT"; then
        echo "ERROR: $DRIVE_MOUNT did not mount. Check that the drive is attached and 'lsblk -f' shows the expected UUID." >&2
        exit 1
    fi
done
log "All ${#DRIVES[@]} configured drive(s) mounted successfully."

### 2. Configure firewall (ufw) ------------------------------------------------

if [[ "$CONFIGURE_FIREWALL" == "true" ]]; then
    log "Configuring ufw firewall..."

    if ! command -v ufw >/dev/null 2>&1; then
        log "Installing ufw..."
        apt-get install -y ufw >/dev/null
    fi

    # Detect the actual configured SSH port so we don't lock ourselves out.
    # Falls back to 22 if nothing explicit is set in sshd_config.
    SSH_PORT=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
    SSH_PORT="${SSH_PORT:-22}"
    log "Allowing SSH on port $SSH_PORT (must be first, before default-deny)..."
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'

    log "Allowing Plex Media Server access (32400/tcp) from anywhere..."
    ufw allow 32400/tcp comment 'Plex Media Server'

    # Detect the local LAN subnet (e.g. 192.168.1.0/24) to scope the
    # LAN-only discovery/companion ports below. These don't need to be
    # reachable from the internet, only from other devices on the same LAN.
    # Derived from the default route's interface specifically, rather than
    # just the first "scope link" route, so a docker/VPN/bridge interface
    # can't get picked instead of the real LAN NIC.
    DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)
    LAN_SUBNET=""
    if [[ -n "$DEFAULT_IFACE" ]]; then
        LAN_SUBNET=$(ip -4 route show scope link dev "$DEFAULT_IFACE" 2>/dev/null | awk '{print $1}' | head -n1 || true)
    fi

    if [[ -n "$LAN_SUBNET" ]]; then
        log "Allowing Plex LAN-only ports (DLNA/GDM discovery, Companion) from $LAN_SUBNET..."
        ufw allow from "$LAN_SUBNET" to any port 1900 proto udp comment 'Plex DLNA discovery'
        ufw allow from "$LAN_SUBNET" to any port 32410:32414 proto udp comment 'Plex GDM discovery'
        ufw allow from "$LAN_SUBNET" to any port 32469 proto tcp comment 'Plex DLNA server'
        ufw allow from "$LAN_SUBNET" to any port 3005 proto tcp comment 'Plex Companion'
    else
        log "WARNING: could not detect LAN subnet, skipping the optional DLNA/GDM/Companion rules."
        log "  (Core Plex access on 32400/tcp is still allowed - add the rest manually if you need them.)"
    fi

    log "Setting default policy (deny incoming, allow outgoing)..."
    ufw default deny incoming
    ufw default allow outgoing

    log "Enabling ufw..."
    ufw --force enable
    ufw status verbose
else
    log "CONFIGURE_FIREWALL is false, skipping firewall setup."
fi

### 3. Install (or update) Plex from the official apt repo --------------------

update_plex_package

### 4. Stop the service before touching its data dir ---------------------------

log "Stopping $PLEX_SERVICE (may already be starting from fresh install)..."
systemctl stop "$PLEX_SERVICE" || true

### 5. Locate, verify, and extract the backup ----------------------------------

BACKUP_ARCHIVE="${1:-}"
if [[ -z "$BACKUP_ARCHIVE" ]]; then
    log "No backup path given, searching for the newest archive..."
    # Matches both *.tar (current, uncompressed) and *.tar.gz (backups made
    # before compression was dropped - see plex_backup.sh) so older archives
    # are still found. Extraction below auto-detects either format.
    BACKUP_ARCHIVE=$(find "${BACKUP_SEARCH_DIRS[@]}" \( -name '*.tar' -o -name '*.tar.gz' \) -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n1 | cut -d' ' -f2- || true)
fi

if [[ -z "$BACKUP_ARCHIVE" || ! -f "$BACKUP_ARCHIVE" ]]; then
    echo "ERROR: no backup archive found under: ${BACKUP_SEARCH_DIRS[*]}" >&2
    echo "Pass one explicitly: $0 ${BACKUP_DEST_MOUNT}/${BACKUP_DEST_SUBDIR}/<dir>/plex_backup_*.tar" >&2
    exit 1
fi
log "Using backup archive: $BACKUP_ARCHIVE"

CHECKSUM_FILE="${BACKUP_ARCHIVE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
    log "Verifying checksum..."
    if ! (cd "$(dirname "$BACKUP_ARCHIVE")" && sha256sum -c "$(basename "$CHECKSUM_FILE")"); then
        echo "ERROR: checksum verification failed for $BACKUP_ARCHIVE - archive may be corrupt/incomplete." >&2
        exit 1
    fi
else
    log "WARNING: no checksum file found alongside archive, skipping verification."
fi

SAFETY_DIR=""
if [[ -d "$PLEX_DATA_DIR" ]]; then
    # Kept well outside Library/Application Support entirely (not just outside
    # the "Plex Media Server" folder) - Plex's own docs warn that anything it
    # doesn't recognize under its data directory can get swept up by its
    # periodic cleanup, so this has no business being anywhere nearby.
    mkdir -p /var/backups
    SAFETY_DIR="/var/backups/plex_fresh_install_bak.$(date '+%Y%m%d_%H%M%S')"
    log "Moving fresh-install data dir aside to $SAFETY_DIR (not deleting, just in case)..."
    mv "$PLEX_DATA_DIR" "$SAFETY_DIR"
fi

log "Extracting backup into place..."
mkdir -p "$PLEX_DATA_PARENT"
# No -z: GNU tar auto-detects gzip vs. plain from the file's own magic
# bytes on extraction, regardless of extension, so this handles both
# current (uncompressed) and older (gzip'd) archives without branching.
tar -xf "$BACKUP_ARCHIVE" -C "$PLEX_DATA_PARENT"

### 6. Fix ownership and start ------------------------------------------------

log "Fixing ownership (plex:plex)..."
chown -R plex:plex "$PLEX_DATA_PARENT"

log "Starting $PLEX_SERVICE..."
systemctl enable --now "$PLEX_SERVICE"

sleep 3
if systemctl is-active --quiet "$PLEX_SERVICE"; then
    log "Plex is running."
else
    echo "WARNING: $PLEX_SERVICE does not appear to be active. Check: systemctl status $PLEX_SERVICE" >&2
fi

CONFIGURED_MOUNTS=""
for entry in "${DRIVES[@]}"; do
    parse_drive_entry "$entry"
    CONFIGURED_MOUNTS="${CONFIGURED_MOUNTS}${CONFIGURED_MOUNTS:+, }${DRIVE_MOUNT}"
done

cat <<EOF

Restore finished. Next, check in a browser at http://<destination-ip>:32400/web :
  - Settings > Manage > Libraries: confirm each library's folder paths
    resolve (they should, since mount points match the source system: $CONFIGURED_MOUNTS).
  - If you skipped Media/ (generated thumbnails) in the backup, Plex will
    regenerate scrubber previews/thumbnails over time - no action needed.
  - ufw is now enabled with default-deny incoming. Run 'sudo ufw status verbose'
    to review the rules. If remote access (outside your LAN) was working on
    the source system via a router port-forward to 32400, that router
    configuration is separate from this system's firewall and points at the
    old system's LAN IP - you'll need to update the router's forwarding rule
    to this system's IP.
  - Confirm the server shows as the same server (same name/identity) under
    Settings > General, and that Remote Access still works if you use it.
  - If you disabled "Empty trash automatically after every scan" on the
    source system before backing up, you can turn that back on now.
EOF

if [[ -n "$SAFETY_DIR" ]]; then
    log "Once everything's confirmed working, you can remove the fresh-install backup at: $SAFETY_DIR"
fi
