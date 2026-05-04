# Secrets

Part of [LoungeBox v2 spec](spec.md).

## Overview

Secrets are managed via sops-nix: encrypted in the git repo, decrypted on the server at activation time. This ensures the repo is fully self-contained — a fresh NixOS install plus this repo (plus the server's SSH host key) restores everything, including secrets.

## How It Works

1. Secrets are stored in `secrets.yaml` at the repo root, encrypted with age.
2. Two keys can decrypt: the server's SSH host key (for deploy-time decryption) and the developer's personal age key (for editing on the laptop).
3. On `nixos-rebuild switch`, sops-nix decrypts secrets to `/run/secrets/` — a tmpfs that never touches disk.
4. Nix config references secrets as file paths (e.g., `/run/secrets/cloudflare_api_token`).
5. App compose stacks access secrets via `.env` files or bind-mounted secret files written by Nix.

## Keys

### Server Key

sops-nix derives an age key from the server's SSH host key (`/etc/ssh/ssh_host_ed25519_key`). This means:
- No separate key management for the server.
- The key is created automatically during NixOS installation.
- If the server is reinstalled, a new SSH host key is generated — secrets must be re-encrypted for the new key.

To get the server's age public key (after NixOS is installed):
```bash
ssh loungebox "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age
```

### Developer Key

A personal age key for editing secrets on the laptop:
```bash
age-keygen -o ~/.config/sops/age/keys.txt
```

The private key (`AGE-SECRET-KEY-1...`) should be backed up in Bitwarden. If the laptop is lost, retrieve the key from Bitwarden to regain editing access.

The public key (`age1...`) goes into `.sops.yaml`.

## File Structure

### .sops.yaml

Lives at the repo root. Declares which keys can decrypt which files:

```yaml
keys:
  - &server age1<server-public-key-here>
  - &developer age1<developer-public-key-here>

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *server
          - *developer
```

### secrets.yaml

Encrypted secrets file. When viewed in git, key names are visible but values are encrypted:

```yaml
eros_admin_api_key: ENC[AES256_GCM,data:...,type:str]
cloudflare_api_token: ENC[AES256_GCM,data:...,type:str]
sops:
    # sops metadata (key fingerprints, etc.)
```

### Nix Config

In the flake inputs:
```nix
inputs.sops-nix.url = "github:Mic92/sops-nix";
```

In the host config:
```nix
sops.defaultSopsFile = ../../secrets.yaml;
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

sops.secrets.eros_admin_api_key = {};
sops.secrets.cloudflare_api_token = {};
```

Secrets are then available at `/run/secrets/eros_admin_api_key`, etc.

## Editing Workflow

### Editing an Existing Secret

```bash
# On the laptop (requires sops + personal age key):
sops secrets.yaml
```

This opens your default editor (`$EDITOR`) with the decrypted content:

```yaml
eros_admin_api_key: my-actual-secret-value
cloudflare_api_token: cf-abc123-actual-token
```

Edit, save, close. sops automatically re-encrypts the file on save.

```bash
git add secrets.yaml
git commit -m "rotate eros admin key"
./deploy.sh  # Applies to server
```

### Adding a New Secret

1. Add the secret value to `secrets.yaml` via `sops secrets.yaml`.
2. Declare the secret in the Nix config:
   ```nix
   sops.secrets.new_secret_name = {};
   ```
3. Reference it in the app module (e.g., in an `.env` template or bind mount).
4. Commit and deploy.

### Rotating Secrets

Same as editing — open with `sops`, change the value, commit, deploy. The server picks up the new value on the next `nixos-rebuild switch` and restarts affected services.

## Initial Bootstrap

This is the chicken-and-egg sequence for setting up sops-nix on a fresh install:

1. **Install NixOS** with a minimal config (SSH enabled, `lounge` user). No sops-nix yet.
2. **Get the server's age public key:**
   ```bash
   ssh loungebox "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age
   ```
3. **Generate developer age key** (if not already done):
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   # Save to Bitwarden
   ```
4. **Create `.sops.yaml`** with both public keys.
5. **Create `secrets.yaml`:**
   ```bash
   sops secrets.yaml
   # Enter initial secret values, save
   ```
6. **Add sops-nix to the flake** and declare secrets in the Nix config.
7. **Deploy** — `nixos-rebuild switch` now decrypts and deploys secrets.

Steps 1-3 happen once. After that, the normal editing workflow applies.

## What Happens If...

**The server is reinstalled?**
A new SSH host key is generated. The old server key can no longer decrypt. You need to:
1. Get the new server's age public key.
2. Update `.sops.yaml` with the new key.
3. Re-encrypt: `sops updatekeys secrets.yaml`
4. Commit and deploy.

**The laptop is lost?**
Retrieve the developer age key from Bitwarden. Install sops and age on the new laptop. Restore the key to `~/.config/sops/age/keys.txt`. You can edit secrets again.

**Both keys are lost?**
Secrets are unrecoverable. You'd need to generate new secrets (new API keys, new tokens) and re-encrypt from scratch. This is why the developer key is backed up in Bitwarden.

## Managed Secrets

| Secret | Used By | Purpose | Notes |
|--------|---------|---------|-------|
| `eros_admin_api_key` | Eros backend | Admin API authentication | |
| `cloudflare_api_token` | Caddy | DNS challenge for TLS certificates | Token needs `Zone:DNS:Edit` permission on the specific zone only. Do **not** use a global Cloudflare API key. |
| *(future app secrets)* | — | Added as apps are added | |
