-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-09.
-- Game and app quick launch for Slate.
-- Uses saved launcher selections and installed plugins’ own menu actions.

local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")

local Games = {}
local SELECTION_KEY = "slate.launcher_plugins"
local APP_SELECTION_KEY = "slate.app_launcher_plugins"
local module_source = debug.getinfo(1, "S").source
local module_dir = module_source:sub(1, 1) == "@"
    and (module_source:sub(2):match("(.*/)") or "") or ""

local function selectedIds(section)
    local saved = G_reader_settings:readSetting(section == "apps" and APP_SELECTION_KEY or SELECTION_KEY, {})
    return type(saved) == "table" and saved or {}
end

local function sortEntries(entries)
    table.sort(entries, function(a, b)
        local first, second = tostring(a.text):lower(), tostring(b.text):lower()
        if first == second then return a.id < b.id end
        return first < second
    end)
    return entries
end

local function contains(rect, pos)
    return rect and pos and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function drawText(bb, text, rect, size, bold, center, enabled)
    local widget
    for font_size = size, 6, -1 do
        widget = TextWidget:new{
            text = tostring(text or ""), face = Font:getFace("cfont", font_size),
            bold = bold,
            fgcolor = enabled == false and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
        }
        local dim = widget:getSize()
        if (dim.h <= rect.h - 8 and dim.w <= rect.w) or font_size == 6 then break end
        widget:free()
    end
    local dim = widget:getSize()
    local x = rect.x
    if center then x = x + math.max(0, math.floor((rect.w - dim.w) / 2)) end
    widget:paintTo(bb, x, rect.y + math.max(0, math.floor((rect.h - dim.h) / 2)))
    widget:free()
    return x, dim.w
end

function Games:paintButton(bb, rect, stroke, foreground, background, invert, icon_name)
    foreground = foreground or Blitbuffer.COLOR_BLACK
    background = background or Blitbuffer.COLOR_WHITE
    local radius = math.floor(rect.w / 2)
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, background, radius)
    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, stroke, foreground, radius)
    local size = math.max(1, math.floor(rect.w * 0.58))
    local icon
    if icon_name then
        icon = IconWidget:new{
            icon = icon_name, width = size, height = size,
            alpha = true, original_in_nightmode = false, invert = invert or false,
        }
    else
        icon = ImageWidget:new{
            file = module_dir .. "icons/gamepad.svg", width = size, height = size,
            alpha = true, original_in_nightmode = false, invert = invert or false,
        }
    end
    icon:paintTo(bb, rect.x + math.floor((rect.w - size) / 2),
        rect.y + math.floor((rect.h - size) / 2))
    icon:free()
end

