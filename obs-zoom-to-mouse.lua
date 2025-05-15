--
-- OBS Zoom to Mouse
-- An OBS lua script to zoom a display-capture source to focus on the mouse.
-- Copyright (c) BlankSourceCode.  All rights reserved.
--

local OBS = getfenv().obslua
local FFI = require("ffi")
local VERSION = "1.0.2"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"

local SOCKET_AVAILABLE, SOCKET = pcall(require, "ljsocket")
local SOCKET_SERVER = nil
local SOCKET_MOUSE = nil
local USE_SOCKET = false
local SOCKET_PORT = 0
local SOCKET_POLL = 1000

local DC_SOURCE = nil
local SCENEITEM = nil
local SCENEITEM_INFO = {
    current = nil,
    original = nil,
}
local SCENEITEM_CROP = nil
local CROP_FILTER = {
    conversion = nil,
    zoom = nil,
}
local CROP_FILTER_SETTINGS = nil
local CROP_FILTER_INFO = {
    current = { x = 0, y = 0, w = 0, h = 0 },
    original = { x = 0, y = 0, w = 0, h = 0 },
}
local MONITOR_INFO = nil
local ZOOM_INFO = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    crop_sums = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local ZOOM_TARGET = nil
local LOCKED_CENTER = nil
local LOCKED_LAST_POS = nil
local HOTKEYS = {}

local IS_TIMER_RUNNING = false
local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

local SETTINGS = {
    auto_start = true,
    dc_source_name = "",
    use_rezoom = false,
    use_auto_follow_mouse = true,
    follow_outside_bounds = false,
    clamp_to_edges = true,
    is_following_mouse = false,
    follow_speed = 0.1,
    follow_border = 0,
    follow_safezone_sensitivity = 10,
    use_follow_auto_lock = false,
    zoom_value = 2,
    zoom_speed = 0.1,
    allow_all_sources = false,
    use_monitor_override = false,
    monitor_override_x = 0,
    monitor_override_y = 0,
    monitor_override_w = 0,
    monitor_override_h = 0,
    monitor_override_sx = 0,
    monitor_override_sy = 0,
    monitor_override_dw = 0,
    monitor_override_dh = 0,
    keep_shape = false,
    shape_aspect = 1,
    use_socket = false,
    socket_port = 0,
    socket_poll = 1000,
    debug_logs = false,
}

local IS_OBS_LOADED = false
local IS_SCRIPT_LOADED = false

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local ZOOM_STATE = ZoomState.None
local ZOOM_TIME = 0

local VERSION_STR = OBS.obs_get_version_string()
local m1, m2 = VERSION_STR:match("(%d+%.%d+)%.(%d+)")
local VERSION_MAJOR = tonumber(m1) or 0
local VERSION_MINOR = tonumber(m2) or 0
local AUTO_START_RUNNING = false

-- Define the mouse cursor functions for each platform
if FFI.os == "Windows" then
    FFI.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
    ]])
    win_point = FFI.new("POINT[1]")
elseif FFI.os == "Linux" then
    FFI.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    x11_lib = FFI.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = FFI.new("Window[1]"),
            child_win = FFI.new("Window[1]"),
            root_x = FFI.new("int[1]"),
            root_y = FFI.new("int[1]"),
            win_x = FFI.new("int[1]"),
            win_y = FFI.new("int[1]"),
            mask = FFI.new("unsigned int[1]")
        }
    end
elseif FFI.os == "OSX" then
    FFI.cdef([[
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
        int access(const char *path, int amode);
    ]])

    osx_lib = FFI.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = FFI.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if SOCKET_MOUSE ~= nil then
        mouse.x = SOCKET_MOUSE.x
        mouse.y = SOCKET_MOUSE.y
    else
        if FFI.os == "Windows" then
            if win_point and FFI.C.GetCursorPos(win_point) ~= 0 then
                mouse.x = win_point[0].x
                mouse.y = win_point[0].y
            end
        elseif FFI.os == "Linux" then
            if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
                if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                    mouse.x = tonumber(x11_mouse.win_x[0])
                    mouse.y = tonumber(x11_mouse.win_y[0])
                end
            end
        elseif FFI.os == "OSX" then
            if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
                local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
                mouse.x = point.x
                if MONITOR_INFO ~= nil then
                    if MONITOR_INFO.display_height > 0 then
                        mouse.y = MONITOR_INFO.display_height - point.y
                    else
                        mouse.y = MONITOR_INFO.height - point.y
                    end
                end
            end
        end
    end

    return mouse
end

---
-- Get the information about display capture sources for the current platform
---@return any
function get_dc_info()
    if FFI.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif FFI.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif FFI.os == "OSX" then
        if VERSION_MAJOR > 29.0 then
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
---@param temp_obj any The managed OBS object
---@param delete_func function Thefunction which deletes the packaged data (such as obs.obs_data_release)
---@param callback function The function which carries the temporary object
function wrap_managed(temp_obj, delete_func, callback)
    if temp_obj == nil then
        return
    end
    local result = callback(temp_obj)
    delete_func(temp_obj)
    return result
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if SETTINGS.debug_logs then
        OBS.script_log(OBS.OBS_LOG_INFO, msg)
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
-- Take a shallow copy of the table
---@param tbl any
---@return string result The copied table
function copy_table(tbl)
    local res = {}
    for k, v in pairs(tbl) do
        res[k] = v
    end
    return res
end

---
-- Linear interpolate between v0 and v1
---@param v0 number The start position
---@param v1 number The end position
---@param t number Time
---@return number value The interpolated value
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t
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
    if SETTINGS.use_monitor_override then
        return {
            x = SETTINGS.monitor_override_x,
            y = SETTINGS.monitor_override_y,
            width = SETTINGS.monitor_override_w,
            height = SETTINGS.monitor_override_h,
            scale_x = SETTINGS.monitor_override_sx,
            scale_y = SETTINGS.monitor_override_sy,
            display_width = SETTINGS.monitor_override_dw,
            display_height = SETTINGS.monitor_override_dh,
        }
    end

    local function find_display_name(dc_info, settings, monitor_id_prop)
        local to_match
        if dc_info.prop_type == "string" then
            to_match = OBS.obs_data_get_string(settings, dc_info.prop_id)
        elseif dc_info.prop_type == "int" then
            to_match = OBS.obs_data_get_int(settings, dc_info.prop_id)
        end

        local item_count = OBS.obs_property_list_item_count(monitor_id_prop)
        for i = 0, item_count do
            local name = OBS.obs_property_list_item_name(monitor_id_prop, i)
            local value
            if dc_info.prop_type == "string" then
                value = OBS.obs_property_list_item_string(monitor_id_prop, i)
            elseif dc_info.prop_type == "int" then
                value = OBS.obs_property_list_item_int(monitor_id_prop, i)
            end

            if value == to_match then
                return name
            end
        end
    end

    local function calculate_info()
        if not should_use_source(source) then
            return
        end

        local dc_info = get_dc_info()
        if dc_info == nil then
            return
        end

        return wrap_managed(OBS.obs_source_properties(source), OBS.obs_properties_destroy, function(props)
            local monitor_id_prop = OBS.obs_properties_get(props, dc_info.prop_id)
            if monitor_id_prop == nil then
                return
            end

            local found = wrap_managed(OBS.obs_source_get_settings(source), OBS.obs_data_release, function(settings)
                return find_display_name(dc_info, settings, monitor_id_prop)
            end)

            if not found then
                return
            end

            -- This works for many machines as the monitor names are given as "U2790B: 3840x2160 @ -1920,0 (Primary Monitor)"
            -- I don't know if this holds true for other machines and/or OBS versions
            -- TODO: Update this with some custom FFI calls to find the monitor top-left x and y coordinates if it doesn't work for anyone else
            -- TODO: Refactor this into something that would work with Windows/Linux/Mac assuming we can't do it like this
            log("Parsing display name: " .. found)
            local x, y = found:match("(-?%d+),(-?%d+)")
            local width, height = found:match("(%d+)x(%d+)")

            local temp_info = { x = 0, y = 0, width = 0, height = 0 }
            temp_info.x = tonumber(x, 10)
            temp_info.y = tonumber(y, 10)
            temp_info.width = tonumber(width, 10)
            temp_info.height = tonumber(height, 10)
            temp_info.scale_x = 1
            temp_info.scale_y = 1
            temp_info.display_width = temp_info.width
            temp_info.display_height = temp_info.height

            log("Parsed the following display information\n" .. format_table(temp_info))

            if temp_info.width > 0 or temp_info.height > 0 then
                return temp_info
            end
        end)
    end

    -- Only do the expensive look up if we are using automatic calculations on a display source
    local info = calculate_info()

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
function should_use_source(source_to_check)
    if not SETTINGS.allow_all_sources then
        return true
    end

    if source_to_check == nil then
        return false
    end

    local dc_info = get_dc_info()
    if dc_info == nil then
        return false
    end

    local source_type = OBS.obs_source_get_id(source_to_check)
    return source_type == dc_info.source_id
