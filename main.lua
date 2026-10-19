-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-09.
-- Slate: reading, custom backgrounds, weather, quotes, and a plugin launcher.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local DataStorage = require("datastorage")
local ImageWidget = require("ui/widget/imagewidget")
local IconWidget = require("ui/widget/iconwidget")
local util = require("util")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local SlateWeatherAPI = require("slate_weather_api")
local SlateUtils = require("slate_utils")
local SlateQuickLaunch = require("slate_quicklaunch")
local SlateQuotes = require("slate_quotes")
local SlateSettings = require("slate_settings")
local SlatePinPad = require("slate_pinpad")
local SlateBooks = require("slate_books")

local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")

local function descriptionEvent(owner, event)
    local loaded, descriptions = pcall(require, "slate_book_descriptions")
    if not loaded or type(descriptions[event]) ~= "function" then return end
    local ok, err = pcall(descriptions[event], descriptions, owner)
    if not ok then logger.warn("Slate: book description update failed:", err) end
end

local function contains(rect, pos)
    return rect and pos and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function drawText(bb, text, x, y, w, h, size, bold, center)
    local widget
    for font_size = size, 1, -1 do
        widget = TextWidget:new{
            text = tostring(text or ""),
            face = Font:getFace("cfont", font_size),
            bold = bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local dim = widget:getSize()
        if (dim.h <= h and dim.w <= w) or font_size == 1 then break end
        widget:free()
    end
    local dim = widget:getSize()
    if center then
        x = x + math.max(0, math.floor((w - dim.w) / 2))
    end
    widget:paintTo(bb, x, y + math.max(0, math.floor((h - dim.h) / 2)))
    widget:free()
end

local function measureForecastText(text, size, bold)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = Font:getFace("cfont", size),
        bold = bold,
    }
    local dim = widget:getSize()
    widget:free()
    return dim.w, dim.h
end

local function wrapForecastText(text, width, size, bold)
    local lines, line = {}, ""
    for word in tostring(text or "—"):gmatch("%S+") do
        if measureForecastText(word, size, bold) > width then
            return nil
        end
        local proposed = line == "" and word or line .. " " .. word
        if measureForecastText(proposed, size, bold) <= width then
            line = proposed
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if #lines == 0 then lines[1] = "—" end
    return lines
end

local function popupUpdateLabel(data)
    local current = data.current or {}
    local fetched = tonumber(data.fetched_at)
    if fetched and not data.is_cached and not data.is_stale then
        local offset = tonumber(current.utc_offset)
        local clock = offset and os.date("!%H:%M", fetched+offset) or os.date("%H:%M", fetched)
        if G_reader_settings:isTrue("twelve_hour_clock") then
            local hour,minute = clock:match("^(%d%d):(%d%d)$")
            hour=tonumber(hour)
            clock=string.format("%d:%s %s",hour%12==0 and 12 or hour%12,minute,hour<12 and "AM" or "PM")
        end
        return _("Updated").." "..clock
    end
    return require("slate_reading"):formatObservationLabel(data)
end

local ForecastPopup = InputContainer:extend{ modal = true }

function ForecastPopup:init()
    self.closed = false
    self.dimen = Screen:getSize()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.box = {
        w = math.min(math.floor(w * 0.96), Screen:scaleBySize(900)),
        h = math.min(math.floor(h * 0.78), Screen:scaleBySize(420)),
    }
    self.box.x = math.floor((w - self.box.w) / 2)
    self.box.y = math.floor((h - self.box.h) / 2)
    self.pad = math.max(8, math.floor(self.box.w * 0.025))
    self.footer_gap = math.max(Screen:scaleBySize(12), math.floor(self.pad * 1.25))
    self.row_h = math.floor(
        (self.box.h - self.pad * 2) / 10
    )
    self.font_size = math.max(
        8, math.min(20, math.floor(self.row_h * 0.55))
    )
    self.heading_h = math.floor(self.row_h * 0.75)
    self.update_h = math.floor(self.row_h * 0.55)
    self.icons_h = self.row_h
    self.moon_h = math.floor(self.row_h * 1.25)
    self.box.h = self.pad * 2 + self.heading_h + self.update_h
        + self.row_h * 4 + self.icons_h + self.moon_h
    self.box.y = math.floor((h - self.box.h) / 2)
    self.ges_events = {
        Hold = {GestureRange:new{ges="hold",range=Geom:new{x=0,y=0,w=w,h=h}}},
        HoldRelease = {GestureRange:new{ges="hold_release",range=Geom:new{x=0,y=0,w=w,h=h}}},
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = w, h = h },
            },
        },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end
end

