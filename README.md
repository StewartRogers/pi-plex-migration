# Plex Server Migration (e.g. RPI3 -> RPI5)

Scripts to move a Plex Media Server install between two systems, backed by
one or more USB drives: back it up on the source, physically move the
drive(s) over, then restore onto a freshly-imaged destination. The source
is taken fully offline first - this isn't a live/concurrent cutover.

Everything under `scripts/`, sharing helpers from `scripts/lib/common.sh`:

- `configure.sh` - interactive wizard. Detects attached drives and writes
  `config.env` for you. Run this first, on either machine.
- `plex_backup.sh` - run on the **source** system. Updates Plex to the
  latest version, stops it, archives its settings/metadata/databases to
  your configured backup drive, checksums it, restarts Plex.
- `plex_restore_setup.sh` - run on the **destination** system (fresh
  Raspberry Pi OS install, or any fresh Debian-based install). Mounts your
  configured drives at the same paths as the source, configures the
  firewall, installs (or updates) Plex from the official apt repo, and
  restores the backup into it.

Works with any number of drives - one, two, or more - not just a fixed pair.

## Setup

From the repo root (the directory containing this README and `scripts/`),
make all three scripts executable once, then run the wizard:

```bash
chmod +x scripts/*.sh
./scripts/configure.sh
```

`configure.sh` runs as your normal user (no `sudo`) - it's only
`plex_backup.sh` and `plex_restore_setup.sh` that need root, later, on
whichever machine you're backing up or restoring on.

The wizard scans attached drives with `lsblk`, lets you pick which ones are
part of your migration, asks where backups should live, and writes
`config.env` in the repo root (gitignored, never committed - it's specific
to your hardware). It also sets permissions to `600`, since the file is
sourced as root by both scripts.

For the mount point prompt, if a drive is already mounted, the wizard shows
you where and defaults to that same path - just press Enter to accept it.
Only type a different path if you want to mount it somewhere new.

Prefer to do it by hand instead? Copy `config.example.env` to `config.env`
and fill it in yourself; `lsblk -f` gives you the UUIDs/filesystem types.

Either way, both scripts refuse to run if `config.env` is missing, malformed,
or still has the example's placeholder UUID - a forgotten edit fails fast
with a clear error instead of quietly writing a bogus entry to `/etc/fstab`.

### config.env reference

```bash
# One entry per drive involved in the migration.
# Format: "UUID:MOUNT_POINT:FSTYPE"
DRIVES=(
    "a1b2c3d4-e5f6-7890-abcd-ef1234567890:/mnt/hdddisk:ext4"
    "f0e1d2c3-b4a5-6978-fedc-ba0987654321:/mnt/newdisk:ext4"
)

BACKUP_DEST_MOUNT="/mnt/newdisk"   # must be one of the mount points above
BACKUP_DEST_SUBDIR="plex_backups"

RETENTION_COUNT=3                  # how many past backups to keep
INCLUDE_GENERATED_MEDIA=false      # back up regenerable thumbnails too?
CONFIGURE_FIREWALL=true            # set up ufw during restore?
UPDATE_PLEX=true                   # update Plex to latest during both steps?
```

## Steps

1. Copy this whole repo (including your filled-in `config.env`) to the
   source system (e.g. `scp -r . pi@source:~/plex-migration/`), or clone it
   there and run `configure.sh` on that machine. Either way, `cd` into the
   repo root on the source and run `chmod +x scripts/*.sh` once - git
   doesn't preserve the executable bit on a fresh clone/copy, so this is
   needed again here even if you already ran it locally.
2. On the source, in the Plex web app, disable "Empty trash automatically
   after every scan": click the wrench/gear **Settings** icon (top right)
   > **Server** (left sidebar) > **Library**, and uncheck it there - it's
   a global server setting, not a per-library one. This is Plex's own
   recommended prep step before a migration - it stops Plex from
   prematurely trashing library entries during the transition.
3. On the source, from the repo root:
   ```bash
   sudo ./scripts/plex_backup.sh
   ```
   This updates Plex to the latest version, then writes the archive to
   `<BACKUP_DEST_MOUNT>/<BACKUP_DEST_SUBDIR>/<timestamp>/`.
