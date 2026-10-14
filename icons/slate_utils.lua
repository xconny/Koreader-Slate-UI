-- Modified for Slate on 2026-10-10.
--[[
    Utility Functions for Slate
    Helper functions for time formatting, icon paths, caching, and icon installation
--]]

local DataStorage = require("datastorage")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local util = require("util")
local Device = require("device")
local Screen = Device.screen

local SlateUtils = {}

function SlateUtils:scaleToScreenHeight(max_height, base_sizes, top_bottom_margin, header_font_size, header_margin)
    --[[
        Scales a set of base sizes to fit within available height.

        Args:
            screen_height: available_height:
            base_sizes: table with:
                - elements: array of element heights that will be stacked vertically
            top_bottom_margin: total margin (top + bottom)
            header_font_size: fixed header font size
            header_margin: fixed header margin

        Returns:
            scale_factor: the factor to apply to all base sizes (1.0 if content fits, <1.0 if scaled down)
    ]]

    -- Calculate available space
    local header_height = header_font_size + header_margin * 2
    local available_height = max_height - header_height - 2 * top_bottom_margin

    -- Calculate total required height
    local estimated_height = 0
    for _, element_height in ipairs(base_sizes.elements) do
        estimated_height = estimated_height + element_height
    end

    -- Calculate scale factor
    local scale_factor = 1.0
    if estimated_height > available_height then
        scale_factor = available_height / estimated_height
        logger.dbg("Slate: Content scaled down to:", scale_factor,
                   "- estimated:", estimated_height, "available:", available_height)
    else
        logger.dbg("Slate: Content fits without scaling - estimated:", estimated_height,
                   "available:", available_height)
    end

    return scale_factor
end

function SlateUtils:formatHourLabel(hour, twelve_hour_clock)
    if twelve_hour_clock then
        if hour == 0 then
            return "12 AM"
        elseif hour < 12 then
            return hour .. " AM"
        elseif hour == 12 then
            return "12 PM"
        else
            return (hour - 12) .. " PM"
        end
    else
        return hour .. ":00"
    end
end

local moon_phases = {
    ["new moon"] = { "New Moon", "new_moon.svg" },
    ["waxing crescent"] = { "Waxing Crescent", "waxing_crescent.svg" },
    ["first quarter"] = { "First Quarter", "first_quarter.svg" },
    ["waxing gibbous"] = { "Waxing Gibbous", "waxing_gibbous.svg" },
    ["full moon"] = { "Full Moon", "full_moon.svg" },
    ["waning gibbous"] = { "Waning Gibbous", "waning_gibbous.svg" },
    ["last quarter"] = { "Last Quarter", "last_quarter.svg" },
    ["third quarter"] = { "Last Quarter", "last_quarter.svg" },
    ["waning crescent"] = { "Waning Crescent", "waning_crescent.svg" },
}

function SlateUtils:normalizeMoonPhase(phase)
    if type(phase) ~= "string" then return nil end
    local key = phase:lower():gsub("[_%-]", " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", "")
    local entry = moon_phases[key]
    return entry and entry[1] or nil
end

function SlateUtils:getMoonPhaseIcon(moon_phase)
    local phase = self:normalizeMoonPhase(moon_phase)
    if not phase then return nil end
    local entry = moon_phases[phase:lower()]
    local path = DataStorage:getDataDir() .. "/icons/moonphases/" .. entry[2]
    local f = io.open(path, "r")
    if f then
        f:close()
        return path
    end
    return nil
end

-- Convert a civil date to UTC seconds without using the device's timezone.
function SlateUtils:dateTimeToEpoch(value)
    if type(value) ~= "string" then return nil end
    local y, m, d, h, minute = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d?):(%d%d)")
    if not y then
        y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        h, minute = 0, 0
    end
    y, m, d, h, minute = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute)
    if not y or not m or not d or not h or not minute then return nil end
    if y < 1970 or y > 9999 or m < 1 or m > 12 or h < 0 or h > 23
        or minute < 0 or minute > 59 then return nil end
    local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
    local lengths = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if d < 1 or d > lengths[m] then return nil end
    local adjusted_y = y - (m <= 2 and 1 or 0)
    local era = math.floor(adjusted_y / 400)
    local year_of_era = adjusted_y - era * 400
    local adjusted_m = m + (m > 2 and -3 or 9)
    local day_of_year = math.floor((153 * adjusted_m + 2) / 5) + d - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    return (era * 146097 + day_of_era - 719468) * 86400 + h * 3600 + minute * 60
end