function Games:getAvailableEntries(owner)
    local registered = {}
    local candidates, seen_plugins = {}, {}
    local function add(plugin)
        if type(plugin) == "table" and not seen_plugins[plugin] then
            seen_plugins[plugin] = true
            candidates[#candidates + 1] = plugin
        end
    end
    -- The lockscreen owner can belong to a previous UI instance. Resolve
    -- actions from the live plugin loader as well as the active menus.
    local ok, loader = pcall(require, "pluginloader")
    if ok then
        for _, plugin in pairs(loader.loaded_plugins or {}) do add(plugin) end
    end
    local function addUI(ui)
        for _, plugin in pairs(ui and ui.menu and ui.menu.registered_widgets or {}) do add(plugin) end
    end
    addUI(owner and owner.ui)
    for _, module in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local loaded, ui_class = pcall(require, module)
        if loaded then addUI(ui_class.instance) end
    end
    for _, plugin in ipairs(candidates) do
        if type(plugin.addToMainMenu) == "function" then
            local items = {}
            local ok, err = pcall(plugin.addToMainMenu, plugin, items)
            if ok then
                for id, item in pairs(items) do
                    if type(item) == "table" then
                        registered[id] = { item = item, plugin = plugin }
                    end
                end
            else
                logger.warn("Slate: game menu registration failed:", err)
            end
        end
    end

    local entries = {}
    for id, source in pairs(registered) do
        local item = source.item
        local actionable = type(item.callback) == "function"
            or type(item.sub_item_table_func) == "function"
            or type(item.sub_item_table) == "table"
        if type(id) == "string" and id ~= "slate" and actionable then
            local label = item.text or id
            if type(item.text_func) == "function" then
                local ok, text = pcall(item.text_func)
                if ok and type(text) == "string" then label = text end
            end
            local enabled = item.enabled ~= false
            if enabled and type(item.enabled_func) == "function" then
                local ok, value = pcall(item.enabled_func)
                enabled = ok and not not value
            end
            entries[#entries + 1] = {
                id = id, text = label, enabled = not not enabled,
                item = item, plugin = source.plugin,
            }
        end
    end
    return sortEntries(entries)
end

function Games:getEntries(owner, section)
    local selected, entries = {}, {}
    for index, id in ipairs(selectedIds(section)) do
        if type(id) == "string" then selected[id] = true end
    end
    for index, entry in ipairs(self:getAvailableEntries(owner)) do
        if selected[entry.id] then entries[#entries + 1] = entry end
    end
    return entries
end

function Games:launch(owner, entry)
    if not entry or not entry.enabled then return end
    self:close(owner)
    local screen = owner._slate_screen
    if screen then ScreenSaverWidget.onClose(screen) end
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            if type(entry.item.callback) == "function" then
                entry.item.callback()
            elseif entry.id == "crossword" and entry.plugin
                and type(entry.plugin.showQuickMenu) == "function" then
                entry.plugin:showQuickMenu()
            else
                local items = entry.item.sub_item_table
                if type(entry.item.sub_item_table_func) == "function" then
                    items = entry.item.sub_item_table_func()
                end
                if type(items) ~= "table" then error("Game menu is unavailable") end
                UIManager:show(Menu:new{
                    title = entry.text, item_table = items,
                    width = math.floor(Screen:getWidth() * 0.9),
                    height = math.floor(Screen:getHeight() * 0.9),
                })
            end
        end)
        if not ok then
            logger.warn("Slate: could not launch plugin:", entry.id, err)
            UIManager:show(InfoMessage:new{ text = _("Could not open this plugin.") })
        end
    end)
end

local GamesPopup = InputContainer:extend{ modal = true }

function GamesPopup:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Screen:getSize()
    self.entries = self.selection_mode and Games:getAvailableEntries(self.owner)
        or Games:getEntries(self.owner)
    self.pending = {}
    if self.selection_mode then
        for index, id in ipairs(selectedIds(self.section)) do self.pending[id] = true end
    end
    self.page = 1
    self.row_h = math.max(24, Screen:scaleBySize(32))
    self.box = { w = math.min(math.floor(w * 0.90), Screen:scaleBySize(620)) }
    self.pad = math.max(10, math.floor(self.box.w * 0.045))
    self.title_h = math.floor(self.row_h * 1.5)
    self.warning_h = self.selection_mode and self.row_h * 2 or 0
    local max_rows = math.max(1, math.floor(
        (h * 0.85 - self.pad * 2 - self.title_h - self.warning_h - self.row_h * 2) / self.row_h))
    self.row_count = math.min(max_rows, math.max(1, math.ceil(#self.entries / 2)))
    self.page_size = self.row_count * 2
    self.pages = math.max(1, math.ceil(#self.entries / self.page_size))
    self.box.h = self.pad * 2 + self.title_h + self.warning_h + self.row_count * self.row_h
        + (self.pages > 1 and self.row_h or 0)
        + (self.selection_mode and self.row_h or 0)
    self.box.x = math.floor((w - self.box.w) / 2)
    self.box.y = math.floor((h - self.box.h) / 2)
    self.font_size = 18
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = w, h = h } } },
        Swipe = { GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = w, h = h } } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { "Back" } } } end