end

---
-- Releases the current sceneitem and resets data back to default
function release_sceneitem()
    if IS_TIMER_RUNNING then
        OBS.timer_remove(on_timer)
        IS_TIMER_RUNNING = false
    end

    ZOOM_STATE = ZoomState.None

    if SCENEITEM ~= nil then
        if CROP_FILTER.zoom ~= nil and DC_SOURCE ~= nil then
            log("Zoom crop filter removed")
            OBS.obs_source_filter_remove(DC_SOURCE, CROP_FILTER.zoom)
            OBS.obs_source_release(CROP_FILTER.zoom)
            CROP_FILTER.zoom = nil
        end

        if CROP_FILTER.conversion ~= nil and DC_SOURCE ~= nil then
            log("Conversion crop filter removed")
            OBS.obs_source_filter_remove(DC_SOURCE, CROP_FILTER.conversion)
            OBS.obs_source_release(CROP_FILTER.conversion)
            CROP_FILTER.conversion = nil
        end

        if CROP_FILTER_SETTINGS ~= nil then
            OBS.obs_data_release(CROP_FILTER_SETTINGS)
            CROP_FILTER_SETTINGS = nil
        end

        toggle_sceneitem_change_listener(false)
        OBS.obs_sceneitem_release(SCENEITEM)
        SCENEITEM = nil
    end

    if DC_SOURCE ~= nil then
        OBS.obs_source_release(DC_SOURCE)
        DC_SOURCE = nil
    end
end

