# LoungeBox v2 Spec — Final Architecture Review

Previous review: [review.md](review.md)
Spec files reviewed: `spec.md`, `zfs.md`, `networking.md`, `apps.md`, `secrets.md`, `gaming.md`, `deployment.md`

---

## 1. Previous Review Findings — Status Check

Going through each item from the previous review's recommendation table (review.md, section 7).

### Fix Items

| # | Previous Finding | Status | Notes |
|---|-----------------|--------|-------|
| 1 | **`system.autoUpgrade.flake` missing or disable auto-upgrade** (deployment.md:148) | **Addressed.** | Auto-upgrade is now disabled entirely. deployment.md:246-250 has an explicit comment explaining why: NixOS doesn't support security-only updates, auto-upgrades risk surprise breakage, manual updates via `./deploy.sh update` are preferred. The deploy script includes an `update` command (deployment.md:289-292) and a `rollback` command (deployment.md:293-298). Good fix — disabling was the right call. |
| 2 | **Caddy data path contradiction** (apps.md:93 vs networking.md:94) | **Addressed.** | The Eros directory structure in apps.md:122-129 no longer contains `caddy/` or `caddy-config/` entries. Caddy's data lives at `/mnt/storage/caddy/` as defined in networking.md:96-103. apps.md:132 explicitly cross-references networking.md for Caddy's location. Clean fix. |
| 3 | **Remove `DISPLAY=:0` from gaming service, research gamescope DRM** | **Addressed.** | gaming.md:89-111 now uses `--backend drm`, sets `WLR_BACKENDS=drm`, removes `DISPLAY=:0`, adds `TTYPath=/dev/tty7` and `XDG_RUNTIME_DIR`. The service runs as user `lounge` with a note (gaming.md:122-127) that DRM device permissions may require elevation or udev rules. This is correctly flagged as needing hardware testing. Good fix. |
| 4 | **Add PipeWire config for HDMI audio** | **Addressed.** | gaming.md:63-76 now includes a full PipeWire config with PulseAudio and ALSA compatibility. Correctly placed in the gaming module, not the base config. Notes that HDMI audio device selection may need tuning on hardware. |
| 5 | **Add `input` group to `lounge` user** | **Addressed.** | gaming.md:80-83 adds `input` to `extraGroups`. |
| 6 | **Coordinate backup hook and sanoid timing** | **Addressed.** | zfs.md:152-158 now specifies explicit `OnCalendar` times: backup hooks at 12:00, sanoid snapshots at 13:00. One-hour buffer. Clear and simple. |

### Specify Items

| # | Previous Finding | Status | Notes |
|---|-----------------|--------|-------|
| 7 | **Show mechanism for writing `docker-compose.yml` and `.env` to `/mnt/storage/`** | **Addressed.** | apps.md:43-76 shows activation scripts with full Nix code. Includes `mkdir -p`, heredoc-based compose file writing, `.env` generation from sops-nix secrets, `chmod 600`, and `chown root:root`. The security note at apps.md:76 acknowledges the plaintext-on-disk trade-off. Thorough fix. |
| 8 | **Show Caddyfile assembly mechanism** | **Addressed.** | networking.md:67-83 now specifies a single hardcoded Caddyfile in `modules/caddy.nix`, explicitly choosing simplicity over modular assembly. The reasoning (networking.md:83) is sound: "For a small number of apps, this is easier to understand and debug." This is the right call for a NixOS beginner with 2-3 apps. |
| 9 | **Declare `storage/caddy` ZFS dataset** | **Addressed.** | zfs.md:93 now lists `storage/caddy` → `/mnt/storage/caddy` in the dataset table. deployment.md:117-119 declares it in the disko config. |
| 10 | **Add `fileSystems` entries** | **Addressed.** | zfs.md:25-33 now shows the `fileSystems` entries that should appear in `hardware.nix`, with a note (zfs.md:25) that `nixos-generate-config` creates them but they should be verified. |
| 11 | **Document per-app ZFS dataset creation** | **Addressed.** | zfs.md:87-102 explains the two-phase model: initial datasets in disko (created during installation), future datasets added to `disk.nix` but created manually with `zfs create` on the live system. Includes the manual command. Clear. |