function ForecastPopup:paintTo(bb)
    local r, pad, row = self.box, self.pad, self.row_h
    local night_mode = G_reader_settings:isTrue("night_mode")
    local radius = math.max(0, math.min(60, tonumber(
        G_reader_settings:readSetting("slate.popup_corner_radius", 40)) or 40))
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, radius)

    local data = self.owner._slate_data or { current = {} }
    local today = SlateUtils:getWeatherLocalDate(data)
        or os.date("%Y-%m-%d")
    local epoch = SlateUtils:dateTimeToEpoch(today)
    local weekday = tonumber(os.date("!%w", epoch))
    local monday = epoch - ((weekday + 6) % 7) * 86400
    local x, y, width = r.x + pad, r.y + pad, r.w - pad * 2
    local location = data.current and data.current.location
        or G_reader_settings:readSetting("slate_weather_location")
        or self.owner.default_location

    local menu_size = math.max(24, Screen:scaleBySize(32))
    self.menu_button = {x = x + width - menu_size, y = y,
        w = menu_size, h = menu_size}
    local menu_icon
    local painted = pcall(function()
        menu_icon = ImageWidget:new{file = self.owner:getPluginDir() .. "/icons/menu.svg",
            width = menu_size, height = menu_size, alpha = true,
            original_in_nightmode = false, invert = false}
        menu_icon:paintTo(bb, self.menu_button.x, self.menu_button.y)
    end)
    if menu_icon then menu_icon:free() end
    if not painted then drawText(bb, "≡", self.menu_button.x, self.menu_button.y,
        menu_size, menu_size, 32, true, true) end
    local heading_width = math.max(1, width - menu_size - pad)

    drawText(
        bb,
        location .. " • " .. os.date("!%d %b", monday) .. "–"
            .. os.date("!%d %b", monday + 6 * 86400),
        x, y, heading_width, self.heading_h, self.font_size + 2, true
    )
    y = y + self.heading_h
    drawText(
        bb,
        self.refresh_status or popupUpdateLabel(data),
        x, y, heading_width, self.update_h, math.max(7, math.floor(self.font_size * 0.60))
    )
    y = y + self.update_h

    -- Monday through Sunday run across the top; details run down the side.
    local label_w = math.min(
        Screen:scaleBySize(58), math.floor(width * 0.12)
    )
    local days_x = x + label_w
    local column_w = (width - label_w) / 7
    local cell_pad = math.max(2, math.floor(column_w * 0.025))
    local day_y, icons_y = y, y + row
    local icons_h = self.icons_h
    local temp_y = icons_y + icons_h
    local detail_y = temp_y + row
    local detail_h = row
    local moon_y = detail_y + detail_h
    local moon_h = self.moon_h
    local rain_y = moon_y + moon_h
    local by_date = {}

    for _, day in ipairs(data.forecast_days or {}) do
        by_date[day.date] = day
    end

    local labels = {
        _("Mon"), _("Tue"), _("Wed"), _("Thu"),
        _("Fri"), _("Sat"), _("Sun"),
    }
    local row_labels = {
        _("Day"):upper(), _("Highs"):upper(), _("Lows"):upper(), _("Weather"):upper(), _("Moon Phase"):upper(), _("Rain"):upper(),
    }

    local cells = {}
    for i = 1, 7 do
        local cell_x = math.floor(days_x + (i - 1) * column_w)
        local next_x = math.floor(days_x + i * column_w)
        local date = os.date("!%Y-%m-%d", monday + (i - 1) * 86400)
        local day = by_date[date]
        local phase = day and day.moon_phase
        local astronomy = data.astronomy_days and data.astronomy_days[date]
        if astronomy and astronomy.date == date
            and astronomy.source == "astronomy" then
            phase = astronomy.moon_phase
        elseif date == today and data.astronomy
            and data.astronomy.date == today
            and data.astronomy.source == "astronomy" then
            phase = data.astronomy.moon_phase
        end
        cells[i] = {
            x = cell_x + cell_pad,
            w = next_x - cell_x - cell_pad * 2,
            date = date,
            day = day,
            phase = phase,
        }
    end

    -- Use a shared font for every weather and moon-phase cell.
    local detail_size, detail_line_h = self.font_size, 1
    local detail_padding = math.max(2, math.floor(row * 0.06))
    for candidate = self.font_size, 1, -1 do
        local fits, line_h = true, 1
        for _, cell in ipairs(cells) do
            cell.condition_lines = wrapForecastText(
                tostring(cell.day and cell.day.condition or "—"):upper(),
                cell.w, candidate, cell.date == today)
            cell.phase_lines = {}
            for word in tostring(cell.phase or "—"):upper():gmatch("%S+") do
                if measureForecastText(word, candidate, cell.date == today) > cell.w then
                    cell.phase_lines = nil
                    break
                end
                cell.phase_lines[#cell.phase_lines + 1] = word
            end
            if not cell.condition_lines or not cell.phase_lines then
                fits = false
                break
            end
            for _, lines in ipairs({cell.condition_lines, cell.phase_lines}) do
                for _, line in ipairs(lines) do
                    local _, text_h = measureForecastText(line, candidate, cell.date == today)
                    line_h = math.max(line_h, text_h)
                end
            end
        end
        if fits then
            for _, cell in ipairs(cells) do
                if #cell.condition_lines * line_h > detail_h - detail_padding * 2
                    or #cell.phase_lines * line_h > moon_h - detail_padding * 2 then
                    fits = false
                    break
                end
            end
        end
        if fits or candidate == 1 then
            detail_size, detail_line_h = candidate, line_h
            break
        end
    end

    local label_size = math.max(self.font_size, 28)
    local high_label_h = math.max(1, math.floor(row / 2))
    local fitted_labels = {row_labels[1], row_labels[2], row_labels[3],
        row_labels[4], _("Moon"):upper(), _("Phase"):upper(), row_labels[6]}
    for index, label in ipairs(fitted_labels) do
        local available_h = (index == 2 or index == 3) and high_label_h or row
        for candidate = label_size, 1, -1 do
            local widget = TextWidget:new{
                text = label,
                face = Font:getFace("cfont", candidate),
                bold = true,
            }
            local dim = widget:getSize()
            widget:free()
            if dim.w <= label_w - cell_pad and dim.h <= available_h then
                label_size = candidate
                break
            end
        end
    end

    drawText(
        bb, row_labels[1], x, day_y,
        label_w - cell_pad, row, label_size, true
    )
    drawText(
        bb, row_labels[2], x, temp_y,
        label_w - cell_pad, high_label_h, label_size, true
    )
    drawText(
        bb, row_labels[3], x, temp_y + high_label_h,
        label_w - cell_pad, row - high_label_h, label_size, true
    )
    drawText(
        bb, row_labels[4], x, detail_y,
        label_w - cell_pad, detail_h, label_size, true
    )
    local moon_label_y = moon_y + math.floor((moon_h - row) / 2)
    drawText(
        bb, _("Moon"):upper(), x, moon_label_y,
        label_w - cell_pad, high_label_h, label_size, true
    )
    drawText(
        bb, _("Phase"):upper(), x, moon_label_y + high_label_h,
        label_w - cell_pad, row - high_label_h, label_size, true
    )
    drawText(
        bb, row_labels[6], x, rain_y,
        label_w - cell_pad, row, label_size, true
    )

    -- The icon row deliberately has no redundant label.
    for _, line_y in ipairs({
        icons_y, detail_y, temp_y, moon_y, rain_y, rain_y + row,
    }) do
        bb:paintRect(x, line_y, width, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    local moon_size = tonumber(
        G_reader_settings:readSetting("slate_weather_widget_moon_icon_size")
    ) or 85
    local weather_size = tonumber(
        G_reader_settings:readSetting("slate_weather_widget_weather_icon_size")
    ) or 146

    if moon_size <= 0 then moon_size = 85 end
    if weather_size <= 0 then weather_size = 146 end

    for i = 1, 7 do
        local cell = cells[i]
        local text_x, text_w = cell.x, cell.w
        local date, day, phase = cell.date, cell.day, cell.phase
        local underline_h = math.max(2, Screen:scaleBySize(2))
        local day_text_h = math.max(1, row - underline_h - cell_pad * 2)

        drawText(
            bb, labels[i] .. " " .. date:sub(9),
            text_x, day_y, text_w, day_text_h,
            math.max(1, self.font_size - 2), date == today, true
        )
        if date == today then
            local underline_w = math.max(1, math.floor(text_w * 0.82))
            bb:paintRect(
                text_x + math.floor((text_w - underline_w) / 2),
                day_y + row - cell_pad - underline_h,
                underline_w, underline_h, Blitbuffer.COLOR_BLACK
            )
        end

        local function paintDescription(lines, cell_y, cell_h)
            lines = lines or { "—" }
            local content_h = #lines * detail_line_h
            local text_y = cell_y
                + math.max(0, math.floor((cell_h - content_h) / 2))
            for _, line in ipairs(lines) do
                drawText(
                    bb, line, text_x, text_y, text_w, detail_line_h,
                    detail_size, date == today, true
                )
                text_y = text_y + detail_line_h
            end
        end
        paintDescription(cell.condition_lines, detail_y, detail_h)
        paintDescription(cell.phase_lines, moon_y, moon_h)

        drawText(
            bb, day and day.high_low or "—",
            text_x, temp_y, text_w, row,
            self.font_size, date == today, true
        )
        drawText(
            bb,
            day and day.chance_of_rain
                and tostring(day.chance_of_rain) .. "%" or "—",
            text_x, rain_y, text_w, row,
            self.font_size, date == today, true
        )

        local moon_path = phase and self.owner:getMoonPhaseIcon(phase)
        local weather_path = day and day.icon_path
        local gap = math.max(2, math.floor(text_w * 0.06))

        -- Use the same relative sizes as the sleep screen, scaled together.
        local factor = math.min(
            1,
            math.max(1, text_w - gap) / (moon_size + weather_size),
            math.max(1, icons_h - cell_pad * 2)
                / math.max(moon_size, weather_size)
        )
        local moon_pixels = math.max(1, math.floor(moon_size * factor))
        local weather_pixels = math.max(1, math.floor(weather_size * factor))
        local pair_w = moon_pixels + weather_pixels + gap
        local pair_x = text_x + math.floor((text_w - pair_w) / 2)

        local function paintDayIcon(kind, path, icon_x, icon_size)
            if not path then
                drawText(
                    bb, "—", icon_x, icons_y,
                    icon_size, icons_h, self.font_size, false, true
                )
                return
            end

            local key = date .. "_" .. kind
            self.row_icons = self.row_icons or {}
            local icon = self.row_icons[key]
            local alpha = kind == "moon" or not night_mode
            local original = kind == "weather" and night_mode

            if not icon or icon.file ~= path or icon.width ~= icon_size
                or icon._forecast_night_mode ~= night_mode then
                if icon then icon:free() end
                icon = ImageWidget:new{
                    file = path,
                    width = icon_size,
                    height = icon_size,
                    alpha = alpha,
                    original_in_nightmode = original,
                    invert = false,
                }
                icon._forecast_night_mode = night_mode
                self.row_icons[key] = icon
            end

            icon:paintTo(
                bb, icon_x,
                icons_y + math.floor((icons_h - icon_size) / 2)
            )
        end

        paintDayIcon("moon", moon_path, pair_x, moon_pixels)
        paintDayIcon(
            "weather", weather_path,
            pair_x + moon_pixels + gap, weather_pixels
        )
    end

end

function ForecastPopup:showSettings()
    local ButtonDialog = require("ui/widget/buttondialog")
    local SpinWidget = require("ui/widget/spinwidget")
    local ConfirmBox = require("ui/widget/confirmbox")
    local popup, menu = self
    local function track(dialog)
        local close = dialog.onCloseWidget
        dialog.onCloseWidget = function(instance, ...)
            if popup._settings_dialog == instance then popup._settings_dialog = nil end
            if close then return close(instance, ...) end
        end
        popup._settings_dialog = dialog
        UIManager:show(SlateUtils:themePopup(dialog))
        return dialog
    end
    local function closeMenu() if menu then UIManager:close(menu) end end
    local function save(key, value, refresh)
        G_reader_settings:saveSetting("slate_weather_" .. key, value)
        G_reader_settings:flush()
        if refresh and not popup.closed then popup.owner:refreshForecastPopup(popup) end
    end
    local location = G_reader_settings:readSetting("slate_weather_location") or self.owner.default_location
    local scale = G_reader_settings:readSetting("slate_weather_temp_scale", "C")
    local hours = math.max(1, math.floor((tonumber(G_reader_settings:readSetting("slate_weather_cache_max_age")) or 3600) / 3600))
    local buttons = {
        {{text = _("City") .. " (" .. location .. ")", callback = function()
            closeMenu()
            local dialog
            dialog = InputDialog:new{modal = true, title = _("City"), input = location,
                input_hint = _("City, Country or latitude,longitude"), input_type = "string",
                buttons = {{
                    {text = _("Cancel"), callback = function() UIManager:close(dialog) end},
                    {text = _("Apply"), callback = function()
                        local value = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if value == "" then return end
                        UIManager:close(dialog); save("location", value, true)
                    end},
                }},
            }
            track(dialog); if dialog.onShowKeyboard then dialog:onShowKeyboard() end
        end}},
        {{text = _("Temperature scale") .. " (°" .. scale .. ")", callback = function()
            closeMenu()
            local choices
            choices = ButtonDialog:new{modal = true, title = _("Temperature scale"), buttons = {
                {{text = (scale == "C" and "✓ " or "") .. _("Celsius"), callback = function()
                    UIManager:close(choices); save("temp_scale", "C", true) end}},
                {{text = (scale == "F" and "✓ " or "") .. _("Fahrenheit"), callback = function()
                    UIManager:close(choices); save("temp_scale", "F", true) end}},
            }}
            track(choices)
        end}},
        {{text = _("Cache duration") .. " (" .. hours .. " h)", callback = function()
            closeMenu()
            track(SpinWidget:new{modal = true, title_text = _("Cache duration"), value = hours,
                value_min = 1, value_max = 24, value_step = 1, value_hold_step = 2,
                unit = _("hours"), ok_text = _("Apply"),
                callback = function(spin) save("cache_max_age", spin.value * 3600) end})
        end}},
        {{text = _("Clear cache"), callback = function()
            closeMenu()
            track(ConfirmBox:new{modal = true, text = _("Clear cached weather data and icons?"),
                ok_text = _("Clear"), ok_callback = function()
                    popup.owner:clearCache(); if not popup.closed then popup.owner:refreshForecastPopup(popup) end
                end})
        end}},
    }
    menu = ButtonDialog:new{modal = true, title = _("WEATHER SETTINGS"), buttons = buttons,
        width = math.floor(self.box.w * 0.85)}
    track(menu)
end

function ForecastPopup:onHold(_,ges)
    if not contains(self.box,ges and ges.pos)then
        require('slate_popup_navigation'):switch(self,self.owner,ges,'hold')
    end
    return true
end
function ForecastPopup:onHoldRelease()return true end

function ForecastPopup:onTap(_, ges)
    if not contains(self.box,ges and ges.pos)then
        if require('slate_popup_navigation'):switch(self,self.owner,ges)then return true end
        return self:onClose()
    end
    if contains(self.menu_button, ges and ges.pos) then self:showSettings() end
    return true
end

function ForecastPopup:onClose()
    UIManager:close(self)
    return true
end

function ForecastPopup:onCloseWidget()
    self.closed = true
    if self._settings_dialog then UIManager:close(self._settings_dialog); self._settings_dialog = nil end
    if self._refresh_task then UIManager:unschedule(self._refresh_task) end
    self._refresh_task = nil
    for _, icon in pairs(self.row_icons or {}) do
        icon:free()
    end
    self.row_icons = nil
    if self.owner._slate_forecast_popup == self then
        self.owner._slate_forecast_popup = nil
    end
    UIManager:setDirty(nil, "ui")
end

local function paintWidgetIcon(icon, bb, x, y, emulate)
    if not emulate then
        icon:paintTo(bb, x, y)
        return
    end
    icon:getSize()
    local source = icon._bb
    local inverted = source:copy()
    local kind = source:getType()
    local premultiplied = not icon._is_straight_alpha
        and (kind == Blitbuffer.TYPE_BB8A or kind == Blitbuffer.TYPE_BBRGB32)
    for iy = 0, source:getHeight() - 1 do
        for ix = 0, source:getWidth() - 1 do
            local pixel = source:getPixel(ix, iy):getColorRGB32()
            local alpha = pixel:getAlpha()
            local maximum = premultiplied and alpha or 255
            inverted:setPixel(ix, iy, Blitbuffer.ColorRGB32(
                math.max(0, maximum - pixel:getR()),
                math.max(0, maximum - pixel:getG()),
                math.max(0, maximum - pixel:getB()), alpha))
        end
    end
    icon._bb = inverted
    local ok, err = pcall(icon.paintTo, icon, bb, x, y)
    icon._bb = source
    inverted:free()
    if not ok then error(err) end
end

local function paintActionButton(owner, bb, rect, setting, default_file,
    default_icon, stroke, foreground, background, invert)
    local radius = math.floor(rect.w / 2)
    local icon_size = math.max(1, math.floor(rect.w * 0.58))
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, background, radius)
    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, stroke, foreground, radius)

    local selected = G_reader_settings:readSetting("slate.widget_icons." .. setting)
    local custom = type(selected) == "string" and selected ~= ""
        and util.fileExists(selected) and selected or nil

    local function paint(file)
        local icon
        local ok, err = pcall(function()
            local options = {
                width = icon_size,
                height = icon_size,
                alpha = true,
                original_in_nightmode = false,
                invert = false,
            }
            if file then
                options.file = file
                icon = ImageWidget:new(options)
            else
                options.icon = default_icon
                icon = IconWidget:new(options)
            end
            paintWidgetIcon(icon, bb,
                rect.x + math.floor((rect.w - icon_size) / 2),
                rect.y + math.floor((rect.h - icon_size) / 2), invert)
        end)
        if icon then icon:free() end
        return ok, err
    end

    if custom then
        local ok, err = paint(custom)
        if ok then return end
        logger.warn("Slate: could not render selected icon:", setting, err)
    end
    local fallback = default_file
        and (owner:getPluginDir() .. "/icons/" .. default_file) or nil
    local ok, err = paint(fallback)
    if not ok then
        logger.warn("Slate: could not render widget icon:", setting, err)
    end
