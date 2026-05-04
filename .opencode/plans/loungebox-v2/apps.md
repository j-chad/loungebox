# Apps & Docker

Part of [LoungeBox v2 spec](spec.md).

## Docker Configuration (modules/docker.nix)

```nix
virtualisation.docker = {
  enable = true;
  autoPrune = {
    enable = true;
    dates = "weekly";
  };
  daemon.settings = {
    log-driver = "json-file";
    log-opts = {
      max-size = "10m";
      max-file = "3";
    };
  };
};
users.users.lounge.extraGroups = [ "docker" ];
```

- **Auto-prune** removes unused images, containers, and volumes weekly. Prevents disk creep.
- **Log rotation** caps container logs at 10MB × 3 files per container.
- **`lounge` user** is in the `docker` group for convenience. Note: docker group = root-equivalent access. Acceptable for a single-user personal server.

## App Pattern

Every Docker-based app follows the same structure. An app module in `apps/<app>.nix` declares:

| Concern | What It Declares | Example (Eros) |
|---------|-----------------|----------------|
| **ZFS dataset** | `storage/<app>` dataset | `storage/eros` → `/mnt/storage/eros` |
| **Directories** | App-specific directory tree | `data/db/`, `data/files/`, `admin-build/`, `client-build/` |
| **Compose stack** | `docker-compose.yml` written to `/mnt/storage/<app>/` | Go backend + Caddy containers |
| **Caddy route** | Site block contributed to the shared Caddyfile | `eros.yourdomain.com → localhost:8080` |
| **Secrets** | References to sops-nix secrets | `eros_admin_api_key` |
| **Backup hook** | Optional systemd timer for app-specific backup | SQLite safe backup before ZFS snapshot |
| **Systemd service** | Manages `docker compose up/down` lifecycle | `eros.service` |

### How Files Get Written to `/mnt/storage/`

NixOS's `environment.etc` only writes to `/etc/`. To write files to arbitrary paths (like `/mnt/storage/<app>/docker-compose.yml`), use activation scripts:

```nix
# In apps/eros.nix:
{ pkgs, config, ... }:
{
  system.activationScripts.eros-compose = ''
    mkdir -p /mnt/storage/eros/data/db /mnt/storage/eros/data/files
    mkdir -p /mnt/storage/eros/admin-build /mnt/storage/eros/client-build

    cat > /mnt/storage/eros/docker-compose.yml <<'COMPOSE'
    services:
      backend:
        image: eros-backend:latest
        ...
    COMPOSE

    # Write .env with secrets from sops-nix
    # Secrets are decrypted to /run/secrets/ by sops-nix
    cat > /mnt/storage/eros/.env <<EOF
    ADMIN_API_KEY=$(cat /run/secrets/eros_admin_api_key)
    APP_ENV=production
    LOG_LEVEL=INFO
    LOG_JSON=true
    EOF
    chmod 600 /mnt/storage/eros/.env
    chown root:root /mnt/storage/eros/.env
  '';
}
```

**Security note:** The `.env` file contains plaintext secrets on the ZFS dataset. This partially defeats sops-nix's tmpfs model (where secrets only exist in RAM). For a personal server this is acceptable, but the file is `chmod 600` and root-owned to limit access. An alternative is bind-mounting individual secret files from `/run/secrets/` into containers, but that's more complex.

### How the Systemd Service Works

Each app gets a systemd service that manages its Docker Compose stack:

```nix
systemd.services.<app> = {
  description = "<App> Docker Compose stack";
  after = [ "docker.service" ];
  requires = [ "docker.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    WorkingDirectory = "/mnt/storage/<app>";
    ExecStart = "${pkgs.docker}/bin/docker compose up -d";
    ExecStop = "${pkgs.docker}/bin/docker compose down";
  };
};
```

- **Starts on boot** (`wantedBy = multi-user.target`).
- **Depends on Docker** being ready.
- **`RemainAfterExit`** — the service stays "active" after `docker compose up -d` returns, so `systemctl stop <app>` runs the `ExecStop` to bring containers down.
- **Restart an app** with `systemctl restart <app>`.

### Adding a New App

1. Create `apps/<app>.nix`.
2. Declare the ZFS dataset, directories, compose file, Caddy route, and systemd service.
3. Import the new module in `hosts/loungebox/default.nix`.
4. Add DNS records in Cloudflare and NextDNS (manual, outside Nix).
5. `nixos-rebuild switch` — the app is live.

## Eros App (apps/eros.nix)

Eros migrates from the ad-hoc deploy script model to the standard app pattern.

### ZFS Dataset

`storage/eros` → `/mnt/storage/eros`

### Directory Structure

```
/mnt/storage/eros/
  docker-compose.yml    # Written by Nix (via activation script)
  .env                  # Written by Nix (secrets from sops-nix, chmod 600, root-owned)
  data/
    db/                 # SQLite database (bind mount target)
    files/              # Uploaded files (bind mount target)
  admin-build/          # Admin frontend static files (deployed by Eros deploy script)
  client-build/         # Client frontend static files (deployed by Eros deploy script)
```