function SlateUtils:getWeatherLocalDate(weather_data, now)
    local current = type(weather_data) == "table" and weather_data.current
    if type(current) ~= "table" then return nil end
    now = tonumber(now) or os.time()
    local offset = tonumber(current.utc_offset)
    if offset and math.abs(offset) <= 86400 then
        return os.date("!%Y-%m-%d", now + offset)
    end
    -- Use the API location clock as an anchor when an offset is unavailable.
    local anchor = self:dateTimeToEpoch(current.localtime)
    local fetched_at = tonumber(weather_data.fetched_at)
    if anchor and fetched_at and now >= fetched_at then
        return os.date("!%Y-%m-%d", anchor + now - fetched_at)
    end
    return nil
end

function SlateUtils:prepareWeatherData(weather_data, now, max_age)
    if type(weather_data) ~= "table" then return nil end
    now = tonumber(now) or os.time()
    local current = weather_data.current
    if type(current) ~= "table" then return nil end
    local observation = tonumber(current.observation_epoch)
    local fetched_at = tonumber(weather_data.fetched_at)
    local reference = observation or fetched_at
    if reference then
        weather_data.age_seconds = math.max(0, now - reference)
        weather_data.is_stale = reference > now + 300
            or weather_data.age_seconds > (max_age or self:getCacheMaxAge())
    else
        weather_data.is_stale = true
    end
    local astronomy = weather_data.astronomy
    if type(astronomy) == "table" then
        if astronomy.source == "astronomy" and astronomy.moon_phase
            and self:dateTimeToEpoch(astronomy.date) then
            weather_data.astronomy_days = weather_data.astronomy_days or {}
            local saved = {}
            for key, value in pairs(astronomy) do saved[key] = value end
            weather_data.astronomy_days[astronomy.date] = saved
        end
        local today = self:getWeatherLocalDate(weather_data, now)
        if today and astronomy.date == today and astronomy.source == "astronomy" then
            astronomy.moon_phase = self:normalizeMoonPhase(astronomy.moon_phase)
            astronomy.is_stale = false
        else
            -- Reject legacy forecast Moon values as well as earlier dates.
            -- The forecast and astronomy endpoints can disagree.
            astronomy.moon_phase = nil
            astronomy.moon_illumination = nil
            astronomy.is_stale = true
        end
    end
    return weather_data
end

function SlateUtils:getPluginDir()
    local callerSource = debug.getinfo(2, "S").source
    if callerSource:find("^@") then
        return callerSource:gsub("^@(.*)/[^/]*", "%1")
    end
end

function SlateUtils:getCacheMaxAge()
    local age = tonumber(G_reader_settings:readSetting("slate_weather_cache_max_age"))
    if not age or age ~= age or age == math.huge or age < 0 then return 3600 end
    return age
end

local function cache_context()
    local location = tostring(G_reader_settings:readSetting("slate_weather_location") or "")
        :lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return {
        location = location,
        temperature_unit = G_reader_settings:readSetting("slate_weather_temp_scale") or "C",
    }
end

