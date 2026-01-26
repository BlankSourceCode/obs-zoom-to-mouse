--
-- OBS Zoom to Mouse
-- An OBS lua script to zoom a display-capture source to focus on the mouse.
-- Copyright (c) BlankSourceCode.  All rights reserved.
-- Fixed for macOS Apple Silicon (M1/M2/M3) and OBS Studio 30+/32+
--

local obs = obslua
local ffi = require("ffi")
local VERSION = "1.0.2-macos-m3"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"

local source_name = ""
local source = nil
local sceneitem = nil
local sceneitem_info_orig = nil
local sceneitem_crop_orig = nil
local sceneitem_info = nil
local sceneitem_crop = nil
local crop_filter = nil
local crop_filter_temp = nil
local crop_filter_settings = nil
local crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
local crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
local monitor_info = nil
local zoom_info = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local zoom_time = 0
local zoom_target = nil
local locked_center = nil
local locked_last_pos = nil
local hotkey_zoom_id = nil
local hotkey_follow_id = nil
local is_timer_running = false

local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_cg_lib = nil
local osx_main_display_height = nil

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.1
local follow_border = 0
local follow_safezone_sensitivity = 10
local use_follow_auto_lock = false
local zoom_value = 2
local zoom_speed = 0.1
local allow_all_sources = false
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local monitor_override_sx = 0
local monitor_override_sy = 0
local monitor_override_dw = 0
local monitor_override_dh = 0
local debug_logs = false

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

local version = obs.obs_get_version_string()
local major = tonumber(version:match("(%d+)")) or 0
local minor = tonumber(version:match("%d+%.(%d+)")) or 0

-- Check if we're on OBS 30+ which uses different API
local use_new_api = (major >= 30)

-- Define the mouse cursor functions for each platform
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
    ]])
    win_point = ffi.new("POINT[1]")
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    local success, lib = pcall(ffi.load, "X11.so.6")
    if success then
        x11_lib = lib
        x11_display = x11_lib.XOpenDisplay(nil)
        if x11_display ~= nil then
            x11_root = x11_lib.XDefaultRootWindow(x11_display)
            x11_mouse = {
                root_win = ffi.new("Window[1]"),
                child_win = ffi.new("Window[1]"),
                root_x = ffi.new("int[1]"),
                root_y = ffi.new("int[1]"),
                win_x = ffi.new("int[1]"),
                win_y = ffi.new("int[1]"),
                mask = ffi.new("unsigned int[1]")
            }
        end
    end
elseif ffi.os == "OSX" then
    -- Use CoreGraphics for reliable mouse position on Apple Silicon
    -- This approach works better on M1/M2/M3 Macs than the NSEvent method
    local cg_loaded = false
    
    ffi.cdef([[
        typedef double CGFloat;
        typedef struct CGPoint {
            CGFloat x;
            CGFloat y;
        } CGPoint;
        typedef struct CGSize {
            CGFloat width;
            CGFloat height;
        } CGSize;
        typedef struct CGRect {
            CGPoint origin;
            CGSize size;
        } CGRect;
        typedef uint32_t CGDirectDisplayID;
        typedef uint32_t CGEventSourceStateID;
        
        CGPoint CGEventGetLocation(void* event);
        void* CGEventCreate(void* source);
        void CFRelease(void* cf);
        
        CGDirectDisplayID CGMainDisplayID(void);
        CGRect CGDisplayBounds(CGDirectDisplayID display);
        size_t CGDisplayPixelsHigh(CGDirectDisplayID display);
    ]])
    
    -- Try to load CoreGraphics framework
    local paths_to_try = {
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/CoreGraphics.framework/CoreGraphics",
        "CoreGraphics"
    }
    
    for _, path in ipairs(paths_to_try) do
        local success, lib = pcall(ffi.load, path)
        if success then
            osx_cg_lib = lib
            cg_loaded = true
            
            -- Get main display height for coordinate conversion
            local main_display = osx_cg_lib.CGMainDisplayID()
            osx_main_display_height = tonumber(osx_cg_lib.CGDisplayPixelsHigh(main_display))
            
            break
        end
    end
    
    if not cg_loaded then
        print("OBS-Zoom-To-Mouse: WARNING - Could not load CoreGraphics framework")
        print("Mouse tracking may not work correctly on this Mac")
    end
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if ffi.os == "Windows" then
        if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
            mouse.x = win_point[0].x
            mouse.y = win_point[0].y
        end
    elseif ffi.os == "Linux" then
        if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
            if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                mouse.x = tonumber(x11_mouse.win_x[0])
                mouse.y = tonumber(x11_mouse.win_y[0])
            end
        end
    elseif ffi.os == "OSX" then
        if osx_cg_lib ~= nil then
            -- Use CGEventGetLocation which works reliably on Apple Silicon
            local success, result = pcall(function()
                -- Create a null event to get current mouse location
                local event = osx_cg_lib.CGEventCreate(nil)
                if event ~= nil then
                    local point = osx_cg_lib.CGEventGetLocation(event)
                    osx_cg_lib.CFRelease(event)
                    return point
                end
                return nil
            end)
            
            if success and result then
                mouse.x = tonumber(result.x)
                mouse.y = tonumber(result.y)
            end
        end
    end

    return mouse
end

---
-- Get the information about display capture sources for the current platform
---@return any
function get_dc_info()
    if ffi.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif ffi.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif ffi.os == "OSX" then
        -- OBS 30+ uses screen_capture, older versions use display_capture
        if major >= 30 then
            return {
                source_id = "screen_capture",
                prop_id = "display_uuid",
                prop_type = "string"
            }
        else
            return {
                source_id = "display_capture",
                prop_id = "display",
                prop_type = "int"
            }
        end
    end

    return nil
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

