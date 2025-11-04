-- OBS Zoom to Mouse
-- An OBS lua script to zoom a display-capture source to focus on the mouse.
-- Copyright (c) BlankSourceCode.  All rights reserved.
--

local obs = obslua
local ffi = require("ffi")
local VERSION = "1.1.0"
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
local x11_lib = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil
local osx_cg_lib = nil

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

--- State variables
local last_applied_crop = { x = -99999, y = -99999, w = -99999, h = -99999 }
local CROP_UPDATE_THRESHOLD = 0.5
local last_polled_mouse = { x = 0, y = 0 }
local last_mouse_poll_time = 0
local MOUSE_POLL_INTERVAL_MS = 30

-- Deferred refresh state to avoid race conditions during startup
local deferred_refresh_pending = false
local deferred_find_newest = true
local size_retry_attempts = 0
local SIZE_RETRY_MAX = 10

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

local version = obs.obs_get_version_string()
local major = tonumber(version:match("(%d+%.%d+)")) or 0

--- API compatibility helpers to handle renamed functions in newer OBS versions
local function sceneitem_get_info(item, info)
    if obs.obs_sceneitem_get_info ~= nil then
        return obs.obs_sceneitem_get_info(item, info)
    elseif obs.obs_sceneitem_get_info2 ~= nil then
        return obs.obs_sceneitem_get_info2(item, info)
    end
end

local function sceneitem_set_info(item, info)
    if obs.obs_sceneitem_set_info ~= nil then
        return obs.obs_sceneitem_set_info(item, info)
    elseif obs.obs_sceneitem_set_info2 ~= nil then
        return obs.obs_sceneitem_set_info2(item, info)
    end
end

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

    local ok, lib = pcall(function() return ffi.load("X11.so.6") end)
    if ok and lib ~= nil then
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
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;
        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
    ]])

    local ok, lib = pcall(function() return ffi.load("libobjc") end)
    if ok and lib ~= nil then
        osx_lib = lib
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            if imp ~= nil then
                osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
            end
        end
        local okcg, cglib = pcall(function() return ffi.load("CoreGraphics") end)
        if okcg and cglib ~= nil then
            osx_cg_lib = cglib
            ffi.cdef([[
                typedef unsigned int CGDirectDisplayID;
                CGDirectDisplayID CGMainDisplayID(void);
                size_t CGDisplayPixelsHigh(CGDirectDisplayID display);
            ]])
        end
    end
end

---
-- Get the current mouse position (raw FFI call)
---@return table Mouse position
function get_mouse_pos_raw()
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
        if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
            local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
            mouse.x = point.x
            local display_height = nil
            if monitor_info ~= nil then
                if monitor_info.display_height and monitor_info.display_height > 0 then
                    display_height = monitor_info.display_height
                elseif monitor_info.height and monitor_info.height > 0 then
                    display_height = monitor_info.height
                end
            end
            if (display_height == nil or display_height == 0) and osx_cg_lib ~= nil then
                local did = osx_cg_lib.CGMainDisplayID()
                display_height = tonumber(osx_cg_lib.CGDisplayPixelsHigh(did))
            end
            if display_height ~= nil and display_height > 0 then
                mouse.y = display_height - point.y
            else
                mouse.y = point.y
            end
        end
    end
    return mouse
end

--- Mouse polling throttled to reduce FFI calls
function get_mouse_pos()
    local t = os.clock() * 1000
    if (t - last_mouse_poll_time) >= MOUSE_POLL_INTERVAL_MS then
        local m = get_mouse_pos_raw()
        last_polled_mouse.x = m.x
        last_polled_mouse.y = m.y
        last_mouse_poll_time = t
    end
    return { x = last_polled_mouse.x, y = last_polled_mouse.y }
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
        if major > 29.0 then
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

