# LoungeBox v2 — NixOS Migration

## Problem

LoungeBox is a custom-built NAS that runs Eros (a couples scavenger hunt app) and serves as a home server. It's currently provisioned with Ubuntu Server 24.04 LTS + Ansible. While this works, it has fundamental reproducibility gaps: Ansible manages desired state on top of a mutable OS, so drift is possible, idempotency is fragile (e.g. ZFS pool creation), and there's no guarantee two runs produce the same system. The deployment model for Eros was built as a quick first solution and doesn't scale to multiple self-hosted apps.

The server needs to become a proper self-hosting platform — fully declarative, reproducible from a single git repo, with a clean pattern for adding Docker-based apps.

## Goals

- **Fully declarative server.** The entire system — OS, services, apps, networking, storage — is defined in a single NixOS flake. `nixos-rebuild switch` produces a known-good state every time.
- **Reproducible from scratch.** If the NVMe dies, a fresh NixOS install + the git repo restores the full system (including secrets via sops-nix).
- **Clean app pattern.** Adding a new Docker app means adding a Nix module that declares its compose stack, Caddy route, ZFS dataset, secrets, and backup hooks. No ad-hoc deploy scripts.
- **Container dashboard.** A web UI (Dockge) for monitoring containers, viewing logs, and start/stop control — but app definitions live in Nix, not the UI.
- **On-demand gaming.** Steam on the TV via a manually-activated systemd service. No GPU or display resources consumed when idle.
- **Energy conscious.** Nightly auto-shutdown. Gaming only when explicitly started.

## Non-Goals

- **Monitoring stack (Grafana/Prometheus).** Deferred to a later iteration.
- **Off-site backups.** Acknowledged as a gap. ZFS snapshots and local backups only for now.
- **Public internet exposure.** All apps are LAN + Tailscale only. No port forwarding, no public DNS pointing to a public IP.
- **Media server (Plex/Jellyfin).** Not planned yet.
- **NAS file sharing (SMB/NFS).** Not needed yet.

## Overview

LoungeBox v2 replaces Ubuntu + Ansible with a NixOS flake that declares the entire system. The NVMe boot drive runs NixOS on ZFS (enabling system rollback via snapshots). The 4x WD Red drives form a ZFS RAIDZ1 pool for app data and backups, with each app getting its own dataset. Docker runs app stacks defined as docker-compose files in the Nix config. Caddy (with Cloudflare DNS plugin) reverse-proxies all apps with real TLS certificates on local subdomains. Tailscale provides remote access. Secrets are encrypted in the git repo via sops-nix. A deploy script on the developer's laptop wraps SSH + git pull + nixos-rebuild for easy updates.

## Repository Structure

```
loungebox/
  flake.nix              # Entry point — declares the NixOS system
  flake.lock             # Pinned nixpkgs + inputs
  deploy.sh              # Laptop-side script: SSH + git pull + nixos-rebuild
  secrets.yaml           # sops-encrypted secrets (committed to git)
  .sops.yaml             # sops config (which keys can decrypt which files)
  hosts/
    loungebox/
      default.nix        # Host-level config (imports modules)
      hardware.nix       # Hardware-specific config (generated during install)
      disk.nix           # disko config — NVMe partitions, ZFS pools, all datasets
  modules/
    base.nix             # System packages, locale, timezone, SSH, nightly shutdown
    zfs.nix              # ZFS storage pool, datasets, scrub schedule
    docker.nix           # Docker daemon config, log rotation
    caddy.nix            # Caddy reverse proxy with Cloudflare DNS plugin
    networking.nix       # Firewall rules, Tailscale
    backups.nix          # Sanoid snapshot policy, per-app backup hooks
    gaming.nix           # On-demand Steam + gamescope, NVIDIA drivers
    dockge.nix           # Dockge container dashboard
  apps/
    eros.nix             # Eros app: compose stack, Caddy route, ZFS dataset, backup hook
```

The `modules/` directory contains infrastructure concerns. The `apps/` directory contains per-app definitions. Adding a new app means creating a new file in `apps/` and importing it.

## Technical Approach

