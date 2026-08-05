#!/usr/bin/env bash
#
# configure.sh - interactive wizard that detects attached drives and writes
# config.env for you. Run as a normal user (no root/sudo needed) on either
# the source or destination Pi.
#
# Safe to re-run - it asks before overwriting an existing config.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config.env"

echo "Plex migration setup wizard"
echo "============================"
echo

if [[ -f "$CONFIG_FILE" ]]; then
    read -r -p "config.env already exists at $CONFIG_FILE. Overwrite it? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Left the existing config.env untouched."
        exit 0
    fi
fi

# Pulls a single field's value out of an `lsblk -P` (key="value") line
# without eval - just bash regex matching against our own trusted lsblk
# output, so there's no risk in how it's parsed.
get_field() {
    local key="$1" line="$2"
    if [[ "$line" =~ ${key}=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

echo "Scanning attached drives..."
echo

mapfile -t LSBLK_LINES < <(lsblk -P -o NAME,PATH,FSTYPE,UUID,LABEL,SIZE,MOUNTPOINT 2>/dev/null)

CANDIDATES=()
for line in "${LSBLK_LINES[@]}"; do
    fstype=$(get_field FSTYPE "$line")
    [[ -z "$fstype" || "$fstype" == "swap" ]] && continue
    mountpoint=$(get_field MOUNTPOINT "$line")
    case "$mountpoint" in
        /|/boot|/boot/firmware) continue ;;
    esac
    CANDIDATES+=("$line")
done

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No eligible drives found (excluding root/boot/swap)." >&2
    echo "Attach your media/backup USB drives and re-run this script." >&2
    exit 1
fi

echo "Found these drives:"
echo
for i in "${!CANDIDATES[@]}"; do
    line="${CANDIDATES[$i]}"
    path=$(get_field PATH "$line")
    fstype=$(get_field FSTYPE "$line")
    uuid=$(get_field UUID "$line")
    label=$(get_field LABEL "$line")
    size=$(get_field SIZE "$line")
    mountpoint=$(get_field MOUNTPOINT "$line")
    printf "  [%d] %-16s %-6s %-14s %-8s uuid=%s%s\n" \
        "$((i + 1))" "$path" "$fstype" "${label:-<no label>}" "$size" "${uuid:-<none>}" \
        "${mountpoint:+  (currently mounted at $mountpoint)}"
done
echo

read -r -p "Enter the numbers of the drives to include, space-separated (e.g. '1 2'): " selection

DRIVES=()
for num in $selection; do
    idx=$((num - 1))
    if (( idx < 0 || idx >= ${#CANDIDATES[@]} )); then
        echo "Skipping invalid selection: $num" >&2
        continue
    fi

    line="${CANDIDATES[$idx]}"
    path=$(get_field PATH "$line")
    fstype=$(get_field FSTYPE "$line")
    uuid=$(get_field UUID "$line")
    label=$(get_field LABEL "$line")
    mountpoint=$(get_field MOUNTPOINT "$line")

    if [[ -z "$uuid" ]]; then
        echo "Skipping $path - no UUID found (unformatted or unsupported filesystem?)." >&2
        continue
    fi

    # Prefer wherever it's already mounted right now (shown above) over a
    # guessed path - that's the mount point Plex's library paths already
    # point at, so it's almost always the right answer. Falls back to a
    # guessed /mnt/<label-or-device> path if it isn't mounted at all yet
    # (e.g. a fresh destination drive).
    default_mount="$mountpoint"
    if [[ -z "$default_mount" ]]; then
        default_mount="/mnt/$(basename "$path")"
        [[ -n "$label" ]] && default_mount="/mnt/${label}"
    fi
    # -e -i pre-fills the input line with the default (editable in place,
    # not just shown in brackets) and enables readline tab-completion for
    # paths, so you can Tab through existing /mnt/* directories instead of
    # typing the whole thing out.
    read -e -r -i "$default_mount" -p "Mount point for $path (uuid=$uuid): " mount
    mount="${mount:-$default_mount}"

    read -e -r -i "$fstype" -p "Filesystem type for $path: " fs
    fs="${fs:-$fstype}"

    DRIVES+=("${uuid}:${mount}:${fs}")
    echo "  -> added ${uuid}:${mount}:${fs}"
    echo
done

if [[ ${#DRIVES[@]} -eq 0 ]]; then
    echo "No drives were configured. Aborting." >&2
    exit 1
fi

echo "Configured drives:"
for d in "${DRIVES[@]}"; do
    echo "  $d"
done
echo

echo "Which mount point should hold the backup archive?"
for i in "${!DRIVES[@]}"; do
    IFS=':' read -r _ mount _ <<< "${DRIVES[$i]}"
    printf "  [%d] %s\n" "$((i + 1))" "$mount"
done
read -r -p "Enter a number: " backup_choice
backup_idx=$((backup_choice - 1))
if (( backup_idx < 0 || backup_idx >= ${#DRIVES[@]} )); then
    echo "Invalid selection." >&2
    exit 1
fi
IFS=':' read -r _ BACKUP_DEST_MOUNT _ <<< "${DRIVES[$backup_idx]}"

read -e -r -i "plex_backups" -p "Subdirectory for backups under $BACKUP_DEST_MOUNT: " BACKUP_DEST_SUBDIR
BACKUP_DEST_SUBDIR="${BACKUP_DEST_SUBDIR:-plex_backups}"

read -r -p "How many past backups to keep [3]: " RETENTION_COUNT
RETENTION_COUNT="${RETENTION_COUNT:-3}"
if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Not a number, defaulting to 3." >&2
    RETENTION_COUNT=3
fi

read -r -p "Include generated Media/ (thumbnails - larger backup, skips regeneration)? [y/N] " include_media
if [[ "$include_media" =~ ^[Yy]$ ]]; then
    INCLUDE_GENERATED_MEDIA=true
else
    INCLUDE_GENERATED_MEDIA=false
fi

read -r -p "Configure the ufw firewall during restore? [Y/n] " configure_fw
if [[ "$configure_fw" =~ ^[Nn]$ ]]; then
    CONFIGURE_FIREWALL=false
else
    CONFIGURE_FIREWALL=true
fi

read -r -p "Update Plex to the latest version during backup/restore? [Y/n] " update_plex
if [[ "$update_plex" =~ ^[Nn]$ ]]; then
    UPDATE_PLEX=false
else
    UPDATE_PLEX=true
fi

{
    echo "# Generated by scripts/configure.sh on $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Re-run that script any time to regenerate this file."
    echo
    echo "DRIVES=("
    for d in "${DRIVES[@]}"; do
        echo "    \"$d\""
    done
    echo ")"
    echo
    echo "BACKUP_DEST_MOUNT=\"$BACKUP_DEST_MOUNT\""
    echo "BACKUP_DEST_SUBDIR=\"$BACKUP_DEST_SUBDIR\""
    echo
    echo "RETENTION_COUNT=$RETENTION_COUNT"
    echo "INCLUDE_GENERATED_MEDIA=$INCLUDE_GENERATED_MEDIA"
    echo "CONFIGURE_FIREWALL=$CONFIGURE_FIREWALL"
    echo "UPDATE_PLEX=$UPDATE_PLEX"
} > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

echo
echo "Wrote $CONFIG_FILE (permissions set to 600)."
echo "If your source and destination are different physical machines, copy this"
echo "same config.env to the other one before running the backup/restore scripts there."
