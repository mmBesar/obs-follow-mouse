--[[
    OBS Follow Mouse for Linux (current cursor backend: Hyprland)

    Upstream project: https://github.com/Itz-Hex/hypr-obs-mouse-follow
    Original script header credits: Ollie Wells
    License: GNU General Public License v3.0 (see LICENSE)

    This is a modified fork. Changes in this derivative include:
      * Native OBS and OBS Flatpak command execution modes.
      * Optional execution of host hyprctl through flatpak-spawn.
      * Configurable hyprctl executable path (including NixOS paths).
      * Correct handling of monitor global-layout origins and cursor scaling.
      * Cursor coordinates outside the selected monitor are ignored.
      * Correct smoothing-factor setting name and behavior.
      * Correct OBS timer removal/restart handling.
      * Validated settings, diagnostics, and throttled repeated error messages.

    Security note for Flatpak:
      flatpak-spawn --host requires OBS to talk to org.freedesktop.Flatpak.
      That permission allows host command execution from the application; it is
      not restricted to hyprctl. See README.md before enabling it.
]]

obs = obslua

-- Script configuration values.
local source_name = ""
local interval_ms = 50
-- Defaults match a single 1920x1080 monitor and a 1920x1080 OBS base canvas.
-- Change both pairs only when your capture or OBS base canvas differs.
local display_width = 1920
local display_height = 1080
local output_width = 1920
local output_height = 1080
local zoom_scale = 1.58125
local smoothing_factor = 0.1

-- Current cursor backend: Hyprland (`hyprctl cursorpos`).
-- Command execution modes:
--   0 = Auto (detect Flatpak from the app environment)
--   1 = Flatpak host command (flatpak-spawn --host)
--   2 = Native command (hyprctl must be reachable by OBS)
local command_mode = 0
local hyprctl_path = "hyprctl"

-- hyprctl cursorpos reports global Hyprland layout coordinates. Set these to
-- the selected monitor's "at XxY" origin from `hyprctl monitors`.
local cursor_origin_x = 0
local cursor_origin_y = 0

-- Convert the monitor's logical cursor coordinates to captured-source pixels.
-- Use 1.0 unless the logical monitor dimensions differ from the capture pixels.
local cursor_scale_x = 1.0
local cursor_scale_y = 1.0

local timer_running = false
local update_crop
local current_x = nil
local current_y = nil
local source_sized = false
local sized_scene_name = nil
local logged_cursor_error = false
local logged_missing_source = false
local logged_outside_monitor = false
local logged_connected = false
local cursor_retry_after = 0

local function log(message)
    print("[OBS Follow Mouse / Hyprland] " .. message)
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

-- Quote a configured executable path for the shell used by io.popen.
local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function flatpak_is_detected()
    local flatpak_id = os.getenv("FLATPAK_ID")
    local flatpak_sandbox_dir = os.getenv("FLATPAK_SANDBOX_DIR")
    return (flatpak_id ~= nil and flatpak_id ~= "") or
           (flatpak_sandbox_dir ~= nil and flatpak_sandbox_dir ~= "")
end

local function use_flatpak_host_command()
    if command_mode == 1 then return true end
    if command_mode == 2 then return false end
    return flatpak_is_detected()
end

local function stop_timer()
    -- OBS timer_remove takes the callback function, not a timer ID.
    if timer_running and update_crop then
        obs.timer_remove(update_crop)
        timer_running = false
    end
end