Note: Caddy's TLS cert storage lives at `/mnt/storage/caddy/` (shared infrastructure), not under any app directory. See [networking.md](networking.md).

### Docker Compose Stack

The `docker-compose.yml` is written by Nix to `/mnt/storage/eros/docker-compose.yml`:

```yaml
services:
  backend:
    image: eros-backend:latest
    ports:
      - "8080:8080"
    volumes:
      - ./data/db:/app/data/db
      - ./data/files:/app/data/files
      - ./admin-build:/app/admin-build
      - ./client-build:/app/client-build
    env_file: .env
    restart: unless-stopped

  # Note: Caddy is shared infrastructure, not per-app.
  # See networking.md for the Caddy setup.
```

The `.env` file is written by the activation script (see "How Files Get Written" above) with secrets from sops-nix:

```
ADMIN_API_KEY=<from sops>
APP_ENV=production
LOG_LEVEL=INFO
LOG_JSON=true
```

**Fresh install note:** On a brand new system, `eros-backend:latest` doesn't exist as a Docker image — it's not pulled from a registry, it's loaded locally. The Eros deploy script must be run once after initial setup to build and load the image before the Eros systemd service will start successfully.

### Caddy Route

Contributed to the shared Caddyfile:

```
eros.yourdomain.com {
  reverse_proxy localhost:8080
}
```

### Backup Hook

A systemd timer runs the SQLite safe backup daily:

```bash
sqlite3 /mnt/storage/eros/data/db/eros.sqlite \
  ".backup '/mnt/storage/backups/eros/eros-$(date +%Y-%m-%d).sqlite'"
```

With a cleanup job that removes backups older than 30 days from `/mnt/storage/backups/eros/`.

### Impact on Eros Deploy Script

The Eros repo's `deploy.sh` needs to be updated. The new model:

**What Nix manages (in this repo):**
- `docker-compose.yml`
- `.env` (secrets)
- Caddy configuration
- Directory structure
- Systemd service lifecycle

**What the Eros deploy script manages (in the Eros repo):**
- Building the Go backend Docker image
- Copying frontend builds (`admin-build/`, `client-build/`)
- Loading the backend image on the server
- Restarting the Eros service

New deploy script flow:
```bash
# 1. Build backend image locally (or in CI)
docker build -t eros-backend:latest .

# 2. Save and copy to server
docker save eros-backend:latest | ssh loungebox "docker load"

# 3. Copy frontend builds
scp -r admin-build/* loungebox:/mnt/storage/eros/admin-build/
scp -r client-build/* loungebox:/mnt/storage/eros/client-build/

# 4. Restart
ssh loungebox "sudo systemctl restart eros"
```

This is a cleaner separation: Nix owns infrastructure, the Eros deploy script owns application code. The Eros deploy script update is handled separately in the Eros repo — it's not part of this spec.

## Dockge (modules/dockge.nix)

Dockge is the container management dashboard. It runs as a Docker Compose stack declared in Nix.

### Purpose

- View all running containers across all app stacks.
- View container logs in real time.
- Start/stop/restart individual containers.
- **Not** the source of truth for stack definitions — that's Nix.

### Setup

- **Image:** `louislam/dockge:latest`
- **Port:** 5001 (proxied via Caddy at `dockge.yourdomain.com`)
- **Volumes:**
  - Docker socket (`/var/run/docker.sock`) — for container visibility and control
  - Persistent state on ZFS (`/mnt/storage/dockge`)
  - Compose stack directories (`/mnt/storage/*/docker-compose.yml`) — so Dockge can discover stacks
- **Restart policy:** `unless-stopped`

### Dockge and the "Nix as Source of Truth" Model

Dockge will show editing capabilities for stacks (it's designed as a stack manager). In this setup, those editing capabilities should be ignored — any changes made through Dockge's UI would be overwritten on the next `nixos-rebuild switch`.

This is an acceptable tradeoff. Dockge's monitoring and control features (logs, start/stop, container status) are valuable enough to justify running it even if the editing features go unused.

The convention is simple: **don't edit stacks in Dockge, edit them in Nix.** If this becomes a problem, Dockge can be forked or replaced with a read-only alternative later.

## App Lifecycle

### Starting an App
Apps start automatically on boot via their systemd services. Manual start:
```bash
sudo systemctl start <app>
```

### Stopping an App
```bash
sudo systemctl stop <app>
```
This runs `docker compose down` for that app's stack.

### Updating App Configuration
Edit the app's Nix module, commit, push, then deploy:
```bash
./deploy.sh
```
This runs `nixos-rebuild switch` which rewrites the compose file and restarts the systemd service if the config changed.

### Removing an App
1. Remove the app's Nix module from `apps/`.
2. Remove the import from `hosts/loungebox/default.nix`.
3. Deploy — the systemd service is removed, containers are stopped.
4. Optionally destroy the ZFS dataset: `zfs destroy storage/<app>`.
5. Remove DNS records from Cloudflare and NextDNS.