-- This function was inspired by Project: Title. Thanks!
function SlateUtils:installIcons(plugin_dir_func)
    local icons_path = DataStorage:getDataDir() .. "/icons"
    local icons_list = {
        "sun",
        "moon",
    }

    -- Moon phase icons.
    local moonphases_path = DataStorage:getDataDir() .. "/icons/moonphases"
    local moonphases_list = {
        "new_moon",
        "waxing_crescent",
        "first_quarter",
        "waxing_gibbous",
        "full_moon",
        "waning_gibbous",
        "last_quarter",
        "waning_crescent",
    }

    -- Wind direction icons.
    local arrows_path = DataStorage:getDataDir() .. "/icons/arrows"
    local arrows_list = {
        "arrow_n",
        "arrow_ne",
        "arrow_e",
        "arrow_se",
        "arrow_s",
        "arrow_sw",
        "arrow_w",
        "arrow_nw",
    }

    local function checkicons()
        logger.dbg("Slate: Checking for icons")
        local icons_found = true
        for _, icon in ipairs(icons_list) do
            local icon_file = icons_path .. "/" .. icon .. ".svg"
            if not util.fileExists(icon_file) then
                icons_found = false
                break
            end
        end
        if icons_found then
            logger.dbg("Slate: All icons found")
            return true
        else
            return false
        end
    end

    local function checkmoonphases()
        logger.dbg("Slate: Checking for moon phase icons")
        local moonphases_found = true
        for _, moonphase in ipairs(moonphases_list) do
            local moonphase_file = moonphases_path .. "/" .. moonphase .. ".svg"
            if not util.fileExists(moonphase_file) then
                moonphases_found = false
                break
            end
        end
        if moonphases_found then
            logger.dbg("Slate: All moon phase icons found")
            return true
        else
            return false
        end
    end

    local function checkarrows()
        logger.dbg("Slate: Checking for arrow icons")
        local arrows_found = true
        for _, arrow in ipairs(arrows_list) do
            local arrow_file = arrows_path .. "/" .. arrow .. ".svg"
            if not util.fileExists(arrow_file) then
                arrows_found = false
                break
            end
        end
        if arrows_found then
            logger.dbg("Slate: All arrow icons found")
            return true
        else
            return false
        end
    end

    if checkicons() and checkmoonphases() and checkarrows() then return true end

    local result
    if not util.directoryExists(icons_path) then
        result = util.makePath(icons_path .. "/")
        logger.dbg("Slate: Creating icons folder")
        if not result then return false end
    end

    if not util.directoryExists(moonphases_path) then
        result = util.makePath(moonphases_path .. "/")
        logger.dbg("Slate: Creating moonphases folder")
        if not result then return false end
    end

    if not util.directoryExists(arrows_path) then
        result = util.makePath(arrows_path .. "/")
        logger.dbg("Slate: Creating arrows folder")
        if not result then return false end
    end

    if util.directoryExists(icons_path) then
        local plugin_dir = plugin_dir_func()
        if not plugin_dir then
            logger.warn("Slate: plugin dir unknown; cannot copy bundled icons")
            return false
        end

        for _, icon in ipairs(icons_list) do
            -- check icon files one at a time, and only copy when missing
            -- this will preserve custom icons set by the user
            local icon_file = icons_path .. "/" .. icon .. ".svg"
            if not util.fileExists(icon_file) then
                local bundled_icon_file = plugin_dir .. "/icons/" .. icon .. ".svg"
                if util.fileExists(bundled_icon_file) then
                    logger.dbg("Slate: Copying icon " .. icon)
                    ffiUtil.copyFile(bundled_icon_file, icon_file)
                else
                    logger.warn("Slate: bundled icon missing: " .. bundled_icon_file)
                end
            end
        end

        for _, moonphase in ipairs(moonphases_list) do
            -- check moonphase files one at a time, and only copy when missing
            -- this will preserve custom moonphases set by the user
            local moonphase_file = moonphases_path .. "/" .. moonphase .. ".svg"
            if not util.fileExists(moonphase_file) then
                local bundled_moonphase_file = plugin_dir .. "/icons/moonphases/" .. moonphase .. ".svg"
                if util.fileExists(bundled_moonphase_file) then
                    logger.dbg("Slate: Copying moon phase " .. moonphase)
                    ffiUtil.copyFile(bundled_moonphase_file, moonphase_file)
                else
                    logger.warn("Slate: bundled moon phase missing: " .. bundled_moonphase_file)
                end
            end
        end

        for _, arrow in ipairs(arrows_list) do
            -- check arrow files one at a time, and only copy when missing
            -- this will preserve custom arrows set by the user
            local arrow_file = arrows_path .. "/" .. arrow .. ".svg"
            if not util.fileExists(arrow_file) then
                local bundled_arrow_file = plugin_dir .. "/icons/arrows/" .. arrow .. ".svg"
                if util.fileExists(bundled_arrow_file) then
                    logger.dbg("Slate: Copying arrow " .. arrow)
                    ffiUtil.copyFile(bundled_arrow_file, arrow_file)
                else
                    logger.warn("Slate: bundled arrow missing: " .. bundled_arrow_file)
                end
            end
        end
    end

    if checkicons() and checkmoonphases() and checkarrows() then return true end
    return false
end