### Add Items

| # | Previous Finding | Status | Notes |
|---|-----------------|--------|-------|
| 12 | **Data migration step in v0.4** | **Addressed.** | spec.md:119 now includes "Copy Eros SQLite DB and uploaded files from the old Ubuntu system to `/mnt/storage/eros/data/`" as an explicit sub-step of v0.4. |
| 13 | **Eros deploy script update as v0.4 sub-task** | **Addressed.** | spec.md:120 lists "Eros deploy script in Eros repo updated for the new model" and spec.md:121 adds "Run Eros deploy script once to load the backend Docker image." |
| 14 | **Note: initial Eros image must be loaded via deploy script on fresh install** | **Addressed.** | apps.md:165 adds a "Fresh install note" explaining that `eros-backend:latest` doesn't exist until the Eros deploy script is run once. |
| 15 | **Document Cloudflare API token permissions** | **Addressed.** | secrets.md:173 now specifies "Token needs `Zone:DNS:Edit` permission on the specific zone only. Do **not** use a global Cloudflare API key." |
| 16 | **Pre-v0.2 step: set up developer age key** | **Addressed.** | spec.md:104 adds "Pre-requisite: Set up developer age key on laptop (`age-keygen`, save to Bitwarden)" as the first step of v0.2. |

### Improve Items

| # | Previous Finding | Status | Notes |
|---|-----------------|--------|-------|
| 17 | **Acknowledge `.env` plaintext secrets; set chmod 600** | **Addressed.** | apps.md:70-71 shows `chmod 600` and `chown root:root`. apps.md:76 has a security note documenting the trade-off. |
| 18 | **Add `mountpoint=legacy` to zfs.md boot datasets** | **Addressed.** | zfs.md:18-24 now shows "Mountpoint Type" column with `legacy` for all rpool datasets. zfs.md:25 explains why legacy mounts are required. |
| 19 | **Consider disabling `system.autoUpgrade`** | **Addressed.** | Same as item #1 — auto-upgrade is now disabled with clear rationale. |

### Defer Items

| # | Previous Finding | Status | Notes |
|---|-----------------|--------|-------|
| 20 | **Caddy image rebuild trigger** | **Addressed.** | networking.md:59-63 now describes building the image once on initial setup with a manual rebuild command, explicitly deferring automation. The Dockerfile is written to `/tmp` by a Nix activation script. |
| 21 | **"Erase your darlings"** | **Unchanged (correctly).** | Still deferred per zfs.md:35 and deployment.md:94-95. The `@blank` snapshot is still taken. |

### Other Findings (from review.md sections 1-6, not in the table)

| Finding | Status | Notes |
|---------|--------|-------|
| **`pkgs` not in scope in snippets** (review.md §3) | **Partially addressed.** | gaming.md:25 now shows `{ pkgs, config, ... }:` at the module top. But apps.md:49 also shows it for eros. deployment.md and zfs.md snippets still don't show the module preamble, though this matters less — zfs.md's snippets are configuration blocks inside a module, not standalone modules. Acceptable. |
| **Docker compose path — `pkgs.docker` may not include compose** (review.md §3) | **Not explicitly addressed.** | apps.md:92 still uses `${pkgs.docker}/bin/docker compose`. NixOS's `virtualisation.docker` module should provide the compose plugin since Docker Compose v2 is bundled, but this is version-dependent. No harm in leaving it — it'll either work or fail loudly on first build. Low risk. |
| **`hostId` trap** (review.md §3) | **Addressed.** | zfs.md:57 now explicitly says "hardcode the value in the Nix config and never change it" and warns about reinstallation. |
| **`services.xserver.videoDrivers` on headless system** (review.md §3) | **Addressed.** | gaming.md:33-36 now includes `services.xserver.videoDrivers = [ "nvidia" ]` alongside `services.xserver.enable = false` with a comment explaining the legacy option name. |
| **Gamescope DRM mode details** (review.md §3) | **Addressed.** | Covered by item #3 above. |
| **Nightly shutdown vs long-running tasks** (review.md §2) | **Not addressed.** | No mention of `nixos-rebuild` interrupted by shutdown, or inhibitor locks. See new issues below. |
| **Docker socket in Dockge — security** (review.md §6) | **Unchanged.** | Still mounted. This is inherent to Dockge's design and acceptable for a personal server. No change needed. |

