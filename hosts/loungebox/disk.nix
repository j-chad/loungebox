# Declarative disk layout for disko.
# Defines NVMe boot drive (ZFS root) and 4x WD Red RAIDZ1 storage pool.
#
# TODO: Replace all /dev/disk/by-id/ placeholders with actual disk IDs.
#       Boot the NixOS USB, SSH in, and run: ls /dev/disk/by-id/
{ ... }:
{
  disko.devices = {
    disk = {
      # ── NVMe boot drive ──────────────────────────────────────────────
      nvme = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-CHANGE_ME"; # TODO: actual NVMe disk ID
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };

      # ── WD Red storage drives (4x 4TB) ──────────────────────────────
      # TODO: Replace each device path with the actual /dev/disk/by-id/ path.
      wd-red-1 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-CHANGE_ME_1"; # TODO
        content = { type = "gpt"; partitions.zfs = { size = "100%"; content = { type = "zfs"; pool = "storage"; }; }; };
      };
      wd-red-2 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-CHANGE_ME_2"; # TODO
        content = { type = "gpt"; partitions.zfs = { size = "100%"; content = { type = "zfs"; pool = "storage"; }; }; };
      };
      wd-red-3 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-CHANGE_ME_3"; # TODO
        content = { type = "gpt"; partitions.zfs = { size = "100%"; content = { type = "zfs"; pool = "storage"; }; }; };
      };
      wd-red-4 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-CHANGE_ME_4"; # TODO
        content = { type = "gpt"; partitions.zfs = { size = "100%"; content = { type = "zfs"; pool = "storage"; }; }; };
      };
    };

    # ── ZFS pools ────────────────────────────────────────────────────────
    zpool = {
      # Boot pool on NVMe
      rpool = {
        type = "zpool";
        options = {
          ashift = "12";
        };
        rootFsOptions = {
          compression = "lz4";
          atime = "off";
          xattr = "sa";
          acltype = "posixacl";
          mountpoint = "none";
        };
        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options.mountpoint = "legacy";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.mountpoint = "legacy";
          };
          home = {
            type = "zfs_fs";
            mountpoint = "/home";
            options.mountpoint = "legacy";
          };
        };
        # Take blank snapshot after creation for potential "erase your darlings" later
        postCreateHook = "zfs snapshot rpool/root@blank";
      };

      # Storage pool on 4x WD Red (RAIDZ1)
      storage = {
        type = "zpool";
        mode = "raidz";
        options = {
          ashift = "12";
        };
        rootFsOptions = {
          compression = "lz4";
          atime = "off";
          xattr = "sa";
          acltype = "posixacl";
        };
        mountpoint = "/mnt/storage";
        datasets = {
          eros = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/eros";
          };
          backups = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/backups";
          };
          caddy = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/caddy";
          };
          dockge = {
            type = "zfs_fs";
            mountpoint = "/mnt/storage/dockge";
          };
        };
      };
    };
  };
}