end

local SlateScreenSaver = ScreenSaverWidget:extend{
    name = "SlateScreenSaver",
}

function SlateScreenSaver:init()
    ScreenSaverWidget.init(self)
    self.ges_events = self.ges_events or {}
    self.ges_events.Hold = {
        GestureRange:new{ ges = "hold", range = Screen:getSize() },
    }
    self.ges_events.HoldRelease = {
        GestureRange:new{ ges = "hold_release", range = Screen:getSize() },
    }
    local diagonal = math.sqrt(Screen:getWidth()^2 + Screen:getHeight()^2)
    self.ges_events.SlateScreenshot = {
        GestureRange:new{
            ges = "two_finger_tap",
            scale = { diagonal - Screen:scaleBySize(200), diagonal },
            rate = 1.0,
        },
    }
end

function SlateScreenSaver:onSlateScreenshot()
    if not self.interactive or not self.awake then return true end
    local ui = self.owner.ui or {}
    local screenshot = ui.screenshot
    if not screenshot or type(screenshot.onScreenshot) ~= "function" then
        screenshot = require("ui/widget/screenshoter"):new{ ui = ui, prefix = "Slate" }
    end
    local ok, err = pcall(screenshot.onScreenshot, screenshot)
    if not ok then
        logger.warn("Slate: screenshot failed:", err)
        UIManager:show(InfoMessage:new{ text = _("Could not save screenshot.") })
    end
    return true
