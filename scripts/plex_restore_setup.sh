#!/usr/bin/env bash
#
# plex_restore_setup.sh - Set up mounts, install Plex, and restore settings
# on a new machine (the RPI5). Run as root: sudo ./plex_restore_setup.sh
#
# Optional argument: path to a specific backup .tar.gz to restore. If
# omitted, the newest backup found under the configured search paths is used.
#
# Steps:
#   1. Add fstab entries for the two data drives (by UUID) if not present,
#      then mount them - this keeps library paths identical to the RPI3.
#   2. Configure the firewall (ufw): allow SSH first, then Plex's ports.
#   3. Install Plex Media Server from the official Plex apt repo.
#   4. Stop the freshly-installed service before it creates its own state.
#   5. Verify and extract the backup archive over the data directory.
#   6. Fix ownership and start the service.

set -euo pipefail

### --- Load machine-specific config (drive UUIDs/mounts) --------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.env not found at $CONFIG_FILE" >&2
    echo "Copy config.example.env to config.env and fill in your drive UUIDs (see 'lsblk -f')." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

### --- Config: must match the source machine's setup ------------------------

PLEX_DATA_PARENT="/var/lib/plexmediaserver/Library/Application Support"
PLEX_DATA_DIR="${PLEX_DATA_PARENT}/Plex Media Server"
PLEX_SERVICE="plexmediaserver"

# Where to look for backups if no path is given as $1 (newest *.tar.gz wins)
BACKUP_SEARCH_DIRS=("${NEWDISK_MOUNT}/plex_backups" "${HDDDISK_MOUNT}/plex_backups")

# Set to "false" to skip all ufw configuration (e.g. if you manage the
# firewall some other way, or a firewall is already configured to your liking).
CONFIGURE_FIREWALL=true

### --- End config -----------------------------------------------------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root (sudo $0)" >&2
    exit 1
fi

### 0. Ensure required packages are present ------------------------------------
# A fresh Raspberry Pi OS Lite image may not have curl/gnupg/ca-certificates
# preinstalled, and its apt package index may be stale from image-build time.

log "Refreshing apt package index..."
apt-get update -qq

log "Installing prerequisite packages (curl, gnupg, ca-certificates)..."
apt-get install -y curl gnupg ca-certificates >/dev/null

### 1. fstab entries + mounts -------------------------------------------------

ensure_fstab_entry() {
    local uuid="$1" mount_point="$2"
    if grep -q "$uuid" /etc/fstab; then
        log "fstab already has an entry for UUID $uuid, skipping."
        return
    fi
    log "Adding fstab entry for UUID $uuid -> $mount_point"
    mkdir -p "$mount_point"
    cp /etc/fstab "/etc/fstab.bak.$(date '+%Y%m%d_%H%M%S')"
    echo "/dev/disk/by-uuid/${uuid}    ${mount_point}         ext4    defaults   0   0" >> /etc/fstab
}

ensure_fstab_entry "$HDDDISK_UUID" "$HDDDISK_MOUNT"
ensure_fstab_entry "$NEWDISK_UUID" "$NEWDISK_MOUNT"

log "Mounting all fstab entries..."
mount -a

for mp in "$HDDDISK_MOUNT" "$NEWDISK_MOUNT"; do
    if ! mountpoint -q "$mp"; then
        echo "ERROR: $mp did not mount. Check that the drive is attached and 'lsblk -f' shows the expected UUID." >&2
        exit 1
    fi
done
log "Both drives mounted successfully."

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
    LAN_SUBNET=$(ip -4 route show scope link 2>/dev/null | awk '{print $1}' | head -n1 || true)

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

### 3. Install Plex from the official apt repo --------------------------------

if command -v plexmediaserver >/dev/null 2>&1 || dpkg -s plexmediaserver >/dev/null 2>&1; then
    log "plexmediaserver already installed, skipping install step."
else
    log "Adding Plex apt repo..."
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
        | gpg --dearmor -o /usr/share/keyrings/plex-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" \
        > /etc/apt/sources.list.d/plexmediaserver.list

    log "Installing plexmediaserver..."
    apt-get update -qq
    apt-get install -y plexmediaserver
fi

### 4. Stop the service before touching its data dir ---------------------------

log "Stopping $PLEX_SERVICE (may already be starting from fresh install)..."
systemctl stop "$PLEX_SERVICE" || true

### 5. Locate, verify, and extract the backup ----------------------------------

BACKUP_ARCHIVE="${1:-}"
if [[ -z "$BACKUP_ARCHIVE" ]]; then
    log "No backup path given, searching for the newest archive..."
    BACKUP_ARCHIVE=$(find "${BACKUP_SEARCH_DIRS[@]}" -name '*.tar.gz' -type f 2>/dev/null \
        | xargs -I{} stat --format '%Y {}' {} 2>/dev/null \
        | sort -rn | head -n1 | cut -d' ' -f2- || true)
fi

if [[ -z "$BACKUP_ARCHIVE" || ! -f "$BACKUP_ARCHIVE" ]]; then
    echo "ERROR: no backup archive found. Pass one explicitly: $0 /mnt/newdisk/plex_backups/<dir>/plex_backup_*.tar.gz" >&2
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

if [[ -d "$PLEX_DATA_DIR" ]]; then
    SAFETY_DIR="${PLEX_DATA_DIR}.fresh_install_bak.$(date '+%Y%m%d_%H%M%S')"
    log "Moving fresh-install data dir aside to $SAFETY_DIR (not deleting, just in case)..."
    mv "$PLEX_DATA_DIR" "$SAFETY_DIR"
fi

log "Extracting backup into place..."
mkdir -p "$PLEX_DATA_PARENT"
tar -xzf "$BACKUP_ARCHIVE" -C "$PLEX_DATA_PARENT"

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

cat <<EOF

Restore finished. Next, check in a browser at http://<rpi5-ip>:32400/web :
  - Settings > Manage > Libraries: confirm each library's folder paths
    resolve (they should, since mount points match the RPI3: $HDDDISK_MOUNT, $NEWDISK_MOUNT).
  - If you skipped Media/ (generated thumbnails) in the backup, Plex will
    regenerate scrubber previews/thumbnails over time - no action needed.
  - ufw is now enabled with default-deny incoming. Run 'sudo ufw status verbose'
    to review the rules. If remote access (outside your LAN) was working on
    the RPI3 via a router port-forward to 32400, that router configuration
    is separate from this Pi's firewall and points at the old RPI3's LAN IP -
    you'll need to update the router's forwarding rule to the RPI5's IP.
  - Confirm the server shows as the same server (same name/identity) under
    Settings > General, and that Remote Access still works if you use it.
  - Once confirmed working, you can remove the .fresh_install_bak.* directory
    left under: $PLEX_DATA_PARENT
EOF
