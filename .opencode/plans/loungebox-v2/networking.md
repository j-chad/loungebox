# Networking

Part of [LoungeBox v2 spec](spec.md).

## Firewall

NixOS's built-in firewall (nftables) replaces UFW. The policy is simple: LAN and Tailscale traffic only, nothing exposed to the public internet.

```nix
networking.firewall = {
  enable = true;
  # Ports open on all interfaces (LAN + Tailscale)
  allowedTCPPorts = [ 22 80 443 ];
  # Tailscale interface is trusted
  trustedInterfaces = [ "tailscale0" ];
};
```

- **Default deny** incoming on all interfaces.
- **SSH (22)** — open on LAN and Tailscale for remote management.
- **HTTP/HTTPS (80, 443)** — open on LAN and Tailscale for Caddy to serve apps.
- **Tailscale interface (`tailscale0`)** — fully trusted, allows all traffic. This is safe because only devices on your Tailnet can reach this interface.
- **Outgoing** — all allowed (needed for package downloads, Tailscale coordination, DNS challenges, Docker image pulls).

App modules can open additional ports if needed, though most apps sit behind Caddy and don't need direct port exposure.

## Tailscale

Tailscale provides secure remote access when away from the LAN.

```nix
services.tailscale.enable = true;
```

**First-time setup:** After NixOS is installed and this config is applied, SSH into the machine on the LAN and run `tailscale up` interactively. This opens a browser-based auth flow. Once authenticated, Tailscale state persists across rebuilds — subsequent `nixos-rebuild switch` runs don't need re-authentication.

**What Tailscale provides:**
- SSH access to the server from anywhere.
- Access to all web apps (Eros, Dockge, etc.) from anywhere via Tailscale IP or MagicDNS.
- A stable IP for Cloudflare DNS records (Tailscale IPs don't change).

## Caddy Reverse Proxy

Caddy routes traffic to apps by subdomain and handles TLS certificate provisioning via Cloudflare DNS challenges.

### Why a Custom Docker Image

The standard NixOS Caddy package doesn't include the Cloudflare DNS plugin. Since TLS certificates are provisioned via Cloudflare DNS challenge (required because the server isn't publicly accessible for HTTP challenges), Caddy needs the plugin. The simplest solution is a custom Docker image built with `xcaddy`.

### Caddy Docker Image

```dockerfile
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

This image is built once on the server during initial setup. To rebuild (e.g., when upgrading Caddy), run:
```bash
ssh loungebox "docker build -f /tmp/Dockerfile.caddy -t eros-caddy:latest /tmp"
```
The Nix activation script writes the Dockerfile to `/tmp/Dockerfile.caddy`. Automating rebuild detection is deferred — Caddy upgrades are infrequent enough to do manually.

### Caddyfile

The Caddyfile is maintained as a single file in `modules/caddy.nix`. When adding a new app, add its site block to this file.

```
{
  acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

eros.yourdomain.com {
  reverse_proxy localhost:8080
}

dockge.yourdomain.com {
  reverse_proxy localhost:5001
}
```

This is intentionally simple — a single hardcoded Caddyfile rather than a modular assembly system. For a small number of apps, this is easier to understand and debug. A more sophisticated approach (where each app module contributes its own Caddy site block and they're assembled automatically) can be added later with more NixOS experience.

### Caddy Compose Stack

Caddy runs as a Docker container alongside the apps it proxies:

- **Ports:** 80 and 443 on the host.
- **Volumes:** Persistent TLS cert storage on the ZFS pool, Caddyfile bind-mounted from Nix-managed path.
- **Environment:** `CLOUDFLARE_API_TOKEN` from sops-nix secret.
- **Restart policy:** `unless-stopped`.

### Caddy Data Persistence

Caddy's TLS certificates and ACME state are persisted to avoid re-issuing certs on every restart:

| Path | Purpose |
|------|---------|
| `/mnt/storage/caddy/data` | TLS certs, OCSP staples |
| `/mnt/storage/caddy/config` | Caddy runtime config |

These live on the ZFS storage pool under a shared `caddy` directory (not per-app — Caddy is infrastructure, not an app).

## DNS

DNS is managed outside of NixOS across two services:

### Cloudflare (Public DNS)

Each app gets an A record pointing to the server's Tailscale IP:
- `eros.yourdomain.com → 100.x.x.x` (Tailscale IP)
- `dockge.yourdomain.com → 100.x.x.x`

This enables:
1. Caddy to obtain real Let's Encrypt TLS certificates via DNS challenge.
2. Remote access via Tailscale — devices on the Tailnet resolve the domain to the Tailscale IP and can reach the server.

### NextDNS (Local Override)

NextDNS rewrites the same domains to the server's LAN IP for devices on the home network:
- `eros.yourdomain.com → 192.168.1.197`
- `dockge.yourdomain.com → 192.168.1.197`

This means LAN devices hit the server directly without routing through Tailscale. Devices get real HTTPS with trusted certificates because the cert was issued for the actual domain name.

### Adding a New App's DNS

When adding a new app, two manual steps are needed outside of NixOS:
1. Add an A record in Cloudflare pointing `newapp.yourdomain.com` to the Tailscale IP.
2. Add a rewrite in NextDNS pointing `newapp.yourdomain.com` to the LAN IP.

These are the only manual steps when adding an app — everything else (compose stack, Caddy route, ZFS dataset) is declared in the Nix config.

## Network Topology

```
Internet
    │
    ├── Cloudflare DNS (domain → Tailscale IP)
    │
    └── Tailscale relay ── tailscale0 ── LoungeBox
                                              │
LAN devices ── NextDNS (domain → LAN IP) ── eth0 ── LoungeBox
                                              │
                                         ┌────┴────┐
                                         │  Caddy   │ :80/:443
                                         └────┬────┘
                                    ┌─────┬───┴───┬──────┐
                                    │     │       │      │
                                  Eros  Dockge  App3  App4
                                 :8080  :5001  :xxxx :xxxx
```

All external traffic hits Caddy, which terminates TLS and routes to the correct app by subdomain. Apps only listen on localhost ports — they're not directly accessible.