-- Read the current Hyprland cursor position. In Flatpak mode, execute hyprctl on the host.
local function get_hyprland_cursor_position()
    -- Avoid spawning a failing command 20 times per second when permission or
    -- executable-path configuration is wrong. Retry periodically without log spam.
    local now = os.time()
    if now < cursor_retry_after then return nil, nil end

    local executable = hyprctl_path
    if executable == nil or executable:match("^%s*$") then
        executable = "hyprctl"
    end

    local quoted_executable = shell_quote(executable)
    local command
    if use_flatpak_host_command() then
        command = "flatpak-spawn --host " .. quoted_executable .. " cursorpos 2>&1"
    else
        command = quoted_executable .. " cursorpos 2>&1"
    end

    local handle, popen_error = io.popen(command, "r")
    if not handle then
        if not logged_cursor_error then
            log("ERROR: Could not start the cursor command: " .. tostring(popen_error))
            logged_cursor_error = true
            cursor_retry_after = now + 2
        end
        return nil, nil
    end

    local output = handle:read("*a") or ""
    local close_ok, close_reason, close_code = handle:close()
    output = output:gsub("^%s+", ""):gsub("%s+$", "")

    -- Signed numbers support monitors placed left of or above the desktop origin.
    local x_text, y_text = output:match("^(-?%d+)%s*,%s*(-?%d+)$")
    if not x_text or not y_text then
        if not logged_cursor_error then
            log("ERROR: Could not read cursor coordinates from hyprctl output: " ..
                (output ~= "" and output or "<empty output>"))
            if close_ok == nil then
                log("Command status: " .. tostring(close_reason) .. " " .. tostring(close_code))
            end
            if use_flatpak_host_command() then
                log("For OBS Flatpak, check the org.freedesktop.Flatpak permission and the hyprctl path.")
            else
                log("Check that hyprctl is available to OBS, or select Flatpak host mode if OBS is sandboxed.")
            end
            logged_cursor_error = true
        end
        cursor_retry_after = now + 2
        return nil, nil
    end

    cursor_retry_after = 0
    logged_cursor_error = false
    if not logged_connected then
        local mode_label = use_flatpak_host_command() and "Flatpak host" or "native"
        log("Hyprland cursor provider connected (" .. mode_label .. " command mode).")
        logged_connected = true
    end

    return tonumber(x_text), tonumber(y_text)
end

-- Find a top-level source item in the current active OBS scene.
local function get_current_scene_name()
    local scene_source = obs.obs_frontend_get_current_scene()
    if not scene_source then return nil end

    local name = obs.obs_source_get_name(scene_source)
    obs.obs_source_release(scene_source)
    return name
end

local function find_current_scene_item()
    local scene_source = obs.obs_frontend_get_current_scene()
    if not scene_source then
        return nil, nil
    end

    local scene = obs.obs_scene_from_source(scene_source)
    if not scene then
        obs.obs_source_release(scene_source)
        return nil, nil
    end

    local scene_item = obs.obs_scene_find_source(scene, source_name)
    return scene_source, scene_item
end

local function set_source_size()
    if source_name == "" then return false end

    local scene_source, scene_item = find_current_scene_item()
    if not scene_source then return false end

    if not scene_item then
        obs.obs_source_release(scene_source)
        source_sized = false
        sized_scene_name = nil
        if not logged_missing_source then
            log("ERROR: Source '" .. source_name .. "' was not found as a top-level item in the current scene.")
            logged_missing_source = true
        end
        return false
    end

    local bounds = obs.vec2()
    bounds.x = display_width * zoom_scale
    bounds.y = display_height * zoom_scale

    obs.obs_sceneitem_set_bounds_type(scene_item, obs.OBS_BOUNDS_STRETCH)
    obs.obs_sceneitem_set_bounds_alignment(scene_item, 0)
    obs.obs_sceneitem_set_bounds(scene_item, bounds)

    sized_scene_name = obs.obs_source_get_name(scene_source)
    obs.obs_source_release(scene_source)
    source_sized = true
    logged_missing_source = false
    return true
end

local function set_source_position(x, y)
    if source_name == "" then return false end

    local scene_source, scene_item = find_current_scene_item()
    if not scene_source then return false end

    if not scene_item then
        obs.obs_source_release(scene_source)
        source_sized = false
        if not logged_missing_source then
            log("ERROR: Source '" .. source_name .. "' was not found as a top-level item in the current scene.")
            logged_missing_source = true
        end
        return false
    end

    local position = obs.vec2()
    position.x = x
    position.y = y
    obs.obs_sceneitem_set_pos(scene_item, position)

    obs.obs_source_release(scene_source)
    logged_missing_source = false
    return true
end