---
-- Updates the current sceneitem with a refreshed set of data from the source
-- Optionally will release the existing sceneitem and get a new one from the current scene
---@param find_newest boolean True to release the current sceneitem and get a new one
function refresh_sceneitem(find_newest)
    -- TODO: Figure out why we need to get the size from the named source during update instead of via the sceneitem source
    local source_raw = { width = 0, height = 0 }
    local function find_scene_item_by_name(root_scene)
        local queue = {}
        table.insert(queue, root_scene)

        while #queue > 0 do
            local s = table.remove(queue, 1)
            log("Looking in scene '" .. OBS.obs_source_get_name(OBS.obs_scene_get_source(s)) .. "'")

            -- Check if the current scene has the target scene item
            local found = OBS.obs_scene_find_source(s, SETTINGS.dc_source_name)
            if found ~= nil then
                log("Found sceneitem '" .. SETTINGS.dc_source_name .. "'")
                OBS.obs_sceneitem_addref(found)
                return found
            end

            -- If the current scene has nested scenes, enqueue them for later examination
            local all_items = OBS.obs_scene_enum_items(s)
            if all_items then
                for _, item in pairs(all_items) do
                    local nested = OBS.obs_sceneitem_get_source(item)
                    if nested ~= nil then
                        if OBS.obs_source_is_scene(nested) then
                            local nested_scene = OBS.obs_scene_from_source(nested)
                            table.insert(queue, nested_scene)
                        elseif OBS.obs_source_is_group(nested) then
                            local nested_scene = OBS.obs_group_from_source(nested)
                            table.insert(queue, nested_scene)
                        end
                    end
                end
                OBS.sceneitem_list_release(all_items)
            end
        end

        return nil
    end

    local function release_and_refresh()
        -- Release the current sceneitem now that we are replacing it
        release_sceneitem()

        -- Quit early if we are using no zoom source
        -- This allows users to reset the crop data back to the original,
        -- update it, and then force the conversion to happen by re-selecting it.
        if SETTINGS.dc_source_name == "obs-zoom-to-mouse-none" then
            return false
        end

        -- Get a matching source we can use for zooming in the current scene
        log("Finding sceneitem for Zoom Source '" .. SETTINGS.dc_source_name .. "'")
        if SETTINGS.dc_source_name == nil then
            return true
        end

        DC_SOURCE = OBS.obs_get_source_by_name(SETTINGS.dc_source_name)
        if DC_SOURCE == nil then
            return true
        end

        -- Get the source size, for some reason this works during load but the sceneitem source doesn't
        source_raw.width = OBS.obs_source_get_width(DC_SOURCE)
        source_raw.height = OBS.obs_source_get_height(DC_SOURCE)

        -- Get the current scene
        local scene_source = OBS.obs_frontend_get_current_scene()
        if scene_source ~= nil then

            -- Find the sceneitem for the source_name by looking through all the items
            -- We start at the current scene and use a BFS to look into any nested scenes
            local current = OBS.obs_scene_from_source(scene_source)
            SCENEITEM = find_scene_item_by_name(current)
            toggle_sceneitem_change_listener(true)

            OBS.obs_source_release(scene_source)
        end

        if not SCENEITEM then
            log(
                "WARNING: Source not part of the current scene hierarchy.\n"
                    .. "         Try selecting a different zoom source or switching scenes."
            )
            OBS.obs_sceneitem_release(SCENEITEM)
            OBS.obs_source_release(DC_SOURCE)

            SCENEITEM = nil
            DC_SOURCE = nil
            return false
        end

        return true
    end

    if find_newest then
        if not release_and_refresh() then
            return
        end
    end

    if not MONITOR_INFO then
        MONITOR_INFO = get_monitor_info(DC_SOURCE)
    end

    local use = should_use_source(DC_SOURCE)
    if not use and not SETTINGS.use_monitor_override then
        log("ERROR: Selected Zoom Source is not a display capture source.\n" ..
            "       You MUST enable 'Set manual source position' and set the correct override values for size and position.")
    end

    if SCENEITEM == nil then
        return
    end

    -- Capture the original settings so we can restore them later
    SCENEITEM_INFO.original = OBS.obs_transform_info()
    OBS.obs_sceneitem_get_info(SCENEITEM, SCENEITEM_INFO.original)

    SCENEITEM_INFO.current = OBS.obs_transform_info()
    OBS.obs_sceneitem_get_info(SCENEITEM, SCENEITEM_INFO.current)

    SCENEITEM_CROP = OBS.obs_sceneitem_crop()
    OBS.obs_sceneitem_get_crop(SCENEITEM, SCENEITEM_CROP)

    -- Get the current source size (this will be the value after any applied crop filters)
    if not DC_SOURCE then
        log("ERROR: Could not get source for sceneitem (" .. SETTINGS.dc_source_name .. ")")
    end

    -- TODO: Figure out why we need this fallback code
    local source_width = OBS.obs_source_get_base_width(DC_SOURCE)
    local source_height = OBS.obs_source_get_base_height(DC_SOURCE)

    if source_width == 0 then
        source_width = source_raw.width
    end
    if source_height == 0 then
        source_height = source_raw.height
    end

    if source_width == 0 or source_height == 0 then
        if MONITOR_INFO ~= nil and MONITOR_INFO.width > 0 and MONITOR_INFO.height > 0 then
            log("WARNING: Something went wrong determining source size.\n" ..
                "         Using source size from info: " .. MONITOR_INFO.width .. ", " .. MONITOR_INFO.height)
            source_width = MONITOR_INFO.width
            source_height = MONITOR_INFO.height
        else
            log("ERROR: Something went wrong determining source size.\n" ..
            "       Try using the 'Set manual source position' option and adding override values")
        end
    else
        log("Using source size: " .. source_width .. ", " .. source_height)
    end

    -- Convert the current transform into one we can correctly modify for zooming
    -- Ideally the user just has a valid one set and we don't have to change anything because this might not work 100% of the time
    ZOOM_INFO.transform_bounds = SCENEITEM_INFO.current.bounds
    SCENEITEM_INFO.current.bounds_type = OBS.OBS_BOUNDS_SCALE_OUTER
    -- SCENEITEM_INFO.current.bounds_alignment = 0 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT) (0 == OBS_ALIGN_CENTER)

    OBS.obs_sceneitem_set_info(SCENEITEM, SCENEITEM_INFO.current)

    log("WARNING: Found existing non-boundingbox transform. This may cause issues with zooming.\n" ..
        "         Settings have been auto converted to a bounding box scaling transfrom instead.\n" ..
        "         If you have issues with your layout consider making the transform use a bounding box manually.")

    -- Get information about any existing crop filters (that aren't ours)
    ZOOM_INFO.crop_sums = { x = 0, y = 0, w = 0, h = 0 }
    local found_crop_filter = false
    local function iterate_filter(crop_sums, filter)
        local id = OBS.obs_source_get_id(filter)
        if id ~= "crop_filter" then
            return false
        end
        local name = OBS.obs_source_get_name(filter)
        if name == CROP_FILTER_NAME then
            return false
        end
        if name == "temp_" .. CROP_FILTER_NAME then
            return false
        end

        wrap_managed(OBS.obs_source_get_settings(filter), OBS.obs_data_release, function(settings)
            if not OBS.obs_data_get_bool(settings, "relative") then
                log("WARNING: Found existing relative crop/pad filter (" .. name .. ").\n" ..
                    "         This will cause issues with zooming. Convert to relative settings instead.")
                return
            end
            crop_sums.x = crop_sums.x + OBS.obs_data_get_int(settings, "left")
            crop_sums.y = crop_sums.y + OBS.obs_data_get_int(settings, "top")
            crop_sums.w = crop_sums.w + OBS.obs_data_get_int(settings, "cx")
            crop_sums.h = crop_sums.h + OBS.obs_data_get_int(settings, "cy")
            log("Found existing non-relative crop/pad filter (" ..
                name ..
                "). Applying settings " .. format_table(crop_sums))
        end)
        return true
    end

    wrap_managed(OBS.obs_source_enum_filters(DC_SOURCE), OBS.source_list_release, function(filters)
        for _, v in pairs(filters) do
            if iterate_filter(ZOOM_INFO.crop_sums, v) then
                found_crop_filter = true
            end
        end
    end)

    -- If the user has transform crops set, we need to convert it (or them) into a crop filter so that it works correctly with zooming
    -- Ideally the user does this manually and uses a crop filter instead of the transfrom crop because this might not work 100% of the time
    if not found_crop_filter and (SCENEITEM_CROP.left ~= 0 or SCENEITEM_CROP.top ~= 0 or SCENEITEM_CROP.right ~= 0 or SCENEITEM_CROP.bottom ~= 0) then
        log("Creating new crop filter")

        -- Update the source size
        source_width = source_width - (SCENEITEM_CROP.left + SCENEITEM_CROP.right)
        source_height = source_height - (SCENEITEM_CROP.top + SCENEITEM_CROP.bottom)

        -- Update the source crop filter now that we will be using one
        ZOOM_INFO.crop_sums.x = SCENEITEM_CROP.left
        ZOOM_INFO.crop_sums.y = SCENEITEM_CROP.top
        ZOOM_INFO.crop_sums.w = source_width
        ZOOM_INFO.crop_sums.h = source_height

        -- Add a new crop filter that emulates the existing transform crop
        local settings = OBS.obs_data_create()
        OBS.obs_data_set_bool(settings, "relative", false)
        OBS.obs_data_set_int(settings, "left", ZOOM_INFO.crop_sums.x)
        OBS.obs_data_set_int(settings, "top", ZOOM_INFO.crop_sums.y)
        OBS.obs_data_set_int(settings, "cx", ZOOM_INFO.crop_sums.w)
        OBS.obs_data_set_int(settings, "cy", ZOOM_INFO.crop_sums.h)
        CROP_FILTER.conversion = OBS.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
        OBS.obs_source_filter_add(DC_SOURCE, CROP_FILTER.conversion)
        OBS.obs_data_release(settings)

        -- Clear out the transform crop
        SCENEITEM_CROP.left = 0
        SCENEITEM_CROP.top = 0
        SCENEITEM_CROP.right = 0
        SCENEITEM_CROP.bottom = 0
        OBS.obs_sceneitem_set_crop(SCENEITEM, SCENEITEM_CROP)

        log("WARNING: Found existing transform crop. This may cause issues with zooming.\n" ..
            "         Settings have been auto converted to a relative crop/pad filter instead.\n" ..
            "         If you have issues with your layout consider making the filter manually.")
    elseif found_crop_filter then
        source_width = ZOOM_INFO.crop_sums.w
        source_height = ZOOM_INFO.crop_sums.h
    end

    -- Get the rest of the information needed to correctly zoom
    ZOOM_INFO.source_size = { width = source_width, height = source_height }
    ZOOM_INFO.source_crop = {
        l = SCENEITEM_CROP.left,
        t = SCENEITEM_CROP.top,
        r = SCENEITEM_CROP.right,
        b = SCENEITEM_CROP.bottom,
    }
    --log("Transform updated. Using following values -\n" .. format_table(zoom_info))

    -- Set the initial the crop filter data to match the source
    CROP_FILTER_INFO.original = {
        x = 0,
        y = 0,
        w = ZOOM_INFO.source_size.width,
        h = ZOOM_INFO.source_size.height,
    }
    CROP_FILTER_INFO.current = copy_table(CROP_FILTER_INFO.original)

    -- Get or create our crop filter that we change during zoom
    CROP_FILTER.zoom = OBS.obs_source_get_filter_by_name(DC_SOURCE, CROP_FILTER_NAME)
    if CROP_FILTER.zoom == nil then
        CROP_FILTER_SETTINGS = OBS.obs_data_create()
        OBS.obs_data_set_bool(CROP_FILTER_SETTINGS, "relative", false)
        CROP_FILTER.zoom = OBS.obs_source_create_private("crop_filter", CROP_FILTER_NAME, CROP_FILTER_SETTINGS)
        OBS.obs_source_filter_add(DC_SOURCE, CROP_FILTER.zoom)
    else
        CROP_FILTER_SETTINGS = OBS.obs_source_get_settings(CROP_FILTER.zoom)
    end

    OBS.obs_source_filter_set_order(DC_SOURCE, CROP_FILTER.zoom, OBS.OBS_ORDER_MOVE_BOTTOM)
    set_crop_settings(CROP_FILTER_INFO.original)
end

---
-- Get the target position that we will attempt to zoom towards
---@param zoom_info any
---@return table
function get_target_position(zoom_info)
    local mouse_pos = get_mouse_pos()

    -- If we have monitor information then we can offset the mouse by the top-left of the monitor position
    -- This is because the display-capture source assumes top-left is 0,0 but the mouse uses the total desktop area,
    -- so a second monitor might start at x:1920, y:0 for example, so when we click at 1920,0 we want it to look like we clicked 0,0 on the source.
    if MONITOR_INFO then
        mouse_pos.x = mouse_pos.x - MONITOR_INFO.x
        mouse_pos.y = mouse_pos.y - MONITOR_INFO.y
    end

    -- Now offset the mouse by the crop top-left because if we cropped 100px off of the display clicking at 100,0 should really be the top-left 0,0
    mouse_pos.x = mouse_pos.x - zoom_info.crop_sums.x
    mouse_pos.y = mouse_pos.y - zoom_info.crop_sums.y

    -- If the source uses a different scale to the display, apply that now.
    -- This can happen with cloned sources, where it is cloning a scene that has a full screen display.
    -- The display will be the full desktop pixel size, but the cloned scene will be scaled down to the canvas,
    -- so we need to scale down the mouse movement to match
    if MONITOR_INFO and MONITOR_INFO.scale_x and MONITOR_INFO.scale_y then
        mouse_pos.x = mouse_pos.x * MONITOR_INFO.scale_x
        mouse_pos.y = mouse_pos.y * MONITOR_INFO.scale_y
    end

    local zoom_factor = zoom_info.zoom_to
    if MONITOR_INFO then
    log(string.format("%f", math.max(
        (ZOOM_INFO.transform_bounds.x / MONITOR_INFO.width),
        (ZOOM_INFO.transform_bounds.y / MONITOR_INFO.height))))
        zoom_factor = zoom_factor / math.max(
            (ZOOM_INFO.transform_bounds.x / MONITOR_INFO.width),
            (ZOOM_INFO.transform_bounds.y / MONITOR_INFO.height))
    end

    -- Get the new size after we zoom
    -- Remember that because we are using a crop/pad filter making the size smaller (dividing by zoom) means that we see less of the image
    -- in the same amount of space making it look bigger (aka zoomed in)
    local new_size = {
        width = zoom_info.source_size.width / zoom_factor,
        height = zoom_info.source_size.height / zoom_factor,
    }

    -- If should keep shape, use aspect ratio to get new width
    if SETTINGS.keep_shape then
        new_size.width = new_size.height * SETTINGS.shape_aspect
    end

    -- New offset for the crop/pad filter is whereever we clicked minus half the size, so that the clicked point because the new center
    local pos = {
        x = mouse_pos.x - new_size.width * 0.5,
        y = mouse_pos.y - new_size.height * 0.5,
    }

    -- Create the full crop results
    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    -- Keep the zoom in bounds of the source so that we never show something outside that user is trying to hide with existing crop settings
    if SETTINGS.clamp_to_edges then
        crop.x = math.floor(clamp(0, (zoom_info.source_size.width - new_size.width), crop.x))
        crop.y = math.floor(clamp(0, (zoom_info.source_size.height - new_size.height), crop.y))
    end

    return {
        crop = crop, 
        raw_center = mouse_pos,
        clamped_center = {
             x = math.floor(crop.x + crop.w * 0.5), 
             y = math.floor(crop.y + crop.h * 0.5),
         },
    }
end

function on_toggle_follow(pressed)
    if pressed then
        IS_FOLLOWING_MOUSE = not IS_FOLLOWING_MOUSE
        log("Tracking mouse is " .. (IS_FOLLOWING_MOUSE and "on" or "off"))

        if IS_FOLLOWING_MOUSE and ZOOM_STATE == ZoomState.ZoomedIn then
            -- Since we are zooming we need to start the timer for the animation and tracking
            if IS_TIMER_RUNNING == false then
                IS_TIMER_RUNNING = true
                local timer_interval = math.floor(OBS.obs_get_frame_interval_ns() / 1000000)
                OBS.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_toggle_zoom(pressed, force_value)
    if not pressed and not force_value then
        return
    end

    -- Check if we are in a safe state to zoom
    if ZOOM_STATE == ZoomState.ZoomedIn or ZOOM_STATE == ZoomState.None then
        if ZOOM_STATE == ZoomState.ZoomedIn then
            log("Zooming out")
            -- To zoom out, we set the target back to whatever it was originally
            ZOOM_STATE = ZoomState.ZoomingOut
            ZOOM_TIME = 0
            LOCKED_CENTER = nil
            LOCKED_LAST_POS = nil
            ZOOM_TARGET = { crop = CROP_FILTER_INFO.original, c = SCENEITEM_CROP }
            if IS_FOLLOWING_MOUSE then
                IS_FOLLOWING_MOUSE = false
                log("Tracking mouse is off (due to zoom out)")
            end
        else
            -- If the desktop source was scaled, let's adjust the scaling so that items on the monitor remain the same absolute size

            log("Zooming in")
            -- To zoom in, we get a new target based on where the mouse was when zoom was clicked
            SETTINGS.shape_aspect = ZOOM_INFO.transform_bounds.x / ZOOM_INFO.transform_bounds.y
            ZOOM_STATE = ZoomState.ZoomingIn
            ZOOM_INFO.zoom_to = SETTINGS.zoom_value
            ZOOM_TIME = 0
            LOCKED_CENTER = nil
            LOCKED_LAST_POS = nil
            ZOOM_TARGET = get_target_position(ZOOM_INFO)
        end

        -- Since we are zooming we need to start the timer for the animation and tracking
        if IS_TIMER_RUNNING == false then
            IS_TIMER_RUNNING = true
            local timer_interval = math.floor(OBS.obs_get_frame_interval_ns() / 1000000)
            OBS.timer_add(on_timer, timer_interval)
        end
    end
end

function on_timer()
    local crop = CROP_FILTER_INFO.current
    if crop == nil then
        return
    end
    if ZOOM_TARGET == nil then
        return
    end

    -- Update our zoom time that we use for the animation
    ZOOM_TIME = ZOOM_TIME + SETTINGS.zoom_speed

    if ZOOM_STATE == ZoomState.ZoomingOut or ZOOM_STATE == ZoomState.ZoomingIn then
        -- When we are doing a zoom animation (in or out) we linear interpolate the crop to the target
        if ZOOM_TIME <= 1 then
            -- If we have auto-follow turned on, make sure to keep the mouse in the view while we zoom
            -- This is incase the user is moving the mouse a lot while the animation (which may be slow) is playing
            if ZOOM_STATE == ZoomState.ZoomingIn and SETTINGS.use_auto_follow_mouse then
                ZOOM_TARGET = get_target_position(ZOOM_INFO)
            end
            crop.x = lerp(crop.x, ZOOM_TARGET.crop.x, ease_in_out(ZOOM_TIME))
            crop.y = lerp(crop.y, ZOOM_TARGET.crop.y, ease_in_out(ZOOM_TIME))
            crop.w = lerp(crop.w, ZOOM_TARGET.crop.w, ease_in_out(ZOOM_TIME))
            crop.h = lerp(crop.h, ZOOM_TARGET.crop.h, ease_in_out(ZOOM_TIME))
            set_crop_settings(crop)
        end
   
    -- If we are not zooming we only move the x/y to follow the mouse (width/height stay constant)
    elseif IS_FOLLOWING_MOUSE then
        ZOOM_TARGET = get_target_position(ZOOM_INFO)

        local skip_frame = false
        if not SETTINGS.follow_outside_bounds then
            if ZOOM_TARGET.raw_center.x < ZOOM_TARGET.crop.x or
                ZOOM_TARGET.raw_center.x > ZOOM_TARGET.crop.x + ZOOM_TARGET.crop.w or
                ZOOM_TARGET.raw_center.y < ZOOM_TARGET.crop.y or
                ZOOM_TARGET.raw_center.y > ZOOM_TARGET.crop.y + ZOOM_TARGET.crop.h then
                -- Don't follow the mouse if we are outside the bounds of the source
                skip_frame = true
            end
        end

        if not skip_frame then
            -- If we have a locked_center it means we are currently in a locked zone and
            -- shouldn't track the mouse until it moves out of the area
            if LOCKED_CENTER ~= nil then
                local diff = {
                    x = ZOOM_TARGET.raw_center.x - LOCKED_CENTER.x,
                    y = ZOOM_TARGET.raw_center.y - LOCKED_CENTER.y
                }

                local track = {
                    x = ZOOM_TARGET.crop.w * (0.5 - (SETTINGS.follow_border * 0.01)),
                    y = ZOOM_TARGET.crop.h * (0.5 - (SETTINGS.follow_border * 0.01))
                }

                if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                    -- Cursor moved into the active border area, so resume tracking by clearing out the locked_center
                    LOCKED_CENTER = nil
                    LOCKED_LAST_POS = {
                        x = ZOOM_TARGET.raw_center.x,
                        y = ZOOM_TARGET.raw_center.y,
                        diff_x = diff.x,
                        diff_y = diff.y
                    }
                    log("Locked area exited - resume tracking")
                end
            end

            local crop = CROP_FILTER_INFO.current
            if LOCKED_CENTER == nil and (ZOOM_TARGET.crop.x ~= crop.x or ZOOM_TARGET.crop.y ~= crop.y) then
                crop.x = lerp(crop.x, ZOOM_TARGET.crop.x, SETTINGS.follow_speed)
                crop.y = lerp(crop.y, ZOOM_TARGET.crop.y, SETTINGS.follow_speed)
                set_crop_settings(crop)

                -- Check to see if the mouse has stopped moving long enough to create a new safe zone
                if IS_FOLLOWING_MOUSE and LOCKED_CENTER == nil and LOCKED_LAST_POS ~= nil then
                    local diff = {
                        x = math.abs(crop.x - ZOOM_TARGET.crop.x),
                        y = math.abs(crop.y - ZOOM_TARGET.crop.y),
                        auto_x = ZOOM_TARGET.raw_center.x - LOCKED_LAST_POS.x,
                        auto_y = ZOOM_TARGET.raw_center.y - LOCKED_LAST_POS.y
                    }

                    LOCKED_LAST_POS.x = ZOOM_TARGET.raw_center.x
                    LOCKED_LAST_POS.y = ZOOM_TARGET.raw_center.y

                    local lock = false
                    if math.abs(LOCKED_LAST_POS.diff_x) > math.abs(LOCKED_LAST_POS.diff_y) then
                        if (diff.auto_x < 0 and LOCKED_LAST_POS.diff_x > 0) or (diff.auto_x > 0 and LOCKED_LAST_POS.diff_x < 0) then
                            lock = true
                        end
                    else
                        if (diff.auto_y < 0 and LOCKED_LAST_POS.diff_y > 0) or (diff.auto_y > 0 and LOCKED_LAST_POS.diff_y < 0) then
                            lock = true
                        end
                    end

                    if
                        (lock and SETTINGS.use_follow_auto_lock) or (
                            diff.x <= SETTINGS.follow_safezone_sensitivity and
                            diff.y <= SETTINGS.follow_safezone_sensitivity) then
                        -- Make the new center the position of the current camera (which might not be the same as the mouse since we lerp towards it)
                        LOCKED_CENTER = {
                            x = math.floor(crop.x + ZOOM_TARGET.crop.w * 0.5),
                            y = math.floor(crop.y + ZOOM_TARGET.crop.h * 0.5)
                        }
                        log("Cursor stopped. Tracking locked to " .. LOCKED_CENTER.x .. ", " .. LOCKED_CENTER.y)
                    end
                end
            end
        end
    end

    -- Check to see if the animation is still running
    if ZOOM_TIME < 1 then
        return
    end

    local should_stop_timer = false
    -- When we finished zooming out we remove the timer
    if ZOOM_STATE == ZoomState.ZoomingOut then
        log("Zoomed out")
        set_crop_settings(CROP_FILTER_INFO.original)
        ZOOM_STATE = ZoomState.None
        should_stop_timer = true
    elseif ZOOM_STATE == ZoomState.ZoomingIn then
        log("Zoomed in")
        ZOOM_STATE = ZoomState.ZoomedIn
        -- If we finished zooming in and we arent tracking the mouse we can also remove the timer
        should_stop_timer = (not SETTINGS.use_auto_follow_mouse) and (not IS_FOLLOWING_MOUSE)

        if SETTINGS.use_auto_follow_mouse then
            IS_FOLLOWING_MOUSE = true
            log("Tracking mouse is " .. (IS_FOLLOWING_MOUSE and "on" or "off") .. " (due to auto follow)")
        end
    end

    if should_stop_timer then
        IS_TIMER_RUNNING = false
        OBS.timer_remove(on_timer)
    end
end

function on_socket_timer()
    if not SOCKET_SERVER then
        return
    end

    repeat
        local data, status = SOCKET_SERVER:receive_from()
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                local x = tonumber(sx, 10)
                local y = tonumber(sy, 10)
                if not SOCKET_MOUSE then
                    log("Socket server client connected")
                    SOCKET_MOUSE = { x = x, y = y }
                else
                    SOCKET_MOUSE.x = x
                    SOCKET_MOUSE.y = y
                end
            end
        elseif status ~= "timeout" then
            error(status)
        end
    until data == nil
end

function start_server()
    if SOCKET_AVAILABLE then
        local address = SOCKET.find_first_address("*", SOCKET_PORT)

        SOCKET_SERVER = SOCKET.create("inet", "dgram", "udp")
        if SOCKET_SERVER ~= nil then
            SOCKET_SERVER:set_option("reuseaddr", 1)
            SOCKET_SERVER:set_blocking(false)
            SOCKET_SERVER:bind(address, SOCKET_PORT)
            OBS.timer_add(on_socket_timer, SOCKET_POLL)
            log("Socket server listening on port " .. SOCKET_PORT .. "...")
        end
    end
end

function stop_server()
    if SOCKET_SERVER ~= nil then
        log("Socket server stopped")
        OBS.timer_remove(on_socket_timer)
        SOCKET_SERVER:close()
        SOCKET_SERVER = nil
        SOCKET_MOUSE = nil
    end
end

function set_crop_settings(crop)
    if CROP_FILTER.zoom ~= nil and CROP_FILTER_SETTINGS ~= nil then
        -- Call into OBS to update our crop filter with the new settings
        -- I have no idea how slow/expensive this is, so we could potentially only do it if something changes
        OBS.obs_data_set_int(CROP_FILTER_SETTINGS, "left", math.floor(crop.x))
        OBS.obs_data_set_int(CROP_FILTER_SETTINGS, "top", math.floor(crop.y))
        OBS.obs_data_set_int(CROP_FILTER_SETTINGS, "cx", math.floor(crop.w))
        OBS.obs_data_set_int(CROP_FILTER_SETTINGS, "cy", math.floor(crop.h))
        OBS.obs_source_update(CROP_FILTER.zoom, CROP_FILTER_SETTINGS)
    end
end

function on_transition_start(t)
    log("Transition started")
    -- We need to remove the crop from the sceneitem as the transition starts to avoid
    -- a delay with the rendering where you see the old crop and jump to the new one
    release_sceneitem()
    ---
    -- Ensure to restart filters on scene change back
    ---
    if SETTINGS.dc_source_name ~= "obs-zoom-to-mouse-none" and SETTINGS.auto_start and not AUTO_START_RUNNING then
        log("Auto starting")
        AUTO_START_RUNNING = true
        local timer_interval = math.floor(OBS.obs_get_frame_interval_ns() / 100000)
        OBS.timer_add(wait_for_auto_start, timer_interval)
    end
end

function on_transform_update()
    if SETTINGS.keep_shape then
        if ZOOM_STATE == ZoomState.ZoomedIn then
            -- Perform zoom again
            ZOOM_STATE = ZoomState.ZoomingIn
            ZOOM_INFO.zoom_to = SETTINGS.zoom_value
            ZOOM_TIME = 0
            ZOOM_TARGET = get_target_position(ZOOM_INFO)
        end
    end
end

function toggle_sceneitem_change_listener(value)
    local scene = OBS.obs_sceneitem_get_scene(SCENEITEM)
    local scene_source = OBS.obs_scene_get_source(scene)
    local handler = OBS.obs_source_get_signal_handler(scene_source)
    if value then
        OBS.signal_handler_connect(handler, "item_transform", on_transform_update)
    else
        OBS.signal_handler_disconnect(handler, on_transform_update)
    end
end

function on_frontend_event(event)
    if event == OBS.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("OBS Scene changed")
        -- If the scene changes we attempt to find a new source with the same name in this new scene
        -- TODO: There probably needs to be a way for users to specify what source they want to use in each scene
        -- Scene change can happen before OBS has completely loaded, so we check for that here
        if IS_OBS_LOADED then
            refresh_sceneitem(true)
        end
    elseif event == OBS.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        log("OBS Loaded")
        -- Once loaded we perform our initial lookup
        IS_OBS_LOADED = true
        MONITOR_INFO = get_monitor_info(DC_SOURCE)
        refresh_sceneitem(true)
    elseif event == OBS.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        log("OBS Shutting down")
        -- Add a fail-safe for unloading the script during shutdown
        if IS_SCRIPT_LOADED then
            script_unload()
        end
    end
end

function on_update_transform()
    -- Update the crop/size settings based on whatever the source in the current scene looks like
    if IS_OBS_LOADED then
        refresh_sceneitem(true)
    end

    return true
end

function on_settings_modified(props, prop, obs_settings_obj)
    local name = OBS.obs_property_name(prop)

    -- Show/Hide the settings based on if the checkbox is checked or not
    if name == "USE_MONITOR_OVERRIDE" then
        local visible = OBS.obs_data_get_bool(obs_settings_obj, "USE_MONITOR_OVERRIDE")
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_label"), not visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_x"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_y"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_w"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_h"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_sx"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_sy"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_dw"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "monitor_override_dh"), visible)
        return true
    elseif name == "use_socket" then
        local visible = OBS.obs_data_get_bool(obs_settings_obj, "use_socket")
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "socket_label"), not visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "socket_port"), visible)
        OBS.obs_property_set_visible(OBS.obs_properties_get(props, "socket_poll"), visible)
        return true
    elseif name == "allow_all_sources" then
        local sources_list = OBS.obs_properties_get(props, "source")
        populate_zoom_sources(sources_list)
        return true
    elseif name == "keep_shape" then
        on_transform_update()
    elseif name == "debug_logs" then
        if OBS.obs_data_get_bool(obs_settings_obj, "debug_logs") then
            log_current_settings()
        end
    end

    return false
