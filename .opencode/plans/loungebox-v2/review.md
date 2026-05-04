# LoungeBox v2 Spec — Architecture Review

Reviewed against: `spec.md`, `zfs.md`, `networking.md`, `apps.md`, `secrets.md`, `gaming.md`, `deployment.md`

## 1. Cross-File Consistency

The seven files are **well-aligned overall** — clearly written together with a shared mental model. These are the mismatches and ambiguities I found:

### Caddy data paths — contradicted between networking.md and apps.md

- **networking.md:94-99** puts Caddy's TLS cert storage under `/mnt/storage/caddy/data` and `/mnt/storage/caddy/config`, explicitly noting Caddy is "infrastructure, not an app."
- **apps.md:93-94** puts Caddy directories under `/mnt/storage/eros/caddy/` and `/mnt/storage/eros/caddy-config/` inside the Eros directory structure.

These can't both be right. Since Caddy is shared infrastructure (networking.md's model), its cert storage should be at `/mnt/storage/caddy/`, not nested under any app. The Eros directory structure in apps.md needs to drop the `caddy/` and `caddy-config/` entries — they're remnants of the old single-app model where Eros ran its own Caddy sidecar.

### ZFS dataset for Caddy — undeclared

networking.md says Caddy data lives under `/mnt/storage/caddy/` but no ZFS dataset `storage/caddy` appears in zfs.md's dataset table (zfs.md:92-97). Either Caddy's data goes into a dedicated dataset (consistent with the "per-app dataset" philosophy) or it goes directly under the storage pool root. The spec should pick one and declare it. A dedicated dataset makes sense — Caddy certs are small but distinct from app data and shouldn't be snapshotted on the same schedule.

### Caddyfile assembly mechanism — described but never specified

networking.md:63 says "The Caddyfile is assembled by Nix from all app modules. Each app contributes a site block." apps.md:38 says each app declares a "Caddy route" as a "Site block contributed to the shared Caddyfile." But **neither file shows how this assembly works in Nix.** This is the most architecturally interesting part of the app pattern and it's hand-waved. Options include:

1. A `caddy.nix` module that defines a NixOS option (e.g. `services.loungebox.caddy.sites`) which app modules populate, and the module uses `mkMerge` to assemble the final Caddyfile.
2. Each app module writes its own fragment, and `caddy.nix` concatenates them with `builtins.concatStringsSep`.
3. A simpler approach: one Caddyfile maintained manually in `caddy.nix`, updated when apps are added.

Option 1 is the cleanest (truly modular) but hardest for a NixOS beginner. Option 3 is simplest and fine for a two-app server. **This needs a decision and at least a sketch of the Nix implementation** — it's central to the "clean app pattern" goal.

### Backup hook timing — assumed but uncoordinated

zfs.md:148 says backup hooks run "daily before the sanoid snapshot window." But sanoid is configured with `daily` snapshots (zfs.md:129) and no specific time is set. Sanoid defaults to running snapshots when its timer fires, which is typically midnight or whenever systemd schedules it. The backup hook timer in zfs.md:160-166 is also just `OnCalendar = "daily"` with no specific time.

There's **no ordering guarantee** between the backup hook and sanoid. The backup hook might run after the snapshot, making the snapshot miss the backup artifact. Fix: either set explicit `OnCalendar` times (e.g. backup at 02:00, sanoid at 03:00) or make the backup hook a `Before=` dependency of the sanoid service.

### `storage` pool mountpoint — inconsistent creation style

zfs.md:64 uses `-m /mnt/storage` in `zpool create`, but deployment.md:61 also creates the storage pool and uses the same flag. These are consistent with each other but the dataset creation in deployment.md (step 4-5) **only creates the rpool datasets, not the storage datasets**. The spec is vague about when per-app datasets (`storage/eros`, `storage/backups`, `storage/dockge`) are created. zfs.md:90 says "created either during installation or by the app module (with an existence check)" — but no Nix code shows the existence check or the `zfs create` command. For a beginner, this needs to be explicit.

### `rpool` dataset mountpoints — missing `mountpoint=legacy`

