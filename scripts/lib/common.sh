#!/usr/bin/env bash
#
# common.sh - shared helpers for plex_backup.sh and plex_restore_setup.sh.
# Not meant to be run directly; sourced by the two migration scripts.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

PLEX_DATA_PARENT="/var/lib/plexmediaserver/Library/Application Support"
PLEX_DATA_DIR="${PLEX_DATA_PARENT}/Plex Media Server"
PLEX_SERVICE="plexmediaserver"

# Loads config.env (expected one directory above the calling script) and
# fails fast if it's missing or still has placeholder values. Also warns if
# the file's permissions would let another local user tamper with it, since
# it's sourced (and therefore executed) as root.
load_config() {
    local script_dir="$1"
    local config_file="${script_dir}/../config.env"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: config.env not found at $config_file" >&2
        echo "Copy config.example.env to config.env and fill in your drive UUIDs (see 'lsblk -f')." >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$config_file"

    local placeholder="00000000-0000-0000-0000-000000000000"
    local var
    for var in HDDDISK_UUID NEWDISK_UUID; do
        if [[ -z "${!var:-}" || "${!var}" == "$placeholder" ]]; then
            echo "ERROR: $var in config.env is empty or still the example placeholder." >&2
            echo "Edit $config_file with your real drive UUID (see 'lsblk -f') before running this script." >&2
            exit 1
        fi
    done

    local perms
    perms=$(stat -c '%a' "$config_file" 2>/dev/null || true)
    if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
        echo "WARNING: $config_file has permissions $perms (group/other may be able to read or write it)." >&2
        echo "  This file is sourced as root - consider: chmod 600 $config_file" >&2
    fi

    # Default filesystem type for older config.env files that predate this
    # setting (both drives were ext4 in the original setup this was built for).
    : "${HDDDISK_FSTYPE:=ext4}"
    : "${NEWDISK_FSTYPE:=ext4}"
}