---
-- Format the given lua table into a string
---@param tbl any
---@param indent any
---@return string result The formatted string
function format_table(tbl, indent)
    if not indent then
        indent = 0
    end

    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key .. " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"

    return str
end

---
-- Linear interpolate between v0 and v1
---@param v0 number The start position
---@param v1 number The end position
---@param t number Time
---@return number value The interpolated value
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t;
end

---
-- Ease a time value in and out
---@param t number Time between 0 and 1
---@return number
function ease_in_out(t)
    t = t * 2
    if t < 1 then
        return 0.5 * t * t * t
    else
        t = t - 2
        return 0.5 * (t * t * t + 2)
    end
end

---
-- Clamps a given value between min and max
---@param min number The min value
---@param max number The max value
---@param value number The number to clamp
---@return number result the clamped number
function clamp(min, max, value)
    return math.max(min, math.min(max, value))
end

---
-- Helper functions for OBS 30+ API compatibility
-- Store and restore scene item transform using individual functions
---
function get_sceneitem_transform(item)
    local transform = {}
    
    local pos = obs.vec2()
    obs.obs_sceneitem_get_pos(item, pos)
    transform.pos_x = pos.x
    transform.pos_y = pos.y
    
    local scale = obs.vec2()
    obs.obs_sceneitem_get_scale(item, scale)
    transform.scale_x = scale.x
    transform.scale_y = scale.y
    
    transform.rot = obs.obs_sceneitem_get_rot(item)
    transform.alignment = obs.obs_sceneitem_get_alignment(item)
    transform.bounds_type = obs.obs_sceneitem_get_bounds_type(item)
    transform.bounds_alignment = obs.obs_sceneitem_get_bounds_alignment(item)
    
    local bounds = obs.vec2()
    obs.obs_sceneitem_get_bounds(item, bounds)
    transform.bounds_x = bounds.x
    transform.bounds_y = bounds.y
    
    return transform
end

function set_sceneitem_transform(item, transform)
    if not transform then return end
    
    local pos = obs.vec2()
    pos.x = transform.pos_x
    pos.y = transform.pos_y
    obs.obs_sceneitem_set_pos(item, pos)
    
    local scale = obs.vec2()
    scale.x = transform.scale_x
    scale.y = transform.scale_y
    obs.obs_sceneitem_set_scale(item, scale)
    
    obs.obs_sceneitem_set_rot(item, transform.rot)
    obs.obs_sceneitem_set_alignment(item, transform.alignment)
    obs.obs_sceneitem_set_bounds_type(item, transform.bounds_type)
    obs.obs_sceneitem_set_bounds_alignment(item, transform.bounds_alignment)
    
    local bounds = obs.vec2()
    bounds.x = transform.bounds_x
    bounds.y = transform.bounds_y
    obs.obs_sceneitem_set_bounds(item, bounds)
end

---
-- Get the size and position of the monitor so that we know the top-left mouse point
---@param source any The OBS source
---@return table|nil monitor_info The monitor size/top-left point
function get_monitor_info(source)
    local info = nil

    -- Only do the expensive look up if we are using automatic calculations on a display source
    if is_display_capture(source) and not use_monitor_override then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            local props = obs.obs_source_properties(source)
            if props ~= nil then
                local monitor_id_prop = obs.obs_properties_get(props, dc_info.prop_id)
                if monitor_id_prop then
                    local found = nil
                    local settings = obs.obs_source_get_settings(source)
                    if settings ~= nil then
                        local to_match
                        if dc_info.prop_type == "string" then
                            to_match = obs.obs_data_get_string(settings, dc_info.prop_id)
                        elseif dc_info.prop_type == "int" then
                            to_match = obs.obs_data_get_int(settings, dc_info.prop_id)
                        end

                        local item_count = obs.obs_property_list_item_count(monitor_id_prop);
                        for i = 0, item_count do
                            local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                            local value
                            if dc_info.prop_type == "string" then
                                value = obs.obs_property_list_item_string(monitor_id_prop, i)
                            elseif dc_info.prop_type == "int" then
                                value = obs.obs_property_list_item_int(monitor_id_prop, i)
                            end

                            if value == to_match then
                                found = name
                                break
                            end
                        end
                        obs.obs_data_release(settings)
                    end

                    -- Parse monitor name for dimensions and position
                    -- Format is typically: "Monitor Name: 3840x2160 @ -1920,0 (Primary Monitor)"
                    if found then
                        log("Parsing display name: " .. found)
                        local x, y = found:match("(-?%d+),(-?%d+)")
                        local width, height = found:match("(%d+)x(%d+)")

                        info = { x = 0, y = 0, width = 0, height = 0 }
                        info.x = tonumber(x, 10) or 0
                        info.y = tonumber(y, 10) or 0
                        info.width = tonumber(width, 10) or 0
                        info.height = tonumber(height, 10) or 0
                        info.scale_x = 1
                        info.scale_y = 1
                        info.display_width = info.width
                        info.display_height = info.height

                        log("Parsed the following display information\n" .. format_table(info))

                        if info.width == 0 and info.height == 0 then
                            info = nil
                        end
                    end
                end

                obs.obs_properties_destroy(props)
            end
        end
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h,
            scale_x = monitor_override_sx,
            scale_y = monitor_override_sy,
            display_width = monitor_override_dw,
            display_height = monitor_override_dh
        }
    end

    if not info then
        log("WARNING: Could not auto calculate zoom source position and size.\n" ..
            "         Try using the 'Set manual source position' option and adding override values")
    end

    return info
end