**Summary: 20 of 21 actionable items addressed. 1 partially addressed (module preamble). 2 minor items not addressed but acceptable.**

---

## 2. New Issues Found

### 2.1 Gaming service: `PAMName = "login"` may not be sufficient for DRM access (gaming.md:100)

The gaming service runs as `User = "lounge"` with `PAMName = "login"`. For gamescope's DRM backend, the user needs access to `/dev/dri/card*` devices. The spec acknowledges this (gaming.md:122-127, 169) as needing hardware testing, and lists three possible approaches (run as root, udev rules, or seatd).

This is appropriately flagged as an open question. However, the spec should note that the **most likely working approach** for a first attempt is adding the `lounge` user to the `video` group:
```nix
users.users.lounge.extraGroups = [ "docker" "wheel" "input" "video" ];
```
This is cheap to try and often sufficient. If it isn't, the escalation path (udev rules → seatd) is already documented. **Minor gap — the `video` group should be listed alongside `input` in the extraGroups declaration.** gaming.md:83 currently only shows `input` being added.

**Severity: Low.** Easy to add during implementation. The open question already covers the territory.

### 2.2 Caddy Docker image: Dockerfile written to `/tmp` (networking.md:62)

networking.md:62 says "The Nix activation script writes the Dockerfile to `/tmp/Dockerfile.caddy`." But `/tmp` is cleaned on reboot (NixOS uses `systemd-tmpfiles` which clears `/tmp`). This means:

1. On first boot after install, the activation script writes the Dockerfile and the manual build command works.
2. After a reboot, the Dockerfile is gone. Running the manual rebuild command will fail.
3. On subsequent `nixos-rebuild switch`, the activation script rewrites it — so it's available again after a rebuild.

This is fine in practice (you'd only rebuild Caddy during a nixos-rebuild session), but it's confusing if you reboot and then try to rebuild Caddy separately. A more durable location like `/etc/caddy/Dockerfile` (via `environment.etc`) would avoid the confusion. Or just note that the Dockerfile is ephemeral and a rebuild requires `nixos-rebuild switch` first.

**Severity: Very low.** Nit-pick on operational ergonomics.

### 2.3 Deploy script: `nix flake update` runs on the server (deployment.md:290)

The `update` command runs `nix flake update` on the server, which updates `flake.lock` on the server's copy of the repo. This means:
1. The server's `flake.lock` now differs from the laptop's repo (and from git origin).
2. The script reminds you to commit the updated `flake.lock` (deployment.md:291-292), but that commit happens on the server, not the laptop.
3. Next `git pull` from the laptop will need to pull that server-side commit.

This creates a slightly awkward git workflow where commits originate from two places (laptop and server). It works, but a cleaner model would be to run `nix flake update` on the laptop, commit there, push, then deploy. This way the laptop is always the source of truth.

**Severity: Low.** Operational preference, not a correctness issue. The current approach works — it's just worth being aware of the two-origin commit flow.

### 2.4 `rpool` datasets: no sanoid config for system snapshots

zfs.md:128-139 configures sanoid for `storage/eros` but not for any `rpool` datasets. The rpool has a `@blank` snapshot from installation (for erase-your-darlings) but no ongoing automatic snapshots.

This means if a `nixos-rebuild switch` breaks something in a way that NixOS generation rollback can't fix (e.g., corruption in `/home`, or state that lives outside the Nix store), there's no ZFS snapshot to fall back to. NixOS generations only roll back `/nix/store` content and symlinks — they don't roll back user data in `/home` or any other state.

For v1 this is fine — `/home` is mostly empty on a server, and the `@blank` snapshot plus NixOS generations cover most recovery scenarios. But it's worth a one-line note in zfs.md acknowledging the decision: "rpool snapshots are not configured in v1 because the system is declarative and `/home` holds minimal state. Add sanoid config for `rpool/home` later if needed."

**Severity: Low.** Correct for v1, just worth documenting the deliberate choice.

### 2.5 Dockge compose stack discovery (apps.md:241)

apps.md:241 says Dockge volumes include "Compose stack directories (`/mnt/storage/*/docker-compose.yml`) — so Dockge can discover stacks." But Dockge discovers stacks by pointing it at a **stacks directory**, not by globbing. The Dockge `DOCKGE_STACKS_DIR` environment variable tells it where to look for stack directories.

Since each app's compose file is at `/mnt/storage/<app>/docker-compose.yml`, Dockge's stacks directory should be `/mnt/storage/`. This works, but Dockge will also "discover" its own stack and the Caddy stack (if Caddy has a compose file there). The spec doesn't show the actual Dockge compose configuration — just a description.

**Severity: Very low.** Implementation detail that'll be sorted during v0.3. Not a spec issue per se.

### 2.6 Nightly shutdown: `Persistent = false` means missed shutdowns are skipped (deployment.md:257)

deployment.md:257 sets `Persistent = false` on the nightly shutdown timer, meaning if the server is off at 23:00, it won't shut down on next boot. This is clearly intentional (you wouldn't want the server to immediately shut down after being turned on the next day). Good.