--- Logs a message to the OBS script console
function log(msg, level)
    level = level or "INFO"
    if level == "ERROR" then obs.script_log(obs.OBS_LOG_ERROR, msg)
    elseif level == "WARNING" then obs.script_log(obs.OBS_LOG_WARNING, msg)
    elseif level == "INFO" then
        if debug_logs then obs.script_log(obs.OBS_LOG_INFO, msg) end
    elseif level == "DEBUG" then
        if debug_logs then obs.script_log(obs.OBS_LOG_DEBUG, msg) end
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
-- Get the size and position of the monitor so that we know the top-left mouse point
---@param source any The OBS source
---@return table|nil monitor_info The monitor size/top-left point
function get_monitor_info(source)
    local info = nil

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

                    if found then
                        log("Parsing display name: " .. found, "DEBUG")
                        local x, y = found:match("(-?%d+),(-?%d+)")
                        local width, height = found:match("(%d+)x(%d+)")

                        if x and y and width and height then
                            info = { x = 0, y = 0, width = 0, height = 0 }
                            info.x = tonumber(x, 10)
                            info.y = tonumber(y, 10)
                            info.width = tonumber(width, 10)
                            info.height = tonumber(height, 10)
                            info.scale_x = 1
                            info.scale_y = 1
                            info.display_width = info.width
                            info.display_height = info.height

                            log("Parsed the following display information\n" .. format_table(info), "DEBUG")

                            if info.width == 0 and info.height == 0 then
                                info = nil
                            end
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
        -- Suppress warning at startup when no valid source is selected yet
        if source ~= nil and source_name ~= nil and source_name ~= "" and source_name ~= "obs-zoom-to-mouse-none" then
            log("Could not auto calculate zoom source position and size.\n" ..
                "         Try using the 'Set manual source position' option and adding override values", "WARNING")
        end
    end

    return info
end

