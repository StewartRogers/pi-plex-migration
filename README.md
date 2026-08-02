# Plex RPI3 -> RPI5 Migration

Two scripts under `scripts/`:

- `plex_backup.sh` - run on the **RPI3** (source). Stops Plex, archives its
  settings/metadata/databases to `/mnt/newdisk/plex_backups/`, checksums it,
  restarts Plex.
- `plex_restore_setup.sh` - run on the **RPI5** (destination, fresh Raspberry
  Pi OS install). Mounts the two USB drives at the same paths as the RPI3,
  installs Plex from the official apt repo, and restores the backup into it.

## Setup

Both scripts read drive UUIDs/mount points from `config.env` (gitignored,
never committed - it's specific to your hardware):

```bash
cp config.example.env config.env
lsblk -f   # find your drives' UUIDs
# edit config.env with your actual UUIDs and mount points
```

## Steps

1. Copy this whole repo (including your filled-in `config.env`) to the RPI3
   (e.g. `scp -r . pi@rpi3:~/plex-migration/`), or clone it there.
2. On the RPI3:
   ```bash
   chmod +x scripts/plex_backup.sh
   sudo ./scripts/plex_backup.sh
   ```
   This writes the archive to `/mnt/newdisk/plex_backups/<timestamp>/`.
3. Shut down the RPI3, move the two USB drives (`hdddisk` and `newdisk`,
   containing your media + the fresh backup) over to the RPI5.
4. Flash the latest Raspberry Pi OS (64-bit) to the RPI5's SD card, boot it,
   enable SSH, attach the two USB drives.
5. Copy `scripts/plex_restore_setup.sh` to the RPI5 and run it:
   ```bash
   chmod +x scripts/plex_restore_setup.sh
   sudo ./scripts/plex_restore_setup.sh
   ```
   It auto-finds the newest backup under `/mnt/newdisk/plex_backups` or
   `/mnt/hdddisk/plex_backups`. To restore a specific archive instead:
   ```bash
   sudo ./scripts/plex_restore_setup.sh /mnt/newdisk/plex_backups/20260802_120000/plex_backup_20260802_120000.tar.gz
   ```
6. Open `http://<rpi5-ip>:32400/web`, confirm libraries and settings look
   right (see the script's final printout for a short checklist).

## Firewall (ufw)

The restore script configures `ufw` on the RPI5 by default:

- SSH is allowed first (auto-detected port, default 22) so enabling the
  firewall can't lock you out.
- `32400/tcp` (core Plex access) is allowed from anywhere.
- DLNA/GDM discovery and Plex Companion ports are allowed only from your
  detected LAN subnet, not the whole internet.
- Default policy becomes deny-incoming / allow-outgoing.

If you use a router port-forward for remote access, that's separate from
this Pi's firewall - point it at the RPI5's IP after the move. Set
`CONFIGURE_FIREWALL=false` near the top of `plex_restore_setup.sh` to skip
this section entirely.

## Notes / assumptions

- Both drives are UUID-pinned in `/etc/fstab` on the RPI3. The restore script
  replicates the same fstab lines (using the UUIDs from your `config.env`) on
  the RPI5, so Plex library paths need no changes.
- The backup skips `Cache/`, `Crash Reports/`, `Logs/`, `Diagnostics/`,
  `Codecs/`, and (by default) `Media/` (generated thumbnails/BIF previews) -
  all regenerable, and skipping them keeps the archive small and fast to
  create on a RPI3. Flip `INCLUDE_GENERATED_MEDIA=true` in the backup script
  if you'd rather not wait for Plex to regenerate those.
- The restore script moves aside (not deletes) whatever data directory a
  fresh Plex install creates, so nothing is destroyed if something looks off.
- Plex's official apt repo publishes arm64 builds, so this works whether the
  RPI5 image is 32-bit or 64-bit Raspberry Pi OS (64-bit recommended).