However, if the server is turned on at, say, 22:58, it would shut down 2 minutes later. There's no "grace period after boot" logic. For a manually-started server (WoL or power button), being shut down almost immediately would be confusing. This is an edge case — the server presumably gets turned on in the evening and gaming sessions happen before 23:00 — but worth a one-line note.

**Severity: Very low.** Edge case, unlikely in practice given usage patterns.

---

## 3. Cross-File Consistency Check

After all the edits, checking for contradictions between files.

### 3.1 `lounge` user `extraGroups` — declared in multiple places

- deployment.md:222: `extraGroups = [ "docker" "wheel" ]`
- apps.md:22: `extraGroups = [ "docker" ]`
- gaming.md:83: `extraGroups = [ "docker" "wheel" "input" ]`

In practice, these are all **snippets showing context-relevant groups** in different modules, and NixOS's `mkMerge` / list merging would combine them. But it's confusing in a spec because it looks like three contradictory declarations. deployment.md:222 (base.nix) is the canonical one; gaming.md:83 shows the additional `input` group.

The real question: in actual Nix modules, will these merge or conflict? If `base.nix` sets `extraGroups = [ "docker" "wheel" ]` and `gaming.nix` sets `extraGroups = [ "docker" "wheel" "input" ]`, the latter **overwrites** the former — NixOS doesn't auto-merge list options by default. The correct approach is:

```nix
# In gaming.nix:
users.users.lounge.extraGroups = [ "input" ];  # Merged with base groups via mkMerge
```

But NixOS's `extraGroups` is actually a `mkOption` with `type = lib.types.listOf lib.types.str` and uses `mkMerge` implicitly — so both declarations would be concatenated, not overwritten. This is fine. But the spec snippets show full lists (with `docker` and `wheel` repeated), which will work but is redundant. Minor style point.

**Impact: None.** NixOS handles this correctly. But for spec clarity, gaming.nix's snippet could just show `extraGroups = [ "input" ]` with a comment that other groups come from base.nix.

### 3.2 Open questions — consistent and reduced

spec.md:91-92 lists 2 open questions (gaming DRM/session setup, disk IDs). gaming.md:166-173 lists 4 open questions (DRM permissions, display output, audio device, session management). zfs.md:182-183 lists 1 (disk IDs). These are all consistent — the gaming open questions are correctly detailed in gaming.md and summarized in spec.md. No contradictions.

The open question count has shrunk significantly from the original review — ARC memory sizing (zfs.md:187), GPU power management (gaming.md:175), and several others have been moved to "Resolved" sections. Good housekeeping.

### 3.3 Caddy compose stack — not fully specified

networking.md:87-92 describes Caddy's Docker setup (ports, volumes, restart policy) but doesn't show the actual `docker-compose.yml` for Caddy. apps.md shows the Eros compose stack in detail (apps.md:138-154) but Caddy's is only described in prose.

This is a minor omission. Since the Caddyfile is shown (networking.md:69-81) and the volume mounts are described, writing the compose file is straightforward. But for a spec that shows Eros's compose file in full, it's inconsistent to only describe Caddy's in prose.

**Impact: Low.** The information is there; the format is inconsistent.