deployment.md:46-48 correctly sets `mountpoint=legacy` on rpool datasets. But zfs.md's boot pool section (zfs.md:18-23) shows the datasets without mentioning `mountpoint=legacy`. This matters because NixOS with ZFS root requires `legacy` mountpoints managed by `/etc/fstab` (or `fileSystems` in Nix), not ZFS auto-mounting. A beginner following zfs.md alone would miss this. The deployment.md version is correct — zfs.md should match.

### Eros compose stack — image source unclear

apps.md:106 references `image: eros-backend:latest`, and apps.md:170-174 shows the image being built locally and loaded via `docker save | docker load`. But there's no mention of where or how the image is initially available on a fresh install. If restoring from scratch, the Eros image doesn't exist on the new machine. The systemd service will try to `docker compose up` and fail because `eros-backend:latest` isn't a registry image — it's locally loaded. The spec should note that the Eros deploy script must be run once after initial setup to load the image.

## 2. Gaps and Risks

### The Caddy Docker image rebuild trigger is unsolved

spec.md:93 lists this as an open question and it's a real problem. The spec proposes a systemd service that rebuilds the image "if the Dockerfile changes (tracked via content hash)" (networking.md:59) but shows no Nix code for this. Implementing content-hash-based rebuild detection in a systemd service is non-trivial. A simpler approach: always build the image during `nixos-rebuild switch` via an activation script, and tag it with a hash. If the hash matches the running container's image, no restart. This is still fiddly but more tractable.

**Practical suggestion for a beginner:** Skip the clever rebuild detection. Build the Caddy image once during installation, document the manual rebuild command, and add a comment in `caddy.nix` with the rebuild instructions. You'll upgrade Caddy once a year, not every deploy.

### No `fileSystems` declarations shown anywhere

NixOS with ZFS root requires explicit `fileSystems` entries for legacy-mounted datasets. The spec never shows these:

```nix
fileSystems."/" = { device = "rpool/root"; fsType = "zfs"; };
fileSystems."/nix" = { device = "rpool/nix"; fsType = "zfs"; };
fileSystems."/home" = { device = "rpool/home"; fsType = "zfs"; };
fileSystems."/boot" = { device = "/dev/disk/by-id/<nvme>-part1"; fsType = "vfat"; };
```

These would typically go in `hardware.nix` (or be generated by `nixos-generate-config`). The spec mentions `hardware.nix` is "generated during install" (spec.md:43) which should capture them — but it's worth explicitly noting that these entries are critical and the generated config must be verified, not blindly trusted. `nixos-generate-config` sometimes gets ZFS mounts wrong.

### No audio stack for gaming

gaming.md:119 flags audio as an open question, and it's a bigger gap than it looks. Gamescope on NixOS needs PipeWire (or PulseAudio) to route audio to the TV via HDMI. Without a sound server, Steam will have no audio. NixOS doesn't enable a sound server by default on a headless system. The gaming module needs:

```nix
# Required for gaming audio
services.pipewire = {
  enable = true;
  pulse.enable = true;  # PulseAudio compatibility (Steam uses PulseAudio)
  alsa.enable = true;
};
```

This should be part of the gaming module, not the base config, so the audio stack only exists because gaming exists.

### No `input` group for controller access

gaming.md:118 flags this as an open question but it's almost certainly required. Steam Input needs access to `/dev/input/*` devices. The `lounge` user needs to be in the `input` group:

```nix
users.users.lounge.extraGroups = [ "docker" "wheel" "input" ];
```

Without this, controllers won't work and the gaming experience breaks on first use. Don't leave this to "test on hardware" — just add the group.

### Nightly shutdown vs. long-running tasks

The 23:00 shutdown (deployment.md:153-167) will kill everything — Docker containers, active gaming sessions, ZFS scrubs mid-progress, `nixos-rebuild` if it happens to be running. The spec acknowledges gaming (gaming.md:106-113) but doesn't mention what happens to a ZFS scrub interrupted by shutdown. ZFS handles interrupted scrubs gracefully (it resumes next time), so this is fine — but it's worth a one-line note. More critically, what if the nightly shutdown fires during a `nixos-rebuild switch`? That could leave the system in a partially-activated state. Low probability, but a `ExecCondition` check or inhibitor lock would be defensive.

