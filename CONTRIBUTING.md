# Contributing

Issues and pull requests are welcome. Please describe your compositor, OBS installation method (native or Flatpak), capture source type, monitor layout, and relevant script log messages when reporting a problem. Remove private information from logs before sharing them.

## Scope

The current cursor provider uses Hyprland's `hyprctl cursorpos`. The project name is compositor-neutral, but support for Sway or another compositor is not implemented yet. Contributions for another compositor should add a separate cursor-position provider instead of assuming that every compositor exposes the same command or coordinate system.

Keep cursor acquisition separate from monitor-local coordinate mapping and crop positioning where practical. New providers should document the coordinate space they return and how monitor origins are determined.

## Before submitting

- Run a Lua syntax check if a compatible Lua compiler is available:

  ```bash
  luac -p obs_follow_mouse.lua
  ```

- Test with native OBS and/or Flatpak OBS as applicable.
- Verify that the cursor follows within the selected monitor and that movement outside it leaves the crop unchanged.
- Test changing script settings and unloading/reloading the script to check timer cleanup.
- Update `README.md` and `CHANGELOG.md` for user-visible changes.

Please don't claim support for a compositor or capture method until it has been tested.