function SlateUtils:mergeWeatherHistory(weather_data, previous, now)
    if type(weather_data) ~= "table" then return weather_data end
    now = tonumber(now) or os.time()
    local today = self:getWeatherLocalDate(weather_data, now) or os.date("%Y-%m-%d", now)
    local today_epoch = self:dateTimeToEpoch(today)
    if not today_epoch then return weather_data end
    local weekday = tonumber(os.date("!%w", today_epoch))
    local monday = today_epoch - ((weekday + 6) % 7) * 86400
    local last_day = today_epoch + 6 * 86400
    local days, astronomy = {}, {}

    local function inRange(date)
        local epoch = self:dateTimeToEpoch(date)
        return epoch and epoch >= monday and epoch <= last_day
    end

    local function add(source)
        if type(source) ~= "table" then return end
        for _, day in ipairs(source.forecast_days or {}) do
            if type(day) == "table" and inRange(day.date) then
                local old = days[day.date]
                local merged = {}
                if old then
                    for key, value in pairs(old) do merged[key] = value end
                end
                for key, value in pairs(day) do merged[key] = value end
                days[day.date] = merged
            end
        end
        for date, astro in pairs(source.astronomy_days or {}) do
            if type(astro) == "table" and astro.date == date
                and astro.source == "astronomy" and inRange(date) then
                astronomy[date] = astro
            end
        end
        local astro = source.astronomy
        if type(astro) == "table" and astro.source == "astronomy"
            and astro.moon_phase and inRange(astro.date) then
            astronomy[astro.date] = astro
        end
    end

    add(previous)
    add(weather_data)
    local result = {}
    for date, day in pairs(days) do
        local astro = astronomy[date]
        if astro and self:normalizeMoonPhase(astro.moon_phase) then
            day.moon_phase = self:normalizeMoonPhase(astro.moon_phase)
            day.moon_illumination = tonumber(astro.moon_illumination)
            day.moon_source = "astronomy"
        end
        local epoch = self:dateTimeToEpoch(date)
        day.date_epoch = epoch
        day.weekday = tonumber(os.date("!%w", epoch))
        day.day_name = date == today and "Today"
            or (date == os.date("!%Y-%m-%d", today_epoch + 86400)
                and "Tomorrow" or os.date("!%a", epoch))
        result[#result + 1] = day
    end
    table.sort(result, function(a, b) return a.date < b.date end)
    weather_data.forecast_days = result
    weather_data.forecast_days_available = #result
    weather_data.astronomy_days = astronomy
    return weather_data
end

function SlateUtils:saveWeatherCache(weather_data)
    if type(weather_data) ~= "table" or type(weather_data.current) ~= "table" then
        return false
    end
    local now = os.time()
    weather_data.fetched_at = tonumber(weather_data.fetched_at) or now
    local previous = self:loadWeatherCache(nil, true)
    self:mergeWeatherHistory(weather_data, previous, now)
    local cache_file = DataStorage:getDataDir() .. "/cache/slate-weather.json"
    util.makePath(DataStorage:getDataDir() .. "/cache/")
    local json = require("json")
    local ok, encoded = pcall(json.encode, {
        version = 2,
        timestamp = now,
        context = cache_context(),
        data = weather_data,
    })
    if not ok then return false end
    -- Write a temporary file first so an interrupted save cannot truncate
    -- the last valid cache.
    local temporary = cache_file .. ".tmp"
    local f = io.open(temporary, "w")
    if not f then return false end
    local written = f:write(encoded)
    local closed = f:close()
    if not written or not closed then
        os.remove(temporary)
        return false
    end
    local renamed = os.rename(temporary, cache_file)
    if not renamed then os.remove(temporary) end
    return renamed and true or false
end

function SlateUtils:loadWeatherCache(get_max_age_func, allow_stale)
    local cache_file = DataStorage:getDataDir() .. "/cache/slate-weather.json"
    local f = io.open(cache_file, "r")
    if not f then return nil, false end
    local content = f:read("*all")
    f:close()
    local json = require("json")
    local ok, cache = pcall(json.decode, content or "")
    if not ok or type(cache) ~= "table" or cache.version ~= 2
        or type(cache.context) ~= "table" or type(cache.data) ~= "table"
        or type(cache.data.current) ~= "table" then
        return nil, false
    end
    local expected = cache_context()
    if cache.context.location ~= expected.location
        or cache.context.temperature_unit ~= expected.temperature_unit then
        return nil, false
    end
    local saved_at = tonumber(cache.timestamp)
    local now = os.time()
    if not saved_at or saved_at ~= saved_at or saved_at <= 0
        or saved_at > now + 300 then return nil, false end
    local data = cache.data
    data.fetched_at = tonumber(data.fetched_at) or saved_at
    local max_age = self:getCacheMaxAge()
    if type(get_max_age_func) == "function" then
        local success, result = pcall(get_max_age_func)
        result = success and tonumber(result) or nil
        if result and result == result and result >= 0 and result < math.huge then
            max_age = result
        end
    end
    self:prepareWeatherData(data, now, max_age)
    local cache_age = math.max(0, now - saved_at)
    data.cache_age_seconds = cache_age
    data.is_cached = true
    data.is_stale = data.is_stale or cache_age > max_age
        or (data.age_seconds and data.age_seconds > max_age) or false
    if allow_stale ~= true and data.is_stale then return nil, false end
    return data, true
end

function SlateUtils:clearCache()
    local cache_file = DataStorage:getDataDir() .. "/cache/slate-weather.json"
    local icons_cache_dir = DataStorage:getDataDir() .. "/cache/slate-weather-icons/"

    local cleared = false

    -- Remove cached weather data
    if util.fileExists(cache_file) then
        os.remove(cache_file)
        logger.dbg("Slate: Removed cached weather data")
        cleared = true
    end

    -- Remove cached weather icons directory
    if util.directoryExists(icons_cache_dir) then
        -- Remove all files in the directory
        local lfs = require("libs/libkoreader-lfs")
        for entry in lfs.dir(icons_cache_dir) do
            if entry ~= "." and entry ~= ".." then
                local file_path = icons_cache_dir .. entry
                logger.dbg("Slate: Removed ", file_path)
                os.remove(file_path)
            end
        end
        -- Remove the directory itself
        lfs.rmdir(icons_cache_dir)
        logger.dbg("Slate: Removed cached weather icons")
        cleared = true
    end

    return cleared
end

--------------------------------------------------------------------
-- Reading-information cache shared by both display modes.       --
--  (fixed to use writable DataStorage dir, with legacy fallback) --
--------------------------------------------------------------------

-- Primary cache path: always under DataStorage (writable on all devices)
function SlateUtils:getDocInfoCachePath()
    -- keep it simple & predictable
    return DataStorage:getDataDir() .. "/cache/slate-docinfo.json"
end

function SlateUtils:saveDocInfoCache(doc_info)
    if not doc_info or type(doc_info) ~= "table" then
        return false
    end

    local path = self:getDocInfoCachePath()
    -- ensure parent dir exists
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        util.makePath(dir .. "/")
    end

    local f = io.open(path, "w")
    if not f then
        logger.warn("Slate: Unable to open docinfo cache file for writing: " .. path)
        return false
    end

    local json = require("json")
    local ok, encoded = pcall(json.encode, doc_info)
    if not ok then
        logger.warn("Slate: Failed to encode docinfo cache as JSON")
        f:close()
        return false
    end

    f:write(encoded)
    f:close()
    return true
end

function SlateUtils:loadDocInfoCache()
    local json = require("json")

    local function try_path(path)
        if not path then return nil end
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local content = f:read("*all")
        f:close()
        local ok, data = pcall(json.decode, content)
        if not ok or type(data) ~= "table" then
            logger.warn("Slate: Failed to decode docinfo cache JSON at " .. path)
            return nil
        end
        return data
    end

    -- 1) New primary path in DataStorage
    local primary_path = self:getDocInfoCachePath()
    local data = try_path(primary_path)
    if data then
        return data
    end

    -- 2) Legacy path in plugin dir (if any), to not break existing caches
    local plugin_dir = self:getPluginDir()
    if plugin_dir and plugin_dir ~= "" then
        local legacy_path = plugin_dir .. "/last_docinfo.json"
        data = try_path(legacy_path)
        if data then
            -- re-save into the new primary location for future runs
            pcall(function()
                self:saveDocInfoCache(data)
            end)
            return data
        end
    end

    return nil