### Docker Compose file writing — no mechanism shown

apps.md:37 and apps.md:101 say the `docker-compose.yml` is "written by Nix" to the ZFS dataset. But no Nix code shows how. The likely approach is an activation script or `environment.etc` entry, but neither is shown. For a beginner, this is a critical gap — the entire app pattern depends on it. A sketch:

```nix
# Write compose file to ZFS dataset
environment.etc."loungebox/eros/docker-compose.yml" = {
  target = "/mnt/storage/eros/docker-compose.yml";  # Won't work — etc targets /etc/
  text = ''
    services:
      backend:
        ...
  '';
};
```

Actually, `environment.etc` writes to `/etc/`, not arbitrary paths. Writing to `/mnt/storage/` requires a different approach — likely a systemd tmpfiles rule or an activation script:

```nix
system.activationScripts.eros-compose = ''
  mkdir -p /mnt/storage/eros
  cat > /mnt/storage/eros/docker-compose.yml <<'EOF'
  ...
  EOF
'';
```

This is a NixOS-specific gotcha that the spec should address explicitly. It's not hard, but a beginner won't know which mechanism to use.

### `.env` file with secrets — security trade-off undocumented

apps.md:89 and secrets.md:15 say app compose stacks access secrets via `.env` files written by Nix. But sops-nix decrypts secrets to `/run/secrets/` (tmpfs, never on disk), while writing them into a `.env` file on a ZFS dataset **puts them on disk in plaintext**. This defeats some of sops-nix's security model. For a personal server this is acceptable, but the spec should acknowledge the trade-off and consider:

1. Setting restrictive permissions on the `.env` file (e.g. `chmod 600`, owned by root).
2. Using Docker secrets or bind-mounting individual secret files from `/run/secrets/` into containers instead of `.env`.

Option 2 is cleaner but more work. Option 1 is fine for a personal server.

### `system.autoUpgrade` with Flakes — needs `flake` option

deployment.md:148-151 enables `system.autoUpgrade` but doesn't set the `flake` option. Without it, NixOS doesn't know which flake to upgrade from. For a flake-based system:

```nix
system.autoUpgrade = {
  enable = true;
  flake = "/home/lounge/loungebox#loungebox";
  allowReboot = false;
};
```

Without the `flake` option, `system.autoUpgrade` will look for `/etc/nixos/configuration.nix`, which won't exist in a flake-based setup, and the auto-upgrade will silently fail or error. **This is a real bug in the spec.**

Also, `system.autoUpgrade` runs `nixos-rebuild switch`, which updates the running system. Combined with `allowReboot = false`, the kernel and kernel modules won't be updated until the next boot (the nightly shutdown handles this). But auto-upgrade also runs `nix flake update` or equivalent — is the intent to auto-update nixpkgs? That's risky for stability. If the intent is security patches only, NixOS doesn't natively distinguish security-only updates. Consider whether auto-upgrade is actually wanted, or if manual `flake.lock` updates via the deploy script are safer.

## 3. NixOS-Specific Concerns

### ZFS + NixOS boot — the `hostId` trap

zfs.md:44 correctly identifies that `networking.hostId` is required for ZFS. But it says to generate it with `head -c 8 /etc/machine-id`. This works but note: `/etc/machine-id` is generated during install. If you reinstall NixOS, a new machine-id is generated, which changes the hostId, which can make ZFS refuse to import pools (it checks hostId to prevent accidental imports on the wrong machine). **The hostId should be hardcoded in the Nix config** (which it appears to be — `networking.hostId = "<8-char-hex>"`), not dynamically generated. Just pick a value, commit it, and never change it. Good that the spec declares it in Nix; just make sure the value is set once and left alone.

### `services.xserver.videoDrivers` on a headless system

gaming.md:27 sets `services.xserver.videoDrivers = [ "nvidia" ]`. On NixOS, this option name is a legacy holdover — it configures GPU drivers regardless of whether X11 is actually used. However, setting this **may pull in X11 packages and services** depending on the NixOS version. On a headless server that only uses gamescope (Wayland), you want NVIDIA kernel modules without an X server. Verify that enabling this doesn't start an X display manager. It shouldn't if `services.xserver.enable` is not set, but this is a common NixOS confusion point. The safer approach:

