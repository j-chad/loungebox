# Deployment

Part of [LoungeBox v2 spec](spec.md).

## NixOS Installation

The installation is fully automated using **disko** (declarative disk partitioning) and **nixos-anywhere** (remote NixOS installer). One command from your Mac partitions all drives, creates ZFS pools and datasets, installs NixOS with the full flake config, and reboots into the finished system.

### disko — Declarative Disk Layout

Instead of manual `parted` and `zpool create` commands, the entire disk layout is declared in Nix (`hosts/loungebox/disk.nix`). disko handles partitioning, formatting, ZFS pool creation, and dataset creation during installation.

```nix
# hosts/loungebox/disk.nix
{ ... }:
{
  disko.devices = {
    disk = {
      nvme = {
        type = "disk";
        device = "/dev/disk/by-id/<nvme-disk-id>";
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
      # WD Red drives — identified by /dev/disk/by-id/ paths
      wd-red-1 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-<id1>";
        content = { type = "zfs"; pool = "storage"; };
      };
      wd-red-2 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-<id2>";
        content = { type = "zfs"; pool = "storage"; };
      };
      wd-red-3 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-<id3>";
        content = { type = "zfs"; pool = "storage"; };
      };
      wd-red-4 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-WDC_WD40EFZX-<id4>";
        content = { type = "zfs"; pool = "storage"; };
      };
    };
    zpool = {
      rpool = {
        type = "zpool";
        options = { ashift = "12"; };
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
      storage = {
        type = "zpool";
        mode = "raidz";
        options = { ashift = "12"; };
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
```

Key points:
- **`ashift=12`** on both pools — critical for 4KB sector drives. Cannot be changed after creation.
- **`mountpoint=legacy`** on rpool datasets — required for NixOS ZFS root (NixOS manages mounts via `fileSystems`).
- **RAIDZ1 mode** on the storage pool — one-drive fault tolerance across 4 drives.
- **All datasets declared** — disko creates them all in one pass during installation.
- **The `@blank` snapshot** is taken via `postCreateHook` for potential future "erase your darlings" pattern.

### nixos-anywhere — Remote Installation

nixos-anywhere runs from your Mac, SSHes into a NixOS live environment on the target machine, and handles everything:

#### Prerequisites

- **On the NAS:** Boot from a NixOS minimal USB stick. Connect to LAN. Note the IP address.
- **On your Mac:** Nix installed (`curl -L https://nixos.org/nix/install | sh`), or use the flake directly.
- **Disk IDs:** The `/dev/disk/by-id/` paths for the NVMe and all 4 WD Red drives must be known and set in `disk.nix`. To discover them, SSH into the live environment and run `ls /dev/disk/by-id/`.

#### Installation Command

```bash
# From your Mac:
nix run github:nix-community/nixos-anywhere -- \
  --flake .#loungebox \
  --build-on-remote \
  root@<nas-ip>
```

- **`--flake .#loungebox`** — uses the flake in the current directory, targeting the `loungebox` system config.
- **`--build-on-remote`** — builds the NixOS system on the target machine (avoids needing a Linux builder on macOS).
- **`root@<nas-ip>`** — SSHes into the NixOS live environment (root has no password in the live environment, SSH is enabled).

#### What Happens

1. nixos-anywhere SSHes into the live environment.
2. Runs disko — partitions the NVMe, creates both ZFS pools and all datasets.
3. Installs NixOS with the full flake config.
4. Reboots.
5. The machine comes up fully configured — SSH, Docker, Caddy, firewall, everything.

The entire process takes ~10-15 minutes.

#### Flake Inputs

disko and nixos-anywhere need to be declared in the flake:

```nix
# In flake.nix:
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  sops-nix.url = "github:Mic92/sops-nix";
  disko = {
    url = "github:nix-community/disko";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

nixos-anywhere is not a flake input — it's run directly from your Mac via `nix run`. Only disko needs to be in the flake (it provides the NixOS module that declares the disk layout).

### Post-Installation

After the machine reboots into NixOS:

1. **Verify SSH access:** `ssh lounge@<nas-ip>` (should work with your SSH key).
2. **Tailscale:** `sudo tailscale up` — interactive browser auth, one-time.
3. **sops-nix bootstrap:** Follow the sequence in [secrets.md](secrets.md#initial-bootstrap).
4. **Verify** ZFS pools are mounted (`zpool status`), Docker is running (`docker ps`), Caddy is serving.

### Re-Installation

If you ever need to reinstall from scratch:
1. Boot from NixOS USB.
2. Run the same `nixos-anywhere` command.
3. disko recreates everything. **This is destructive — all data on all drives is wiped.**
4. Restore data from backups after installation.

## Base System Config (modules/base.nix)

```nix
{
  networking.hostName = "loungebox";
  
  time.timeZone = "Pacific/Auckland";
  i18n.defaultLocale = "en_NZ.UTF-8";
  console.keyMap = "us";  # AU keyboard layout

  # User
  users.users.lounge = {
    isNormalUser = true;
    extraGroups = [ "docker" "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... jackson@laptop"
    ];
  };
  users.users.lounge.hashedPassword = "!";  # Disable password login

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # System packages
  environment.systemPackages = with pkgs; [
    git
    curl
    nano
    htop
    sqlite
  ];

  # Auto-upgrade is intentionally disabled. NixOS doesn't support security-only
  # updates — 'nix flake update' pulls everything. Auto-upgrades risk surprise
  # breakage on a server with no one around to fix it. Instead, update manually
  # via './deploy.sh update' when convenient, test in VM if worried, and roll
  # back with 'nixos-rebuild switch --rollback' if something breaks.

  # Nightly shutdown at 23:00
  systemd.timers.nightly-shutdown = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 23:00:00";
      Persistent = false;  # Don't run on boot if the time was missed
    };
  };
  systemd.services.nightly-shutdown = {
    description = "Nightly automatic shutdown";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/poweroff";
    };
  };
}
```

## Deploy Script (deploy.sh)

Lives at the repo root. Run from the developer's laptop to apply config changes:

```bash
#!/bin/bash
set -euo pipefail