---
-- Check to see if the specified source is a display capture source
---@param source_to_check any The source to check
---@return boolean result True if source is a display capture, false if it nil or some other source type
function is_display_capture(source_to_check)
    if source_to_check == nil then
        return false
    end

    -- If opted to allow any source, consider it "valid" for this check.
    -- The script later warns if it's not a display capture and manual overrides are not set.
    if allow_all_sources then
        return true
    end

    -- Otherwise, strictly check if it's a display capture source.
    local dc_info = get_dc_info()
    if dc_info ~= nil then
        local source_type = obs.obs_source_get_id(source_to_check)
        if source_type == dc_info.source_id then
            return true
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
            log("Zoom crop filter removed", "DEBUG")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("Conversion crop filter removed", "DEBUG")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if sceneitem_info_orig ~= nil then
            log("Transform info reset back to original", "DEBUG")
            sceneitem_set_info(sceneitem, sceneitem_info_orig)
            sceneitem_info_orig = nil
        end

        if sceneitem_crop_orig ~= nil then
            log("Transform crop reset back to original", "DEBUG")
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
---@param find_newest boolean True to release the current sceneitem and get a new one
function refresh_sceneitem(find_newest)
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        release_sceneitem()

        if source_name == "obs-zoom-to-mouse-none" then
            return
        end

        log("Finding sceneitem for Zoom Source '" .. source_name .. "'", "DEBUG")
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local function find_scene_item_by_name(root_scene)
                        local queue = {}
                        table.insert(queue, root_scene)
                        while #queue > 0 do
                            local s = table.remove(queue, 1)
                            log("Looking in scene '" .. obs.obs_source_get_name(obs.obs_scene_get_source(s)) .. "'", "DEBUG")

                            local found = obs.obs_scene_find_source(s, source_name)
                            if found ~= nil then
                                log("Found sceneitem '" .. source_name .. "'", "DEBUG")
                                obs.obs_sceneitem_addref(found)
                                return found
                            end

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

                    local current = obs.obs_scene_from_source(scene_source)
                    sceneitem = find_scene_item_by_name(current)
                    obs.obs_source_release(scene_source)
                end

                if not sceneitem then
                    log("Source not part of the current scene hierarchy.\n" ..
                        "         Try selecting a different zoom source or switching scenes.", "WARNING")
                    if sceneitem then obs.obs_sceneitem_release(sceneitem) end
                    if source then obs.obs_source_release(source) end
                    sceneitem = nil
                    source = nil
                    return
                end
            end
        end
    end

    if not monitor_info and source ~= nil then
        monitor_info = get_monitor_info(source)
    end
    
    if source and not is_display_capture(source) and not use_monitor_override then
        log("Selected Zoom Source is not a display capture source.\n" ..
            "       You MUST enable 'Set manual source position' and set the correct override values for size and position.", "ERROR")
    end

    if sceneitem ~= nil then
        sceneitem_info_orig = obs.obs_transform_info()
        sceneitem_get_info(sceneitem, sceneitem_info_orig)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = obs.obs_transform_info()
        sceneitem_get_info(sceneitem, sceneitem_info)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        if not is_display_capture(source) then
            sceneitem_crop_orig.left = 0
            sceneitem_crop_orig.top = 0
            sceneitem_crop_orig.right = 0
            sceneitem_crop_orig.bottom = 0
        end

        if not source then
            log("Could not get source for sceneitem (" .. source_name .. ")", "ERROR")
        end

        local source_width = obs.obs_source_get_base_width(source)
        local source_height = obs.obs_source_get_base_height(source)

        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        if source_width == 0 or source_height == 0 then
            -- Defer and retry source size detection a few times during startup
            if source ~= nil and source_name ~= nil and source_name ~= "" and source_name ~= "obs-zoom-to-mouse-none" and size_retry_attempts < SIZE_RETRY_MAX then
                size_retry_attempts = size_retry_attempts + 1
                refresh_sceneitem_deferred(find_newest, 150)
                return
            end
            size_retry_attempts = 0
            -- Only warn if a specific, non-None source is selected
            if source ~= nil and source_name ~= nil and source_name ~= "" and source_name ~= "obs-zoom-to-mouse-none" then
                log("Something went wrong determining source size." ..
                    "       Try using the 'Set manual source position' option and adding override values", "ERROR")
            end

            if monitor_info ~= nil then
                source_width = monitor_info.width
                source_height = monitor_info.height
            end
        else
            size_retry_attempts = 0
            log("Using source size: " .. source_width .. ", " .. source_height, "DEBUG")
        end

        if sceneitem_info.bounds_type == obs.OBS_BOUNDS_NONE then
            sceneitem_info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
            sceneitem_info.bounds_alignment = 5
            sceneitem_info.bounds.x = source_width * sceneitem_info.scale.x
            sceneitem_info.bounds.y = source_height * sceneitem_info.scale.y
            sceneitem_set_info(sceneitem, sceneitem_info)
            log("Found existing non-boundingbox transform. This may cause issues with zooming.\n" ..
                "         Settings have been auto converted to a bounding box scaling transfrom instead.\n" ..
                "         If you have issues with your layout consider making the transform use a bounding box manually.", "WARNING")
        end

        zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
        local found_crop_filter = false
        local filters = obs.obs_source_enum_filters(source)
        if filters ~= nil then
            for _, v in pairs(filters) do
                if obs.obs_source_get_id(v) == "crop_filter" then
                    local name = obs.obs_source_get_name(v)
                    if name ~= CROP_FILTER_NAME and name ~= "temp_" .. CROP_FILTER_NAME then
                        found_crop_filter = true
                        local settings = obs.obs_source_get_settings(v)
                        if settings ~= nil then
                            if not obs.obs_data_get_bool(settings, "relative") then
                                zoom_info.source_crop_filter.x = zoom_info.source_crop_filter.x + obs.obs_data_get_int(settings, "left")
                                zoom_info.source_crop_filter.y = zoom_info.source_crop_filter.y + obs.obs_data_get_int(settings, "top")
                                zoom_info.source_crop_filter.w = zoom_info.source_crop_filter.w + obs.obs_data_get_int(settings, "cx")
                                zoom_info.source_crop_filter.h = zoom_info.source_crop_filter.h + obs.obs_data_get_int(settings, "cy")
                                log("Found existing relative crop/pad filter (" .. name .. "). Applying settings " .. format_table(zoom_info.source_crop_filter), "DEBUG")
                            else
                                log("Found existing non-relative crop/pad filter (" .. name .. ").\n" ..
                                    "         This will cause issues with zooming. Convert to relative settings instead.", "WARNING")
                            end
                            obs.obs_data_release(settings)
                        end
                    end
                end
            end
            obs.source_list_release(filters)
        end

        if not found_crop_filter and (sceneitem_crop_orig.left ~= 0 or sceneitem_crop_orig.top ~= 0 or sceneitem_crop_orig.right ~= 0 or sceneitem_crop_orig.bottom ~= 0) then
            log("Creating new crop filter", "DEBUG")
            source_width = source_width - (sceneitem_crop_orig.left + sceneitem_crop_orig.right)
            source_height = source_height - (sceneitem_crop_orig.top + sceneitem_crop_orig.bottom)
            zoom_info.source_crop_filter.x = sceneitem_crop_orig.left
            zoom_info.source_crop_filter.y = sceneitem_crop_orig.top
            zoom_info.source_crop_filter.w = source_width
            zoom_info.source_crop_filter.h = source_height

            local settings = obs.obs_data_create()
            obs.obs_data_set_bool(settings, "relative", false)
            obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
            obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
            obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
            obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
            crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
            obs.obs_source_filter_add(source, crop_filter_temp)
            obs.obs_data_release(settings)

            sceneitem_crop.left = 0
            sceneitem_crop.top = 0
            sceneitem_crop.right = 0
            sceneitem_crop.bottom = 0
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)
            log("Found existing transform crop. This may cause issues with zooming.\n" ..
                "         Settings have been auto converted to a relative crop/pad filter instead.\n" ..
                "         If you have issues with your layout consider making the filter manually.", "WARNING")
        elseif found_crop_filter then
            source_width = zoom_info.source_crop_filter.w
            source_height = zoom_info.source_crop_filter.h
        end

        zoom_info.source_size = { width = source_width, height = source_height }
        zoom_info.source_crop = {
            l = sceneitem_crop_orig.left,
            t = sceneitem_crop_orig.top,
            r = sceneitem_crop_orig.right,
            b = sceneitem_crop_orig.bottom
        }

        crop_filter_info_orig = { x = 0, y = 0, w = zoom_info.source_size.width, h = zoom_info.source_size.height }
        crop_filter_info = {
            x = crop_filter_info_orig.x,
            y = crop_filter_info_orig.y,
            w = crop_filter_info_orig.w,
            h = crop_filter_info_orig.h
        }

        crop_filter = obs.obs_source_get_filter_by_name(source, CROP_FILTER_NAME)
        if crop_filter == nil then
            crop_filter_settings = obs.obs_data_create()
            obs.obs_data_set_bool(crop_filter_settings, "relative", false)
            crop_filter = obs.obs_source_create_private("crop_filter", CROP_FILTER_NAME, crop_filter_settings)
            obs.obs_source_filter_add(source, crop_filter)
        else
            crop_filter_settings = obs.obs_source_get_settings(crop_filter)
        end
        obs.obs_source_filter_set_order(source, crop_filter, obs.OBS_ORDER_MOVE_BOTTOM)
        set_crop_settings(crop_filter_info_orig)
    end