end

---
-- Write the current settings into the log for debugging and user issue reports
function log_current_settings()
    log("OBS Version: " .. string.format("%.1f", VERSION_MAJOR) .. "." .. VERSION_MINOR)
    log("Platform: " .. FFI.os)
    log("Current settings:")
    log(format_table(SETTINGS))
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
        "Zoomed at OBS Startup: Start OBS with source zoomed\n" ..
        "Dynamic Aspect Ratio: Adjusst zoom aspect ratio to canvas source size\n" ..
        "Auto Follow Mouse: True to track the cursor while you are zoomed in\n" ..
        "Follow Outside Bounds: True to track the cursor even when it is outside the bounds of the source\n" ..
        "Follow Speed: The speed at which the zoomed area will follow the mouse when tracking\n" ..
        "Follow Border: The %distance from the edge of the source that will re-enable mouse tracking\n" ..
        "Lock Sensitivity: How close the tracking needs to get before it locks into position and stops tracking until you enter the follow border\n" ..
        "Auto Lock on Reverse Direction: Automatically stop tracking if you reverse the direction of the mouse\n" ..
        "Show All Sources: True to allow selecting any source as the Zoom Source - You MUST set manual source position for non-display capture sources\n" ..
        "Set Manual Source Position: True to override the calculated x/y (topleft position), width/height (size), and scaleX/scaleY (canvas scale factor) for the selected source\n" ..
        "X: The coordinate of the left most pixel of the source\n" ..
        "Y: The coordinate of the top most pixel of the source\n" ..
        "Width: The width of the source (in pixels)\n" ..
        "Height: The height of the source (in pixels)\n" ..
        "Scale X: The x scale factor to apply to the mouse position if the source size is not 1:1 (useful for cloned sources)\n" ..
        "Scale Y: The y scale factor to apply to the mouse position if the source size is not 1:1 (useful for cloned sources)\n" ..
        "Monitor Width: The width of the monitor that is showing the source (in pixels)\n" ..
        "Monitor Height: The height of the monitor that is showing the source (in pixels)\n"

    if SOCKET_AVAILABLE then
        help = help ..
            "Enable remote mouse listener: True to start a UDP socket server that will listen for mouse position messages from a remote client, see: https://github.com/BlankSourceCode/obs-zoom-to-mouse-remote\n" ..
            "Port: The port number to use for the socket server\n" ..
            "Poll Delay: The time between updating the mouse position (in milliseconds)\n"
    end

    help = help ..
        "More Info: Show this text in the script log\n" ..
        "Enable debug logging: Show additional debug information in the script log\n\n"

    OBS.script_log(OBS.OBS_LOG_INFO, help)