- **OS:** NixOS (latest stable release), Flakes
- **Configuration:** Single flake in a git repo, applied via `nixos-rebuild switch`
- **Installation:** disko (declarative disk partitioning) + nixos-anywhere (remote installer from macOS)
- **Boot drive:** NVMe with ZFS root (`rpool`)
- **Storage:** ZFS RAIDZ1 on 4x WD Red drives (`storage` pool), `ashift=12`, LZ4 compression, `atime=off`
- **Containers:** Docker + Docker Compose, stacks declared in Nix modules
- **Reverse proxy:** Caddy (custom Docker image with Cloudflare DNS plugin)
- **TLS:** Real Let's Encrypt certs via Cloudflare DNS challenge, served on LAN subdomains
- **DNS:** Cloudflare (public, points to Tailscale IP) + NextDNS (local override to LAN IP)
- **Secrets:** sops-nix with age encryption, encrypted secrets committed to git
- **Backups:** ZFS auto-snapshots via sanoid (daily, 30-day retention) + per-app backup hooks
- **VPN:** Tailscale for remote access
- **Firewall:** NixOS built-in (nftables), LAN + Tailscale only
- **Gaming:** On-demand systemd service — gamescope + Steam + NVIDIA proprietary drivers
- **Container dashboard:** Dockge (web UI for monitoring, logs, start/stop)
- **Deploy:** Shell script wrapping SSH + git pull + nixos-rebuild

## Detailed Design

Split into focused documents:

- **[ZFS & Storage](zfs.md)** — Boot drive ZFS root, storage pool, datasets, scrubs, snapshots, sanoid config
- **[Networking](networking.md)** — Firewall, Tailscale, Caddy reverse proxy, DNS, TLS certificates
- **[Apps & Docker](apps.md)** — Docker setup, app pattern, Eros migration, Dockge dashboard
- **[Secrets](secrets.md)** — sops-nix setup, age keys, editing workflow, initial bootstrapping
- **[Gaming](gaming.md)** — NVIDIA drivers, Steam, gamescope, on-demand systemd service
- **[Deployment](deployment.md)** — NixOS installation, deploy script, VM testing, base system config

## Open Questions

1. **RAM amount.** Affects ZFS ARC cache sizing. Check on the machine — if less than 16GB, may need to cap ARC to leave room for Docker containers.
2. **Dockge read-only mode.** Dockge is designed to manage stacks, not just view them. Need to verify whether it can be configured in a monitoring-only mode, or if editing features should just be ignored by convention.
3. **Gaming DRM/session setup.** Gamescope in DRM mode with NVIDIA, audio routing, and controller input needs hardware testing. This is the highest-risk area of the spec. See [gaming.md](gaming.md) for details.
4. **Eros deploy script changes.** The Eros repo's `deploy.sh` needs updating to match the new model (SCP builds + restart service). This is a change in the Eros repo, not this one.

## Milestones

### v0.1 — Bootable NixOS with ZFS
- Flake structure with `hosts/loungebox/` and base modules.
- disko config (`disk.nix`) declaring NVMe partitions, ZFS root pool, and storage pool.
- Base system config: hostname, locale, timezone, SSH, `lounge` user.
- **Test in a VM first** — use `nixos-rebuild build-vm --flake .#loungebox` to verify the config builds and boots (VM can't test real ZFS hardware, but catches Nix syntax and module errors).
- **Install on hardware** — boot NixOS USB, run `nixos-anywhere` from Mac. One command creates everything.

### v0.2 — Networking + Secrets
- **Pre-requisite:** Set up developer age key on laptop (`age-keygen`, save to Bitwarden).
- Tailscale enabled and authenticated.
- NixOS firewall configured (LAN + Tailscale only).
- sops-nix set up with initial secrets (bootstrap sequence in [secrets.md](secrets.md)).
- Deploy script working from laptop.

### v0.3 — Docker + Caddy + App Pattern
- Docker enabled.
- Caddy running with Cloudflare DNS plugin.
- App pattern established (the module structure for `apps/`).
- Dockge deployed as the first test of the pattern.

### v0.4 — Eros Migration
- Eros app defined in `apps/eros.nix` following the app pattern.
- ZFS dataset, compose stack, Caddy route, secrets all wired up.
- **Data migration:** Copy Eros SQLite DB and uploaded files from the old Ubuntu system to `/mnt/storage/eros/data/`.
- Eros deploy script in Eros repo updated for the new model (SCP builds + restart service).
- Run Eros deploy script once to load the backend Docker image.
- Backup hook (SQLite safe backup) + sanoid snapshots working.
- Verify Eros is fully functional end-to-end.

### v0.5 — Gaming
- NVIDIA drivers configured.
- Steam installed.
- gamescope + gaming systemd service.
- Verify: `systemctl start gaming` shows Steam on TV, `systemctl stop gaming` returns to headless.

### v1.0 — Complete Migration
- Nightly shutdown timer.
- All features verified on real hardware.
- Old `ubuntu/` and `ansible/` directories deleted.
- README updated.
- The system is fully described by the flake — a fresh install + this repo recreates everything.