### 3.4 Storage pool `mountpoint` — disko vs zfs.md

deployment.md:107 sets `mountpoint = "/mnt/storage"` on the storage zpool in disko. zfs.md doesn't show the pool-level mountpoint (it only shows dataset mountpoints). This is fine — disko is the source of truth (zfs.md:65-67 explicitly says so). No contradiction, just different levels of detail.

### 3.5 Milestones vs actual spec content — aligned

Verified that each milestone in spec.md references features that are fully specified in sub-documents:
- v0.1 (ZFS boot) → zfs.md, deployment.md ✓
- v0.2 (networking + secrets) → networking.md, secrets.md ✓
- v0.3 (Docker + Caddy + pattern) → apps.md, networking.md ✓
- v0.4 (Eros) → apps.md ✓
- v0.5 (Gaming) → gaming.md ✓
- v1.0 (polish) → deployment.md ✓

No orphaned milestones or features specified in sub-docs but missing from milestones.

---

## 4. Overall Assessment

**This spec is ready to build from.**

The previous review raised 21 actionable items. All material issues have been addressed. The fixes are clean — not band-aids, but genuine improvements to the spec. The most significant fixes were:

1. **Disabling auto-upgrade** (eliminates a real bug and a stability risk).
2. **Activation script mechanism for compose files** (fills the biggest implementation gap for a beginner).
3. **Choosing a hardcoded Caddyfile over modular assembly** (honest about complexity, right for the context).
4. **Gamescope DRM backend** (previous config was broken, now at least correct in approach).
5. **Backup hook timing** (explicit `OnCalendar` times, no race condition).

### Remaining Risks

1. **Gaming (v0.5) is still high-risk.** The spec correctly identifies this. Gamescope + DRM + NVIDIA + PipeWire + controller input is advanced territory with limited documentation for this exact stack. The spec can't eliminate this risk — it can only sequence it last (which it does) and flag it clearly (which it does). Budget extra time.

2. **NixOS learning curve.** The spec is well-structured for incremental learning (VM first, then base system, then layers of complexity). But the owner has zero NixOS experience. Expect v0.1 to take longer than the spec implies as fundamental Nix concepts are learned. This isn't a spec problem — it's inherent to the migration.

3. **Single point of failure: RAIDZ1.** The spec acknowledges no off-site backup (spec.md:21). RAIDZ1 tolerates one drive failure. Two simultaneous failures lose everything. For personal data on a home server, this is a reasonable risk acceptance. Just be aware.

### What the Spec Does Well

- **Honest about complexity.** Gaming is flagged as hard. Caddy assembly was simplified rather than over-engineered. Auto-upgrade was disabled rather than half-configured.
- **Clear separation of concerns.** Infrastructure (modules/) vs apps (apps/) is clean. Caddy is infrastructure, not per-app. Secrets flow is well-documented.
- **Correct milestone sequencing.** Each milestone builds on the previous one with no hidden circular dependencies.
- **Good disaster recovery thinking.** Secrets backed up in Bitwarden. NixOS generation rollback. ZFS snapshots. Multiple recovery layers.
- **Spec is self-consistent.** After the fixes, I found no material contradictions between files.

---

## 5. Final Recommendations

There are no blocking issues. These are all "nice to have before building" improvements, none required.

| Priority | Item | Where |
|----------|------|-------|
| **Nice to have** | Add `video` group to `lounge` user alongside `input` — likely needed for DRM access in gaming. | gaming.md:83 |
| **Nice to have** | Show Caddy's `docker-compose.yml` in full (like Eros's is shown) for spec completeness. | networking.md:87-92 |
| **Nice to have** | Note that gaming.nix should only add `input` (and `video`) to extraGroups, not repeat `docker`/`wheel` — Nix merges lists, but the snippets are misleading. | gaming.md:83 vs deployment.md:222 |
| **Nice to have** | One-line note in zfs.md that rpool automatic snapshots are deliberately omitted in v1. | zfs.md (after sanoid section) |
| **Nice to have** | Consider running `nix flake update` on the laptop instead of the server, to keep the laptop as the single source of commits. | deployment.md:289-292 |

**Verdict: Ship it. Start building v0.1.**