end

function SlateScreenSaver:paintTo(bb, x, y)
    ScreenSaverWidget.paintTo(self, bb, x, y)
    local card = self.owner._slate_card_bounds
    SlateUtils.slate_popup_layout = {
        width = math.min(math.floor(Screen:getWidth() * 0.96), Screen:scaleBySize(900)),
        top = y or 0,
        bottom = card and card.y or Screen:getHeight(),
        owner = self.owner,
    }
    if not self.interactive then return end

    local area = self.owner._slate_button_area
    local size = math.min(
        Screen:scaleBySize(36), math.floor(Screen:getWidth() * 0.08)
    )
    local gap = math.max(2, math.floor(size * 0.56))
    local bx, by

    if area then
        -- Keep the original diameter and reserve equal horizontal/vertical gaps.
        size = math.max(
            1,
            math.min(
                size,
                math.floor((area.w - 2) / 2.56),
                math.floor((area.h - 2) / 2.56)
            )
        )
        gap = math.max(
            2,
            math.min(
                math.floor(size * 0.56),
                math.floor(area.w - size * 2),
                math.floor(area.h - size * 2)
            )
        )
        bx = math.floor(area.x + area.w - size * 2 - gap)
        by = math.floor(area.y + (area.h - size * 2 - gap) / 2)
    else
        local margin = math.floor(Screen:scaleBySize(24) * 1.5)
        bx = x + Screen:getWidth() - margin - size * 2 - gap
        by = y + margin
    end

    self.quicklaunch_button = { x = bx, y = by, w = size, h = size }
    self.quote_button = {
        x = bx + size + gap, y = by, w = size, h = size,
    }
    self.library_button = {
        x = bx, y = by + size + gap, w = size, h = size,
    }
    self.recents_button = {
        x = bx + size + gap, y = by + size + gap,
        w = size, h = size,
    }

    local foreground = area and area.foreground or Blitbuffer.COLOR_BLACK
    local background = area and area.background or Blitbuffer.COLOR_WHITE
    local stroke = math.max(1, math.floor(size / 16))
    local invert = area and area.emulate

    local apps_selected = G_reader_settings:readSetting(
        "slate.quicklaunch_page", "games"
    ) == "apps"
    paintActionButton(
        self.owner, bb, self.quicklaunch_button,
        apps_selected and "apps" or "quicklaunch",
        apps_selected and "apps.svg" or "gamepad.svg",
        nil, stroke, foreground, background, invert
    )
    paintActionButton(
        self.owner, bb, self.quote_button, "quote",
        "quote.svg", nil, stroke, foreground, background, invert
    )
    paintActionButton(
        self.owner, bb, self.library_button, "library",
        "library.svg", nil, stroke, foreground, background, invert
    )
    paintActionButton(
        self.owner, bb, self.recents_button, "recents",
        "recents.svg", nil, stroke, foreground, background, invert
    )

    local r = self.quote_button

    self.lock_button = nil

    if SlatePinPad:showSleepScreenButton() then
        local edge_padding = math.max(
            0, (x or 0) + Screen:getWidth() - (r.x + size)
        )
        local lock_size = math.max(1, math.floor(size * 1.85))
        local lock_radius = math.floor(lock_size / 2)
        local lock_stroke = math.max(1, math.floor(lock_size / 16))
        local lock_icon_size = math.max(1, math.floor(lock_size * 0.58))
        local lock = {
            x = (x or 0) + Screen:getWidth()
                - math.floor((edge_padding + Screen:scaleBySize(20)) / 2)
                - lock_size,
            y = (y or 0)
                + math.floor((edge_padding + Screen:scaleBySize(20)) / 2),
            w = lock_size,
            h = lock_size,
        }

        self.lock_button = lock

        if SlatePinPad:showCircleOutline() then
            bb:paintRoundedRect(
                lock.x, lock.y, lock_size, lock_size,
                background, lock_radius
            )
            bb:paintBorder(
                lock.x, lock.y, lock_size, lock_size,
                lock_stroke, foreground, lock_radius
            )
        end

        local icon = ImageWidget:new{
            file = self.owner:getPluginDir() .. "/icons/"
                .. (SlatePinPad:isEnabled() and "lock.svg" or "unlock.svg"),
            width = lock_icon_size,
            height = lock_icon_size,
            alpha = true,
            original_in_nightmode = false,
            invert = false,
        }
        paintWidgetIcon(icon, bb,
            lock.x + math.floor((lock_size - lock_icon_size) / 2),
            lock.y + math.floor((lock_size - lock_icon_size) / 2), invert
        )
        icon:free()
    end
    self._slate_touch_bounds={x=x or 0,y=y or 0,w=Screen:getWidth(),h=Screen:getHeight()}
    self:updateTouchTargets()