end

---
-- Get the target position that we will attempt to zoom towards
---@param zoom any
---@return table
function get_target_position(zoom)
    local mouse = get_mouse_pos()

    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    mouse.x = mouse.x - zoom.source_crop_filter.x
    mouse.y = mouse.y - zoom.source_crop_filter.y

    if monitor_info and monitor_info.scale_x and monitor_info.scale_y then
        mouse.x = mouse.x * monitor_info.scale_x
        mouse.y = mouse.y * monitor_info.scale_y
    end

    local new_size = {
        width = zoom.source_size.width / zoom.zoom_to,
        height = zoom.source_size.height / zoom.zoom_to
    }

    local pos = {
        x = mouse.x - new_size.width * 0.5,
        y = mouse.y - new_size.height * 0.5
    }

    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))
    crop.y = math.floor(clamp(0, (zoom.source_size.height - new_size.height), crop.y))

    return { crop = crop, raw_center = mouse, clamped_center = { x = math.floor(crop.x + crop.w * 0.5), y = math.floor(crop.y + crop.h * 0.5) } }
end

function on_toggle_follow(pressed)
    if pressed then
        is_following_mouse = not is_following_mouse
        log("Tracking mouse is " .. (is_following_mouse and "on" or "off"), "DEBUG")

        if is_following_mouse and zoom_state == ZoomState.ZoomedIn then
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

