# ZFS & Storage

Part of [LoungeBox v2 spec](spec.md).

## Boot Drive — ZFS Root (NVMe)

NixOS runs on a ZFS root filesystem on the NVMe drive. This enables system rollback via ZFS snapshots in addition to NixOS's built-in generation switching.

### NVMe Partition Layout

| Partition | Size | Filesystem | Purpose |
|-----------|------|-----------|---------|
| EFI System Partition | 512MB | FAT32 | Bootloader (systemd-boot) |
| ZFS partition | Remainder | ZFS pool `rpool` | NixOS root |

### Boot Pool Datasets

| Dataset | Mount | Mountpoint Type | Purpose |
|---------|-------|----------------|---------|
| `rpool/root` | `/` | `legacy` | Root filesystem |
| `rpool/nix` | `/nix` | `legacy` | Nix store — large, benefits from LZ4 compression |
| `rpool/home` | `/home` | `legacy` | User home directories |
| `rpool/root@blank` | — | — | Empty snapshot taken immediately after install |

All rpool datasets use `mountpoint=legacy`, meaning NixOS manages the mounts via `fileSystems` entries (in `hardware.nix`) rather than ZFS auto-mounting. This is required for NixOS ZFS root. The `nixos-generate-config` command creates these entries automatically, but verify them:

```nix
# In hardware.nix (generated, but verify these exist):
fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; };
fileSystems."/nix" = { device = "rpool/nix"; fsType = "zfs"; };
fileSystems."/home" = { device = "rpool/home"; fsType = "zfs"; };
fileSystems."/boot" = { device = "/dev/disk/by-id/<nvme>-part1"; fsType = "vfat"; };
```

The `@blank` snapshot enables the "erase your darlings" pattern if desired later — on every boot, the root dataset is rolled back to the blank snapshot, ensuring all mutable state is explicitly declared. This is optional and not enabled in v1, but having the snapshot costs nothing and keeps the option open.

### Boot Pool Properties

```
zpool create -f \
  -o ashift=12 \
  -O mountpoint=none \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  rpool /dev/disk/by-id/<nvme-disk-id>-part2
```

NixOS config declares the boot pool:
```nix
boot.supportedFilesystems = [ "zfs" ];
boot.zfs.devNodes = "/dev/disk/by-id";
networking.hostId = "<8-char-hex>";  # Required for ZFS — unique per machine
```

The `hostId` is required by ZFS to prevent accidental pool imports on the wrong machine. Generate once with `head -c 8 /etc/machine-id` during installation, then **hardcode the value in the Nix config and never change it.** If the machine is reinstalled, reuse the same `hostId` — otherwise ZFS may refuse to import existing pools.

## Storage Array — RAIDZ1 (4x WD Red)

The 4x WD Red 4TB drives form a RAIDZ1 pool for app data and backups. This provides one-drive fault tolerance with ~12TB raw / ~8TB usable after parity and compression.

### Pool Creation

Both pools and all datasets are declared in `hosts/loungebox/disk.nix` using **disko**. During installation, nixos-anywhere runs disko which creates the pool, sets all properties, and creates all datasets in one pass. See [deployment.md](deployment.md) for the full disko config.

The pool is **not** created by manual commands. The disko config is the source of truth for the disk layout.

Critical settings (declared in disko):
- **`ashift=12`** — matches 4KB physical sectors on WD Reds. If ZFS guesses wrong and uses 512-byte alignment, write performance degrades 2-10x. **Cannot be changed after pool creation.**
- **`compression=lz4`** — transparent compression with minimal CPU overhead. Often results in a net performance gain (less data to write to disk).
- **`atime=off`** — disables access time tracking. Without this, every read triggers a metadata write — pointless overhead, especially for SQLite.
- **`/dev/disk/by-id/`** paths — stable across reboots, unlike `/dev/sdX` which can change.

### Pool Import in NixOS

The Nix config imports the pool at boot:

```nix
boot.zfs.extraPools = [ "storage" ];
```

This ensures the `storage` pool is imported at boot and its datasets are mounted.

### Per-App Datasets

Each app gets its own ZFS dataset under `storage/`. All initial datasets are declared in the disko config and created during installation:

