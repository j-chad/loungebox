# Deployment

Part of [LoungeBox v2 spec](spec.md).

## NixOS Installation

Fresh install on the NVMe, with ZFS root. The WD Red storage pool is also created during installation.

### Prerequisites

- NixOS minimal ISO on a USB stick (latest stable release).
- Physical access to the NAS (keyboard + monitor/TV for installation).
- SSH public key for the `lounge` user.

### Installation Steps

1. **Boot from USB** — NixOS minimal ISO.
2. **Network** — Connect to LAN (DHCP or set a static IP).
3. **Partition the NVMe:**
   ```bash
   # Identify the NVMe device
   ls /dev/disk/by-id/nvme-*

   # Create GPT partition table
   parted /dev/disk/by-id/<nvme> -- mklabel gpt
   
   # EFI system partition (512MB)
   parted /dev/disk/by-id/<nvme> -- mkpart ESP fat32 1MiB 513MiB
   parted /dev/disk/by-id/<nvme> -- set 1 esp on
   mkfs.fat -F 32 /dev/disk/by-id/<nvme>-part1
   
   # ZFS partition (remainder)
   # (ZFS pool creation handles formatting)
   ```
4. **Create ZFS boot pool (`rpool`):**
   ```bash
   zpool create -f \
     -o ashift=12 \
     -O mountpoint=none \
     -O compression=lz4 \
     -O atime=off \
     -O xattr=sa \
     -O acltype=posixacl \
     rpool /dev/disk/by-id/<nvme>-part2
   
   zfs create -o mountpoint=legacy rpool/root
   zfs create -o mountpoint=legacy rpool/nix
   zfs create -o mountpoint=legacy rpool/home
   
   # Take blank snapshot for potential "erase your darlings" later
   zfs snapshot rpool/root@blank
   ```
5. **Create ZFS storage pool:**
   ```bash
   zpool create -f \
     -o ashift=12 \
     -O compression=lz4 \
     -O atime=off \
     -O xattr=sa \
     -O acltype=posixacl \
     -m /mnt/storage \
     storage raidz \
     /dev/disk/by-id/ata-WDC_WD40EFZX-<id1> \
     /dev/disk/by-id/ata-WDC_WD40EFZX-<id2> \
     /dev/disk/by-id/ata-WDC_WD40EFZX-<id3> \
     /dev/disk/by-id/ata-WDC_WD40EFZX-<id4>
   ```
6. **Mount filesystems for installation:**
   ```bash
   mount -t zfs rpool/root /mnt
   mkdir -p /mnt/nix /mnt/home /mnt/boot
   mount -t zfs rpool/nix /mnt/nix
   mount -t zfs rpool/home /mnt/home
   mount /dev/disk/by-id/<nvme>-part1 /mnt/boot
   
   # Import storage pool at the right mount point
   zpool export storage
   zpool import -R /mnt storage
   ```
7. **Generate initial NixOS config:**
   ```bash
   nixos-generate-config --root /mnt
   ```
   This creates `/mnt/etc/nixos/configuration.nix` and `hardware-configuration.nix`. The hardware config captures the ZFS pool and disk layout.
8. **Edit minimal config** — Enable SSH, create `lounge` user with SSH key, set hostname. Just enough to boot and connect remotely.
9. **Install:**
   ```bash
   nixos-install
   ```
10. **Reboot** into the new NixOS installation.
11. **Clone this repo** onto the machine:
    ```bash
    git clone <repo-url> ~/loungebox
    ```
12. **Apply the full config:**
    ```bash
    cd ~/loungebox
    sudo nixos-rebuild switch --flake .#loungebox
    ```

After step 12, the system is fully configured. All subsequent changes go through the normal deploy workflow.

### Post-Installation

- **Tailscale:** Run `sudo tailscale up` to authenticate (interactive, one-time).
- **sops-nix bootstrap:** Follow the sequence in [secrets.md](secrets.md#initial-bootstrap).
- **Verify** ZFS pools are mounted, Docker is running, Caddy is serving.

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
