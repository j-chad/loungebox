# Hardware-specific configuration.
#
# On real hardware, nixos-generate-config produces this file automatically.
# For now this contains the known-required entries. After installation,
# replace this file with the generated version and verify these entries
# are present.
#
# TODO: After first install, run `nixos-generate-config` and merge the
#       output into this file (it adds detected kernel modules, etc.).
{ config, lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ── Bootloader ───────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Kernel ───────────────────────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # ── Filesystems ──────────────────────────────────────────────────────
  # disko manages these declaratively, but NixOS needs the fileSystems
  # entries for ZFS legacy mounts. disko generates these automatically
  # when its module is imported, so they don't need to be duplicated here.
  #
  # If for any reason they're missing after install, the expected entries are:
  #   fileSystems."/"     = { device = "rpool/root"; fsType = "zfs"; };
  #   fileSystems."/nix"  = { device = "rpool/nix";  fsType = "zfs"; };
  #   fileSystems."/home" = { device = "rpool/home"; fsType = "zfs"; };
  #   fileSystems."/boot" = { device = "/dev/disk/by-id/<nvme>-part1"; fsType = "vfat"; };
}