```nix
hardware.nvidia = {
  modesetting.enable = true;
  open = false;
};
# Only set videoDrivers, don't enable xserver
services.xserver.videoDrivers = [ "nvidia" ];
# Explicitly ensure no display manager starts
services.xserver.enable = false;  # Or simply don't set it — false is default
```

### Gamescope without a display server — will it work?

gaming.md:67 runs `gamescope -e -f -- steam -bigpicture` via a systemd service with `DISPLAY=:0` set. But there's no X server providing `:0`. Gamescope on NixOS can run as a standalone Wayland compositor without X, but then `DISPLAY=:0` is wrong — gamescope would create its own `WAYLAND_DISPLAY`. This is a significant configuration gap. The service needs either:

1. **Gamescope in DRM/KMS mode** (no X, no Wayland parent) — this requires running as root or with CAP_SYS_ADMIN, and uses `--backend drm` or similar flags depending on gamescope version. Remove `DISPLAY=:0`.
2. **A minimal X session** that gamescope runs inside — but this conflicts with the "headless by default" goal.

Option 1 is the right approach for this use case but it's not straightforward. The service would look more like:

```nix
serviceConfig = {
  Type = "simple";
  User = "root";  # Or use a wrapper with appropriate capabilities
  TTYPath = "/dev/tty7";
  Environment = [
    "WLR_BACKENDS=drm"
    "XDG_RUNTIME_DIR=/run/user/1000"
  ];
  ExecStart = "${pkgs.gamescope}/bin/gamescope --backend drm -e -f -- steam -bigpicture";
};
```

This needs research and hardware testing. The current spec's approach (setting `DISPLAY=:0` with no X server) **will not work as written.**

### `pkgs` not in scope in several snippets

Multiple Nix snippets reference `pkgs` (e.g., `${pkgs.docker}/bin/docker compose` in apps.md:57, `${pkgs.sqlite}/bin/sqlite3` in zfs.md:156, `${pkgs.gamescope}/bin/gamescope` in gaming.md:67) but don't show the module function signature that brings `pkgs` into scope. For a NixOS module, this requires the standard preamble:

```nix
{ pkgs, config, ... }:
{
  # ... module body
}
```

This is obvious to NixOS users but not to a beginner. Each module file should start with this. Minor but worth noting.

### Docker compose path — `pkgs.docker` may not include compose

apps.md:57 uses `${pkgs.docker}/bin/docker compose`. On NixOS, `docker compose` (the plugin, v2) is a separate package from `docker`. The virtualisation.docker module installs the Docker daemon, but the `docker compose` subcommand requires the compose plugin. NixOS's `virtualisation.docker` should include it, but verify — or explicitly add `docker-compose` to system packages. If `docker compose` isn't available, every app's systemd service will fail to start.

## 4. Complexity Assessment — Feasibility for a NixOS Beginner

### What's appropriately scoped

- **ZFS root on NVMe** — well-documented in the NixOS community. Many guides exist. The spec's approach is standard.
- **Docker via `virtualisation.docker`** — straightforward, one line to enable.
- **sops-nix** — well-documented, the bootstrap sequence in secrets.md is accurate and thorough.
- **Tailscale** — trivial on NixOS, one line plus interactive auth.
- **Sanoid** — NixOS has a native module, the config shown is correct.
- **Basic firewall** — NixOS firewall module is simple and well-documented.

### What's harder than the spec suggests

1. **The Caddyfile assembly pattern** (networking.md + apps.md). Designing a NixOS module option system that lets app modules contribute Caddy site blocks is intermediate-level Nix. For a first NixOS project, start with a hardcoded Caddyfile and refactor to modular assembly later.

2. **Docker compose files written to ZFS** (apps.md). The mechanism for writing files to arbitrary paths (not `/etc/`) during activation is a NixOS-specific skill. Activation scripts work but are considered a rough edge. `systemd.tmpfiles.rules` is another option. Either way, a beginner will need to research this.

3. **Gamescope as a systemd service** (gaming.md). This is the hardest part of the entire spec. Getting gamescope to run on bare DRM without a display server, with correct NVIDIA driver integration, audio routing, and controller input — this is advanced Linux desktop knowledge. The spec significantly underestimates this. Expect multiple iterations and hardware-specific troubleshooting.