HOST="loungebox"
REPO_PATH="/home/lounge/loungebox"
COMMAND="${1:-deploy}"

case "$COMMAND" in
  deploy)
    echo "Deploying to $HOST..."
    ssh "$HOST" "cd $REPO_PATH && git pull && sudo nixos-rebuild switch --flake .#loungebox"
    echo "Done."
    ;;
  update)
    echo "Updating nixpkgs and deploying to $HOST..."
    ssh "$HOST" "cd $REPO_PATH && git pull && nix flake update && sudo nixos-rebuild switch --flake .#loungebox"
    echo "Done. Remember to commit the updated flake.lock:"
    echo "  ssh $HOST 'cd $REPO_PATH && git add flake.lock && git commit -m \"update nixpkgs\"'"
    ;;
  rollback)
    echo "Rolling back $HOST to previous generation..."
    ssh "$HOST" "sudo nixos-rebuild switch --rollback"
    echo "Done."
    ;;
  *)
    echo "Usage: ./deploy.sh [deploy|update|rollback]"
    echo "  deploy   - Pull latest config and rebuild (default)"
    echo "  update   - Update nixpkgs, rebuild, and remind to commit flake.lock"
    echo "  rollback - Switch to the previous NixOS generation"
    exit 1
    ;;
esac
```

### Usage

```bash
# Normal deploy (apply config changes)
./deploy.sh

# Update nixpkgs + rebuild (do this weekly/bi-weekly for security patches)
./deploy.sh update

# Roll back if something broke
./deploy.sh rollback
```

### What `deploy` Does

1. SSH into the server.
2. Pull the latest config from git.
3. Run `nixos-rebuild switch` which:
   - Evaluates the flake.
   - Builds the new system configuration.
   - Activates it (restarts changed services, updates systemd units, etc.).
   - Adds a new generation to the boot menu (rollback via boot menu if something breaks).

### What `update` Does

1. Everything `deploy` does, plus:
2. Runs `nix flake update` first — updates `flake.lock` to the latest nixpkgs commit.
3. This is how security patches are applied. NixOS doesn't have a "security only" update mode — all nixpkgs changes come together.
4. If something breaks, run `./deploy.sh rollback`.

### When to Use

- **`deploy`** — After changing any Nix config file, updating `secrets.yaml`, or any other repo change.
- **`update`** — Weekly or bi-weekly for security patches. Test in VM first if concerned.
- **`rollback`** — If an update or deploy broke something.

### When NOT to Use

- For deploying Eros application code — use the Eros repo's deploy script instead.
- The deploy script is for *system configuration*, not *application deployment*.

## VM Testing

Before deploying to real hardware, test the NixOS config in a VM.

### What Can Be Tested in a VM

- Flake evaluation and build success.
- Base system config (hostname, locale, SSH, user).
- Docker installation and service startup.
- Caddy configuration (with mock certs).
- Systemd services and timers.
- sops-nix secret decryption.
- Module imports and Nix syntax correctness.

### What Cannot Be Tested in a VM

- ZFS on the actual WD Red drives (VMs can simulate ZFS but not with real hardware).
- NVIDIA GPU and gamescope (no GPU passthrough in typical VM setups).
- Actual network topology (Tailscale, LAN access, DNS resolution).
- Performance characteristics.

### Approach

NixOS flakes can build a VM directly:

```bash
# Build a VM from the flake (on a NixOS or Nix-enabled system)
nixos-rebuild build-vm --flake .#loungebox
```

This produces a QEMU VM image that boots the configured system. Use it to verify the config builds and services start correctly before touching real hardware.

Alternatively, test in a manually created VM (UTM on macOS, or VirtualBox) by following the installation steps with virtual disks.

## Repo Location on Server

The git repo lives at `/home/lounge/loungebox`. The deploy script pulls from this location and runs `nixos-rebuild switch --flake .#loungebox`.

NixOS traditionally puts its config at `/etc/nixos/`, but since we're using a flake with `--flake .#loungebox`, the config can live anywhere. Keeping it in the user's home directory is simpler (no root ownership issues for git operations).

## Rollback

If a deploy breaks something:

### Quick Rollback (NixOS Generations)
```bash
# SSH in (if still possible) and switch to the previous generation:
sudo nixos-rebuild switch --rollback

# Or reboot and select the previous generation from the boot menu
```

### ZFS Root Snapshot Rollback
If the system is unbootable:
1. Boot from the NixOS USB installer.
2. Import the boot pool: `zpool import rpool`
3. Roll back to a previous snapshot: `zfs rollback rpool/root@<snapshot>`
4. Reboot.

NixOS generations are the primary rollback mechanism. ZFS snapshots are a deeper safety net for more severe issues.