---
-- Check to see if the specified source is a display capture source
-- If the source_to_check is nil then the answer will be false
---@param source_to_check any The source to check
---@return boolean result True if source is a display capture, false if it nil or some other source type
function is_display_capture(source_to_check)
    if source_to_check ~= nil then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            -- Do a quick check to ensure this is a display capture
            if allow_all_sources then
                local source_type = obs.obs_source_get_id(source_to_check)
                if source_type == dc_info.source_id then
                    return true
                end
            else
                return true
            end
        end
    end

    return false
end

---
-- Releases the current sceneitem and resets data back to default
function release_sceneitem()
    if is_timer_running then
        obs.timer_remove(on_timer)
        is_timer_running = false
    end

    zoom_state = ZoomState.None

    if sceneitem ~= nil then
        if crop_filter ~= nil and source ~= nil then
            log("Zoom crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("Conversion crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if sceneitem_info_orig ~= nil then
            log("Transform info reset back to original")
            set_sceneitem_transform(sceneitem, sceneitem_info_orig)
            sceneitem_info_orig = nil
        end

        if sceneitem_crop_orig ~= nil then
            log("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop_orig)
            sceneitem_crop_orig = nil
        end

        obs.obs_sceneitem_release(sceneitem)
        sceneitem = nil
    end

    if source ~= nil then
        obs.obs_source_release(source)
        source = nil
    end
end

---
-- Updates the current sceneitem with a refreshed set of data from the source
-- Optionally will release the existing sceneitem and get a new one from the current scene
---@param find_newest boolean True to release the current sceneitem and get a new one
function refresh_sceneitem(find_newest)
    -- TODO: Figure out why we need to get the size from the named source during update instead of via the sceneitem source
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        -- Release the current sceneitem now that we are replacing it
        release_sceneitem()

        -- Quit early if we are using no zoom source
        -- This allows users to reset the crop data back to the original,
        -- update it, and then force the conversion to happen by re-selecting it.
        if source_name == "obs-zoom-to-mouse-none" then
            return
        end

        -- Get a matching source we can use for zooming in the current scene
        log("Finding sceneitem for Zoom Source '" .. source_name .. "'")
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                -- Get the source size, for some reason this works during load but the sceneitem source doesn't
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                -- Get the current scene
                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local function find_scene_item_by_name(root_scene)
                        local queue = {}
                        table.insert(queue, root_scene)

                        while #queue > 0 do
                            local s = table.remove(queue, 1)
                            log("Looking in scene '" .. obs.obs_source_get_name(obs.obs_scene_get_source(s)) .. "'")

                            -- Check if the current scene has the target scene item
                            local found = obs.obs_scene_find_source(s, source_name)
                            if found ~= nil then
                                log("Found sceneitem '" .. source_name .. "'")
                                obs.obs_sceneitem_addref(found)
                                return found
                            end

                            -- If the current scene has nested scenes, enqueue them for later examination
                            local all_items = obs.obs_scene_enum_items(s)
                            if all_items then
                                for _, item in pairs(all_items) do
                                    local nested = obs.obs_sceneitem_get_source(item)
                                    if nested ~= nil and obs.obs_source_is_scene(nested) then
                                        local nested_scene = obs.obs_scene_from_source(nested)
                                        table.insert(queue, nested_scene)
                                    end
                                end
                                obs.sceneitem_list_release(all_items)
                            end
                        end

                        return nil
                    end

                    -- Find the sceneitem for the source_name by looking through all the items
                    -- We start at the current scene and use a BFS to look into any nested scenes
                    local current = obs.obs_scene_from_source(scene_source)
                    sceneitem = find_scene_item_by_name(current)

                    obs.obs_source_release(scene_source)
                end

                if not sceneitem then
                    log("WARNING: Source not part of the current scene hierarchy.\n" ..
                        "         Try selecting a different zoom source or switching scenes.")
                    obs.obs_sceneitem_release(sceneitem)
                    obs.obs_source_release(source)

                    sceneitem = nil
                    source = nil
                    return
                end
            end
        end
    end

    if not monitor_info then
        monitor_info = get_monitor_info(source)
    end

    local is_non_display_capture = not is_display_capture(source)
    if is_non_display_capture then
        if not use_monitor_override then
            log("ERROR: Selected Zoom Source is not a display capture source.\n" ..
                "       You MUST enable 'Set manual source position' and set the correct override values for size and position.")
        end
    end

    if sceneitem ~= nil then
        -- Capture the original settings so we can restore them later
        -- Use our helper function for OBS 30+ compatibility
        sceneitem_info_orig = get_sceneitem_transform(sceneitem)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = get_sceneitem_transform(sceneitem)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        if is_non_display_capture then
            -- Non-Display Capture sources don't correctly report crop values
            sceneitem_crop_orig.left = 0
            sceneitem_crop_orig.top = 0
            sceneitem_crop_orig.right = 0
            sceneitem_crop_orig.bottom = 0
        end

        -- Get the current source size (this will be the value after any applied crop filters)
        if not source then
            log("ERROR: Could not get source for sceneitem (" .. source_name .. ")")
        end

        -- TODO: Figure out why we need this fallback code
        local source_width = obs.obs_source_get_base_width(source)
        local source_height = obs.obs_source_get_base_height(source)

        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        if source_width == 0 or source_height == 0 then
            log("ERROR: Something went wrong determining source size." ..
                "       Try using the 'Set manual source position' option and adding override values")

            if monitor_info ~= nil then
                source_width = monitor_info.width
                source_height = monitor_info.height
            end
        else
            log("Using source size: " .. source_width .. ", " .. source_height)
        end

        -- Note: Check for any existing crop filters
        local has_crop_filter = false
        local crop_filter_check = obs.obs_source_get_filter_by_name(source, CROP_FILTER_NAME)
        if crop_filter_check ~= nil then
            -- We already have a crop filter which means we might be currently zooming in
            crop_filter = crop_filter_check
            has_crop_filter = true
            crop_filter_settings = obs.obs_source_get_settings(crop_filter)
            crop_filter_info = {
                x = obs.obs_data_get_int(crop_filter_settings, "left"),
                y = obs.obs_data_get_int(crop_filter_settings, "top"),
                w = source_width - obs.obs_data_get_int(crop_filter_settings, "left") - obs.obs_data_get_int(crop_filter_settings, "right"),
                h = source_height - obs.obs_data_get_int(crop_filter_settings, "top") - obs.obs_data_get_int(crop_filter_settings, "bottom")
            }
            crop_filter_info_orig = {
                x = crop_filter_info.x,
                y = crop_filter_info.y,
                w = crop_filter_info.w,
                h = crop_filter_info.h
            }
            log("Existing crop filter found. Using crop: " .. format_table(crop_filter_info))
        end

        -- Store the zoom info to be used by the zoom calculation
        zoom_info = {
            source_size = { width = source_width, height = source_height },
            source_crop = {
                x = sceneitem_crop.left,
                y = sceneitem_crop.top,
                w = source_width - sceneitem_crop.left - sceneitem_crop.right,
                h = source_height - sceneitem_crop.top - sceneitem_crop.bottom
            },
            source_crop_filter = {
                x = crop_filter_info.x,
                y = crop_filter_info.y,
                w = crop_filter_info.w,
                h = crop_filter_info.h
            },
            zoom_to = zoom_value
        }

        log("Using zoom info:\n" .. format_table(zoom_info))

        -- If we don't already have a crop filter, then convert the sceneitem crop into our own filter
        -- We do this so we can freely animate the crop box ourselves which we need for the zoom logic
        if not has_crop_filter then
            -- Convert to the crop/pad to a scale filter crop, removing the original source crop
            local has_sceneitem_crop = (sceneitem_crop.left > 0 or sceneitem_crop.top > 0 or sceneitem_crop.right > 0 or sceneitem_crop.bottom > 0)
            if has_sceneitem_crop then
                -- Remove the sceneitem crop (add a filter crop version right after)
                local reset_crop = obs.obs_sceneitem_crop()
                obs.obs_sceneitem_set_crop(sceneitem, reset_crop)

                -- NOTE: This adds an extra temporary filter to show to the user that when we release it, we also need to remove this filter
                -- and add the existing crop back into the transform crop if it was there before
                crop_filter_temp = obs.obs_source_create_private("crop_filter", "obs-zoom-to-mouse-conversion-crop", nil)
                obs.obs_source_filter_add(source, crop_filter_temp)
                local settings = obs.obs_source_get_settings(crop_filter_temp)
                obs.obs_data_set_int(settings, "left", sceneitem_crop.left)
                obs.obs_data_set_int(settings, "top", sceneitem_crop.top)
                obs.obs_data_set_int(settings, "right", sceneitem_crop.right)
                obs.obs_data_set_int(settings, "bottom", sceneitem_crop.bottom)
                obs.obs_source_update(crop_filter_temp, settings)
                obs.obs_data_release(settings)
                log("Conversion crop filter added")
            end

            -- Add a crop filter that we can use to animate the zoom
            crop_filter = obs.obs_source_create_private("crop_filter", CROP_FILTER_NAME, nil)
            obs.obs_source_filter_add(source, crop_filter)

            crop_filter_settings = obs.obs_source_get_settings(crop_filter)
            obs.obs_data_set_int(crop_filter_settings, "left", 0)
            obs.obs_data_set_int(crop_filter_settings, "top", 0)
            obs.obs_data_set_int(crop_filter_settings, "right", 0)
            obs.obs_data_set_int(crop_filter_settings, "bottom", 0)
            obs.obs_source_update(crop_filter, crop_filter_settings)
            log("Zoom crop filter added")
        end
    end
end

---
-- Get the relative position of the mouse for the given monitor
-- If the mouse is outside the bounds of the zoom source, returns nil
---@return table|nil mouse The { x = 0, y = 0 } position, or nil if not within the monitor bounds
function get_relative_mouse_pos()
    local mouse = get_mouse_pos()

    if monitor_info ~= nil then
        local x = mouse.x - monitor_info.x
        local y = mouse.y - monitor_info.y

        if monitor_info.scale_x ~= nil then
            x = x * monitor_info.scale_x
        end
        if monitor_info.scale_y ~= nil then
            y = y * monitor_info.scale_y
        end

        log("Mouse position on monitor: " .. x .. " x " .. y)

        -- Ensure the mouse is within the bounds of the zoom source
        if use_follow_outside_bounds or (x >= 0 and x <= zoom_info.source_size.width and y >= 0 and y <= zoom_info.source_size.height) then
            return { x = x, y = y }
        end
    end

    return nil
end

---
-- Calculate the current zoom rectangle
---@param from_rect table The crop rect position to zoom from (defaults to full source size)
---@param to_rect table The crop rect position to zoom to
---@return any result The zoom rect to use
function calc_zoom(from_rect, to_rect)
    local zoom_rect = { x = from_rect.x, y = from_rect.y, w = from_rect.w, h = from_rect.h }

    local t = ease_in_out(zoom_time)
    zoom_rect.w = lerp(from_rect.w, to_rect.w, t)
    zoom_rect.h = lerp(from_rect.h, to_rect.h, t)
    zoom_rect.x = lerp(from_rect.x, to_rect.x, t)
    zoom_rect.y = lerp(from_rect.y, to_rect.y, t)

    return zoom_rect
end

---
-- Calculate the crop rect target position that would be used as a target for zooming in towards
---@param to_zoom number The zoom factor
---@param center table|nil The center point of where we are zooming to (defaults to the current mouse position)
---@return table result The rect to use as the zoom-to target
function calc_target_rect(to_zoom, center)
    local target_width = zoom_info.source_size.width / to_zoom
    local target_height = zoom_info.source_size.height / to_zoom

    local target_rect = { x = 0, y = 0, w = target_width, h = target_height }
    center = center or get_relative_mouse_pos()

    if center ~= nil then
        local half_target_width = target_width / 2
        local half_target_height = target_height / 2

        local target_left = center.x - half_target_width
        local target_top = center.y - half_target_height
        local target_right = center.x + half_target_width
        local target_bottom = center.y + half_target_height

        -- Account for any existing crop on the source (from the crop/pad filter)
        local effective_width = zoom_info.source_size.width - zoom_info.source_crop_filter.x
        local effective_height = zoom_info.source_size.height - zoom_info.source_crop_filter.y

        -- Make sure we don't go outside of the bounds of the source
        if target_left < zoom_info.source_crop_filter.x then
            target_left = zoom_info.source_crop_filter.x
            target_right = target_left + target_width
        end
        if target_top < zoom_info.source_crop_filter.y then
            target_top = zoom_info.source_crop_filter.y
            target_bottom = target_top + target_height
        end
        if target_right > effective_width then
            target_right = effective_width
            target_left = target_right - target_width
        end
        if target_bottom > effective_height then
            target_bottom = effective_height
            target_top = target_bottom - target_height
        end

        target_rect.x = target_left
        target_rect.y = target_top
    end

    return target_rect
end

---
-- Update the crop filter settings to use the current zoom rect values
---@param zoom_rect table The zoom rect to apply to the crop filter
function apply_crop(zoom_rect)
    obs.obs_data_set_int(crop_filter_settings, "left", zoom_rect.x)
    obs.obs_data_set_int(crop_filter_settings, "top", zoom_rect.y)
    obs.obs_data_set_int(crop_filter_settings, "right", zoom_info.source_size.width - zoom_rect.x - zoom_rect.w)
    obs.obs_data_set_int(crop_filter_settings, "bottom", zoom_info.source_size.height - zoom_rect.y - zoom_rect.h)
    obs.obs_source_update(crop_filter, crop_filter_settings)
end

---
-- Callback for the timer
function on_timer()
    -- Only act if we are in a zooming mode
    if zoom_state == ZoomState.None then
        return
    end

    if zoom_state == ZoomState.ZoomingIn then
        -- Zoom into the target (mouse position) and lock to the initial position
        zoom_time = zoom_time + zoom_speed
        if zoom_time >= 1 then
            zoom_time = 1
            zoom_state = ZoomState.ZoomedIn

            if use_auto_follow_mouse then
                is_following_mouse = true
            end
        end

        local zoom_rect = calc_zoom(zoom_info.source_crop_filter, zoom_target)
        apply_crop(zoom_rect)
    elseif zoom_state == ZoomState.ZoomingOut then
        -- Zoom out of the target and zoom the full source
        zoom_time = zoom_time + zoom_speed
        if zoom_time >= 1 then
            zoom_time = 1
            zoom_state = ZoomState.None
        end

        local zoom_rect = calc_zoom(zoom_target, crop_filter_info_orig)
        apply_crop(zoom_rect)
    elseif zoom_state == ZoomState.ZoomedIn then
        -- Track the mouse
        local zoom_rect = { x = zoom_target.x, y = zoom_target.y, w = zoom_target.w, h = zoom_target.h }
        local mouse = get_relative_mouse_pos()

        if mouse == nil then
            -- The mouse has left the monitor, either stop tracking or keep it in its current position (no work needed)
            if not use_follow_outside_bounds then
                return
            end
        else
            -- Only move if we are following the mouse around
            if is_following_mouse then
                -- Check if the mouse is within the 'follow border' area of the view
                -- If it's inside that area, then don't move unless we want to follow it
                local border = follow_border
                local ew = (zoom_target.w / 100) * border
                local eh = (zoom_target.h / 100) * border
                local left_edge = zoom_target.x + ew
                local right_edge = zoom_target.x + zoom_target.w - ew
                local top_edge = zoom_target.y + eh
                local bottom_edge = zoom_target.y + zoom_target.h - eh

                local enable_tracking_to_left = mouse.x <= left_edge
                local enable_tracking_to_right = mouse.x >= right_edge
                local enable_tracking_to_top = mouse.y <= top_edge
                local enable_tracking_to_bottom = mouse.y >= bottom_edge

                log(string.format("rect=%f,%f  mouse=%f,%f  edges=%f,%f,%f,%f  tracking=l:%s,r:%s,t:%s,b:%s",
                    zoom_target.x, zoom_target.y, mouse.x, mouse.y, left_edge, right_edge, top_edge, bottom_edge,
                    tostring(enable_tracking_to_left), tostring(enable_tracking_to_right), tostring(enable_tracking_to_top), tostring(enable_tracking_to_bottom)))

                -- Track the mouse
                local track_target = calc_target_rect(zoom_info.zoom_to, mouse)

                if locked_center ~= nil then
                    -- We are locked but the mouse is moving back to the edge so we should unlock it
                    local unlock_from_left = enable_tracking_to_left and mouse.x < locked_last_pos.x
                    local unlock_from_right = enable_tracking_to_right and mouse.x > locked_last_pos.x
                    local unlock_from_top = enable_tracking_to_top and mouse.y < locked_last_pos.y
                    local unlock_from_bottom = enable_tracking_to_bottom and mouse.y > locked_last_pos.y

                    if unlock_from_left or unlock_from_right or unlock_from_top or unlock_from_bottom then
                        locked_center = nil
                        locked_last_pos = nil
                    end
                end

                if locked_center == nil then
                    if enable_tracking_to_left or enable_tracking_to_right or enable_tracking_to_top or enable_tracking_to_bottom then
                        zoom_rect.x = lerp(zoom_target.x, track_target.x, follow_speed)
                        zoom_rect.y = lerp(zoom_target.y, track_target.y, follow_speed)
                    end

                    -- Snap to center once we're close enough (this helps smooth out micro movements)
                    local center_x = zoom_rect.x + (zoom_rect.w / 2)
                    local center_y = zoom_rect.y + (zoom_rect.h / 2)

                    local safezone_distance_x = (zoom_target.w / 100) * follow_safezone_sensitivity
                    local safezone_distance_y = (zoom_target.h / 100) * follow_safezone_sensitivity
                    local within_x = math.abs(center_x - mouse.x) < safezone_distance_x
                    local within_y = math.abs(center_y - mouse.y) < safezone_distance_y

                    if within_x and within_y then
                        -- Center the zoom position on the mouse now that it's close enough and lock the position (prevent micro movements)
                        if use_follow_auto_lock then
                            zoom_rect.x = mouse.x - (zoom_rect.w / 2)
                            zoom_rect.y = mouse.y - (zoom_rect.h / 2)
                            locked_center = { x = zoom_rect.x, y = zoom_rect.y }
                            locked_last_pos = { x = mouse.x, y = mouse.y }
                        end
                    end
                else
                    -- Use the locked position
                    zoom_rect.x = locked_center.x
                    zoom_rect.y = locked_center.y
                    locked_last_pos = { x = mouse.x, y = mouse.y }
                end

                zoom_target.x = zoom_rect.x
                zoom_target.y = zoom_rect.y
            end
        end

        apply_crop(zoom_rect)
    end
end

---
-- Callback for when the toggle zoom hotkey is pressed
---@param pressed boolean True if the hotkey was pressed, false otherwise
function on_toggle_zoom(pressed)
    if not pressed then
        return
    end

    if sceneitem == nil then
        log("ERROR: No zoom source found, please select a zoom source")
        return
    end

    if zoom_state == ZoomState.None then
        local mouse = get_relative_mouse_pos()
        if mouse == nil then
            log("ERROR: Mouse not within zoom source bounds")
            return
        end

        -- Get the target zoom position based on the current mouse location and start zooming in
        zoom_time = 0
        zoom_target = calc_target_rect(zoom_value)
        zoom_info.zoom_to = zoom_value
        locked_center = nil
        locked_last_pos = nil
        zoom_state = ZoomState.ZoomingIn
    elseif zoom_state == ZoomState.ZoomedIn then
        -- Start zooming out back to the original zoom
        zoom_time = 0
        is_following_mouse = false
        locked_center = nil
        locked_last_pos = nil
        zoom_state = ZoomState.ZoomingOut
    elseif zoom_state == ZoomState.ZoomingIn then
        -- We were zooming in, so zoom back out from our current position
        zoom_time = 1 - zoom_time
        is_following_mouse = false
        locked_center = nil
        locked_last_pos = nil
        zoom_state = ZoomState.ZoomingOut
    elseif zoom_state == ZoomState.ZoomingOut then
        -- We were zooming out, so zoom back in to where we were
        zoom_time = 1 - zoom_time
        locked_center = nil
        locked_last_pos = nil
        zoom_state = ZoomState.ZoomingIn
    end

    if not is_timer_running then
        obs.timer_add(on_timer, 16)
        is_timer_running = true
    end
end

---
-- Callback for when the toggle follow hotkey is pressed
---@param pressed boolean True if the hotkey was pressed, false otherwise
function on_toggle_follow(pressed)
    if not pressed then
        return
    end

    -- Toggle the follow mouse setting
    is_following_mouse = not is_following_mouse
    locked_center = nil
    locked_last_pos = nil
end

---
-- Callback for when the frontend event is triggered
---@param event number The OBS event
function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("Refreshing sceneitem due to scene change")
        refresh_sceneitem(true)
    end
end

---
-- Callback for when a transition starts
---@param event_data any The OBS event data
function on_transition_start(event_data)
    log("Refreshing sceneitem due to transition start")
    refresh_sceneitem(true)
end

---
-- Callback for when the settings are modified
---@param props any The properties
---@param prop any The property that changed
---@param settings any The settings
---@return boolean result
function on_settings_modified(props, prop, settings)
    -- Update the settings visibility
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    local sources_list = obs.obs_properties_get(props, "source")
    local override_x = obs.obs_properties_get(props, "monitor_override_x")
    local override_y = obs.obs_properties_get(props, "monitor_override_y")
    local override_w = obs.obs_properties_get(props, "monitor_override_w")
    local override_h = obs.obs_properties_get(props, "monitor_override_h")
    local override_sx = obs.obs_properties_get(props, "monitor_override_sx")
    local override_sy = obs.obs_properties_get(props, "monitor_override_sy")
    local override_dw = obs.obs_properties_get(props, "monitor_override_dw")
    local override_dh = obs.obs_properties_get(props, "monitor_override_dh")

    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_visible(override_sx, use_monitor_override)
    obs.obs_property_set_visible(override_sy, use_monitor_override)
    obs.obs_property_set_visible(override_dw, use_monitor_override)
    obs.obs_property_set_visible(override_dh, use_monitor_override)

    populate_zoom_sources(sources_list)

    return true
end

---
-- Log the current settings
function log_current_settings()
    local settings = {
        source_name = source_name,
        version = major .. "." .. minor,
        zoom_value = zoom_value,
        zoom_speed = zoom_speed,
        use_auto_follow_mouse = use_auto_follow_mouse,
        use_follow_outside_bounds = use_follow_outside_bounds,
        follow_speed = follow_speed,
        follow_border = follow_border,
        follow_safezone_sensitivity = follow_safezone_sensitivity,
        use_follow_auto_lock = use_follow_auto_lock,
        use_monitor_override = use_monitor_override,
        monitor_override_x = monitor_override_x,
        monitor_override_y = monitor_override_y,
        monitor_override_w = monitor_override_w,
        monitor_override_h = monitor_override_h,
        monitor_override_sx = monitor_override_sx,
        monitor_override_sy = monitor_override_sy,
        monitor_override_dw = monitor_override_dw,
        monitor_override_dh = monitor_override_dh,
        debug_logs = debug_logs
    }

    log("OBS Version: " .. major .. "." .. minor)
    log("Current settings:")
    log(format_table(settings))
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "Help Information for OBS-Zoom-To-Mouse v" .. VERSION .. "\n" ..
        "https://github.com/BlankSourceCode/obs-zoom-to-mouse\n" ..
        "----------------------------------------------------\n" ..
        "This script will zoom the selected display-capture source to focus on the mouse\n\n" ..
        "Zoom Source: The display capture in the current scene to use for zooming\n" ..
        "Zoom Factor: How much to zoom in by\n" ..
        "Zoom Speed: The speed of the zoom in/out animation\n" ..
        "Auto follow mouse: True to track the cursor while you are zoomed in\n" ..
        "Follow outside bounds: True to track the cursor even when it is outside the bounds of the source\n" ..
        "Follow Speed: The speed at which the zoomed area will follow the mouse when tracking\n" ..
        "Follow Border: The %distance from the edge of the source that will re-enable mouse tracking\n" ..
        "Lock Sensitivity: How close the tracking needs to get before it locks into position and stops tracking until you enter the follow border\n" ..
        "Auto Lock on reverse direction: Automatically stop tracking if you reverse the direction of the mouse\n" ..
        "Show all sources: True to allow selecting any source as the Zoom Source - You MUST set manual source position for non-display capture sources\n" ..
        "Set manual source position: True to override the calculated x/y (topleft position), width/height (size), and scaleX/scaleY (canvas scale factor) for the selected source\n" ..
        "X: The coordinate of the left most pixel of the source\n" ..
        "Y: The coordinate of the top most pixel of the source\n" ..
        "Width: The width of the source (in pixels)\n" ..
        "Height: The height of the source (in pixels)\n" ..
        "Scale X: The x scale factor to apply to the mouse position if the source size is not 1:1 (useful for cloned sources)\n" ..
        "Scale Y: The y scale factor to apply to the mouse position if the source size is not 1:1 (useful for cloned sources)\n" ..
        "Monitor Width: The width of the monitor that is showing the source (in pixels)\n" ..
        "Monitor Height: The height of the monitor that is showing the source (in pixels)\n" ..
        "More Info: Show this text in the script log\n" ..
        "Enable debug logging: Show additional debug information in the script log\n\n"

    obs.script_log(obs.OBS_LOG_INFO, help)
end

function script_description()
    return "Zoom the selected display-capture source to focus on the mouse\n\n" ..
           "Fixed for macOS Apple Silicon (M1/M2/M3) and OBS Studio 30+/32+\n" ..
           "Version: " .. VERSION
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Populate the sources list with the known display-capture sources
    local sources_list = obs.obs_properties_add_list(props, "source", "Zoom Source", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)

    populate_zoom_sources(sources_list)

    local refresh_sources = obs.obs_properties_add_button(props, "refresh", "Refresh zoom sources",
        function()
            populate_zoom_sources(sources_list)
            monitor_info = get_monitor_info(source)
            return true
        end)
    obs.obs_property_set_long_description(refresh_sources,
        "Click to re-populate Zoom Sources dropdown with available sources")

    -- Add the rest of the settings UI
    local zoom = obs.obs_properties_add_float(props, "zoom_value", "Zoom Factor", 1, 5, 0.5)
    local zoom_speed = obs.obs_properties_add_float_slider(props, "zoom_speed", "Zoom Speed", 0.01, 1, 0.01)
    local follow = obs.obs_properties_add_bool(props, "follow", "Auto follow mouse ")
    obs.obs_property_set_long_description(follow,
        "When enabled mouse tracking will auto-start when zoomed in without waiting for tracking toggle hotkey")

    local follow_outside_bounds = obs.obs_properties_add_bool(props, "follow_outside_bounds", "Follow outside bounds ")
    obs.obs_property_set_long_description(follow_outside_bounds,
        "When enabled the mouse will be tracked even when the cursor is outside the bounds of the zoom source")

    local follow_speed = obs.obs_properties_add_float_slider(props, "follow_speed", "Follow Speed", 0.01, 1, 0.01)
    local follow_border = obs.obs_properties_add_int_slider(props, "follow_border", "Follow Border", 0, 50, 1)
    local safezone_sense = obs.obs_properties_add_int_slider(props,
        "follow_safezone_sensitivity", "Lock Sensitivity", 1, 20, 1)
    local follow_auto_lock = obs.obs_properties_add_bool(props, "follow_auto_lock", "Auto Lock on reverse direction ")
    obs.obs_property_set_long_description(follow_auto_lock,
        "When enabled moving the mouse to edge of the zoom source will begin tracking,\n" ..
        "but moving back towards the center will stop tracking similar to panning the camera in a RTS game")

    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "Allow any zoom source ")
    obs.obs_property_set_long_description(allow_all, "Enable to allow selecting any source as the Zoom Source\n" ..
        "You MUST set manual source position for non-display capture sources")

    local override = obs.obs_properties_add_bool(props, "use_monitor_override", "Set manual source position ")
    obs.obs_property_set_long_description(override,
        "When enabled the specified size/position settings will be used for the zoom source instead of the auto-calculated ones")

    local override_x = obs.obs_properties_add_int(props, "monitor_override_x", "X", -10000, 10000, 1)
    local override_y = obs.obs_properties_add_int(props, "monitor_override_y", "Y", -10000, 10000, 1)
    local override_w = obs.obs_properties_add_int(props, "monitor_override_w", "Width", 0, 10000, 1)
    local override_h = obs.obs_properties_add_int(props, "monitor_override_h", "Height", 0, 10000, 1)
    local override_sx = obs.obs_properties_add_float(props, "monitor_override_sx", "Scale X ", 0, 100, 0.01)
    local override_sy = obs.obs_properties_add_float(props, "monitor_override_sy", "Scale Y ", 0, 100, 0.01)
    local override_dw = obs.obs_properties_add_int(props, "monitor_override_dw", "Monitor Width ", 0, 10000, 1)
    local override_dh = obs.obs_properties_add_int(props, "monitor_override_dh", "Monitor Height ", 0, 10000, 1)

    obs.obs_property_set_long_description(override_sx, "Usually 1 - unless you are using a scaled source")
    obs.obs_property_set_long_description(override_sy, "Usually 1 - unless you are using a scaled source")
    obs.obs_property_set_long_description(override_dw, "X resolution of your monitor")
    obs.obs_property_set_long_description(override_dh, "Y resolution of your monitor")

    -- Add a button for more information
    local help = obs.obs_properties_add_button(props, "help_button", "More Info", on_print_help)
    obs.obs_property_set_long_description(help,
        "Click to show help information (via the script log)")

    local debug = obs.obs_properties_add_bool(props, "debug_logs", "Enable debug logging ")
    obs.obs_property_set_long_description(debug,
        "When enabled the script will output diagnostics messages to the script log (useful for debugging/github issues)")

    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_visible(override_sx, use_monitor_override)
    obs.obs_property_set_visible(override_sy, use_monitor_override)
    obs.obs_property_set_visible(override_dw, use_monitor_override)
    obs.obs_property_set_visible(override_dh, use_monitor_override)
    obs.obs_property_set_modified_callback(override, on_settings_modified)
    obs.obs_property_set_modified_callback(allow_all, on_settings_modified)
    obs.obs_property_set_modified_callback(debug, on_settings_modified)

    return props
end

function script_load(settings)
    sceneitem_info_orig = nil

    -- Add our hotkey
    hotkey_zoom_id = obs.obs_hotkey_register_frontend("toggle_zoom_hotkey", "Toggle zoom to mouse",
        on_toggle_zoom)

    hotkey_follow_id = obs.obs_hotkey_register_frontend("toggle_follow_hotkey", "Toggle follow mouse during zoom",
        on_toggle_follow)

    -- Attempt to reload existing hotkey bindings if we can find any
    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom")
    obs.obs_hotkey_load(hotkey_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.follow")
    obs.obs_hotkey_load(hotkey_follow_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    -- Load any other settings
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    -- Log macOS-specific info
    if ffi.os == "OSX" then
        if osx_cg_lib then
            obs.script_log(obs.OBS_LOG_INFO, "OBS-Zoom-To-Mouse: CoreGraphics loaded successfully for Apple Silicon")
        else
            obs.script_log(obs.OBS_LOG_WARNING, "OBS-Zoom-To-Mouse: Failed to load CoreGraphics - mouse tracking may not work")
        end
    end
    
    obs.script_log(obs.OBS_LOG_INFO, "OBS-Zoom-To-Mouse: Using OBS " .. major .. "." .. minor .. " API (new_api=" .. tostring(use_new_api) .. ")")

    -- Add the transition_start event handlers to each transition
    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = obs.obs_source_get_name(s)
            log("Adding transition_start listener to " .. name)
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    if ffi.os == "Linux" and not x11_display then
        log("ERROR: Could not get X11 Display for Linux\n" ..
            "Mouse position will be incorrect.")
    end
end

function script_unload()
    -- Clean up the memory usage
    if major >= 30 then
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for i, s in pairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        obs.obs_hotkey_unregister(on_toggle_zoom)
        obs.obs_hotkey_unregister(on_toggle_follow)
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
    end
end

function script_defaults(settings)
    -- Default values for the script
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.25)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "allow_all_sources", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    obs.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    obs.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)
end

function script_save(settings)
    -- Save the custom hotkey information
    if hotkey_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_follow_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_follow_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.follow", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

function script_update(settings)
    local old_source_name = source_name
    local old_override = use_monitor_override
    local old_x = monitor_override_x
    local old_y = monitor_override_y
    local old_w = monitor_override_w
    local old_h = monitor_override_h
    local old_sx = monitor_override_sx
    local old_sy = monitor_override_sy
    local old_dw = monitor_override_dw
    local old_dh = monitor_override_dh

    -- Update the settings
    source_name = obs.obs_data_get_string(settings, "source")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    -- Only do the expensive refresh if the user selected a new source
    if source_name ~= old_source_name then
        refresh_sceneitem(true)
    end

    -- Update the monitor_info if the settings changed
    if source_name ~= old_source_name or
        use_monitor_override ~= old_override or
        monitor_override_x ~= old_x or
        monitor_override_y ~= old_y or
        monitor_override_w ~= old_w or
        monitor_override_h ~= old_h or
        monitor_override_sx ~= old_sx or
        monitor_override_sy ~= old_sy or
        monitor_override_w ~= old_dw or
        monitor_override_h ~= old_dh then
        monitor_info = get_monitor_info(source)
    end
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<None>", "obs-zoom-to-mouse-none")
        for _, source in ipairs(sources) do
            local source_type = obs.obs_source_get_id(source)
            if dc_info and (source_type == dc_info.source_id or allow_all_sources) then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end

        obs.source_list_release(sources)
    end
end