--- Schedule a deferred refresh to let OBS finish initializing sources
function deferred_refresh_callback()
    deferred_refresh_pending = false
    obs.timer_remove(deferred_refresh_callback)
    refresh_sceneitem(deferred_find_newest)
end

function refresh_sceneitem_deferred(find_newest, delay_ms)
    delay_ms = delay_ms or 150
    deferred_find_newest = find_newest
    if deferred_refresh_pending then
        obs.timer_remove(deferred_refresh_callback)  -- Remove old timer
    end
    deferred_refresh_pending = true
    obs.timer_add(deferred_refresh_callback, delay_ms)
end

function on_toggle_zoom(pressed)
    if pressed then
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None then
            if zoom_state == ZoomState.ZoomedIn then
                log("Zooming out", "DEBUG")
                zoom_state = ZoomState.ZoomingOut
                zoom_time = 0
                locked_center = nil
                locked_last_pos = nil
                zoom_target = { crop = crop_filter_info_orig, c = sceneitem_crop_orig }
                if is_following_mouse then
                    is_following_mouse = false
                    log("Tracking mouse is off (due to zoom out)", "DEBUG")
                end
            else
                log("Zooming in", "DEBUG")
                zoom_state = ZoomState.ZoomingIn
                zoom_info.zoom_to = zoom_value
                zoom_time = 0
                locked_center = nil
                locked_last_pos = nil
                zoom_target = get_target_position(zoom_info)
            end

            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_timer()
    if crop_filter_info ~= nil and zoom_target ~= nil then
        zoom_time = zoom_time + zoom_speed

        if zoom_state == ZoomState.ZoomingOut or zoom_state == ZoomState.ZoomingIn then
            if zoom_time <= 1 then
                if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
                    zoom_target = get_target_position(zoom_info)
                end
                local eased_time = ease_in_out(zoom_time)
                crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, eased_time)
                crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, eased_time)
                crop_filter_info.w = lerp(crop_filter_info.w, zoom_target.crop.w, eased_time)
                crop_filter_info.h = lerp(crop_filter_info.h, zoom_target.crop.h, eased_time)
                set_crop_settings(crop_filter_info)
            end
        else
            if is_following_mouse then
                zoom_target = get_target_position(zoom_info)

                local skip_frame = false
                if not use_follow_outside_bounds then
                    if zoom_target.raw_center.x < zoom_target.crop.x or
                        zoom_target.raw_center.x > zoom_target.crop.x + zoom_target.crop.w or
                        zoom_target.raw_center.y < zoom_target.crop.y or
                        zoom_target.raw_center.y > zoom_target.crop.y + zoom_target.crop.h then
                        skip_frame = true
                    end
                end

                if not skip_frame then
                    if locked_center ~= nil then
                        local diff = {
                            x = zoom_target.raw_center.x - locked_center.x,
                            y = zoom_target.raw_center.y - locked_center.y
                        }
                        local track = {
                            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
                            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
                        }
                        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                            locked_center = nil
                            locked_last_pos = {
                                x = zoom_target.raw_center.x,
                                y = zoom_target.raw_center.y,
                                diff_x = diff.x,
                                diff_y = diff.y
                            }
                            log("Locked area exited - resume tracking", "DEBUG")
                        end
                    end

                    if locked_center == nil and (zoom_target.crop.x ~= crop_filter_info.x or zoom_target.crop.y ~= crop_filter_info.y) then
                        crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, follow_speed)
                        crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, follow_speed)
                        set_crop_settings(crop_filter_info)

                        if is_following_mouse and locked_center == nil and locked_last_pos ~= nil then
                            local diff = {
                                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                                y = math.abs(crop_filter_info.y - zoom_target.crop.y),
                                auto_x = zoom_target.raw_center.x - locked_last_pos.x,
                                auto_y = zoom_target.raw_center.y - locked_last_pos.y
                            }
                            locked_last_pos.x = zoom_target.raw_center.x
                            locked_last_pos.y = zoom_target.raw_center.y
                            local lock = false
                            if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                                if (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or (diff.auto_x > 0 and locked_last_pos.diff_x < 0) then
                                    lock = true
                                end
                            else
                                if (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or (diff.auto_y > 0 and locked_last_pos.diff_y < 0) then
                                    lock = true
                                end
                            end
                            if (lock and use_follow_auto_lock) or (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                                locked_center = {
                                    x = math.floor(crop_filter_info.x + zoom_target.crop.w * 0.5),
                                    y = math.floor(crop_filter_info.y + zoom_target.crop.h * 0.5)
                                }
                                log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y, "DEBUG")
                            end
                        end
                    end
                end
            end
        end

        if zoom_time >= 1 then
            local should_stop_timer = false
            if zoom_state == ZoomState.ZoomingOut then
                log("Zoomed out", "DEBUG")
                zoom_state = ZoomState.None
                should_stop_timer = true
            elseif zoom_state == ZoomState.ZoomingIn then
                log("Zoomed in", "DEBUG")
                zoom_state = ZoomState.ZoomedIn
                should_stop_timer = (not use_auto_follow_mouse) and (not is_following_mouse)
                if use_auto_follow_mouse then
                    is_following_mouse = true
                    log("Tracking mouse is " .. (is_following_mouse and "on" or "off") .. " (due to auto follow)", "DEBUG")
                end
                if is_following_mouse and follow_border < 50 then
                    zoom_target = get_target_position(zoom_info)
                    locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                    log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y, "DEBUG")
                end
            end
            if should_stop_timer then
                is_timer_running = false
                obs.timer_remove(on_timer)
            end
        end
    end
end

--- Update the filter only when crop values change.
function set_crop_settings(crop)
    if crop_filter ~= nil and crop_filter_settings ~= nil then
        local fx = math.floor(crop.x)
        local fy = math.floor(crop.y)
        local fw = math.floor(crop.w)
        local fh = math.floor(crop.h)
        local dx = math.abs(fx - last_applied_crop.x)
        local dy = math.abs(fy - last_applied_crop.y)
        local dw = math.abs(fw - last_applied_crop.w)
        local dh = math.abs(fh - last_applied_crop.h)

        if dx > CROP_UPDATE_THRESHOLD or dy > CROP_UPDATE_THRESHOLD or dw > CROP_UPDATE_THRESHOLD or dh > CROP_UPDATE_THRESHOLD then
            obs.obs_data_set_int(crop_filter_settings, "left", fx)
            obs.obs_data_set_int(crop_filter_settings, "top", fy)
            obs.obs_data_set_int(crop_filter_settings, "cx", fw)
            obs.obs_data_set_int(crop_filter_settings, "cy", fh)
            obs.obs_source_update(crop_filter, crop_filter_settings)
            last_applied_crop.x = fx
            last_applied_crop.y = fy
            last_applied_crop.w = fw
            last_applied_crop.h = fh
        end
    end
end

function on_transition_start(t)
    log("Transition started", "DEBUG")
    release_sceneitem()
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("Scene changed", "DEBUG")
        refresh_sceneitem_deferred(true, 200)
    end
end

function on_update_transform()
    refresh_sceneitem_deferred(true, 200)
    return true
end

function on_settings_modified(props, prop, settings)
    local name = obs.obs_property_name(prop)

    if name == "use_monitor_override" then
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_x"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_y"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_w"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_h"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sx"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sy"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dw"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dh"), visible)
        return true
    elseif name == "allow_all_sources" then
        local sources_list = obs.obs_properties_get(props, "source")
        populate_zoom_sources(sources_list)
        return true
    elseif name == "debug_logs" then
        if obs.obs_data_get_bool(settings, "debug_logs") then
            log_current_settings()
        end
    end

    return false