end

function SlateScreenSaver:updateTouchTargets()
    local targets = {}
    local bounds = self._slate_touch_bounds or {x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    local function union(rects)
        local result
        for _,r in pairs(rects or {}) do
            if type(r)=="table" and r.x and r.y and r.w and r.h then
                if not result then result={x=r.x,y=r.y,w=r.w,h=r.h}
                else
                    local x,y=math.min(result.x,r.x),math.min(result.y,r.y)
                    local right,bottom=math.max(result.x+result.w,r.x+r.w),math.max(result.y+result.h,r.y+r.h)
                    result={x=x,y=y,w=right-x,h=bottom-y}
                end
            end
        end
        return result
    end
    self.weather_button=union(self.owner._slate_tap_targets)
    self.book_button=union(self.owner._slate_book_tap_targets)
    local function add(rect)
        if not rect then return end
        local padding = Screen:scaleBySize(12)
        local x = math.max(bounds.x, rect.x - padding)
        local y = math.max(bounds.y, rect.y - padding)
        local right = math.min(bounds.x + bounds.w, rect.x + rect.w + padding)
        local bottom = math.min(bounds.y + bounds.h, rect.y + rect.h + padding)
        targets[#targets + 1] = { original = rect,
            rect = {x=x,y=y,w=right-x,h=bottom-y} }
    end
    add(self.lock_button)
    add(self.quicklaunch_button)
    add(self.quote_button)
    add(self.library_button)
    add(self.recents_button)
    add(self.weather_button)
    add(self.book_button)
    -- Split shared gaps at their midpoint. Expanded rectangles only shrink,
    -- so no tap can belong to two controls.
    for i = 1, #targets do
        for j = i + 1, #targets do
            local a, b = targets[i].rect, targets[j].rect
            if a.x < b.x+b.w and b.x < a.x+a.w
                and a.y < b.y+b.h and b.y < a.y+a.h then
                local oa, ob = targets[i].original, targets[j].original
                if oa.x+oa.w <= ob.x or ob.x+ob.w <= oa.x then
                    local left, right, ol, oright = a,b,oa,ob
                    if ob.x+ob.w <= oa.x then left,right,ol,oright=b,a,ob,oa end
                    local boundary = math.floor((ol.x+ol.w+oright.x)/2)
                    local end_x = right.x+right.w
                    left.w = math.min(left.x+left.w,boundary)-left.x
                    right.x = math.max(right.x,boundary)
                    right.w = end_x-right.x
                else
                    local top, bottom, ot, obottom = a,b,oa,ob
                    if ob.y+ob.h <= oa.y then top,bottom,ot,obottom=b,a,ob,oa end
                    local boundary = math.floor((ot.y+ot.h+obottom.y)/2)
                    local end_y = bottom.y+bottom.h
                    top.h = math.min(top.y+top.h,boundary)-top.y
                    bottom.y = math.max(bottom.y,boundary)
                    bottom.h = end_y-bottom.y
                end
            end
        end
    end
    self.touch_targets = targets
end

function SlateScreenSaver:touchRect(rect)
    for _, target in ipairs(self.touch_targets or {}) do
        if target.original == rect then return target.rect end
    end
    return rect
end

function SlateScreenSaver:onTap(arg, ges)
    if not self.interactive or not self.awake then return true end
    if SlatePinPad:intercept(self.owner) then return true end

    local pos = ges and ges.pos

    if contains(self:touchRect(self.lock_button), pos) then
        return SlatePinPad:toggleEnabled(self.owner)
    end
    if contains(self:touchRect(self.quicklaunch_button), pos) then
        self.owner:showQuickLaunch()
        return true
    end
    if contains(self:touchRect(self.quote_button), pos) then
        self.owner:showQuote()
        return true
    end
    if contains(self:touchRect(self.library_button), pos) then
        self.owner:openLibraryHome()
        return true
    end
    if contains(self:touchRect(self.recents_button), pos) then
        self.owner:openRecents()
        return true
    end

    if contains(self:touchRect(self.weather_button), pos) then
        self.owner:showForecast()
        return true
    end
    if contains(self:touchRect(self.book_button), pos) then
        self.owner:openDisplayedBook()
        return true
    end
    local targets = self.owner._slate_tap_targets or {}
    if contains(targets.weather_section or targets.weather_group, pos) then
        self.owner:showForecast()
        return true
    end

    for _, target in pairs(targets) do
        if contains(target, pos) then
            self.owner:showForecast()
            return true
        end
    end

    for _, target in pairs(self.owner._slate_book_tap_targets or {}) do
        if contains(target, pos) then
            self.owner:openDisplayedBook()
            return true
        end
    end

    if G_reader_settings:readSetting("slate.exit_long_press", false) == true then
        return true
    end
    return ScreenSaverWidget.onClose(self, arg)
end

function SlateScreenSaver:onHold(arg, ges)
    if not self.interactive or not self.awake then return true end
    if SlatePinPad:intercept(self.owner) then return true end
    local pos = ges and ges.pos
    if not pos then return true end
    if G_reader_settings:readSetting("slate.pin.long_press_settings",true)==true
        and contains(self:touchRect(self.lock_button),pos) then
        SlateSettings:showEditor(self.owner)
        return true
    end
    if G_reader_settings:readSetting("slate.book_highlights_long_press", true) == true then
        local book_pressed = contains(self:touchRect(self.book_button), pos)
        if not book_pressed then
            for _, target in pairs(self.owner._slate_book_tap_targets or {}) do
                if contains(target, pos) then book_pressed = true; break end
            end
        end
        if book_pressed then
            self.owner:showBookHighlights()
            return true
        end
    end
    if G_reader_settings:readSetting("slate.exit_long_press", false) ~= true then
        return true
    end
    for _, target in ipairs(self.touch_targets or {}) do
        if contains(target.rect, pos) then return true end
    end
    for _, rect in ipairs({
        self.lock_button or {}, self.quicklaunch_button or {},
        self.quote_button or {}, self.library_button or {},
        self.recents_button or {}, self.weather_button or {}, self.book_button or {},
    }) do
        if rect.x and contains(self:touchRect(rect), pos) then return true end
    end
    for _, targets in ipairs({
        self.owner._slate_tap_targets or {}, self.owner._slate_book_tap_targets or {},
    }) do
        for _, rect in pairs(targets) do
            if contains(rect, pos) then return true end
        end
    end
    return ScreenSaverWidget.onClose(self, arg)
end

function SlateScreenSaver:onHoldRelease()
    return true
end

function SlateScreenSaver:onAnyKeyPressed(arg)
    if not self.awake then return true end
    return self:onClose(arg)
end

function SlateScreenSaver:onClose(arg)
    if not self.awake then return true end
    if SlatePinPad:intercept(self.owner) then return true end
    if G_reader_settings:readSetting("slate.exit_long_press", false) == true then return true end
    return ScreenSaverWidget.onClose(self, arg)
end

function SlateScreenSaver:onResume()
    self.owner:onResume()
end

function SlateScreenSaver:onSuspend()
    ScreenSaverWidget.onSuspend(self)
    self.awake = false
    self.owner:onSuspend()
end

function SlateScreenSaver:onCloseWidget()
    SlatePinPad:close(self.owner)
    self.owner:cancelWeatherRefresh()
    self.owner:closeWeatherPopups()

    if self.owner._slate_screen == self then
        self.owner._slate_screen = nil
    end

    if SlateUtils.slate_popup_layout
        and SlateUtils.slate_popup_layout.owner == self.owner then
        SlateUtils.slate_popup_layout = nil
    end
    self.owner._slate_tap_targets = {}
    self.owner._slate_book_tap_targets = {}
    ScreenSaverWidget.onCloseWidget(self)
end

local Slate = WidgetContainer:extend{
    name = "slate",
    is_doc_only = false,
    default_location = "London",
    default_api_key = "637e03f814b440f782675255250411",
    default_temp_scale = "C",
}

function Slate:getCacheMaxAge()
    return SlateUtils:getCacheMaxAge()
end

function Slate:getPluginDir()
    return SlateUtils:getPluginDir()
end

function Slate:installIcons()
    return SlateUtils:installIcons(function()
        return self:getPluginDir()
    end)
end

function Slate:init()
    if not G_reader_settings:readSetting("slate.popup_icons_72_migrated",false) then
        if G_reader_settings:readSetting("slate.popup_header_icon_size")==64 then
            G_reader_settings:saveSetting("slate.popup_header_icon_size",72)
        end
        G_reader_settings:saveSetting("slate.popup_icons_72_migrated",true)
    end
    _G.SlatePlugin = self
    self:installIcons()
    self.ui.menu:registerToMainMenu(self)
    self:patchScreensaver()
    SlateQuotes:startAutomaticUpdates(self)
end

function Slate:addToMainMenu(menu_items)
    for _,module in ipairs({"ui/elements/filemanager_menu_order","ui/elements/reader_menu_order"})do
        local ok,order=pcall(require,module)
        if ok and type(order.screen)=="table" then
            for i=#order.screen,1,-1 do if order.screen[i]=="slate" then table.remove(order.screen,i)end end
            table.insert(order.screen,1,"slate")
        end
    end
    menu_items.slate = {
        text = _("Slate"),
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
        sorting_hint = "screen",
    }
end

function Slate:getSubMenuItems()
    return SlateSettings:build(self)
end

function Slate:patchScreensaver()
    local Screensaver = require("ui/screensaver")

    if not Screensaver._orig_show_before_slate then
        Screensaver._orig_show_before_slate = Screensaver.show
    end

    if not Screensaver._orig_close_before_slate then
        Screensaver._orig_close_before_slate = Screensaver.close
    end

    Screensaver.close = function(instance)
        local plugin_instance = _G.SlatePlugin or self
        local screen = instance.screensaver_widget

        if screen and screen.owner == plugin_instance and screen.interactive then
            Device.screen_saver_lock = true
            UIManager:unschedule(instance.close_widget)
            instance.delayed_close = nil
            plugin_instance:onResume()
            return
        end

        return Screensaver._orig_close_before_slate(instance)
    end

    Screensaver.show = function(instance)
        local plugin_instance = _G.SlatePlugin or self
        if instance.screensaver_type ~= "slate" then
            return Screensaver._orig_show_before_slate(instance)
        end

        local prefix = instance.prefix
        plugin_instance:cancelWeatherRefresh()
        plugin_instance:closeWeatherPopups()
        SlatePinPad:suspend(plugin_instance)

        if instance.screensaver_widget then
            UIManager:close(instance.screensaver_widget)
        end

        instance.screensaver_type = "slate"
        instance.prefix = prefix
        Device.screen_saver_mode = true

        local rotation = Screen:getRotationMode()
        if rotation % 2 == 1 then
            Device.orig_rotation_mode = rotation
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        end

        local ok, widget = pcall(
            plugin_instance.createWeatherWidget, plugin_instance
        )

        if not ok or not widget then
            if Device.orig_rotation_mode then
                Screen:setRotationMode(Device.orig_rotation_mode)
                Device.orig_rotation_mode = nil
            end
            instance.screensaver_type = "disable"
            return Screensaver._orig_show_before_slate(instance)
        end

        local background = Blitbuffer.COLOR_WHITE
        local screen = SlateScreenSaver:new{
            owner = plugin_instance,
            widget = widget,
            background = background,
            covers_fullscreen = true,
            modal = true,
            dithered = true,
            interactive = not instance.prefix or instance.prefix == "",
            awake = false,
        }

        instance.screensaver_widget = screen
        plugin_instance._slate_screen = screen
        plugin_instance._slate_pin_locked =
            screen.interactive and SlatePinPad:isEnabled() or false

        UIManager:setIgnoreTouchInput(false)
        UIManager:show(screen, "full")
    end

    if not _G._orig_dofile_before_slate then
        local orig_dofile = dofile
        _G._orig_dofile_before_slate = orig_dofile

        _G.dofile = function(filepath)
            local result = orig_dofile(filepath)

            if filepath and filepath:match("screensaver_menu%.lua$") then
                logger.dbg("Slate: Patching screensaver menu")

                if result and result[1] and result[1].sub_item_table then
                    local wallpaper_submenu = result[1].sub_item_table

                    local function genMenuItem(
                        text, setting, value, enabled_func, separator
                    )
                        return {
                            text = text,
                            enabled_func = enabled_func,
                            checked_func = function()
                                return G_reader_settings:readSetting(setting) == value
                            end,
                            callback = function()
                                G_reader_settings:saveSetting(setting, value)
                                G_reader_settings:flush()
                            end,
                            radio = true,
                            separator = separator,
                        }
                    end

                    local slate_item = genMenuItem(
                        _("Show Slate on sleep screen"),
                        "screensaver_type", "slate"
                    )
                    table.insert(
                        wallpaper_submenu,
                        math.min(6, #wallpaper_submenu + 1),
                        slate_item
                    )
                    logger.dbg("Slate: Added Slate option to screensaver menu")
                end

                _G.dofile = orig_dofile
                _G._orig_dofile_before_slate = nil
            end

            return result
        end
    end
end

function Slate:fetchWeatherData()
    local ok, network = pcall(require, "ui/network/manager")
    if ok and type(network.isConnected) == "function" then
        local checked, connected = pcall(network.isConnected, network)
        if checked and not connected then
            return self:loadWeatherCache(false)
        end
    end
    return SlateWeatherAPI:fetchWeatherData(self)
end

function Slate:formatHourLabel(hour, twelve_hour_clock)
    return SlateUtils:formatHourLabel(hour, twelve_hour_clock)
end

function Slate:getMoonPhaseIcon(moon_phase)
    return SlateUtils:getMoonPhaseIcon(moon_phase)
end

function Slate:getIconPath(icon_url_from_api)
    return SlateWeatherAPI:getIconPath(icon_url_from_api)
end

function Slate:saveWeatherCache(weather_data)
    return SlateUtils:saveWeatherCache(weather_data)
end

function Slate:loadWeatherCache(allow_stale)
    return SlateUtils:loadWeatherCache(
        function() return self:getCacheMaxAge() end,
        allow_stale
    )
end

function Slate:clearCache()
    self._slate_last_weather_data = nil
    self._slate_last_weather_context = nil
    return SlateUtils:clearCache()
end

local function usableWeatherData(data)
    if type(data) ~= "table" or type(data.current) ~= "table" then return false end
    local temperature = data.current.temperature
    if type(temperature) == "number" then
        return temperature == temperature and math.abs(temperature) < math.huge
    end
    return type(temperature) == "string" and temperature:find("%d") ~= nil
end

function Slate:getWeatherContext()
    local location = tostring(G_reader_settings:readSetting("slate_weather_location")
        or self.default_location or "")
        :lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return location .. "|" .. tostring(G_reader_settings:readSetting("slate_weather_temp_scale") or "C")
end

function Slate:createWeatherWidget(cached_only)
    logger.dbg("Slate: Creating widget")

    -- Keep the visible card's touch areas until its replacement is painted.
    local context = self:getWeatherContext()
    local fetched, weather_data = true, self._slate_data
    if not cached_only then fetched, weather_data = pcall(self.fetchWeatherData, self) end
    if not fetched then
        weather_data = nil
        logger.warn("Slate: weather fetch raised an error; checking saved data")
    end

    if not usableWeatherData(weather_data) then
        weather_data = nil
        for i = 1, 2 do
            local ok, cached = pcall(self.loadWeatherCache, self, i == 2)
            if ok and usableWeatherData(cached) then
                weather_data = cached
                break
            end
        end
    end
    if not usableWeatherData(weather_data)
        and self._slate_last_weather_context == context
        and usableWeatherData(self._slate_last_weather_data) then
        weather_data = self._slate_last_weather_data
        logger.dbg("Slate: retaining last valid weather after an unavailable refresh")
    end
    if not usableWeatherData(weather_data) and not self._slate_weather_empty_logged then
        self._slate_weather_empty_logged = true
        logger.warn("Slate: no usable weather or matching cache; will retry after wake")
    end

    weather_data = weather_data or {
        current = {},
        forecast_days = {},
        is_stale = true,
    }
    weather_data.current = weather_data.current or {}

    SlateUtils:prepareWeatherData(weather_data)

    local style = G_reader_settings:readSetting(
        "slate_weather_display_style"
    ) or "reading"
    local display_module = require(
        style == "custombg" and "slate_custombg" or "slate_reading"
    )
    local widget = display_module:create(self, weather_data)
    if widget then
        self._slate_data = weather_data
        if usableWeatherData(weather_data) then
            self._slate_last_weather_data = weather_data
            self._slate_last_weather_context = context
            self._slate_weather_empty_logged = false
        end
    end
    return widget
end

function Slate:showBookHighlights()
    if SlatePinPad:intercept(self) then return end
    local file = self._slate_book_file
    if type(file) ~= "string" or file == "" or not util.fileExists(file) then
        UIManager:show(SlateUtils:themePopup(InfoMessage:new{
            text = _("No current book is available."),
        }))
        return
    end
    local loaded, browser = pcall(require, "slate_book_highlights")
    if not loaded or type(browser) ~= "table" or type(browser.show) ~= "function" then
        UIManager:show(SlateUtils:themePopup(InfoMessage:new{
            text = _("The book highlights module is not installed yet."),
        }))
        return
    end
    self:closeWeatherPopups()
    browser:show(self, file)
end

function Slate:openDisplayedBook()
    if SlatePinPad:intercept(self) then return end

    local file = self._slate_book_file
    if type(file) ~= "string" or file == ""
        or not require("util").fileExists(file) then
        UIManager:show(InfoMessage:new{
            text = _("The book shown on this screen is no longer available."),
        })
        return
    end

    local ReaderUI = require("apps/reader/readerui")
    local current = ReaderUI.instance
    local already_open = current and current.document
        and current.document.file == file
    local screen = self._slate_screen

    if screen then ScreenSaverWidget.onClose(screen) end
    if not already_open then
        UIManager:nextTick(function()
            ReaderUI:showReader(file)
        end)
    end
end

function Slate:closeHistoryMenu(ui)
    local history = ui and ui.history
    local menu = history and history.booklist_menu
    if not menu then return end

    if type(menu.close_callback) == "function" then
        menu.close_callback()
    else
        UIManager:close(menu)
        history.booklist_menu = nil
    end
end

function Slate:openLibraryHome()
    if SlatePinPad:intercept(self) then return end

    if not SlateBooks:getOptions("library").native then
        self:closeWeatherPopups()
        SlateBooks:showLibrary(self)
        return
    end

    local screen = self._slate_screen
    if screen then ScreenSaverWidget.onClose(screen) end

    UIManager:nextTick(function()
        local ok, err = pcall(function()
            local ReaderUI = require("apps/reader/readerui")
            local FileManager = require("apps/filemanager/filemanager")

            self:closeHistoryMenu(ReaderUI.instance)
            self:closeHistoryMenu(FileManager.instance)
            self:closeLibraryOverlays(
                ReaderUI.instance, FileManager.instance
            )

            if ReaderUI.instance then
                ReaderUI.instance:onHome()
            end

            local manager = FileManager.instance
            if manager then
                local chooser = manager.file_chooser
                if chooser and type(chooser.changeToPath) == "function" then
                    chooser:changeToPath(SlateBooks:getDirectory())
                else
                    FileManager:showFiles(SlateBooks:getDirectory())
                end
            else
                FileManager:showFiles(SlateBooks:getDirectory())
            end
        end)

        if not ok then
            logger.warn("Slate: could not open library:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open the library."),
            })
        end
    end)