| Dataset | Mount | Declared In |
|---------|-------|------------|
| `storage/eros` | `/mnt/storage/eros` | `disk.nix` (disko) |
| `storage/backups` | `/mnt/storage/backups` | `disk.nix` (disko) |
| `storage/caddy` | `/mnt/storage/caddy` | `disk.nix` (disko) |
| `storage/dockge` | `/mnt/storage/dockge` | `disk.nix` (disko) |
| `storage/<app>` | `/mnt/storage/<app>` | Added to `disk.nix` when adding a new app |

When adding a future app, add its dataset to `disk.nix` and create it manually on the running system:
```bash
zfs create storage/<app-name>
```

disko only runs during installation — it doesn't manage datasets on subsequent rebuilds. New datasets are added to `disk.nix` (so a reinstall would recreate them) but created manually on the live system.

Benefits of per-app datasets:
- **Independent snapshots** — snapshot Eros without snapshotting everything else.
- **Separate compression** — tune per workload if needed (default LZ4 is fine for most).
- **Quotas** — can limit how much space an app uses (not configured in v1, but available).
- **Independent destroy** — remove an app and its data cleanly.

### Scrubs

Monthly ZFS scrubs detect and repair data corruption (bit rot) using RAIDZ1 parity:

```nix
services.zfs.autoScrub = {
  enable = true;
  interval = "monthly";
};
```

A scrub reads every block in the pool and verifies its checksum. If corruption is detected, ZFS reconstructs the correct data from parity. This is essential for long-term data integrity.

### Auto-Snapshots (Sanoid)

Sanoid manages automatic ZFS snapshots with configurable retention:

```nix
services.sanoid = {
  enable = true;
  datasets = {
    "storage/eros" = {
      autosnap = true;
      hourly = 0;
      daily = 30;
      monthly = 3;
    };
    # Additional app datasets follow the same pattern
  };
};
```

Each app dataset gets:
- **Daily snapshots** with 30-day retention.
- **Monthly snapshots** with 3-month retention.
- **No hourly snapshots** — the server shuts down nightly, so hourly snapshots would be sparse and misleading.

Snapshots protect against accidental deletion and app-level corruption. They do **not** protect against drive failure (the snapshots live on the same drives). Off-site backup is acknowledged as a gap and deferred.

### Per-App Backup Hooks

Some apps need application-level consistency before a snapshot is useful. For example, SQLite in WAL mode may have uncommitted data in the WAL file that a raw ZFS snapshot wouldn't capture consistently.

Each app module can optionally define a backup hook — a systemd timer that runs before the sanoid snapshot. Timing is coordinated via explicit `OnCalendar` times to ensure backup hooks complete before snapshots are taken:

- **Backup hooks:** run at **12:00** (noon)
- **Sanoid snapshots:** run at **13:00** (1pm, the default sanoid timer or configured explicitly)

This gives backup hooks an hour to complete before snapshots capture the result.

```nix
# Example: Eros backup hook (in apps/eros.nix)
systemd.services.eros-backup = {
  description = "Eros SQLite safe backup";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.sqlite}/bin/sqlite3 /mnt/storage/eros/data/db/eros.sqlite \".backup '/mnt/storage/backups/eros/eros-$(date +%%Y-%%m-%%d).sqlite'\"";
  };
};

systemd.timers.eros-backup = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-*-* 12:00:00";
    Persistent = true;  # Run on next boot if missed (server was off)
  };
};
```

Backup artifacts go to `storage/backups/<app>/` with 30-day retention (old backups cleaned by a separate cleanup timer).

## Open Questions

- **ARC memory sizing.** ZFS ARC (read cache) defaults to using up to half of system RAM. Need to check how much RAM the machine has. If <16GB, may need to set `boot.kernelParams = [ "zfs.zfs_arc_max=<bytes>" ]` to leave room for Docker.
- **Disk IDs for disko config.** The `/dev/disk/by-id/` paths for the NVMe and all 4 WD Red drives must be discovered before the first install. Boot the NixOS USB, SSH in, and run `ls /dev/disk/by-id/` to find them. The existing Ansible config has the WD Red IDs but they should be re-verified. These go into `disk.nix`.
