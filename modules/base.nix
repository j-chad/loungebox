# Base system configuration.
# Hostname, locale, timezone, SSH, user, system packages, nightly shutdown.
{ pkgs, ... }:
{
  # ── Identity ─────────────────────────────────────────────────────────
  networking.hostName = "loungebox";

  # ── Locale & Timezone ────────────────────────────────────────────────
  time.timeZone = "Pacific/Auckland";
  i18n.defaultLocale = "en_NZ.UTF-8";
  console.keyMap = "us";

  # ── User ─────────────────────────────────────────────────────────────
  users.users.lounge = {
    isNormalUser = true;
    extraGroups = [ "docker" "wheel" ];
    hashedPassword = "!"; # Disable password login — SSH key only
    openssh.authorizedKeys.keys = [
      # TODO: Replace with your actual SSH public key
      "ssh-ed25519 AAAA_REPLACE_ME jackson@laptop"
    ];
  };

  # ── SSH ──────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ── System Packages ──────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    git
    curl
    nano
    htop
    sqlite
  ];

  # ── Nix Settings ─────────────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ── Auto-Upgrade (disabled) ──────────────────────────────────────────
  # NixOS doesn't support security-only updates — `nix flake update` pulls
  # everything. Auto-upgrades risk surprise breakage on a server with no one
  # around to fix it. Instead, update manually via `./deploy.sh update` when
  # convenient, and roll back with `./deploy.sh rollback` if something breaks.

  # ── Nightly Shutdown ─────────────────────────────────────────────────
  systemd.timers.nightly-shutdown = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 23:00:00";
      Persistent = false; # Don't run on boot if the time was missed
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