-- Small backend boundary: other compositor implementations can be added here
-- later without coupling their cursor-query mechanism to the crop calculations.
local function get_cursor_position()
    return get_hyprland_cursor_position()
end

update_crop = function()
    -- The active scene can change while this script is loaded. Re-apply bounds
    -- to the named item in the new scene rather than assuming the old scene item
    -- is still active.
    local active_scene_name = get_current_scene_name()
    if active_scene_name ~= sized_scene_name then
        source_sized = false
    end

    -- Retry sizing if the source wasn't available when configured or the scene changed.
    if not source_sized and not set_source_size() then
        return
    end

    local raw_x, raw_y = get_cursor_position()
    if raw_x == nil or raw_y == nil then return end

    -- Convert global layout coordinates to this monitor's local source pixels.
    local x = (raw_x - cursor_origin_x) * cursor_scale_x
    local y = (raw_y - cursor_origin_y) * cursor_scale_y

    -- Do not clamp an off-monitor pointer to an edge. Side-by-side monitors
    -- share the same Y range, so clamping X alone makes the wrong display's
    -- vertical mouse movement affect this crop.
    if x < 0 or x >= display_width or y < 0 or y >= display_height then
        if not logged_outside_monitor then
            log(string.format(
                "Cursor is outside the selected monitor; holding the last crop position (local %.1f, %.1f; capture %dx%d). Check monitor origin/scale if unexpected.",
                x, y, display_width, display_height
            ))
            logged_outside_monitor = true
        end
        return
    end

    logged_outside_monitor = false

    if current_x == nil then current_x = x end
    if current_y == nil then current_y = y end

    current_x = current_x + (x - current_x) * smoothing_factor
    current_y = current_y + (y - current_y) * smoothing_factor

    local max_left = math.max(0, display_width * zoom_scale - output_width)
    local max_top = math.max(0, display_height * zoom_scale - output_height)

    local left = clamp(current_x * zoom_scale - output_width / 2, 0, max_left)
    local top = clamp(current_y * zoom_scale - output_height / 2, 0, max_top)

    set_source_position(-left, -top)
end

function script_description()
    return "OBS Follow Mouse: zoom and pan a capture to follow the cursor. Current cursor backend: Hyprland."
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "source_name", "")
    obs.obs_data_set_default_int(settings, "interval_ms", 50)
    obs.obs_data_set_default_int(settings, "display_width", 1920)
    obs.obs_data_set_default_int(settings, "display_height", 1080)
    obs.obs_data_set_default_int(settings, "output_width", 1920)
    obs.obs_data_set_default_int(settings, "output_height", 1080)
    obs.obs_data_set_default_double(settings, "zoom_scale", 1.58125)
    obs.obs_data_set_default_double(settings, "smoothing_factor", 0.1)
    obs.obs_data_set_default_int(settings, "command_mode", 0)
    obs.obs_data_set_default_string(settings, "hyprctl_path", "hyprctl")
    obs.obs_data_set_default_int(settings, "cursor_origin_x", 0)
    obs.obs_data_set_default_int(settings, "cursor_origin_y", 0)
    obs.obs_data_set_default_double(settings, "cursor_scale_x", 1.0)
    obs.obs_data_set_default_double(settings, "cursor_scale_y", 1.0)
end