end

function script_description()
    return "Zoom the selected display-capture source to focus on the mouse"
end

function script_properties()
    local props = OBS.obs_properties_create()

    -- Populate the sources list with the known display-capture sources (OBS calls them 'monitor_capture' internally even though the UI says 'Display Capture')
    local sources_list = OBS.obs_properties_add_list(props, "source", "Zoom Source", OBS.OBS_COMBO_TYPE_LIST,
        OBS.OBS_COMBO_FORMAT_STRING)

    populate_zoom_sources(sources_list)

    local refresh_sources = OBS.obs_properties_add_button(props, "refresh", "Refresh zoom sources",
        function()
            populate_zoom_sources(sources_list)
            MONITOR_INFO = get_monitor_info(DC_SOURCE)
            return true
        end)
    OBS.obs_property_set_long_description(refresh_sources,
        "Click to re-populate Zoom Sources dropdown with available sources")

    -- Add the rest of the settings UI
    local zoom = OBS.obs_properties_add_float(props, "zoom_value", "Zoom Factor", 1, 5, 0.5)
    local zoom_speed = OBS.obs_properties_add_float_slider(props, "zoom_speed", "Zoom Speed", 0.01, 1, 0.01)
    local rezoom = OBS.obs_properties_add_bool(props, "use_rezoom", "Adjust Zoom Factor to Transform")

    local auto_start = OBS.obs_properties_add_bool(props, "auto_start", "Zoomed at OBS Startup")
    OBS.obs_property_set_long_description(auto_start,
        "When enabled, auto zoom is activated on OBS start up as soon as possible")

    local keep_shape = OBS.obs_properties_add_bool(props, "keep_shape", "Dynamic Aspect Ratio ")
    OBS.obs_property_set_long_description(keep_shape,
        "When enabled, zoom will follow the aspect ratio of source in canvas")

    local follow = OBS.obs_properties_add_bool(props, "follow", "Auto Follow Mouse")
    OBS.obs_property_set_long_description(follow,
        "When enabled mouse traking will auto-start when zoomed in without waiting for tracking toggle hotkey")

    local follow_outside_bounds = OBS.obs_properties_add_bool(props, "follow_outside_bounds", "Follow Outside Bounds ")
    OBS.obs_property_set_long_description(follow_outside_bounds,
        "When enabled, the mouse will be tracked even when the cursor is outside the bounds of the zoom source")

    local clamp_to_edges = OBS.obs_properties_add_bool(props, "clamp_to_edges", "Clamp to Display Edge")
    local follow_speed = OBS.obs_properties_add_float_slider(props, "follow_speed", "Follow Speed", 0.01, 1, 0.01)
    local follow_border = OBS.obs_properties_add_int_slider(props, "follow_border", "Follow Border", 0, 50, 1)
    local safezone_sense = OBS.obs_properties_add_int_slider(props, "follow_safezone_sensitivity", "Lock Sensitivity", 1, 20, 1)
    local follow_auto_lock = OBS.obs_properties_add_bool(props, "follow_auto_lock", "Auto Lock on Reverse Direction")

    OBS.obs_property_set_long_description(follow_auto_lock,
        "When enabled moving the mouse to edge of the zoom source will begin tracking,\n" ..
        "but moving back towards the center will stop tracking simliar to panning the camera in a RTS game")

    local allow_all = OBS.obs_properties_add_bool(props, "allow_all_sources", "Allow Any Zoom Source ")
    OBS.obs_property_set_long_description(allow_all, "Enable to allow selecting any source as the Zoom Source\n" ..
        "You MUST set manual source position for non-display capture sources")

    local override_props = OBS.obs_properties_create()
    local override_label = OBS.obs_properties_add_text(override_props, "monitor_override_label", "", OBS.OBS_TEXT_DEFAULT)
    local override_x = OBS.obs_properties_add_int(override_props, "monitor_override_x", "X", -10000, 10000, 1)
    local override_y = OBS.obs_properties_add_int(override_props, "monitor_override_y", "Y", -10000, 10000, 1)
    local override_w = OBS.obs_properties_add_int(override_props, "monitor_override_w", "Width", 0, 10000, 1)
    local override_h = OBS.obs_properties_add_int(override_props, "monitor_override_h", "Height", 0, 10000, 1)
    local override_sx = OBS.obs_properties_add_float(override_props, "monitor_override_sx", "Scale X ", 0, 100, 0.01)
    local override_sy = OBS.obs_properties_add_float(override_props, "monitor_override_sy", "Scale Y ", 0, 100, 0.01)
    local override_dw = OBS.obs_properties_add_int(override_props, "monitor_override_dw", "Monitor Width ", 0, 10000, 1)
    local override_dh = OBS.obs_properties_add_int(override_props, "monitor_override_dh", "Monitor Height ", 0, 10000, 1)
    local override = OBS.obs_properties_add_group(props, "USE_MONITOR_OVERRIDE", "Set Manual Source Position",
        OBS.OBS_GROUP_CHECKABLE, override_props)

    OBS.obs_property_set_long_description(override_label,
        "When enabled the specified size/position settings will be used for the zoom source instead of the auto-calculated ones")
    OBS.obs_property_set_long_description(override_sx, "Usually 1 - unless you are using a scaled source")
    OBS.obs_property_set_long_description(override_sy, "Usually 1 - unless you are using a scaled source")
    OBS.obs_property_set_long_description(override_dw, "X resolution of your montior")
    OBS.obs_property_set_long_description(override_dh, "Y resolution of your monitor")

    if SOCKET_AVAILABLE then
        local socket_props = OBS.obs_properties_create()
        local r_label = OBS.obs_properties_add_text(socket_props, "socket_label", "", OBS.OBS_TEXT_INFO)
        local r_port = OBS.obs_properties_add_int(socket_props, "socket_port", "Port ", 1024, 65535, 1)
        local r_poll = OBS.obs_properties_add_int(socket_props, "socket_poll", "Poll Delay (ms)", 0, 1000, 1)
        local socket = OBS.obs_properties_add_group(props, "use_socket", "Enable Remote Mouse Listener",
            OBS.OBS_GROUP_CHECKABLE, socket_props)

        OBS.obs_property_set_long_description(r_label,
            "When enabled a UDP socket server will listen for mouse position messages from a remote client")
        OBS.obs_property_set_long_description(r_port,
            "You must restart the server after changing the port (Uncheck then re-check 'Enable Remote Mouse Listener')")
        OBS.obs_property_set_long_description(r_poll,
            "You must restart the server after changing the poll delay (Uncheck then re-check 'Enable Remote Mouse Listener')")

        OBS.obs_property_set_visible(r_label, not USE_SOCKET)
        OBS.obs_property_set_visible(r_port, USE_SOCKET)
        OBS.obs_property_set_visible(r_poll, USE_SOCKET)
        OBS.obs_property_set_modified_callback(socket, on_settings_modified)
    end

    -- Add a button for more information
    local help = OBS.obs_properties_add_button(props, "help_button", "More Info", on_print_help)
    OBS.obs_property_set_long_description(help,
        "Click to show help information (via the script log)")

    local debug = OBS.obs_properties_add_bool(props, "debug_logs", "Enable debug logging ")
    OBS.obs_property_set_long_description(debug,
        "When enabled the script will output diagnostics messages to the script log (useful for debugging or GitHub issues)")

    OBS.obs_property_set_visible(override_label, not SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_x, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_y, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_w, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_h, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_sx, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_sy, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_dw, SETTINGS.use_monitor_override)
    OBS.obs_property_set_visible(override_dh, SETTINGS.use_monitor_override)
    OBS.obs_property_set_modified_callback(override, on_settings_modified)

    OBS.obs_property_set_modified_callback(allow_all, on_settings_modified)
    OBS.obs_property_set_modified_callback(debug, on_settings_modified)

    return props
