# Host-level configuration for LoungeBox.
# Imports hardware config, disko disk layout, and all modules.
{ ... }:
{
  imports = [
    ./hardware.nix
    ./disk.nix
    ../../modules/base.nix
    ../../modules/zfs.nix
  ];

  # NixOS state version — set to the version used at first install.
  # Do NOT change this on an existing system. It does not control
  # which packages you get; it controls backwards-compatible defaults.
  system.stateVersion = "25.05";
}
