#!/usr/bin/env bash
#
# common.sh - shared helpers for plex_backup.sh and plex_restore_setup.sh.
# Not meant to be run directly; sourced by the two migration scripts.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

LOG_DIR="/var/log/plex-migration"

# Tees all of this script's stdout/stderr (not just log() lines - apt/tar/
# etc. output too) to a timestamped file under LOG_DIR, in addition to still
# printing to the console. Logs go there rather than onto a configured drive
# since the drive's mount status isn't known yet this early in either script.
# Call once, as root, after the EUID check. Pair with an EXIT trap that
# calls stop_logging, or the tee process's final buffered lines can be lost
# (or, if you instead just `wait` for it without restoring fds first, hang
# forever - the tee's stdin pipe never sees EOF while this shell's own
# stdout/stderr still point at it).
setup_logging() {
    local prefix="$1" timestamp="$2"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/${prefix}_${timestamp}.log"
    exec 3>&1 4>&2
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Logging this run to $LOG_FILE"
}

# Restores stdout/stderr to what they were before setup_logging, so `tee`
# sees EOF on its input and can flush + exit, then waits for it. Call from
# an EXIT trap so this runs on every exit path (success, error, interrupt).
stop_logging() {
    exec 1>&3 2>&4 3>&- 4>&-
    wait 2>/dev/null || true
}

# shellcheck disable=SC2034
PLEX_DATA_PARENT="/var/lib/plexmediaserver/Library/Application Support"
# shellcheck disable=SC2034
PLEX_DATA_DIR="${PLEX_DATA_PARENT}/Plex Media Server"
# shellcheck disable=SC2034
PLEX_SERVICE="plexmediaserver"

PLACEHOLDER_UUID="00000000-0000-0000-0000-000000000000"

# Splits a "UUID:MOUNT:FSTYPE" DRIVES entry into three globals: DRIVE_UUID,
# DRIVE_MOUNT, DRIVE_FSTYPE.
parse_drive_entry() {
    IFS=':' read -r DRIVE_UUID DRIVE_MOUNT DRIVE_FSTYPE <<< "$1"
}

# Loads config.env (expected one directory above the calling script) and
# fails fast if it's missing or still has placeholder/inconsistent values.
# Also warns if the file's permissions would let another local user tamper
# with it, since it's sourced (and therefore executed) as root.
load_config() {
    local script_dir="$1"
    local config_file="${script_dir}/../config.env"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: config.env not found at $config_file" >&2
        echo "Run scripts/configure.sh, or copy config.example.env to config.env and fill it in." >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$config_file"

    if [[ -z "${DRIVES+x}" || ${#DRIVES[@]} -eq 0 ]]; then
        echo "ERROR: DRIVES is empty in $config_file." >&2
        echo "Run scripts/configure.sh, or edit $config_file directly (see config.example.env)." >&2
        exit 1
    fi

    local entry seen_backup_mount=false
    for entry in "${DRIVES[@]}"; do
        parse_drive_entry "$entry"
        if [[ -z "$DRIVE_UUID" || -z "$DRIVE_MOUNT" || -z "$DRIVE_FSTYPE" ]]; then
            echo "ERROR: malformed DRIVES entry '$entry' in $config_file (expected UUID:MOUNT:FSTYPE)." >&2
            exit 1
        fi
        if [[ "$DRIVE_UUID" == "$PLACEHOLDER_UUID" ]]; then
            echo "ERROR: DRIVES entry '$entry' in $config_file still has the example placeholder UUID." >&2
            echo "Run scripts/configure.sh, or edit $config_file with your real drive UUID (see 'lsblk -f')." >&2
            exit 1
        fi
        [[ "$DRIVE_MOUNT" == "${BACKUP_DEST_MOUNT:-}" ]] && seen_backup_mount=true
    done

    if [[ -z "${BACKUP_DEST_MOUNT:-}" ]]; then
        echo "ERROR: BACKUP_DEST_MOUNT is not set in $config_file." >&2
        exit 1
    fi
    if [[ "$seen_backup_mount" != "true" ]]; then
        echo "ERROR: BACKUP_DEST_MOUNT ($BACKUP_DEST_MOUNT) doesn't match any mount point in DRIVES." >&2
        exit 1
    fi

    # Defaults for options that may be absent from an older config.env.
    : "${BACKUP_DEST_SUBDIR:=plex_backups}"
    : "${RETENTION_COUNT:=3}"
    : "${INCLUDE_GENERATED_MEDIA:=false}"
    : "${CONFIGURE_FIREWALL:=true}"
    : "${UPDATE_PLEX:=true}"

    local perms
    perms=$(stat -c '%a' "$config_file" 2>/dev/null || true)
    if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
        echo "WARNING: $config_file has permissions $perms (group/other may be able to read or write it)." >&2
        echo "  This file is sourced as root - consider: chmod 600 $config_file" >&2
    fi
}

# Ensures the official Plex apt repo + signing key are configured. Safe to
# call unconditionally - each step here is idempotent.
ensure_plex_apt_repo() {
    if [[ -f /etc/apt/sources.list.d/plexmediaserver.list ]]; then
        return
    fi
    log "Adding Plex apt repo..."
    apt-get install -y curl gnupg ca-certificates >/dev/null

    install -d -m 0755 /usr/share/keyrings
    # No -L: this key URL isn't expected to redirect, so fail loudly instead
    # of silently trusting whatever a redirect might point to.
    curl -fsS https://downloads.plex.tv/plex-keys/PlexSign.key \
        | gpg --dearmor -o /usr/share/keyrings/plex-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" \
        > /etc/apt/sources.list.d/plexmediaserver.list
}

# Installs plexmediaserver if missing, or upgrades it to the latest apt
# candidate if already installed - unless UPDATE_PLEX=false, in which case
# an already-installed version is left alone (a missing one is still
# installed, just not force-upgraded later).
update_plex_package() {
    if ! dpkg -s plexmediaserver >/dev/null 2>&1; then
        ensure_plex_apt_repo
        log "Installing Plex Media Server..."
        apt-get update -qq
        apt-get install -y plexmediaserver
        return
    fi

    if [[ "${UPDATE_PLEX:-true}" != "true" ]]; then
        log "UPDATE_PLEX is false, leaving the installed Plex version as-is."
        return
    fi

    log "Checking for a newer Plex Media Server version..."
    apt-get update -qq
    apt-get install -y plexmediaserver
}
