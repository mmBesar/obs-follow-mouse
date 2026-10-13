# OBS Follow Mouse

A Lua script for OBS Studio that zooms a captured display and smoothly pans the crop to follow the mouse cursor. It is designed for Linux screen recordings, tutorials, demonstrations, streams, and portrait-format clips.

**Current status:** the implemented cursor provider supports **Hyprland** via `hyprctl cursorpos`. The project name is compositor-neutral so other providers (for example, Sway) can be added later. Sway and other compositors are **not supported yet**.

This project is a modified derivative of [Itz-Hex/hypr-obs-mouse-follow](https://github.com/Itz-Hex/hypr-obs-mouse-follow). The original script header credits **Ollie Wells**. Upstream attribution and the GNU GPL v3 license are retained; see [`ATTRIBUTION.md`](ATTRIBUTION.md) and [`LICENSE`](LICENSE).

## Features

- Smooth cursor following with configurable smoothing and update interval.
- Uses Hyprland's global cursor coordinates through `hyprctl cursorpos`.
- Supports manual monitor-origin offsets for multi-monitor layouts.
- Holds the last crop position when the cursor is outside the selected monitor, including when it moves on a neighboring monitor.
- Supports signed cursor coordinates, including monitors located left of or above the layout origin.
- Offers configurable cursor-to-source scaling for setups where logical cursor coordinates differ from capture pixels.
- Supports native OBS and OBS Flatpak, including a configurable host `hyprctl` path for NixOS.
- Correctly removes and restarts the OBS timer when settings change or the script unloads.
- Limits repeated error logging when cursor lookup fails.
- Reapplies source sizing when the active scene changes.

## Requirements

- Linux with [Hyprland](https://hyprland.org/) (current supported compositor).
- OBS Studio with Lua scripting enabled.
- `hyprctl` available on the host.
- For OBS Flatpak: `flatpak-spawn` and permission for OBS to talk to `org.freedesktop.Flatpak`.

The script queries the cursor position independently of the capture API. Your OBS display-capture source can use whatever capture method is supported by your OBS installation, including PipeWire capture on Wayland.

## Installation

1. Download [`obs_follow_mouse.lua`](obs_follow_mouse.lua).
2. Open OBS Studio and choose **Tools → Scripts**.
3. Click **+** and select `obs_follow_mouse.lua`.
4. Select the script in the list and configure the source name, dimensions, monitor origin, and command mode.
5. Move the cursor onto the captured monitor and confirm the crop follows it in the preview.

The configured **OBS Source Name** must match a **top-level item in the currently active scene**. This script changes that scene item's bounds and position. If you need an unaffected view of the same capture, duplicate the source or create a separate scene layout.

## OBS Flatpak

Inside Flatpak, OBS typically cannot execute the host's `hyprctl` by calling `hyprctl` directly. This script can run the host command using `flatpak-spawn --host`, but Flatpak must permit OBS to access the `org.freedesktop.Flatpak` D-Bus interface.

Find the installed OBS Flatpak application ID if needed:

```bash
flatpak list --app | grep -i obs
```

### Test permission for one launch

Close OBS and run:

```bash
flatpak run --talk-name=org.freedesktop.Flatpak com.obsproject.Studio
```

If your application ID differs, substitute the ID shown by `flatpak list --app`.

In the script settings, leave **How to run the cursor-position command** on **Auto** or select **Flatpak host command (flatpak-spawn)** explicitly.

### Make the permission persistent

Only after the one-launch test works, you can make the permission persistent for your user:

```bash
flatpak override --user \
  --talk-name=org.freedesktop.Flatpak \
  com.obsproject.Studio
```

Inspect the current per-user override with:

```bash
flatpak override --user --show com.obsproject.Studio
```

**Security warning:** access to `org.freedesktop.Flatpak` is broader than permission to run `hyprctl` alone. It allows code inside OBS to request host command execution through `flatpak-spawn`. Only enable it if you trust the OBS scripts and plugins you use. Native OBS does not need this Flatpak permission.

### NixOS `hyprctl` path

First confirm the command works on the host:

```bash
command -v hyprctl
hyprctl cursorpos
```

If host-command mode cannot resolve `hyprctl`, set **Hyprland hyprctl Executable** in the script settings to the full path. A common NixOS path is:

```text
/run/current-system/sw/bin/hyprctl
```

Use the path from your system's `command -v hyprctl` output where possible.

## Configuration

Open **Tools → Scripts**, select `obs_follow_mouse.lua`, and adjust the settings. Dimensions are in pixels unless noted.

| Setting | Description |
| --- | --- |
| **OBS Source Name** | Exact name of the display-capture source as a top-level item in the current scene. |
| **How to run the cursor-position command** | `Auto` detects Flatpak from environment variables; `Flatpak host command` uses `flatpak-spawn --host`; `Native OBS` runs `hyprctl` directly. |
| **Hyprland hyprctl Executable** | Command name or full path for `hyprctl`. On NixOS, use `/run/current-system/sw/bin/hyprctl` if needed. |
| **Update Interval (ms)** | Cursor polling interval. Default: 50 ms (about 20 updates per second). Lower values cause more frequent command executions. |
| **Captured Source Width / Height** | Pixel dimensions of the selected monitor capture, not the combined virtual desktop. |
| **Crop / Canvas Width / Height** | Viewport dimensions in OBS scene/base-canvas coordinates that the zoomed source should fill. |
| **Zoom Scale** | Scale factor applied to the captured source. A higher value zooms in further. |
| **Smoothing** | `1.0` follows immediately; smaller values smooth motion but add lag. |
| **Captured Monitor Origin X / Y** | Selected monitor's global `at XxY` position from `hyprctl monitors`. |
| **Cursor-to-Source Scale X / Y** | Converts local cursor coordinates to captured-source pixels. Use `1.0` unless layout/capture dimensions differ. |

### Example: two monitors side by side

Suppose `hyprctl monitors` reports:

```text
Monitor DP-1:
    1920x1080 at 0x0

Monitor eDP-1:
    1920x1080 at 1920x0
```

For a 1920×1080 capture of **DP-1**, use:

| Setting | Value |
| --- | ---: |
| Captured Source Width / Height | `1920` / `1080` |
| Monitor Origin X / Y | `0` / `0` |
| Cursor Scale X / Y | `1.0` / `1.0` |

For **eDP-1**, keep the same dimensions and scales but set **Monitor Origin X** to `1920` and **Monitor Origin Y** to `0`.

The cursor is accepted only while it is inside the selected monitor's configured rectangle. Moving the pointer on a neighboring monitor leaves the crop at its last position. Change the origin when changing the captured monitor; the script does not currently auto-detect which monitor the OBS source captures.

### Choosing a zoom scale

To fill a crop without empty space, the scale must be at least:

```text
zoom_scale >= max(crop_width / source_width,
                  crop_height / source_height)
```

For a 1920×1080 source and a 1080×1920 portrait canvas, the minimum is about `1.778`. A lower scale can leave the canvas partly uncovered. The script logs a warning when your configured scale may be too small.

## Troubleshooting

### `hyprctl: command not found` or the cursor position cannot be read

- Confirm `hyprctl cursorpos` works in a host terminal.
- With OBS Flatpak, test the `org.freedesktop.Flatpak` permission above and choose Flatpak host-command mode.
- On NixOS, set the executable to `/run/current-system/sw/bin/hyprctl` if this matches the path on your system.

### The crop follows the wrong monitor

Set **Captured Monitor Origin X / Y** to the selected monitor's `at XxY` layout position. Do not use the monitor ID as the origin.

### Vertical movement on another monitor moves the crop

Make sure you loaded this project's current `obs_follow_mouse.lua` and that its monitor origin is correct. The script rejects cursor positions outside the selected monitor instead of clamping an outside cursor to the nearest edge.

### The source cannot be found

The source name is case-sensitive and must match a top-level item in the current scene. Nested items inside groups or other scenes aren't found by the direct lookup.

### The zoomed source does not fill the canvas

Ensure the crop dimensions match the OBS base-canvas coordinates used by the scene transform, and set the zoom to at least the minimum described above.

## Current limitations and roadmap

- **Hyprland is the only implemented cursor backend.** Sway support is a future goal and must not be considered supported until implemented and tested.
- Monitor origin and coordinate scaling are configured manually.
- The script controls one named top-level source item in the active scene.
- Cursor polling starts a command at each update interval; very short intervals increase overhead.
- Flatpak host-command mode requires a broad Flatpak D-Bus permission.

Potential future work includes a backend interface for additional Wayland compositors, automatic monitor detection where a reliable API exists, and optional enable/disable controls.

## Validation status

The script is provided as-is. It should be tested in the user's OBS installation, with the intended monitor layout and Flatpak permissions, before relying on it for a recording or live stream. Syntax and mock-logic checks are not substitutes for integration testing against real OBS, Hyprland, and Flatpak.

## Credits and license

This project builds on [Itz-Hex/hypr-obs-mouse-follow](https://github.com/Itz-Hex/hypr-obs-mouse-follow), whose script header credits Ollie Wells. See [`ATTRIBUTION.md`](ATTRIBUTION.md) and [`LICENSE`](LICENSE). The project remains licensed under the GNU General Public License v3.0.