end

function log_current_settings()
    local settings = {
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

    log("OBS Version: " .. string.format("%.1f", major), "INFO")
    log("Current settings:", "INFO")
    log(format_table(settings), "INFO")
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "Help Information for OBS-Zoom-To-Mouse v" .. VERSION .. "\n" ..
        "https://github.com/BlankSourceCode/obs-zoom-to-mouse\n" ..
        "----------------------------------------------------\n" ..
        "This script will zoom the selected display-capture source to focus on the mouse\n\n"
    obs.script_log(obs.OBS_LOG_INFO, help)
end

function script_description()
    return "Zoom the selected display-capture source to focus on the mouse"
end

function script_properties()
    local props = obs.obs_properties_create()
    -- Populate the sources list with the known display-capture sources (OBS calls them 'monitor_capture' internally even though the UI says 'Display Capture')
    local sources_list = obs.obs_properties_add_list(props, "source", "Zoom Source", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)
    populate_zoom_sources(sources_list)

    local refresh_sources = obs.obs_properties_add_button(props, "refresh", "Refresh zoom sources",
        function()
            populate_zoom_sources(sources_list)
            if source ~= nil then
                monitor_info = get_monitor_info(source)
            end
            refresh_sceneitem_deferred(true, 150)
            return true
        end)
    obs.obs_property_set_long_description(refresh_sources,
        "Click to re-populate Zoom Sources dropdown with available sources")

    local zoom = obs.obs_properties_add_float(props, "zoom_value", "Zoom Factor", 1, 5, 0.5)
    local zoom_speed = obs.obs_properties_add_float_slider(props, "zoom_speed", "Zoom Speed", 0.01, 1, 0.01)
    local follow = obs.obs_properties_add_bool(props, "follow", "Auto follow mouse ")
    obs.obs_property_set_long_description(follow,
        "When enabled mouse traking will auto-start when zoomed in without waiting for tracking toggle hotkey")
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
        "but moving back towards the center will stop tracking simliar to panning the camera in a RTS game")

    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "Allow any zoom source ")
    obs.obs_property_set_long_description(allow_all, "Enable to allow selecting any source as the Zoom Source\n" ..
        "You MUST set manual source position for non-display capture sources")
    
    local override = obs.obs_properties_add_bool(props, "use_monitor_override", "Set manual source position ")
    obs.obs_property_set_long_description(override, "When enabled the specified size/position settings will be used for the zoom source instead of the auto-calculated ones")
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
    obs.obs_property_set_long_description(override_dw, "X resolution of your montior")
    obs.obs_property_set_long_description(override_dh, "Y resolution of your monitor")
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

    hotkey_zoom_id = obs.obs_hotkey_register_frontend("toggle_zoom_hotkey", "Toggle zoom to mouse", on_toggle_zoom)
    hotkey_follow_id = obs.obs_hotkey_register_frontend("toggle_follow_hotkey", "Toggle follow mouse during zoom", on_toggle_follow)

    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom")
    obs.obs_hotkey_load(hotkey_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.follow")
    obs.obs_hotkey_load(hotkey_follow_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

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

    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = obs.obs_source_get_name(s)
            log("Adding transition_start listener to " .. name, "DEBUG")
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    if ffi.os == "Linux" and not x11_display then
        log("Could not get X11 Display for Linux\n" ..
            "Mouse position will be incorrect.", "ERROR")
    end
end

function script_unload()
    if major > 29.0 then
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

    if source_name ~= old_source_name then
        refresh_sceneitem_deferred(true, 200)
    end

    if source_name ~= old_source_name or
        use_monitor_override ~= old_override or
        monitor_override_x ~= old_x or
        monitor_override_y ~= old_y or
        monitor_override_w ~= old_w or
        monitor_override_h ~= old_h or
        monitor_override_sx ~= old_sx or
        monitor_override_sy ~= old_sy or
        monitor_override_dw ~= old_dw or
        monitor_override_dh ~= old_dh then
        monitor_info = get_monitor_info(source)
    end
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<None>", "obs-zoom-to-mouse-none")
        for _, s in ipairs(sources) do
            local source_type = obs.obs_source_get_id(s)
            if allow_all_sources or (dc_info and source_type == dc_info.source_id) then
                local name = obs.obs_source_get_name(s)
                obs.obs_property_list_add_string(list, name, name)
            end
        end
        obs.source_list_release(sources)
    end
end