4. **The Caddy Docker image build** (networking.md). Building a custom Docker image as part of system activation is awkward. Docker builds need the Docker daemon running, so they can't happen in a Nix derivation (no network/daemon access during builds). They must happen in an activation script or systemd service, post-boot. This is a layering violation that NixOS beginners will find confusing.

### Recommended learning order

The milestones in spec.md are correctly sequenced for learning. One addition: **spend time in a VM before touching hardware.** The spec mentions VM testing (deployment.md:219-250) but it should be more emphatic — the very first milestone should be "build and boot the flake in a VM" before any physical installation. NixOS evaluation errors and missing module imports are much easier to debug in a VM where you can rebuild in seconds.

## 5. Milestone Ordering and Hidden Dependencies

### The milestone sequence is sound

v0.1 (ZFS boot) → v0.2 (networking + secrets) → v0.3 (Docker + Caddy + pattern) → v0.4 (Eros) → v0.5 (Gaming) → v1.0 (polish). Each milestone builds on the previous one. Good.

### Hidden dependencies within milestones

**v0.2 has an internal ordering constraint.** sops-nix setup (secrets.md bootstrap steps 1-6) requires the server to be installed and SSH-accessible first — which v0.1 provides. But the deploy script (deployment.md:171-185) uses `git pull`, which requires the repo to be cloned on the server — which happens in v0.1 step 11. These are correctly ordered. However, sops-nix bootstrap also requires the developer's age key to be set up, which is a laptop-side prerequisite not listed in v0.1. Add "set up developer age key on laptop" as a pre-v0.2 step.

**v0.3 depends on v0.2 being fully complete.** Caddy needs the `cloudflare_api_token` secret from sops-nix (v0.2) to provision TLS certs. If secrets aren't working, Caddy can't get certs. The spec implies this ordering but doesn't make the dependency explicit.

**v0.4 has an external dependency.** The Eros migration requires changes to the Eros repo's deploy script (apps.md:151-183, spec.md:121). This is called out but not included as a sub-task of the milestone. It should be — otherwise v0.4 will appear "done" in this repo but Eros won't actually deploy.

**v0.5 (Gaming) is correctly last** before v1.0 and correctly isolated. It has no dependencies on Docker, Caddy, or apps — only on base system + NVIDIA drivers. It could theoretically be done in parallel with v0.3/v0.4, but sequencing it last is wise because it's the hardest and least critical feature.

### Missing milestone: data migration

No milestone covers **migrating existing data from the Ubuntu system to the new NixOS system.** Eros has a SQLite database and uploaded files on the current machine. These need to be copied to `/mnt/storage/eros/data/` on the new system. The spec should include a data migration step in v0.4, even if it's just "scp the database and files directory."

## 6. Security

### Good decisions

- **SSH key-only auth, no root login** (deployment.md:130-136) — solid baseline.
- **sops-nix with age encryption** — secrets at rest are protected, the key derivation from SSH host key is elegant and avoids separate key management.
- **Developer key backed up in Bitwarden** (secrets.md:38) — good disaster recovery thinking.
- **LAN + Tailscale only, no public exposure** (spec.md:22, networking.md:7) — dramatically reduces attack surface.
- **Tailscale interface trusted but not wide open to the internet** (networking.md:15-16) — correct. Only Tailnet members can reach `tailscale0`.

### Concerns

**Secrets written to `.env` files on ZFS** — discussed in section 2. Plaintext secrets on disk. Acceptable for personal use, but document the trade-off.

**Docker socket mounted into Dockge** (apps.md:202) — the Docker socket gives full Docker API access, which is root-equivalent. Dockge can create privileged containers, mount the host filesystem, etc. This is inherent to any Docker management tool. For a personal server with no untrusted users, this is fine. But if Dockge has a vulnerability, it's a direct path to root. Keep Dockge behind Caddy with HTTPS and don't expose port 5001 directly.

**`docker` group for `lounge` user** (apps.md:22) — correctly acknowledged as root-equivalent. No action needed for single-user personal server.