end

function script_load(obs_settings_obj)
    SCENEITEM_INFO.original = nil

    -- Workaround for detecting if OBS is already loaded and we were reloaded using "Reload Scripts"
    local current_scene = OBS.obs_frontend_get_current_scene()
    IS_OBS_LOADED = current_scene ~= nil -- Current scene is nil on first OBS load
    OBS.obs_source_release(current_scene)

    -- Add our hotkey
    HOTKEYS = {
        zoom = OBS.obs_hotkey_register_frontend("toggle_zoom_hotkey", "Toggle Zoom To Mouse", on_toggle_zoom),
        follow = OBS.obs_hotkey_register_frontend("toggle_follow_hotkey", "Toggle Follow Mouse During Zoom", on_toggle_follow),
    }

    -- Attempt to reload existing hotkey bindings if we can find any
    for k, v in pairs(HOTKEYS) do
        if v ~= nil then
            local hotkey_save_array = OBS.obs_data_get_array(obs_settings_obj, "obs_zoom_to_mouse.hotkey." .. k)
            OBS.obs_hotkey_load(v, hotkey_save_array)
            OBS.obs_data_array_release(hotkey_save_array)
        end
    end

    -- Load any other settings
    settings_update(obs_settings_obj)

    OBS.obs_frontend_add_event_callback(on_frontend_event)

    if SETTINGS.debug_logs then
        log_current_settings()
    end

    -- Add the transition_start event handlers to each transition (the global source_transition_start event never fires)
    local transitions = OBS.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = OBS.obs_source_get_name(s)
            log("Adding transition_start listener to " .. name)
            local handler = OBS.obs_source_get_signal_handler(s)
            OBS.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        OBS.source_list_release(transitions)
    end

    if FFI.os == "Linux" and not x11_display then
        log("ERROR: Could not get X11 Display for Linux\n" ..
            "Mouse position will be incorrect.")
    end

    SETTINGS.dc_source_name = ""
    USE_SOCKET = false
    IS_SCRIPT_LOADED = true
    if SETTINGS.dc_source_name ~= "obs-zoom-to-mouse-none" and SETTINGS.auto_start and not AUTO_START_RUNNING then
        log("Auto starting")
        AUTO_START_RUNNING = true
        local timer_interval = math.floor(OBS.obs_get_frame_interval_ns() / 100000)
        OBS.timer_add(wait_for_auto_start, timer_interval)
    end