end

function Slate:closeLibraryOverlays(reader, manager)
    -- Launched plugins and their dialogs remain above the main UI while it sleeps.
    -- Close them from the top down, allowing CloseWidget cleanup to run.
    if type(UIManager.topdown_widgets_iter) ~= "function" then return end

    local overlays, found_base = {}, false
    for widget in UIManager:topdown_widgets_iter() do
        if widget == reader or widget == manager then
            found_base = true
            break
        end
        overlays[#overlays + 1] = widget
    end

    if not found_base then return end

    for _, widget in ipairs(overlays) do
        -- A previous close handler may also have closed another dialog.
        local shown = false
        for current in UIManager:topdown_widgets_iter() do
            if current == widget then
                shown = true
                break
            end
        end
        if shown then UIManager:close(widget) end
    end
end

function Slate:openRecents()
    if SlatePinPad:intercept(self) then return end

    if not SlateBooks:getOptions("recents").native then
        self:closeWeatherPopups()
        SlateBooks:showRecents(self)
        return
    end

    local screen = self._slate_screen
    if screen then ScreenSaverWidget.onClose(screen) end

    UIManager:nextTick(function()
        local ok, err = pcall(function()
            local ReaderUI = require("apps/reader/readerui")
            local FileManager = require("apps/filemanager/filemanager")
            local ui = ReaderUI.instance or FileManager.instance

            self:closeHistoryMenu(ReaderUI.instance)
            self:closeHistoryMenu(FileManager.instance)
            self:closeLibraryOverlays(ReaderUI.instance, FileManager.instance)

            if not ui then
                FileManager:showFiles(
                    G_reader_settings:readSetting("home_dir")
                        or Device.home_dir
                )
                ui = FileManager.instance
            end

            if not ui or not ui.history
                or type(ui.history.onShowHist) ~= "function" then
                error("History is unavailable")
            end

            self:closeHistoryMenu(ui)
            ui.history:onShowHist()
        end)

        if not ok then
            logger.warn("Slate: could not open recents:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open recent books."),
            })
        end
    end)
