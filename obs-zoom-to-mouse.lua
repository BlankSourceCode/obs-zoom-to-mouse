--
-- OBS Zoom to Mouse
-- An OBS lua script to zoom a display-capture source to focus on the mouse.
-- Copyright (c) BlankSourceCode.  All rights reserved.
--

local obs = obslua
local ffi = require("ffi")
local VERSION = "1.0"
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
local hotkey_zoom_id = nil
local hotkey_follow_id = nil
local is_timer_running = false
local ppoint = nil

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.1
local follow_border = 0
local follow_safezone_sensitivity = 10
local zoom_value = 2
local zoom_speed = 0.1
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local debug_logs = false

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

-- Define the GetCursorPos function for Windows
-- TODO: Figure out how to do this for Linux/Mac
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
    ]])
    ppoint = ffi.new("POINT[1]")
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    -- TODO: Get the cursor position for Linux/Mac
    if ffi.os == "Windows" then
        if ppoint and ffi.C.GetCursorPos(ppoint) ~= 0 then
            mouse.x = ppoint[0].x
            mouse.y = ppoint[0].y
        end
    end

    return mouse
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
    local props = obs.obs_source_properties(source)
    if props ~= nil then
        local monitor_id_prop = obs.obs_properties_get(props, "monitor_id")
        if monitor_id_prop then
            local to_match = obs.obs_data_get_string(obs.obs_source_get_settings(source), "monitor_id")
            local found = nil
            local item_count = obs.obs_property_list_item_count(monitor_id_prop);
            for i = 0, item_count do
                local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                local value = obs.obs_property_list_item_string(monitor_id_prop, i)
                if value == to_match then
                    found = name
                    break
                end
            end

            -- This works for my machine as the monitor names are given as "U2790B: 3840x2160 @ 0,0 (Primary Monitor)"
            -- I don't know if this holds true for other machines and/or OBS versions
            -- TODO: Update this with some custom FFI calls to find the monitor top-left x and y coordinates if it doesn't work for anyone else
            -- TODO: Refactor this into something that would work with Windows/Linux/Mac assuming we can't do it like this
            if found then
                local x, y = found:match("@ (%d+),(%d+)")
                local width, height = found:match(": (%d+)x(%d+)")

                info = { x = 0, y = 0, width = 0, height = 0 }
                info.x = tonumber(x, 10)
                info.y = tonumber(y, 10)
                info.width = tonumber(width, 10)
                info.height = tonumber(height, 10)

                log("Parsed the following display information\n" .. format_table(info))

                if info.width == 0 and info.height == 0 then
                    info = nil
                end
            end
        end

        obs.obs_properties_destroy(props)
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h
        }
    end

    return info
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
            obs.obs_sceneitem_get_info(sceneitem, sceneitem_info_orig)
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

        -- Get a matching source we can use for zooming in the current scene
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                -- Get the source size, for some reason this works during load but the sceneitem source doesn't
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local scene = obs.obs_scene_from_source(scene_source)
                    if scene ~= nil then
                        sceneitem = obs.obs_scene_sceneitem_from_source(scene, source)

                        local x = obs.obs_scene_find_source(scene, source_name)

                        if not x then
                            log("Warning: Source not part of the current scene")
                            obs.obs_source_release(scene_source)
                            obs.obs_sceneitem_release(sceneitem)
                            obs.obs_source_release(source)

                            sceneitem = nil
                            source = nil
                            return
                        end
                        monitor_info = get_monitor_info(source)
                    end

                    obs.obs_source_release(scene_source)
                end
            end
        end
    end

    if sceneitem ~= nil then
        -- Capture the original settings so we can restore them later
        sceneitem_info_orig = obs.obs_transform_info()
        obs.obs_sceneitem_get_info(sceneitem, sceneitem_info_orig)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = obs.obs_transform_info()
        obs.obs_sceneitem_get_info(sceneitem, sceneitem_info)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        -- Get the current source size (this will be the value after any applied crop filters)
        if not source then
            log("Error: Could not get source for sceneitem (" .. source_name .. ")")
        end

        -- TODO: Figure out why we need this fallback code
        local source_width = obs.obs_source_get_width(source)
        local source_height = obs.obs_source_get_height(source)
        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        log("Source size determined as " .. source_width .. ", " .. source_height)
        if source_width == 0 or source_height == 0 then
            if monitor_info and monitor_info.height > 0 and monitor_info.height > 0 then
                log("Warning: Something went wrong determining source size, defaulting to monitor size " .. monitor_info.width .. ", " .. monitor_info.height)
                source_width = monitor_info.width
                source_height = monitor_info.height
            else
                log("Error: Something went wrong determining source size, try using the 'Set manual monitor position' option and adding override values")
            end
        end

        -- Convert the current transform into one we can correctly modify for zooming
        -- Ideally the user just has a valid one set and we don't have to change anything because this might not work 100% of the time
        if sceneitem_info.bounds_type == obs.OBS_BOUNDS_NONE then
            sceneitem_info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
            sceneitem_info.bounds_alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT) (0 == OBS_ALIGN_CENTER)
            sceneitem_info.bounds.x = source_width * sceneitem_info.scale.x
            sceneitem_info.bounds.y = source_height * sceneitem_info.scale.y

            obs.obs_sceneitem_set_info(sceneitem, sceneitem_info)

            log("Warning: Found existing non-boundingbox transform. This may cause issues with zooming.\n" ..
                "Settings have been auto converted to a bounding box scaling transfrom instead.\n" ..
                "If you have issues with your layout consider making the transform use a bounding box manually.")
        end

        -- Get information about any existing crop filters (that aren't ours)
        zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
        local found_crop_filter = false
        local filters = obs.obs_source_enum_filters(source)
        if filters ~= nil then
            for k, v in pairs(filters) do
                local id = obs.obs_source_get_id(v)
                if id == "crop_filter" then
                    local name = obs.obs_source_get_name(v)
                    if name ~= CROP_FILTER_NAME then
                        found_crop_filter = true
                        local settings = obs.obs_source_get_settings(v)
                        if settings ~= nil then
                            if not obs.obs_data_get_bool(settings, "relative") then
                                zoom_info.source_crop_filter.x =
                                    zoom_info.source_crop_filter.x + obs.obs_data_get_int(settings, "left")
                                zoom_info.source_crop_filter.y =
                                    zoom_info.source_crop_filter.y + obs.obs_data_get_int(settings, "top")
                                zoom_info.source_crop_filter.w =
                                    zoom_info.source_crop_filter.w + obs.obs_data_get_int(settings, "cx")
                                zoom_info.source_crop_filter.h =
                                    zoom_info.source_crop_filter.h + obs.obs_data_get_int(settings, "cy")
                                log("Found existing relative crop/pad filter (" ..
                                    name ..
                                    "). Applying settings " .. format_table(zoom_info.source_crop_filter))
                            else
                                log("Warning: Found existing non-relative crop/pad filter (" ..
                                    name ..
                                    ").\nThis will cause issues with zooming.\nConvert to relative settings instead.")
                            end
                            obs.obs_data_release(settings)
                        end
                    end
                end
            end

            obs.source_list_release(filters)
        end

        -- If the user has a transform crop set, we need to convert it into a crop filter so that it works correctly with zooming
        -- Ideally the user does this manually and uses a crop filter instead of the transfrom crop because this might not work 100% of the time
        if not found_crop_filter and (sceneitem_crop_orig.left ~= 0 or sceneitem_crop_orig.top ~= 0 or sceneitem_crop_orig.right ~= 0 or sceneitem_crop_orig.bottom ~= 0) then
            -- Update the source size
            source_width = source_width - (sceneitem_crop_orig.left + sceneitem_crop_orig.right)
            source_height = source_height - (sceneitem_crop_orig.top + sceneitem_crop_orig.bottom)

            -- Update the source crop filter now that we will be using one
            zoom_info.source_crop_filter.x = sceneitem_crop_orig.left
            zoom_info.source_crop_filter.y = sceneitem_crop_orig.top
            zoom_info.source_crop_filter.w = source_width
            zoom_info.source_crop_filter.h = source_height

            -- Add a new crop filter that emulates the existing transform crop
            local settings = obs.obs_data_create()
            obs.obs_data_set_bool(settings, "relative", false)
            obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
            obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
            obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
            obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
            crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
            obs.obs_source_filter_add(source, crop_filter_temp)
            obs.obs_data_release(settings)

            -- Clear out the transform crop
            sceneitem_crop.left = 0
            sceneitem_crop.top = 0
            sceneitem_crop.right = 0
            sceneitem_crop.bottom = 0
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)

            log("Warning: Found existing transform crop. This may cause issues with zooming.\n" ..
                "Settings have been auto converted to a relative crop/pad filter instead.\n" ..
                "If you have issues with your layout consider making the filter manually.")
        end

        -- Get the rest of the information needed to correctly zoom
        zoom_info.source_size = { width = source_width, height = source_height }
        zoom_info.source_crop = {
            l = sceneitem_crop_orig.left,
            t = sceneitem_crop_orig.top,
            r = sceneitem_crop_orig.right,
            b = sceneitem_crop_orig.bottom
        }
        --log("Transform updated. Using following values -\n" .. format_table(zoom_info))

        -- Set the initial the crop filter data to match the source
        crop_filter_info_orig = { x = 0, y = 0, w = zoom_info.source_size.width, h = zoom_info.source_size.height }
        crop_filter_info = {
            x = crop_filter_info_orig.x,
            y = crop_filter_info_orig.y,
            w = crop_filter_info_orig.w,
            h = crop_filter_info_orig.h
        }

        -- Get or create our crop filter that we change during zoom
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
---@param zoom_info any
---@return table
function get_target_position(zoom_info)
    local mouse = get_mouse_pos()

    -- If we have monitor information then we can offset the mouse by the top-left of the monitor position
    -- This is because the display-capture source assumes top-left is 0,0 but the mouse uses the total desktop area,
    -- so a second monitor might start at x:1920, y:0 for example, so when we click at 1920,0 we want it to look like we clicked 0,0 on the source.
    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    -- Now offset the mouse by the crop top-left because if we cropped 100px off of the display clicking at 100,0 should really be the top-left 0,0
    mouse.x = mouse.x - zoom_info.source_crop_filter.x
    mouse.y = mouse.y - zoom_info.source_crop_filter.y

    -- Get the new size after we zoom
    -- Remember that because we are using a crop/pad filter making the size smaller (dividing by zoom) means that we see less of the image
    -- in the same amount of space making it look bigger (aka zoomed in)
    local new_size = {
        width = zoom_info.source_size.width / zoom_info.zoom_to,
        height = zoom_info.source_size.height / zoom_info.zoom_to
    }

    -- New offset for the crop/pad filter is whereever we clicked minus half the size, so that the clicked point because the new center
    local pos = {
        x = mouse.x - new_size.width * 0.5,
        y = mouse.y - new_size.height * 0.5
    }

    -- Create the full crop results
    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    -- Keep the zoom in bounds of the source so that we never show something outside that user is trying to hide with existing crop settings
    crop.x = clamp(0, (zoom_info.source_size.width - new_size.width), crop.x)
    crop.y = clamp(0, (zoom_info.source_size.height - new_size.height), crop.y)


    return { crop = crop, raw_center = mouse, clamped_center = { x = crop.x + crop.w * 0.5, y = crop.y + crop.h * 0.5 } }
