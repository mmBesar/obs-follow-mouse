# Changelog

## Unreleased

- Changed the default captured-source and crop/canvas dimensions to 1920×1080 to match a standard single-monitor 16:9 OBS setup; documented how to configure a portrait canvas intentionally.
- Clarified that OBS may retain settings from an older script version, so users should verify the four dimension fields after updating.

- Renamed the project and script to the compositor-neutral `OBS Follow Mouse` / `obs_follow_mouse.lua`.
- Documented that Hyprland is the only implemented cursor backend today; Sway and other compositor support remain future work.
- Added native OBS, Flatpak host-command, and automatic command modes.
- Added configurable `hyprctl` executable path, including support for NixOS paths.
- Added monitor-origin offsets, cursor-to-source scale controls, and signed cursor-coordinate parsing.
- Ignore cursor positions outside the selected monitor so movement on a neighboring monitor cannot move the crop.
- Fixed the `smoothing_factor` assignment typo.
- Corrected OBS timer removal and reinitialization when settings change or the script unloads.
- Added settings validation, throttled diagnostic messages, command retry cooldown, scene-change handling, and minimum-zoom warning.
- Rewrote documentation with setup, multi-monitor, Flatpak security, troubleshooting, attribution, and current limitations.