end

function SlateUtils:popupThemeIsOpposite()
    local mode = G_reader_settings:readSetting("slate_weather_widget_theme_override", "default")
    local real = G_reader_settings:isTrue("night_mode")
    return (mode == "night" and not real) or (mode == "day" and real)
end

function SlateUtils:paintThemedPopup(widget, bb, paint, ...)
    if not self:popupThemeIsOpposite() then
        return paint(widget, bb, ...)
    end
    local rect = widget.box or (widget.frame and widget.frame.dimen) or widget.dimen
    if not rect or not rect.x or not rect.y or not rect.w or not rect.h then
        -- Standard dialogs may only establish their bounds during painting.
        -- Invert before and after painting so untouched pixels are restored.
        rect = { x = 0, y = 0, w = bb:getWidth(), h = bb:getHeight() }
    end
    local x, y = math.max(0, rect.x), math.max(0, rect.y)
    local w = math.min(bb:getWidth(), rect.x + rect.w) - x
    local h = math.min(bb:getHeight(), rect.y + rect.h) - y
    if w <= 0 or h <= 0 then return paint(widget, bb, ...) end
    bb:invertRect(x, y, w, h)
    local ok, result = pcall(paint, widget, bb, ...)
    bb:invertRect(x, y, w, h)
    if not ok then error(result) end
    return result
end

function SlateUtils:themePopup(widget)
    if not widget or widget._slate_theme_wrapped then return widget end
    local paint = widget.paintTo
    if type(paint) ~= "function" then return widget end
    widget._slate_theme_wrapped = true
    widget.paintTo = function(instance, bb, ...)
        return SlateUtils:paintThemedPopup(instance, bb, paint, ...)
    end
    return widget
end

return SlateUtils