end

function on_toggle_follow(pressed)
    if pressed then
        is_following_mouse = not is_following_mouse
        log("Tracking mouse is " .. (is_following_mouse and "on" or "off"))

        if is_following_mouse and zoom_state == ZoomState.ZoomedIn then
            -- Since we are zooming we need to start the timer for the animation and tracking
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_toggle_zoom(pressed)
    if pressed then
        -- Check if we are in a safe state to zoom
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None then
            if zoom_state == ZoomState.ZoomedIn then
                log("Zooming out")
                -- To zoom out, we set the target back to whatever it was originally
                zoom_state = ZoomState.ZoomingOut
                zoom_time = 0
                locked_center = nil
                zoom_target = { crop = crop_filter_info_orig, c = sceneitem_crop_orig }
            else
                log("Zooming in")
                -- To zoom in, we get a new target based on where the mouse was when zoom was clicked
                zoom_state = ZoomState.ZoomingIn
                zoom_info.zoom_to = zoom_value
                zoom_time = 0
                locked_center = nil
                zoom_target = get_target_position(zoom_info)
            end

            -- Since we are zooming we need to start the timer for the animation and tracking
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
        -- Update our zoom time that we use for the animation
        zoom_time = zoom_time + zoom_speed

        if zoom_state == ZoomState.ZoomingOut or zoom_state == ZoomState.ZoomingIn then
            -- When we are doing a zoom animation (in or out) we linear interpolate the crop to the target
            if zoom_time <= 1 then
                crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, zoom_time)
                crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, zoom_time)
                crop_filter_info.w = lerp(crop_filter_info.w, zoom_target.crop.w, zoom_time)
                crop_filter_info.h = lerp(crop_filter_info.h, zoom_target.crop.h, zoom_time)
                set_crop_settings(crop_filter_info)
            end
        else
            -- If we are not zooming we only move the x/y to follow the mouse (width/height stay constant)
            if is_following_mouse then
                zoom_target = get_target_position(zoom_info)

                local skip_frame = false
                if not use_follow_outside_bounds then
                    if zoom_target.raw_center.x < zoom_target.crop.x or
                        zoom_target.raw_center.x > zoom_target.crop.x + zoom_target.crop.w or
                        zoom_target.raw_center.y < zoom_target.crop.y or
                        zoom_target.raw_center.y > zoom_target.crop.y + zoom_target.crop.h then
                        -- Don't follow the mouse if we are outside the bounds of the source
                        skip_frame = true
                    end
                end

                if not skip_frame then
                    -- If we have a locked_center it means we are currently in a locked zone and 
                    -- shouldn't track the mouse until it moves out of the area
                    if locked_center ~= nil then
                        local diff = {
                            x = math.abs(zoom_target.raw_center.x - locked_center.x),
                            y = math.abs(zoom_target.raw_center.y - locked_center.y)
                        }

                        local track = {
                            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
                            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
                        }

                        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                            -- Cursor moved into the active border area, so resume tracking by clearing out the locked_center
                            locked_center = nil
                            log("Locked area exited - resume tracking")
                        end
                    end

                    if locked_center == nil and (zoom_target.crop.x ~= crop_filter_info.x or zoom_target.crop.y ~= crop_filter_info.y) then
                        crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, follow_speed)
                        crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, follow_speed)
                        set_crop_settings(crop_filter_info)

                        -- Check to see if the mouse has stopped moving long enough to create a new safe zone
                        if is_following_mouse and locked_center == nil then
                            local diff = {
                                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                                y = math.abs(crop_filter_info.y - zoom_target.crop.y)
                            }

                            if diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity then
                                locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                                log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y )
                            end
                        end
                    end
                end
            end
        end

        -- Check to see if the animation is over
        if zoom_time >= 1 then
            local should_stop_timer = false
            -- When we finished zooming out we remove the timer
            if zoom_state == ZoomState.ZoomingOut then
                log("Zoomed out")
                zoom_state = ZoomState.None
                should_stop_timer = true
            elseif zoom_state == ZoomState.ZoomingIn then
                log("Zoomed in")
                zoom_state = ZoomState.ZoomedIn
                -- If we finished zooming in and we arent tracking the mouse we can also remove the timer
                should_stop_timer = (not use_auto_follow_mouse) and (not is_following_mouse)

                if use_auto_follow_mouse then
                    is_following_mouse = true
                    log("Tracking mouse is " .. (is_following_mouse and "on" or "off") .. " (due to auto follow)")
                end

                -- We set the current position as the center for the follow safezone
                if is_following_mouse and follow_border < 0.5 then
                    zoom_target = get_target_position(zoom_info)
                    locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                    log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                end
            end

            if should_stop_timer then
                is_timer_running = false
                obs.timer_remove(on_timer)
            end
        end
    end