end

function Slate:showQuickLaunch()
    if SlatePinPad:intercept(self) then return end
    self:closeWeatherPopups()
    SlateQuickLaunch:show(self)
end

function Slate:showQuote()
    if SlatePinPad:intercept(self) then return end
    self:closeWeatherPopups()
    SlateQuotes:showQuote()
end

function Slate:showForecast()
    if SlatePinPad:intercept(self) then return end
    SlateQuickLaunch:close(self)
    SlateQuotes:close()
    SlateBooks:close(self)

    if self._slate_forecast_popup then return end
    self._slate_forecast_popup = SlateUtils:themePopup(
        ForecastPopup:new{ owner = self }
    )
    self._slate_forecast_popup.refresh_status = self._slate_weather_refresh_status
    UIManager:show(self._slate_forecast_popup, "ui")
end

function Slate:refreshForecastPopup(popup)
    if popup then
        popup.refresh_status = _("Refreshing…")
        UIManager:setDirty(popup, "ui")
    end
    local function refresh()
        if popup then
            popup._refresh_task = nil
            if self._slate_forecast_popup ~= popup then return end
        end
        local original = SlateWeatherAPI.requestJSON
        local attempted, refreshed = false, false
        -- Observe the live forecast result, since the API may return cached
        -- data after a failed request. Cached data is still shown on failure.
        SlateWeatherAPI.requestJSON = function(api, owner, endpoint, params)
            local result, code = original(api, owner, endpoint, params)
            if owner == self and endpoint == "forecast" then
                attempted = true
                refreshed = code == 200 and type(result) == "table"
                    and type(result.current) == "table" and not result.error
            end
            return result, code
        end
        local ok, applied = pcall(self.refreshWeatherScreen, self)
        SlateWeatherAPI.requestJSON = original
        if not ok then logger.warn("Slate: forecast popup refresh failed:", applied) end
        if ok and applied and attempted and refreshed
            and usableWeatherData(self._slate_data) and not self._slate_data.is_cached then
            self._slate_weather_refresh_status = popupUpdateLabel(self._slate_data)
        else
            self._slate_weather_refresh_status = _("Refresh failed. Showing saved data.")
        end
        local visible = self._slate_forecast_popup
        if visible then
            visible.refresh_status = self._slate_weather_refresh_status
            UIManager:setDirty(visible, "ui")
        end
    end
    if popup then
        popup._refresh_task = refresh
        UIManager:scheduleIn(0.1, refresh)
    else
        refresh()
    end