function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_text(props, "source_name", "OBS Source Name (top-level item in current scene)", obs.OBS_TEXT_DEFAULT)

    local mode = obs.obs_properties_add_list(
        props,
        "command_mode",
        "How to run the cursor-position command (Hyprland backend)",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_INT
    )
    obs.obs_property_list_add_int(mode, "Auto (detect Flatpak)", 0)
    obs.obs_property_list_add_int(mode, "Flatpak host command (flatpak-spawn)", 1)
    obs.obs_property_list_add_int(mode, "Native OBS (run hyprctl directly)", 2)
    obs.obs_properties_add_text(props, "hyprctl_path", "Hyprland hyprctl Executable (path or command name)", obs.OBS_TEXT_DEFAULT)

    obs.obs_properties_add_int(props, "interval_ms", "Update Interval (ms)", 16, 200, 1)
    obs.obs_properties_add_int(props, "display_width", "Captured Source Width (pixels)", 1, 16384, 1)
    obs.obs_properties_add_int(props, "display_height", "Captured Source Height (pixels)", 1, 16384, 1)
    obs.obs_properties_add_int(props, "output_width", "Crop / Canvas Width (scene pixels)", 1, 16384, 1)
    obs.obs_properties_add_int(props, "output_height", "Crop / Canvas Height (scene pixels)", 1, 16384, 1)
    obs.obs_properties_add_float(props, "zoom_scale", "Zoom Scale", 1.0, 10.0, 0.01)
    obs.obs_properties_add_float(props, "smoothing_factor", "Smoothing (0.01 = slow/smooth, 1.0 = immediate)", 0.01, 1.0, 0.01)

    obs.obs_properties_add_int(props, "cursor_origin_x", "Captured Monitor Origin X (Hyprland layout)", -32768, 32768, 1)
    obs.obs_properties_add_int(props, "cursor_origin_y", "Captured Monitor Origin Y (Hyprland layout)", -32768, 32768, 1)
    obs.obs_properties_add_float(props, "cursor_scale_x", "Cursor-to-Source Scale X (usually 1.0)", 0.1, 5.0, 0.01)
    obs.obs_properties_add_float(props, "cursor_scale_y", "Cursor-to-Source Scale Y (usually 1.0)", 0.1, 5.0, 0.01)

    return props
end

function script_update(settings)
    stop_timer()

    source_name = obs.obs_data_get_string(settings, "source_name") or ""
    interval_ms = clamp(obs.obs_data_get_int(settings, "interval_ms"), 16, 200)
    display_width = math.max(1, obs.obs_data_get_int(settings, "display_width"))
    display_height = math.max(1, obs.obs_data_get_int(settings, "display_height"))
    output_width = math.max(1, obs.obs_data_get_int(settings, "output_width"))
    output_height = math.max(1, obs.obs_data_get_int(settings, "output_height"))
    zoom_scale = clamp(obs.obs_data_get_double(settings, "zoom_scale"), 1.0, 10.0)
    smoothing_factor = clamp(obs.obs_data_get_double(settings, "smoothing_factor"), 0.01, 1.0)
    command_mode = clamp(obs.obs_data_get_int(settings, "command_mode"), 0, 2)
    hyprctl_path = obs.obs_data_get_string(settings, "hyprctl_path") or "hyprctl"
    cursor_origin_x = obs.obs_data_get_int(settings, "cursor_origin_x")
    cursor_origin_y = obs.obs_data_get_int(settings, "cursor_origin_y")
    cursor_scale_x = clamp(obs.obs_data_get_double(settings, "cursor_scale_x"), 0.1, 5.0)
    cursor_scale_y = clamp(obs.obs_data_get_double(settings, "cursor_scale_y"), 0.1, 5.0)

    current_x = nil
    current_y = nil
    source_sized = false
    sized_scene_name = nil
    logged_cursor_error = false
    logged_missing_source = false
    logged_outside_monitor = false
    logged_connected = false
    cursor_retry_after = 0

    log("Settings updated; source='" .. source_name .. "', interval=" .. interval_ms .. " ms.")

    local minimum_zoom = math.max(output_width / display_width, output_height / display_height)
    if zoom_scale < minimum_zoom then
        log(string.format(
            "WARNING: Zoom %.3f may not fill the crop. For %dx%d source and %dx%d crop, use a zoom of at least %.3f to fill both dimensions.",
            zoom_scale, display_width, display_height, output_width, output_height, minimum_zoom
        ))
    end

    if source_name == "" then
        log("Set the OBS Source Name to enable mouse following.")
        return
    end

    if command_mode == 1 or (command_mode == 0 and flatpak_is_detected()) then
        log("Using Flatpak host-command mode. OBS needs org.freedesktop.Flatpak access.")
    else
        log("Using native command mode. The hyprctl executable must be available to OBS.")
    end

    set_source_size()
    obs.timer_add(update_crop, interval_ms)
    timer_running = true
end

function script_unload()
    stop_timer()
end