4. Shut down the source system, move the configured drive(s) - containing
   your media plus the fresh backup - over to the destination.
5. Flash a fresh OS to the destination (e.g. the latest Raspberry Pi OS,
   64-bit), boot it, enable SSH, attach the drive(s).
6. Copy the repo (including the same `config.env`) to the destination,
   `cd` into its root, run `chmod +x scripts/*.sh` again (same reason as
   step 1 - it's a separate copy on a separate machine), then:
   ```bash
   sudo ./scripts/plex_restore_setup.sh
   ```
   It auto-finds the newest backup under your configured drives. To restore
   a specific archive instead:
   ```bash
   sudo ./scripts/plex_restore_setup.sh /mnt/newdisk/plex_backups/20260802_120000/plex_backup_20260802_120000.tar.gz
   ```
7. Open `http://<destination-ip>:32400/web`, confirm libraries and settings
   look right (see the script's final printout for a short checklist), then
   re-enable "Empty trash automatically after every scan" (same Settings
   > Server > Library page as step 2).

## Keeping Plex up to date

Both scripts call the same `update_plex_package` helper (`scripts/lib/common.sh`):

- **Backup**: before stopping the service, updates Plex to the latest apt
  candidate first, so the archived data matches the latest version's schema.
- **Restore**: installs Plex if missing, or updates it to the latest apt
  candidate if it's already present (e.g. on a re-run) - either way you end
  up on the latest version, not whatever happened to be cached.

Set `UPDATE_PLEX=false` in `config.env` to skip this and leave whatever
version is already installed alone.

## Firewall (ufw)

The restore script configures `ufw` on the destination by default:

- SSH is allowed first (auto-detected port, default 22) so enabling the
  firewall can't lock you out.
- `32400/tcp` (core Plex access) is allowed from anywhere.
- DLNA/GDM discovery and Plex Companion ports are allowed only from your
  detected LAN subnet, not the whole internet.
- Default policy becomes deny-incoming / allow-outgoing.

If you use a router port-forward for remote access, that's separate from
this Pi's firewall - point it at the destination's IP after the move. Set
`CONFIGURE_FIREWALL=false` in `config.env` to skip this section entirely.

## Notes / assumptions

- Each configured drive is UUID-pinned in `/etc/fstab` on the source. The
  restore script replicates the same fstab lines (using the UUIDs/fstypes
  from your `config.env`, with `nofail` added) on the destination, so Plex
  library paths need no changes and a missing/misidentified drive won't
  hang the boot.
- The backup skips `Cache/`, `Crash Reports/`, `Logs/`, `Diagnostics/`,
  `Codecs/`, and (by default) `Media/` (generated thumbnails/BIF previews) -
  all regenerable, and skipping them keeps the archive small and fast to
  create. Set `INCLUDE_GENERATED_MEDIA=true` in `config.env` if you'd
  rather not wait for Plex to regenerate those.
- The restore script moves aside (not deletes) whatever data directory a
  fresh Plex install creates, to `/var/backups/plex_fresh_install_bak.<timestamp>`
  - deliberately outside `Library/Application Support` entirely, per Plex's
  own warning that anything it doesn't recognize under its data directory can
  get swept up by its periodic cleanup.
- Plex's official apt repo publishes arm64 builds, so this works whether the
  destination image is 32-bit or 64-bit Raspberry Pi OS (64-bit recommended).
- The backup's `.sha256` checksum guards against accidental corruption/bit-rot
  during transit, not tampering - it lives on the same drive as the archive,
  so trust here comes from physically controlling that drive, not from
  cryptographic signing. That's an accepted trade-off for a personal,
  single-user migration tool.
- The backup's `manifest.txt` includes this machine's hostname and full
  `lsblk`/`fstab` output (every attached disk, not just the configured
  migration drives) - handy for troubleshooting your own migration, but
  redact it before pasting into a public forum post or bug report.
- A GitHub Actions workflow (`.github/workflows/lint.yml`) runs `bash -n` and
  `shellcheck` on every push, since there's no other automated test suite for
  a set of standalone shell scripts.
