# Gaming

Part of [LoungeBox v2 spec](spec.md).

## Overview

LoungeBox sits next to a TV and has an NVIDIA GPU. Gaming is an on-demand feature: completely idle by default, activated explicitly via SSH, and shut down when done. No display server or compositor runs unless gaming is active.

**Complexity warning:** This is the hardest part of the entire spec. Getting gamescope to run on bare DRM with NVIDIA drivers, audio routing, and controller input is advanced Linux territory. Expect multiple iterations and hardware-specific troubleshooting. This is correctly placed as the last milestone (v0.5).

## Design Principles

- **Zero resources when idle.** No X server, no Wayland compositor, no GPU display workload. The system is headless by default.
- **Manual activation only.** Gaming never starts on boot. It must be explicitly started via `systemctl start gaming`.
- **Lightweight.** No desktop environment. Gamescope (the SteamOS compositor) runs Steam directly — nothing else.
- **Clean shutdown.** Quitting Steam or running `systemctl stop gaming` tears everything down. The nightly 23:00 shutdown also kills it.

## Components

### NVIDIA Drivers (modules/gaming.nix)

NixOS has built-in NVIDIA support. The proprietary driver is declared in the config:

```nix
{ pkgs, config, ... }:
{
  hardware.nvidia = {
    modesetting.enable = true;
    open = false;  # Use proprietary driver (better for gaming)
    powerManagement.enable = true;  # GPU clocks down when idle, ramps up for gaming
  };

  # Legacy option name — configures GPU drivers regardless of X11 usage
  services.xserver.videoDrivers = [ "nvidia" ];
  # Explicitly ensure no display manager starts on boot
  services.xserver.enable = false;
}
```

The driver is loaded at boot (it's a kernel module), but the GPU stays idle without an active display session. This is necessary so the driver is immediately available when gaming starts.

### Steam

NixOS has first-class Steam support:

```nix
programs.steam = {
  enable = true;
  # Enables 32-bit libraries needed by many games
};
```

This installs Steam and handles the FHS compatibility layer that Steam requires (Steam expects a traditional Linux filesystem layout, which NixOS doesn't have — `programs.steam` creates a sandboxed FHS environment).

### Gamescope

Gamescope is the SteamOS session compositor. It creates a minimal Wayland session and runs Steam inside it, displaying on the TV output. No window manager, no taskbar, no desktop — just Steam.

```nix
programs.gamescope.enable = true;
```

### Audio (PipeWire)

Gaming requires an audio stack for HDMI audio output to the TV. PipeWire is configured in the gaming module (not the base config, since the system is headless otherwise):

```nix
# Required for gaming audio (HDMI to TV)
services.pipewire = {
  enable = true;
  pulse.enable = true;   # PulseAudio compatibility — Steam uses PulseAudio
  alsa.enable = true;    # ALSA compatibility
};
```

The correct HDMI audio output device may need to be configured after testing on hardware (PipeWire usually auto-detects, but NVIDIA HDMI audio can require explicit device selection).

### Controller Input

The `lounge` user needs access to input devices for controller support:

```nix
users.users.lounge.extraGroups = [ "input" "video" ];
# Note: "docker" and "wheel" are set in base.nix — NixOS merges list options automatically
```

Steam handles controller mapping natively via Steam Input.

## Gaming Systemd Service

Gamescope runs in DRM/KMS mode — directly on the GPU without an X server or parent Wayland compositor. This requires the `drm` backend:

```nix
systemd.services.gaming = {
  description = "Steam gaming session (TV)";
  # Not in wantedBy — never starts on boot
  after = [ "network.target" ];
  serviceConfig = {
    Type = "simple";
    User = "lounge";
    PAMName = "login";  # Ensures proper session setup
    TTYPath = "/dev/tty7";
    Environment = [
      "WLR_BACKENDS=drm"
      "XDG_RUNTIME_DIR=/run/user/1000"
      # Display output targeting — see open questions
    ];
    ExecStart = "${pkgs.gamescope}/bin/gamescope --backend drm -e -f -- steam -bigpicture";
    ExecStop = "/bin/kill -TERM $MAINPID";
    Restart = "no";
  };
};
```

Key differences from a typical gaming setup:
- **`--backend drm`** — gamescope runs directly on the GPU via DRM/KMS, no X server needed.
- **`WLR_BACKENDS=drm`** — tells the underlying wlroots library to use the DRM backend.
- **`TTYPath = "/dev/tty7"`** — allocates a virtual terminal for the display session.
- **`XDG_RUNTIME_DIR`** — required for Wayland socket creation. `1000` is the `lounge` user's UID.
- **No `DISPLAY` variable** — there's no X server. Gamescope creates its own Wayland display.
- **`Restart = "no"`** — when Steam exits (user quits), the service stops. It doesn't restart automatically.

**Note:** Running gamescope in DRM mode may require root privileges or specific capabilities (`CAP_SYS_ADMIN`). If the service fails to access the DRM device as the `lounge` user, options include:
1. Running the service as root with `User = "root"` and dropping to `lounge` for Steam.
2. Adding appropriate udev rules to grant the `lounge` user DRM device access.
3. Using a wrapper script with `seatd` or `greetd` for session management.

This needs hardware testing to determine the right approach.

## Usage

### Start a Gaming Session

```bash
# From laptop or phone (via Tailscale SSH):
ssh loungebox "sudo systemctl start gaming"
```

This launches gamescope → Steam Big Picture on the TV. Pick up a controller and play.

### Stop a Gaming Session

Option 1: Quit Steam from the TV interface. The service detects the process exit and cleans up.

Option 2:
```bash
ssh loungebox "sudo systemctl stop gaming"
```

### Check Status

```bash
ssh loungebox "systemctl status gaming"
```

## What Happens at 23:00

The nightly shutdown timer runs `poweroff`. If gaming is still active:
1. systemd stops all services (including `gaming.service`).
2. `ExecStop` sends SIGTERM to gamescope/Steam.
3. Steam exits, gamescope exits.
4. System powers off.

No special handling needed — systemd's normal shutdown sequence handles it.

## Open Questions

All of these require hardware testing and are expected to be resolved during the v0.5 milestone:

- **DRM device permissions.** Gamescope in DRM mode needs access to `/dev/dri/card*`. The `lounge` user may need to be in the `video` group, or a seat manager (`seatd`) may be needed.
- **Display output selection.** If the NVIDIA GPU has multiple outputs (HDMI, DisplayPort), gamescope needs to target the correct one for the TV. This may require `GAMESCOPE_PREFERRED_OUTPUT` or `WLR_DRM_CONNECTORS` environment variables.
- **Audio output device.** PipeWire may need explicit configuration to select the NVIDIA HDMI audio output over other audio devices (e.g., motherboard audio).
- **Session management.** The systemd service approach may need refinement. If DRM access is problematic, a lightweight session manager like `greetd` with an auto-login session for gaming could be an alternative.

## Resolved

- **GPU power management.** Handled by `hardware.nvidia.powerManagement.enable = true` — the GPU clocks down when idle and ramps up for gaming automatically.