**Cloudflare API token scope** — the spec doesn't mention what permissions the token needs. For Caddy DNS challenges, it only needs `Zone:DNS:Edit` on the specific zone. Don't use a global API key. This should be documented so the token is created with minimal permissions.

**Auto-upgrade without `flake` option** — discussed in section 2. If auto-upgrade is fixed and enabled, it will periodically run `nixos-rebuild switch`, which could introduce breaking changes from nixpkgs. For a home server you SSH into occasionally, surprise breakage from an auto-upgrade is more dangerous than running slightly behind on security patches. Consider disabling auto-upgrade entirely and doing manual updates via `nix flake update` + deploy when convenient.

### Not a concern (despite appearances)

**SSH on port 22 open on LAN** — fine. It's LAN + Tailscale only, key-auth only. No reason to change the port.

**No fail2ban** — unnecessary. Key-auth-only SSH can't be brute-forced. The server isn't public-facing.

## 7. Actionable Recommendations

| Priority | Item | Section |
|----------|------|---------|
| **Fix** | Set `system.autoUpgrade.flake` or disable auto-upgrade entirely. Current config will silently fail on a flake-based system. | deployment.md:148 |
| **Fix** | Resolve Caddy data path contradiction — remove `caddy/` and `caddy-config/` from the Eros directory structure, use `/mnt/storage/caddy/` as networking.md specifies. | apps.md:93 vs networking.md:94 |
| **Fix** | Remove `DISPLAY=:0` from gaming service and research gamescope DRM backend. The current config will not launch a display. | gaming.md:64 |
| **Fix** | Add PipeWire config to the gaming module for HDMI audio output. Without it, gaming has no sound. | gaming.md |
| **Fix** | Add `input` group to `lounge` user for controller access. | gaming.md:118 |
| **Fix** | Coordinate backup hook and sanoid timing. Set explicit `OnCalendar` times or use systemd ordering dependencies. | zfs.md:148-166 |
| **Specify** | Show the mechanism for writing `docker-compose.yml` and `.env` to `/mnt/storage/<app>/`. Activation scripts or tmpfiles — pick one and show the Nix code. | apps.md:37,101 |
| **Specify** | Show how the Caddyfile is assembled from app modules, or decide to start with a hardcoded Caddyfile and iterate. | networking.md:63, apps.md:38 |
| **Specify** | Declare a `storage/caddy` ZFS dataset in zfs.md, or note that Caddy data lives in the pool root. | networking.md:94, zfs.md:92 |
| **Specify** | Add `fileSystems` entries to the spec (even if `nixos-generate-config` will produce them — a beginner should know what to expect and verify). | deployment.md |
| **Specify** | Document how/when per-app ZFS datasets are created. Show the Nix code or the manual command and when to run it. | zfs.md:90-91 |
| **Add** | Data migration step in v0.4 — copying Eros SQLite DB and files from the Ubuntu system. | spec.md:119-124 |
| **Add** | Eros deploy script update as an explicit sub-task of v0.4 (it's in another repo, easy to forget). | spec.md:121 |
| **Add** | Note that initial Eros image must be loaded via the Eros deploy script before the systemd service will start on a fresh install. | apps.md:106 |
| **Add** | Document required Cloudflare API token permissions (Zone:DNS:Edit on the specific zone only). | secrets.md:170-174 |
| **Add** | Pre-v0.2 step: set up developer age key on laptop. | spec.md:107-110 |
| **Improve** | Acknowledge `.env` files on ZFS are plaintext secrets on disk; set `chmod 600` and root ownership. | secrets.md:15, apps.md:89 |
| **Improve** | Add `mountpoint=legacy` to zfs.md's boot dataset documentation to match deployment.md. | zfs.md:18-23 |
| **Improve** | Consider disabling `system.autoUpgrade` in favour of manual `nix flake update` + deploy. Auto-upgrades on a personal server risk surprise breakage. | deployment.md:148 |
| **Defer** | Caddy image rebuild trigger — don't automate this in v1. Build once, document the manual rebuild command. | spec.md:93 |
| **Defer** | "Erase your darlings" — correctly deferred. The `@blank` snapshot is free insurance. | zfs.md:25 |