end

function wait_for_auto_start()
    if SETTINGS.dc_source_name == "obs-zoom-to-mouse-none" or not SETTINGS.auto_start then
        OBS.remove_current_callback()
        AUTO_START_RUNNING = false
        log("Auto start cancelled")
    else
        AUTO_START_RUNNING = true
        local found_source = OBS.obs_get_source_by_name(SETTINGS.dc_source_name)
        if found_source ~= nil then
            -- zoom_state = ZoomState.ZoomingIn
            DC_SOURCE = found_source
            on_toggle_zoom(true, true)
            OBS.remove_current_callback()
            AUTO_START_RUNNING = false
            log("Auto start done")
        end
    end
end

function script_unload()
    IS_SCRIPT_LOADED = false

    -- Clean up the memory usage
    -- 29.1.2 and below seems to crash if you do this, so we ignore it as the script is closing anyway
    if VERSION_MAJOR > 29.1 or (VERSION_MAJOR == 29.1 and VERSION_MINOR > 2) then
        local transitions = OBS.obs_frontend_get_transitions()
        if transitions ~= nil then
            for i, s in pairs(transitions) do
                local handler = OBS.obs_source_get_signal_handler(s)
                OBS.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            OBS.source_list_release(transitions)
        end

        OBS.obs_hotkey_unregister(on_toggle_zoom)
        OBS.obs_hotkey_unregister(on_toggle_follow)
        OBS.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
        x11_display = nil
        x11_lib = nil
    end

    if SOCKET_SERVER ~= nil then
        stop_server()
    end
