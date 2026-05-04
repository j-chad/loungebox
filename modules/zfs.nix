# ZFS configuration.
# Boot filesystem support, storage pool import, scrub schedule.
{ ... }:
{
  # ── ZFS Boot Support ─────────────────────────────────────────────────
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev/disk/by-id";

  # Required by ZFS — unique per machine. Prevents accidental pool imports
  # on the wrong machine. Generate with: head -c 8 /etc/machine-id
  # TODO: Replace with actual hostId from the installed machine.
  #       After first boot, run: head -c 8 /etc/machine-id
  #       Then hardcode that value here and NEVER change it.
  networking.hostId = "deadbeef"; # TODO: replace after first install

  # ── Storage Pool Import ──────────────────────────────────────────────
  # Import the RAIDZ1 storage pool at boot.
  boot.zfs.extraPools = [ "storage" ];

  # ── Scrub Schedule ───────────────────────────────────────────────────
  # Monthly scrub detects and repairs data corruption using RAIDZ1 parity.
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };

  # ── Auto-Trim ────────────────────────────────────────────────────────
  # Enable periodic TRIM for the NVMe boot pool (SSDs benefit from TRIM).
  services.zfs.trim.enable = true;
}