end

function GamesPopup:paintTo(bb)
    local r, row = self.box, self.row_h
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, 8)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, 8)
    local x, width = r.x + self.pad, r.w - self.pad * 2
    local title = { x = x, y = r.y + self.pad, w = width, h = self.title_h }
    self.add_button = nil
    if not self.selection_mode then
        local size = math.min(row, self.title_h)
        self.add_button = { x = x + width - size, y = title.y,
            w = size, h = size }
        local stroke = math.max(1, math.floor(size / 14))
        local arm = math.max(3, math.floor(size * 0.5))
        local bx, by = self.add_button.x, self.add_button.y
        bb:paintBorder(bx, by, size, size, stroke, Blitbuffer.COLOR_BLACK,
            math.floor(size / 2))
        bb:paintRect(bx + math.floor((size - arm) / 2),
            by + math.floor((size - stroke) / 2), arm, stroke, Blitbuffer.COLOR_BLACK)
        bb:paintRect(bx + math.floor((size - stroke) / 2),
            by + math.floor((size - arm) / 2), stroke, arm, Blitbuffer.COLOR_BLACK)
        title.x = x + size + self.pad
        title.w = math.max(1, width - (size + self.pad) * 2)
    end
    local tx, tw = drawText(bb, self.selection_mode and _("SELECT PLUGINS") or _("GAMES"), title, self.font_size + 2, true, true)
    bb:paintRect(tx, title.y + self.title_h - math.floor(row * 0.20), tw, 1, Blitbuffer.COLOR_BLACK)
    self.rows, self.buttons = {}, {}
    local first = (self.page - 1) * self.page_size + 1
    local count = math.min(self.page_size, #self.entries - first + 1)
    local left_count = math.ceil(count / 2)
    local column_gap = math.max(8, math.floor(width * 0.055))
    local column_w = math.floor((width - column_gap) / 2)
    local list_y = title.y + self.title_h
    if self.selection_mode then
        drawText(bb, self.section == "apps" and _("Select plugins for APP QUICK LAUNCH.") or _("Only add game plugins."),
            { x = x, y = list_y, w = width, h = row },
            self.font_size - 2, true, true)
        drawText(bb, self.section == "apps" and _("Some plugins require an open book. Select, then APPLY.") or _("Other plugins may cause issues. Select, then APPLY."),
            { x = x, y = list_y + row, w = width, h = row },
            self.font_size - 2, false, true)
        list_y = list_y + self.warning_h
    end

    -- Center each list as a group, keeping every title on one left edge.
    local column_widths = { 0, 0 }
    for i = 1, count do
        local entry = self.entries[first + i - 1]
        local column = i <= left_count and 1 or 2
        local label = (self.selection_mode and (self.pending[entry.id] and "[✓] " or "[ ] ")
            or "[ ") .. tostring(entry.text):upper() .. (self.selection_mode and "" or " ]")
        for font_size = self.font_size, 6, -1 do
            local widget = TextWidget:new{
                text = label, face = Font:getFace("cfont", font_size),
            }
            local dim = widget:getSize()
            widget:free()
            if (dim.h <= row - 8 and dim.w <= column_w) or font_size == 6 then
                column_widths[column] = math.max(column_widths[column], math.min(dim.w, column_w))
                break
            end
        end
    end

    for i = 1, count do
        local entry = self.entries[first + i - 1]
        local column = i <= left_count and 0 or 1
        local index = column == 0 and i - 1 or i - left_count - 1
        local rect = {
            x = x + column * (column_w + column_gap),
            y = list_y + index * row, w = column_w, h = row,
        }
        self.rows[#self.rows + 1] = { rect = rect, entry = entry }
        local label = (self.selection_mode and (self.pending[entry.id] and "[✓] " or "[ ] ")
            or "[ ") .. tostring(entry.text):upper() .. (self.selection_mode and "" or " ]")
        local inset = math.max(0, math.floor((column_w - column_widths[column + 1]) / 2))
        local text_rect = { x = rect.x + inset, y = rect.y, w = column_w - inset, h = rect.h }
        drawText(bb, label, text_rect, self.font_size, false, false, self.selection_mode or entry.enabled)
    end

    if count == 0 then
        drawText(bb, self.selection_mode and _("No plugins available.")
            or _("Tap + to select game plugins."),
            { x = x, y = list_y, w = width, h = row }, self.font_size, false, true)
    end

    if self.pages > 1 then
        local y = list_y + self.row_count * row
        self.buttons = {
            { x = x, y = y, w = math.floor(width / 3), h = row },
            { x = x + math.floor(width * 2 / 3), y = y, w = math.floor(width / 3), h = row },
        }
        drawText(bb, "‹", self.buttons[1], self.font_size, true, true)
        drawText(bb, "›", self.buttons[2], self.font_size, true, true)
        drawText(bb, tostring(self.page) .. " / " .. tostring(self.pages),
            { x = x + math.floor(width / 3), y = y, w = math.floor(width / 3), h = row },
            self.font_size - 2, false, true)
    end
    self.apply_button = nil
    if self.selection_mode then
        self.apply_button = {
            x = x, y = list_y + self.row_count * row
                + (self.pages > 1 and row or 0),
            w = width, h = row,
        }
        bb:paintBorder(self.apply_button.x, self.apply_button.y,
            self.apply_button.w, self.apply_button.h, 1, Blitbuffer.COLOR_BLACK)
        drawText(bb, _("APPLY"), self.apply_button, self.font_size, true, true)
    end

end

function GamesPopup:onTap(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then return self:onClose() end
    if contains(self.add_button, pos) then
        Games:showSelection(self.owner)
        return true
    end
    for _, row in ipairs(self.rows or {}) do
        if contains(row.rect, pos) then
            if self.selection_mode then
                self.pending[row.entry.id] = not self.pending[row.entry.id]
                UIManager:setDirty(self, "ui")
            else
                Games:launch(self.owner, row.entry)
            end
            return true
        end
    end
    if self.selection_mode and contains(self.apply_button, pos) then
        local ids = {}
        for index, entry in ipairs(self.entries) do
            if self.pending[entry.id] then ids[#ids + 1] = entry.id end
        end
        G_reader_settings:saveSetting(self.section == "apps" and APP_SELECTION_KEY or SELECTION_KEY, ids)
        G_reader_settings:flush()
        self:onClose()
        local popup = self.owner._slate_games_popup
        if popup then
            popup:init()
            UIManager:setDirty(popup, "ui")
        end
        return true
    end
    for i, rect in ipairs(self.buttons or {}) do
        if contains(rect, pos) then
            if i == 1 then self.page = math.max(1, self.page - 1)
            else self.page = math.min(self.pages, self.page + 1) end
            UIManager:setDirty(self, "ui")
            return true
        end
    end
    return true
end

function GamesPopup:onSwipe(_, ges)
    if not ges or not contains(self.box, ges.pos) then return true end
    if ges.direction == "north" or ges.direction == "west" then
        self.page = math.min(self.pages, self.page + 1)
    elseif ges.direction == "south" or ges.direction == "east" then
        self.page = math.max(1, self.page - 1)
    end
    UIManager:setDirty(self, "ui")
    return true
end

function GamesPopup:onClose()
    UIManager:close(self)
    return true
end

function GamesPopup:onCloseWidget()
    if self.owner._slate_games_popup == self then self.owner._slate_games_popup = nil end
    if self.owner._slate_plugin_picker == self then self.owner._slate_plugin_picker = nil end
    UIManager:setDirty(nil, "ui")
end

local LauncherPopup = InputContainer:extend{ modal = true }

function LauncherPopup:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Screen:getSize()
    self.row_h = math.max(24, math.min(Screen:scaleBySize(32), math.floor(h * 0.055)))
    self.font_size = 18
    self.box = { w = math.min(math.floor(w * 0.90), Screen:scaleBySize(620)) }
    self.pad = math.max(10, math.floor(self.box.w * 0.045))
    self.title_h = math.floor(self.row_h * 1.5)
    self.section_gap = math.floor(self.row_h * 0.5)
    local max_rows = math.max(1, math.floor((h * 0.85 - self.pad * 2
        - self.title_h * 2 - self.section_gap - self.row_h * 2)
        / (self.row_h * 2)))
    self.sections = {}
    local height = self.pad * 2 + self.section_gap
    for section_index, id in ipairs({ "games", "apps" }) do
        local entries = Games:getEntries(self.owner, id)
        local rows = math.min(max_rows, math.max(1, math.ceil(#entries / 2)))
        local page_size = rows * 2
        local pages = math.max(1, math.ceil(#entries / page_size))
        self.sections[#self.sections + 1] = {
            id = id, entries = entries, rows = rows, page_size = page_size,
            pages = pages, page = 1,
            title = id == "apps" and _("APP QUICK LAUNCH") or _("GAMES | LAUNCHER"),
        }
        height = height + self.title_h + rows * self.row_h
            + (pages > 1 and self.row_h or 0)
    end
    self.box.h = height
    self.box.x = math.floor((w - self.box.w) / 2)
    self.box.y = math.floor((h - height) / 2)
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { "Back" } } } end
end

function LauncherPopup:paintTo(bb)
    local r, row = self.box, self.row_h
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, 8)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, 8)
    local x, width = r.x + self.pad, r.w - self.pad * 2
    local y = r.y + self.pad
    self.rows, self.buttons, self.add_buttons = {}, {}, {}
    for section_index, section in ipairs(self.sections) do
        local top = y
        local size = row
        local add = { x = x + width - size, y = y, w = size, h = size, section = section.id }
        self.add_buttons[#self.add_buttons + 1] = add
        local stroke = math.max(1, math.floor(size / 14))
        local arm = math.floor(size * 0.5)
        bb:paintBorder(add.x, add.y, size, size, stroke, Blitbuffer.COLOR_BLACK, math.floor(size / 2))
        bb:paintRect(add.x + math.floor((size - arm) / 2), add.y + math.floor((size - stroke) / 2), arm, stroke, Blitbuffer.COLOR_BLACK)
        bb:paintRect(add.x + math.floor((size - stroke) / 2), add.y + math.floor((size - arm) / 2), stroke, arm, Blitbuffer.COLOR_BLACK)
        local tx, tw = drawText(bb, section.title, {
            x = x + size + self.pad, y = y,
            w = math.max(1, width - (size + self.pad) * 2), h = self.title_h,
        }, self.font_size + 2, true, true)
        bb:paintRect(tx, y + self.title_h - math.floor(row * 0.20), tw, 1, Blitbuffer.COLOR_BLACK)
        y = y + self.title_h
        local first = (section.page - 1) * section.page_size + 1
        local count = math.min(section.page_size, #section.entries - first + 1)
        local left_count = math.ceil(count / 2)
        local gap = math.max(8, math.floor(width * 0.055))
        local column_w = math.floor((width - gap) / 2)
        local widths = { 0, 0 }
        for i = 1, count do
            local entry = section.entries[first + i - 1]
            local col = i <= left_count and 1 or 2
            local label = "[ " .. tostring(entry.text):upper() .. " ]"
            for font_size = self.font_size, 6, -1 do
                local widget = TextWidget:new{ text = label, face = Font:getFace("cfont", font_size) }
                local dim = widget:getSize()
                widget:free()
                if (dim.h <= row - 8 and dim.w <= column_w) or font_size == 6 then
                    widths[col] = math.max(widths[col], math.min(dim.w, column_w))
                    break
                end
            end
        end
        for i = 1, count do
            local entry = section.entries[first + i - 1]
            local col = i <= left_count and 0 or 1
            local index = col == 0 and i - 1 or i - left_count - 1
            local rect = { x = x + col * (column_w + gap), y = y + index * row, w = column_w, h = row }
            self.rows[#self.rows + 1] = { rect = rect, entry = entry }
            local inset = math.max(0, math.floor((column_w - widths[col + 1]) / 2))
            drawText(bb, "[ " .. tostring(entry.text):upper() .. " ]", {
                x = rect.x + inset, y = rect.y, w = column_w - inset, h = row,
            }, self.font_size, false, false, entry.enabled)
        end
        if count == 0 then
            drawText(bb, section.id == "apps" and _("Tap + to select app plugins.") or _("Tap + to select game plugins."),
                { x = x, y = y, w = width, h = row }, self.font_size, false, true)
        end
        y = y + section.rows * row
        if section.pages > 1 then
            local third = math.floor(width / 3)
            for i, label in ipairs({ "‹", "›" }) do
                local button = { x = x + (i - 1) * third * 2, y = y, w = third, h = row,
                    section = section, delta = i == 1 and -1 or 1 }
                self.buttons[#self.buttons + 1] = button
                drawText(bb, label, button, self.font_size, true, true)
            end
            drawText(bb, section.page .. " / " .. section.pages,
                { x = x + third, y = y, w = third, h = row }, self.font_size - 2, false, true)
            y = y + row
        end
        section.bounds = { x = x, y = top, w = width, h = y - top }
        y = y + self.section_gap
    end
end

function LauncherPopup:onTap(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then return self:onClose() end
    for _, add in ipairs(self.add_buttons or {}) do
        if contains(add, pos) then Games:showSelection(self.owner, add.section); return true end
    end
    for _, item in ipairs(self.rows or {}) do
        if contains(item.rect, pos) then Games:launch(self.owner, item.entry); return true end
    end
    for _, button in ipairs(self.buttons or {}) do
        if contains(button, pos) then
            local section = button.section
            section.page = math.max(1, math.min(section.pages, section.page + button.delta))
            UIManager:setDirty(self, "ui")
            return true
        end
    end
    return true
end

function LauncherPopup:onSwipe(_, ges)
    if not ges then return true end
    for section_index, section in ipairs(self.sections) do
        if contains(section.bounds, ges.pos) then
            if ges.direction == "north" or ges.direction == "west" then
                section.page = math.min(section.pages, section.page + 1)
            elseif ges.direction == "south" or ges.direction == "east" then
                section.page = math.max(1, section.page - 1)
            end
            UIManager:setDirty(self, "ui")
            break
        end
    end
    return true
end

function LauncherPopup:onClose()
    UIManager:close(self)
    return true
end

function LauncherPopup:onCloseWidget()
    if self.owner._slate_games_popup == self then self.owner._slate_games_popup = nil end
    if self.owner._slate_plugin_picker then UIManager:close(self.owner._slate_plugin_picker) end
    UIManager:setDirty(nil, "ui")
end

function Games:show(owner)
    if owner._slate_games_popup then return end
    owner._slate_games_popup = LauncherPopup:new{ owner = owner }
    UIManager:show(owner._slate_games_popup, "ui")
end


function Games:showSelection(owner, section)
    if owner._slate_plugin_picker then return end
    owner._slate_plugin_picker = GamesPopup:new{
        owner = owner, selection_mode = true, section = section or "games",
    }
    UIManager:show(owner._slate_plugin_picker, "ui")
end

function Games:close(owner)
    if owner._slate_games_popup then UIManager:close(owner._slate_games_popup) end
    if owner._slate_plugin_picker then UIManager:close(owner._slate_plugin_picker) end
end

return Games