end

function script_defaults(settings)
    -- Default values for the script
    OBS.obs_data_set_default_double(settings, "zoom_value", 2)
    OBS.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    OBS.obs_data_set_default_bool(settings, "rezoom", false)
    OBS.obs_data_set_default_bool(settings, "follow", true)
    OBS.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    OBS.obs_data_set_default_double(settings, "follow_speed", 0.25)
    OBS.obs_data_set_default_int(settings, "follow_border", 8)
    OBS.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    OBS.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    OBS.obs_data_set_default_bool(settings, "allow_all_sources", false)
    OBS.obs_data_set_default_bool(settings, "USE_MONITOR_OVERRIDE", false)
    OBS.obs_data_set_default_int(settings, "monitor_override_x", 0)
    OBS.obs_data_set_default_int(settings, "monitor_override_y", 0)
    OBS.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    OBS.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    OBS.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    OBS.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    OBS.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    OBS.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    OBS.obs_data_set_default_bool(settings, "use_socket", false)
    OBS.obs_data_set_default_int(settings, "socket_port", 12345)
    OBS.obs_data_set_default_int(settings, "socket_poll", 10)
    OBS.obs_data_set_default_bool(settings, "debug_logs", false)
end

function script_save(settings)
    -- Save the custom hotkey information
    for k, v in pairs(HOTKEYS) do
        if v ~= nil then
            local hotkey_save_array = OBS.obs_hotkey_save(v)
            OBS.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey." .. k, hotkey_save_array)
            OBS.obs_data_array_release(hotkey_save_array)
        end
    end
end

function settings_update(obs_settings_obj)
    local old_settings
    old_settings, SETTINGS = SETTINGS, {
        dc_source_name = OBS.obs_data_get_string(obs_settings_obj, "source"),
        zoom_value = OBS.obs_data_get_double(obs_settings_obj, "zoom_value"),
        zoom_speed = OBS.obs_data_get_double(obs_settings_obj, "zoom_speed"),
        use_auto_follow_mouse = OBS.obs_data_get_bool(obs_settings_obj, "follow"),
        follow_outside_bounds = OBS.obs_data_get_bool(obs_settings_obj, "follow_outside_bounds"),
        clamp_to_edges = OBS.obs_data_get_bool(obs_settings_obj, "clamp_to_edges"),
        follow_speed = OBS.obs_data_get_double(obs_settings_obj, "follow_speed"),
        follow_border = OBS.obs_data_get_int(obs_settings_obj, "follow_border"),
        follow_safezone_sensitivity = OBS.obs_data_get_int(obs_settings_obj, "follow_safezone_sensitivity"),
        use_follow_auto_lock = OBS.obs_data_get_bool(obs_settings_obj, "follow_auto_lock"),
        allow_all_sources = OBS.obs_data_get_bool(obs_settings_obj, "allow_all_sources"),
        use_monitor_override = OBS.obs_data_get_bool(obs_settings_obj, "USE_MONITOR_OVERRIDE"),
        monitor_override_x = OBS.obs_data_get_int(obs_settings_obj, "monitor_override_x"),
        monitor_override_y = OBS.obs_data_get_int(obs_settings_obj, "monitor_override_y"),
        monitor_override_w = OBS.obs_data_get_int(obs_settings_obj, "monitor_override_w"),
        monitor_override_h = OBS.obs_data_get_int(obs_settings_obj, "monitor_override_h"),
        monitor_override_sx = OBS.obs_data_get_double(obs_settings_obj, "monitor_override_sx"),
        monitor_override_sy = OBS.obs_data_get_double(obs_settings_obj, "monitor_override_sy"),
        monitor_override_dw = OBS.obs_data_get_int(obs_settings_obj, "monitor_override_dw"),
        monitor_override_dh = OBS.obs_data_get_int(obs_settings_obj, "monitor_override_dh"),
        use_socket = OBS.obs_data_get_bool(obs_settings_obj, "use_socket"),
        socket_port = OBS.obs_data_get_int(obs_settings_obj, "socket_port"),
        socket_poll = OBS.obs_data_get_int(obs_settings_obj, "socket_poll"),
        debug_logs = OBS.obs_data_get_bool(obs_settings_obj, "debug_logs"),
    }

    local changed_keys = {}
    for k, v in pairs(SETTINGS) do
        if v ~= old_settings[k] then
            changed_keys[k] = true
        end
    end
    return changed_keys
end

function script_update(obs_settings_obj)
    -- Update the settings
    local changed_keys = settings_update(obs_settings_obj)

    -- Only do the expensive refresh if the user selected a new source
    if IS_OBS_LOADED and changed_keys.dc_source_name then
        refresh_sceneitem(true)
    end

    -- Update the monitor_info if the settings changed
    if
        changed_keys.dc_source_name or
        changed_keys.use_monitor_override or
        changed_keys.monitor_override_x or
        changed_keys.monitor_override_y or
        changed_keys.monitor_override_w or
        changed_keys.monitor_override_h or
        changed_keys.monitor_override_sx or
        changed_keys.monitor_override_sy or
        changed_keys.monitor_override_w or
        changed_keys.monitor_override_h then
        if IS_OBS_LOADED then
            MONITOR_INFO = get_monitor_info(DC_SOURCE)
        end
    end

    if changed_keys.use_socket then
        if USE_SOCKET then
            start_server()
        else
            stop_server()
        end
    elseif SETTINGS.use_socket and (changed_keys.socket_port or changed_keys.socket_port) then
        stop_server()
        start_server()
    end
end

function populate_zoom_sources(list)
    OBS.obs_property_list_clear(list)

    local sources = OBS.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        OBS.obs_property_list_add_string(list, "<None>", "obs-zoom-to-mouse-none")
        for _, source in ipairs(sources) do
            local source_type = OBS.obs_source_get_id(source)
            if source_type == dc_info.source_id or SETTINGS.allow_all_sources then
                local name = OBS.obs_source_get_name(source)
                OBS.obs_property_list_add_string(list, name, name)
            end
        end

        OBS.source_list_release(sources)
    end
end