end

function set_crop_settings(crop)
    if crop_filter ~= nil and crop_filter_settings ~= nil then
        -- Call into OBS to update our crop filter with the new settings
        -- I have no idea how slow/expensive this is, so we could potentially only do it if something changes
        obs.obs_data_set_int(crop_filter_settings, "left", math.floor(crop.x))
        obs.obs_data_set_int(crop_filter_settings, "top", math.floor(crop.y))
        obs.obs_data_set_int(crop_filter_settings, "cx", math.floor(crop.w))
        obs.obs_data_set_int(crop_filter_settings, "cy", math.floor(crop.h))
        obs.obs_source_update(crop_filter, crop_filter_settings)
    end
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        -- If the scene changes we attempt to find a new source with the same name in this new scene
        -- TODO: There probably needs to be a way for users to specify what source they want to use in each scene
        refresh_sceneitem(true)
    end
end

function on_update_transform()
    -- Update the crop/size settings based on whatever the source in the current scene looks like
    refresh_sceneitem(false)
    return true
end

function on_settings_modified(props, prop, settings)
    -- Show/Hide the settings based on if the checkbox is checked or not
    local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_x"), visible)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_y"), visible)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_w"), visible)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_h"), visible)
    return true
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "Help Information for OBS-Zoom-To-Mouse v" .. VERSION .. "\n" ..
        "https://github.com/BlankSourceCode/obs-zoom-to-mouse\n" ..
        "----------------------------------------------------\n" ..
        "This script will zoom the selected display-capture source to focus on the mouse\n\n" ..
        "Zoom Source: The display capture in the current scene to use for zooming\n" ..
        "Force transform update: Refresh the internal zoom data if you manually change the transform/filters on your zoom source\n" ..
        "Zoom Factor: How much to zoom in by\n" ..
        "Zoom Speed: The speed of the zoom in/out animation\n" ..
        "Auto follow mouse: True to track the cursor while you are zoomed in\n" ..
        "Follow outside bounds: True to track the cursor even when it is outside the bounds of the source\n" ..
        "Follow Speed: The speed at which the zoomed area will follow the mouse when tracking\n" ..
        "Follow Border: The %distance from the edge of the source that will re-enable mouse tracking\n" ..
        "Lock Sensitivity: How close the tracking needs to get before it locks into position and stops tracking until you enter the follow border\n" ..
        "Set manual monitor position: True to override the calculated x,y topleft position for the selected display\n" ..
        "X: The coordinate of the left most pixel of the display\n" ..
        "Y: The coordinate of the top most pixel of the display\n" ..
        "Width: The width of the display in pixels\n" ..
        "Height: The height of the display in pixels\n" ..
        "More Info: Show this text in the script log\n" ..
        "Enable debug logging: Show additional debug information in the script log\n\n"

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
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local source_id = obs.obs_source_get_id(source)
            local source_type = obs.obs_source_get_id(source)
            if source_type == "monitor_capture" then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(sources_list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    -- This button is used to recalculate the sceneitem and all the transform/crop values
    -- The idea being that if the user moves around the display capture source in their scene layout,
    -- they have a way to reset the zoom settings for the new info
    -- We could potentially do this automatically by listening to a bunch of events to see if anything changes
    -- but this is easier
    obs.obs_properties_add_button(props, "update_transform", "Force transform update", on_update_transform)

    -- Add the rest of the settings UI
    local zoom = obs.obs_properties_add_float(props, "zoom_value", "Zoom Factor", 1, 5, 0.5)
    local zoom_speed = obs.obs_properties_add_float_slider(props, "zoom_speed", "Zoom Speed", 0.01, 1, 0.01)
    local follow = obs.obs_properties_add_bool(props, "follow", "Auto follow mouse")
    local follow_outside_bounds = obs.obs_properties_add_bool(props, "follow_outside_bounds", "Follow outside bounds")
    local follow_speed = obs.obs_properties_add_float_slider(props, "follow_speed", "Follow Speed", 0.01, 1, 0.01)
    local follow_border = obs.obs_properties_add_int_slider(props, "follow_border", "Follow Border", 0, 50, 1)
    local safezone_sense = obs.obs_properties_add_int_slider(props,
        "follow_safezone_sensitivity", "Lock Sensitivity", 1, 20, 1)

    local override = obs.obs_properties_add_bool(props, "use_monitor_override", "Set manual monitor position")
    local override_x = obs.obs_properties_add_int(props, "monitor_override_x", "X", 0, 10000, 1)
    local override_y = obs.obs_properties_add_int(props, "monitor_override_y", "Y", 0, 10000, 1)
    local override_w = obs.obs_properties_add_int(props, "monitor_override_w", "X", 0, 10000, 1)
    local override_h = obs.obs_properties_add_int(props, "monitor_override_h", "Y", 0, 10000, 1)

    -- Add a button for more information
    obs.obs_properties_add_button(props, "help_button", "More Info", on_print_help)
    local debug = obs.obs_properties_add_bool(props, "debug_logs", "Enable debug logging")

    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_modified_callback(override, on_settings_modified)

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
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    obs.obs_frontend_add_event_callback(on_frontend_event)
end

function script_unload()
    -- Clean up the memory usage
    obs.obs_hotkey_unregister(on_toggle_zoom)
    obs.obs_hotkey_unregister(on_toggle_follow)
    obs.obs_frontend_remove_event_callback(on_frontend_event)
    release_sceneitem()
end

function script_defaults(settings)
    -- Default values for the script
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.1)
    obs.obs_data_set_default_bool(settings, "follow", false)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.1)
    obs.obs_data_set_default_int(settings, "follow_border", 2)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
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

    -- Update the settings
    source_name = obs.obs_data_get_string(settings, "source")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    -- Only do the expensive refresh if the user selected a new source
    if source_name ~= old_source_name then
        refresh_sceneitem(true)
    end
end