end

function Slate:closeWeatherPopups()
    local highlights = self._slate_highlights_popup
    if highlights then
        self._slate_highlights_popup = nil
        if highlights.pagination_loading and type(highlights.onCloseWidget) == "function" then
            highlights:onCloseWidget()
        else
            UIManager:close(highlights)
        end
    end
    SlateQuickLaunch:close(self)
    SlateBooks:close(self)
    if self._slate_forecast_popup then
        UIManager:close(self._slate_forecast_popup)
    end
    SlateQuotes:close()
end

function Slate:cancelWeatherRefresh()
    if self._slate_refresh then
        UIManager:unschedule(self._slate_refresh)
    end
    self._slate_refresh = nil
end

function Slate:scheduleWeatherRefresh(delay)
    if self._slate_refresh then return end

    local screen = self._slate_screen
    if not screen or not screen.interactive then return end

    self._slate_refresh = function()
        self._slate_refresh = nil
        if self._slate_screen == screen and screen.awake
            and not self._slate_suspended then
            self:refreshForecastPopup()
        end
    end
    UIManager:scheduleIn(delay or 0.2, self._slate_refresh)
end

function Slate:onResume()
    self._slate_suspended = false
    SlateQuotes:startAutomaticUpdates(self)
    descriptionEvent(self, "onWake")
    if self._slate_screen then
        local first_wake = not self._slate_screen.awake
        self._slate_screen.awake = true
        if first_wake then self._slate_weather_retry_done = false end

        if first_wake and self._slate_screen.interactive then
            SlatePinPad:arm(self)
        end

        self:scheduleWeatherRefresh()
    end
end

function Slate:onNetworkConnected()
    if not self._slate_suspended then descriptionEvent(self, "startNext") end
    if self._slate_screen and self._slate_screen.awake then
        self._slate_weather_retry_done = false
        self:scheduleWeatherRefresh()
    end
end

function Slate:onSuspend()
    self._slate_suspended = true
    descriptionEvent(self, "onSuspend")
    SlateQuotes:stopAutomaticUpdates(self)
    if self._slate_screen then
        self._slate_screen.awake = false
    end

    SlatePinPad:suspend(self)
    self:cancelWeatherRefresh()
    self:closeWeatherPopups()
end

function Slate:refreshWeatherScreen(cached_only)
    local screen = self._slate_screen
    if not screen or not screen.awake or self._slate_suspended
        or self._slate_refresh_running then
        return false
    end

    self._slate_refresh_running = true
    local old_data, old_book_file = self._slate_data, self._slate_book_file
    local ok, widget = pcall(self.createWeatherWidget, self, cached_only)
    self._slate_refresh_running = false

    if not ok or not widget then
        self._slate_data = old_data
        self._slate_book_file = old_book_file
        if not ok then
            logger.warn("Slate: weather refresh failed:", widget)
        end
        return false
    end

    if ok and widget and self._slate_screen == screen then
        local old_frame = screen[1]
        screen.widget = widget
        SlateScreenSaver.init(screen)

        if old_frame and old_frame.free then
            old_frame:free()
        end

        UIManager:setDirty(screen, self._slate_forecast_popup and "ui" or "full")
        if self._slate_forecast_popup then
            UIManager:setDirty(self._slate_forecast_popup, "ui")
        end
        if not usableWeatherData(self._slate_data) and not self._slate_weather_retry_done then
            self._slate_weather_retry_done = true
            self:scheduleWeatherRefresh(3)
        end
        return true
    end
    return false
end

function Slate:cleanupScreensaverState(screensaver_instance)
    if SlatePinPad:intercept(self) then return end

    SlatePinPad:close(self)
    self:cancelWeatherRefresh()
    self:closeWeatherPopups()
    logger.dbg("Slate: cleanupScreensaverState() called")

    if screensaver_instance and screensaver_instance.screensaver_widget then
        UIManager:close(screensaver_instance.screensaver_widget)
        screensaver_instance.screensaver_widget = nil
    end

    local Screen = require("device").screen
    if Device.orig_rotation_mode then
        Screen:setRotationMode(Device.orig_rotation_mode)
        Device.orig_rotation_mode = nil
    end

    Device.screen_saver_mode = false

    if self._last_tap_catcher then
        UIManager:close(self._last_tap_catcher)
        self._last_tap_catcher = nil
    end

    self._pinpad_active = false
    logger.dbg("Slate: cleanupScreensaverState() completed")
end

function Slate:onExit()
    descriptionEvent(self, "onSuspend")
    SlateQuotes:stopAutomaticUpdates(self)
    SlatePinPad:close(self)
    self:cancelWeatherRefresh()
    self:closeWeatherPopups()
end

function Slate:onRestart()
    return self:onExit()
end

return Slate
