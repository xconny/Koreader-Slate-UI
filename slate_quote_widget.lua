-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-09.
-- Quote popup with measured pagination and persistent book filters.

local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local SlateUtils = require("slate_utils")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local ImageWidget = require("ui/widget/imagewidget")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local module_source = debug.getinfo(1, "S").source
local module_dir = module_source:sub(1, 1) == "@"
    and (module_source:sub(2):match("(.*/)") or "") or ""

local quote_history = {}

local function contains(rect, pos)
    return rect and pos and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function clean_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function draw_text(bb, text, rect, size, bold, center, color, face_name)
    local widget
    for candidate = math.max(1, math.floor(size)), 1, -1 do
        widget = TextWidget:new{
            text = tostring(text or ""), face = Font:getFace(face_name or "infofont", candidate),
            bold = bold, fgcolor = color or Blitbuffer.COLOR_BLACK,
        }
        local dim = widget:getSize()
        if dim.w <= rect.w and dim.h <= rect.h then break end
        widget:free()
        widget = nil
    end
    if not widget then return end
    local dim = widget:getSize()
    local x = rect.x
    if center then x = x + math.floor((rect.w - dim.w) / 2) end
    widget:paintTo(bb, x, rect.y + math.floor((rect.h - dim.h) / 2))
    widget:free()
end

local function inset(rect, padding)
    return {
        x = rect.x + padding, y = rect.y + padding,
        w = math.max(1, rect.w - padding * 2),
        h = math.max(1, rect.h - padding * 2),
    }
end

local function cornerRadius(key, default)
    return math.max(0, math.min(60, tonumber(
        G_reader_settings:readSetting(key, default)) or default))
end

local function draw_button(bb, text, rect, selected, enabled, font_size, face_name)
    local background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local foreground = selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    if enabled == false then foreground = Blitbuffer.COLOR_DARK_GRAY end
    local radius = cornerRadius("slate.button_corner_radius", 40)
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, background, radius)
    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, 1, Blitbuffer.COLOR_BLACK, radius)
    if face_name == "cfont" then
        local padding = math.max(4, Screen:scaleBySize(4))
        local text_rect = inset(rect, padding)
        local reference_h = math.max(24, Screen:scaleBySize(32))
        local fit_h = math.min(text_rect.h, reference_h - padding * 2)
        local widget
        for size = font_size or 18, 6, -1 do
            widget = TextWidget:new{
                text = text, face = Font:getFace("cfont", size),
                bold = true, fgcolor = foreground,
            }
            local dim = widget:getSize()
            if (dim.h <= fit_h - 8 and dim.w <= text_rect.w)
                or size == 6 then break end
            widget:free()
        end
        local dim = widget:getSize()
        widget:paintTo(bb,
            text_rect.x + math.max(0, math.floor((text_rect.w - dim.w) / 2)),
            text_rect.y + math.max(0, math.floor((text_rect.h - dim.h) / 2)))
        widget:free()
    else
        draw_text(bb, text, inset(rect, math.max(4, math.floor(rect.h * 0.15))),
            font_size or 16, true, true, foreground, face_name)
    end
end

local function text_height(text, face, width)
    local widget = TextBoxWidget:new{
        text = text, face = face, italic = true, alignment = "left", width = width,
    }
    local height = widget:getSize().h
    widget:free()
    return height
end

-- Split only at UTF-8 character boundaries, preferring a nearby word boundary.
-- Measuring the actual TextBoxWidget prevents long sentences overflowing.
local function build_pages(raw, face, width, height)
    local text = clean_text(raw)
    if text == "" then return { "" } end
    local ends = {}
    for i = 1, #text do
        local next_byte = text:byte(i + 1)
        if not next_byte or next_byte < 128 or next_byte >= 192 then
            ends[#ends + 1] = i
        end
    end
    local pages, start, first = {}, 1, 1
    while start <= #text do
        while first <= #ends and ends[first] < start do first = first + 1 end
        local low, high, best = first, #ends, nil
        while low <= high do
            local middle = math.floor((low + high) / 2)
            local candidate = text:sub(start, ends[middle])
            if text_height("“" .. candidate .. "”", face, width) <= height then
                best = ends[middle]
                low = middle + 1
            else
                high = middle - 1
            end
        end
        if not best then best = ends[first] or #text end
        local finish = best
        if best < #text then
            local chunk = text:sub(start, best)
            local boundary = chunk:match(".*()%s")
            if boundary and boundary > #chunk * 0.55 then
                finish = start + boundary - 2
            end
        end
        pages[#pages + 1] = text:sub(start, finish):gsub("%s+$", "")
        start = finish + 1
        while start <= #text and text:sub(start, start):match("%s") do start = start + 1 end
    end
    return pages
end

local BookPicker = InputContainer:extend{ modal = true }

function BookPicker:init()
    self.dimen = Screen:getSize()
    self.box = Geom:new{
        w = math.floor(Screen:getWidth() * 0.82),
        h = math.floor(Screen:getHeight() * 0.70),
    }
    self.box.x = math.floor((Screen:getWidth() - self.box.w) / 2)
    self.box.y = math.floor((Screen:getHeight() - self.box.h) / 2)
    self.pad = math.max(10,math.floor(self.box.w*.035))
    self.row_h = math.max(24, math.min(Screen:scaleBySize(42), math.floor(self.box.h * 0.10)))
    self.gap = math.max(4, math.floor(self.pad * 0.5))
    self.list = {
        x = self.box.x + self.pad, y = self.box.y + self.pad + self.row_h + self.gap,
        w = self.box.w - self.pad * 2,
    }
    local footer_y = self.box.y + self.box.h - self.pad - self.row_h
    self.visible_rows = math.max(1, math.floor((footer_y - self.gap - self.list.y) / self.row_h))
    self.list.h = self.visible_rows * self.row_h
    self.offset = 0
    self.selected = {}
    if self.initial_selected then
        for name,selected in pairs(self.initial_selected)do if selected then self.selected[name]=true end end
    elseif self.multiple then
        for _, name in ipairs(self.owner.selected_books or {}) do self.selected[name] = true end
    elseif self.owner.selected_book then
        self.selected[self.owner.selected_book] = true
    end
    local control_w = math.floor(self.list.w * 0.15)
    self.up_button = { x = self.list.x, y = footer_y, w = control_w, h = self.row_h }
    self.down_button = {
        x = self.list.x + control_w + self.gap, y = footer_y, w = control_w, h = self.row_h,
    }
    local apply_w = math.floor(self.list.w * 0.28)
    self.apply_button = {
        x = self.list.x + self.list.w - apply_w, y = footer_y, w = apply_w, h = self.row_h,
    }
    self.status = {
        x = self.down_button.x + control_w + self.gap, y = footer_y,
        w = self.apply_button.x - self.down_button.x - control_w - self.gap * 2,
        h = self.row_h,
    }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" } },
            ScrollUp = { { "PgBack" } },
            ScrollDown = { { "PgFwd" } },
        }
    end
end

function BookPicker:selectionCount()
    local count = 0
    for _, book in ipairs(self.books) do
        if self.selected[book.name] then count = count + 1 end
    end
    return count
end

function BookPicker:paintTo(bb)
    local r = self.box
    local radius = cornerRadius("slate.popup_corner_radius", 40)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, radius)
    draw_text(bb, self.title_text or (self.multiple and _("SELECT BOOKS") or _("SELECT A BOOK")), {
        x = r.x + self.pad, y = r.y + self.pad, w = r.w - self.pad * 2, h = self.row_h,
    }, 20, true, true)
    self.row_targets = {}
    for row = 1, self.visible_rows do
        local index = self.offset + row
        local book = self.books[index]
        if not book then break end
        local rect = {
            x = self.list.x, y = self.list.y + (row - 1) * self.row_h,
            w = self.list.w - math.max(4, math.floor(self.pad * 0.5)), h = self.row_h - 2,
        }
        self.row_targets[#self.row_targets + 1] = { rect = rect, book = book }
        local selected = self.selected[book.name]
        bb:paintRect(rect.x, rect.y, rect.w, rect.h,
            selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
        local color = selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local count_w = math.max(20, math.floor(rect.w * 0.11))
        draw_text(bb, (selected and "[✓] " or "[ ] ") .. book.name, {
            x = rect.x + self.gap, y = rect.y, w = rect.w - count_w - self.gap * 2, h = rect.h,
        }, 18, false, false, color)
        draw_text(bb, tostring(book.count or ""), {
            x = rect.x + rect.w - count_w, y = rect.y, w = count_w, h = rect.h,
        }, 14, false, true, color)
        bb:paintRect(rect.x, rect.y + rect.h, rect.w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    end
    if #self.books > self.visible_rows then
        local track_x = self.list.x + self.list.w - 3
        bb:paintRect(track_x, self.list.y, 3, self.list.h, Blitbuffer.COLOR_LIGHT_GRAY)
        local thumb_h = math.max(8, math.floor(self.list.h * self.visible_rows / #self.books))
        local thumb_y = self.list.y + math.floor((self.list.h - thumb_h)
            * self.offset / math.max(1, #self.books - self.visible_rows))
        bb:paintRect(track_x, thumb_y, 3, thumb_h, Blitbuffer.COLOR_BLACK)
    end
    draw_button(bb, "❮", self.up_button, false, self.offset > 0, 24)
    draw_button(bb, "❯", self.down_button, false,
        self.offset + self.visible_rows < #self.books, 24)
    local last = math.min(#self.books, self.offset + self.visible_rows)
    if #self.books==0 and self.title_text then draw_text(bb,_("No tags created yet."),self.list,16,false,true)end
    draw_text(bb, string.format("%d–%d / %d", #self.books>0 and self.offset + 1 or 0, last, #self.books),
        self.status, 13, false, true)
    draw_button(bb, self.multiple and _("APPLY") or _("CANCEL"), self.apply_button,
        false, self.allow_empty or not self.multiple or self:selectionCount() > 0, 16)
end

function BookPicker:scroll(delta)
    self.offset = math.max(0, math.min(math.max(0, #self.books - self.visible_rows),
        self.offset + delta))
    UIManager:setDirty(self, "ui", Geom:new(self.box))
    return true
end

function BookPicker:onScrollUp()
    return self:scroll(-math.max(1, self.visible_rows - 1))
end

function BookPicker:onScrollDown()
    return self:scroll(math.max(1, self.visible_rows - 1))
end

function BookPicker:onSwipe(_, ges)
    if ges and contains(self.box, ges.pos) then
        if ges.direction == "north" or ges.direction == "west" then return self:onScrollDown() end
        if ges.direction == "south" or ges.direction == "east" then return self:onScrollUp() end
    end
    return true
end

function BookPicker:onTap(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then return self:onClose() end
    if contains(self.up_button, pos) then return self:onScrollUp() end
    if contains(self.down_button, pos) then return self:onScrollDown() end
    if contains(self.apply_button, pos) then
        if not self.multiple then return self:onClose() end
        local names = {}
        for _, book in ipairs(self.books) do
            if self.selected[book.name] then names[#names + 1] = book.name end
        end
        if #names == 0 and not self.allow_empty then return true end
        local owner = self.owner
        self:onClose()
        if self.on_apply then self.on_apply(names) else owner:applyFilter("books", names)end
        return true
    end
    for _, target in ipairs(self.row_targets or {}) do
        if contains(target.rect, pos) then
            if self.multiple then
                self.selected[target.book.name] = not self.selected[target.book.name]
                UIManager:setDirty(self, "ui", Geom:new(self.box))
            else
                local owner, name = self.owner, target.book.name
                self:onClose()
                owner:applyFilter("book", name)
            end
            return true
        end
    end
    return true
end

function BookPicker:onClose()
    UIManager:close(self)
    return true
end

function BookPicker:onCloseWidget()
    if self.owner._book_picker == self then self.owner._book_picker = nil end
    if not self.owner._closed then
        if self.owner.startTimeout then self.owner:startTimeout()end
        UIManager:setDirty(self.owner, "ui", Geom:new(self.owner.box))
    end
    UIManager:setDirty(nil, "ui", Geom:new(self.box))
end

local QuoteActions = InputContainer:extend{modal = true}

function QuoteActions:init()
    local parent = self.owner
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Screen:getSize()
    if not self.items then
        self.items={
            {icon="refresh.svg",text=_("Load New Quote"),action="refresh"},
            {icon="view.svg",text=_("View directly in text"),action="view"},
            {icon="unfavourited.svg",text=_("View favourites"),action="favourites"},
        }
        if parent.filter_mode=="book" or parent.filter_mode=="books" then
            self.items[#self.items+1]={icon="switch.svg",text=parent.filter_mode=="book" and _("Select Book") or _("Select Book(s)"),action="switch"}
        end
        if parent.filter_mode=="tags" then
            self.items[#self.items+1]={icon="switch.svg",text=_("Select Tags to View"),action="select_tags"}
            self.items[#self.items+1]={icon="appbar.settings",text=_("Manage Tags"),action="manage_tags"}
        end
        self.items[#self.items+1]={icon="search.svg",text=_("Search all quotes"),action="search"}
    end
    self.pad = math.max(10, Screen:scaleBySize(10))
    self.gap = math.max(8, Screen:scaleBySize(6))
    self.row_h = math.max(70, Screen:scaleBySize(54))
    self.box = {
        w = math.min(parent.box.w - parent.pad * 2, math.floor(w * 0.88)),
        h = self.pad * 2 + #self.items * self.row_h + (#self.items - 1) * self.gap,
    }
    self.box.x = math.floor((w - self.box.w) / 2)
    self.box.y = math.max(0, math.min(h - self.box.h,
        math.floor(parent.box.y + (parent.box.h - self.box.h) / 2)))
    self.buttons = {}
    for index, item in ipairs(self.items) do
        self.buttons[index] = {x = self.box.x + self.pad,
            y = self.box.y + self.pad + (index - 1) * (self.row_h + self.gap),
            w = self.box.w - self.pad * 2, h = self.row_h, item = item}
    end
    self.ges_events = {Tap = {GestureRange:new{ges = "tap", range = self.dimen}}}
    if Device:hasKeys() then self.key_events = {Close = {{"Back"}}} end
end

function QuoteActions:paintTo(bb)
    local r = self.box
    local radius = cornerRadius("slate.popup_corner_radius", 40)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, radius)
    for _, button in ipairs(self.buttons) do
        local radius = cornerRadius("slate.button_corner_radius", 40)
        bb:paintRoundedRect(button.x, button.y, button.w, button.h, Blitbuffer.COLOR_WHITE, radius)
        bb:paintBorder(button.x, button.y, button.w, button.h, 1, Blitbuffer.COLOR_BLACK, radius)
        local size = math.min(Screen:scaleBySize(32), button.h - self.pad * 2)
        local icon
        pcall(function()
            if button.item.icon == "appbar.settings" then
                icon = require("ui/widget/iconwidget"):new{icon = "appbar.settings",
                    width = size, height = size, alpha = true}
            else
                icon = ImageWidget:new{file = module_dir .. "icons/" .. button.item.icon,
                    width = size, height = size, alpha = true, original_in_nightmode = false, invert = false}
            end
            icon:paintTo(bb, button.x + self.pad, button.y + math.floor((button.h - size) / 2))
        end)
        if icon then icon:free() end
        local rect = {x = button.x + self.pad * 2 + size, y = button.y + self.pad,
            w = button.w - self.pad * 3 - size, h = button.h - self.pad * 2}
        if button.item.note then
            local half = math.floor(rect.h / 2)
            draw_text(bb, button.item.text, {x = rect.x, y = rect.y, w = rect.w, h = half}, 18, true, false)
            draw_text(bb, button.item.note, {x = rect.x, y = rect.y + half, w = rect.w,
                h = rect.h - half}, 12, false, false)
        else draw_text(bb, button.item.text, rect, 18, true, false) end
    end
end

function QuoteActions:onTap(arg, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then return self:onClose() end
    for index, button in ipairs(self.buttons) do
        if contains(button, pos) then
            local owner, action = self.owner, button.item.action
            self:onClose()
            if button.item.callback then
                local callback=button.item.callback
                UIManager:nextTick(function()
                    local ok,err=pcall(callback)
                    if not ok then
                        logger.warn("Slate: tag action failed:",err)
                        UIManager:show(SlateUtils:themePopup(InfoMessage:new{modal=true,text=_("Could not open tag action:").."\n"..tostring(err)}))
                        UIManager:setDirty(nil,"ui")
                    end
                end)
            elseif action == "select_tags" then require("slate_quotes"):selectTags()
            elseif action == "manage_tags" then require("slate_quotes"):manageTags()
            elseif action == "refresh" then owner:onNewQuote()
            elseif action == "view" then owner:onViewQuote()
            elseif action == "search" then require("slate_quotes"):searchAllQuotes()
            elseif action == "favourites" then require("slate_quotes"):viewFavourites()
            else owner:showBookPicker(owner.filter_mode == "books") end
            return true
        end
    end
    return true
end

function QuoteActions:onClose()
    UIManager:close(self)
    return true
end

function QuoteActions:onCloseWidget()
    if self.owner._action_menu == self then self.owner._action_menu = nil end
    if not self.owner._closed and self.owner.startTimeout then self.owner:startTimeout() end
    UIManager:setDirty(nil, "ui", Geom:new(self.owner.box))
end

local QuoteWidget = InputContainer:extend{
    modal = true, dismissable = true, timeout = nil,
    initial_page = 1, filter_mode = "random",
}

function QuoteWidget:init()
    if self.cover_task then UIManager:unschedule(self.cover_task);self.cover_task=nil end
    self.face = self.face or Font:getFace("infofont", 18)
    local entry = self.entry
    if type(entry) ~= "table" then entry = { text = tostring(entry or "") } end
    self.entry = {
        text = tostring(entry.text or ""), book = tostring(entry.book or ""),
        author = tostring(entry.author or ""),
        file = entry.file, pos0 = entry.pos0, page = entry.page,
    }
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Screen:getSize()
    local layout = SlateUtils.slate_popup_layout
    local owner = self.owner or (layout and layout.owner)
    self.owner=owner
    local slate_screen = owner and owner._slate_screen
    local lock = slate_screen and slate_screen.lock_button
    -- The visible lock glyph occupies the central 58% of its touch target.
    local region_top = lock and lock.y + math.floor(lock.h * .79) or 0
    local card = owner and owner._slate_card_bounds
    local region_bottom = card and card.y or (layout and layout.bottom) or h
    local edge = math.max(8, Screen:scaleBySize(10))
    local available = math.max(1, region_bottom - region_top - edge * 2)
    local popup_width = math.min(math.floor(w * 0.96), Screen:scaleBySize(900))
    local reference_pad = math.max(10, math.floor(popup_width * 0.035))
    local reference_nav = math.max(36, Screen:scaleBySize(36))
    local reference_line = math.max(32, Screen:scaleBySize(32))
    local base_height = math.max(1, math.floor(math.min(h * 0.60 - Screen:scaleBySize(24), available))
        - reference_nav - reference_line - reference_pad)
    self.box = Geom:new{
        w = popup_width,
        h = math.max(1, math.min(available, math.floor(base_height * 1.25 * 1.18))),
    }
    self.box.x = math.floor((w - self.box.w) / 2)
    self.box.y = math.max(0, math.floor(
        region_top + (region_bottom - region_top - self.box.h) / 2))
    self.pad = reference_pad
    self.gap = math.max(5, math.floor(self.pad * 0.65))
    local inner_x, inner_w = self.box.x + self.pad, self.box.w - self.pad * 2
    local button_h = math.max(26, math.min(Screen:scaleBySize(36), math.floor(self.box.h * 0.11)))
    self.bottom_pad = math.max(10, math.floor(math.min(
        math.floor(w * 0.96), Screen:scaleBySize(900)) * 0.045))
    local button_y = self.box.y + self.box.h - self.bottom_pad - button_h
    local button_w = math.floor((inner_w - self.gap * 2) / 3)
    self.mode_buttons = {}
    for i, mode in ipairs({ "random", "books", "tags" }) do
        self.mode_buttons[i] = {
            mode = mode, x = inner_x + (i - 1) * (button_w + self.gap),
            y = button_y, w = button_w, h = button_h,
        }
    end
    local action_size = math.max(24, Screen:scaleBySize(32))
    local header_icons = G_reader_settings:readSetting("slate.popup_header_icons", true) == true
    local header_size = math.max(16, math.min(200,
        tonumber(G_reader_settings:readSetting("slate.popup_header_icon_size", 72)) or 72))
    local glyph_size = math.max(1, math.floor(header_size))
    local glyph_inset = header_icons and math.floor((header_size - glyph_size) / 2) or 0
    local content_x = inner_x + glyph_inset
    local content_right = inner_x + inner_w - glyph_inset - action_size
    local content_w = math.max(1, content_right - content_x)
    self.content_edges = {left = content_x, right = content_right}
    local left_w = math.floor(math.min(self.box.w * 0.40, content_w * 0.40))
    if self.book_title_widget then self.book_title_widget:free() end
    for size = 16, 6, -1 do
        local face = Font:getFace("infofont", size)
        local line = TextWidget:new{text = "Ag", face = face, bold = true}
        local line_h = line:getSize().h
        line:free()
        self.book_title_widget = TextBoxWidget:new{
            text = self.entry.book, face = face, bold = true,
            width = left_w, alignment = "left",
        }
        if self.book_title_widget:getSize().h <= line_h * 2 or size == 6 then break end
        self.book_title_widget:free()
    end
    local title_h = self.book_title_widget:getSize().h
    local author = TextWidget:new{text = self.entry.author, face = Font:getFace("infofont", 14)}
    local author_h = author:getSize().h
    author:free()
    self.author_gap = math.max(2, math.floor(self.pad * 0.15))
    local meta_h = math.max(Screen:scaleBySize(44), title_h + self.author_gap + author_h)
    self.meta_rect = {
        x = content_x, y = button_y - self.bottom_pad - meta_h,
        w = left_w, h = meta_h,
    }
    self.title_h = title_h
    self.author_h = author_h
    self.quote_rect = {
        x = content_x, y = self.box.y + self.pad * 2, w = content_w,
    }
    self.header_icons = G_reader_settings:readSetting("slate.popup_header_icons", true) == true
    self.header_text = G_reader_settings:readSetting("slate.popup_header_text", true) == true
    self.header_icon_size = math.max(16, math.min(200,
        tonumber(G_reader_settings:readSetting("slate.popup_header_icon_size", 72)) or 72))
    self.header_rect = nil
    self.change_selection_button = nil
    do
        local height = math.max(Screen:scaleBySize(44),
            self.header_icons and self.header_icon_size or 0)
        local original_header_pad=math.max(10,math.min(Screen:scaleBySize(18),math.floor(self.box.w*.05)))
        self.header_rect = {
            x = self.box.x+original_header_pad, y = self.box.y+original_header_pad,
            w = self.box.w-original_header_pad*2, h = height,
        }
        self.quote_rect.y = self.header_rect.y + height + self.pad
    end
    self.menu_button = {
        x = self.header_rect.x + self.header_rect.w - glyph_inset - action_size,
        y = self.header_rect.y + math.floor((self.header_rect.h - action_size) / 2),
        w = action_size, h = action_size,
    }
    self.refresh_button, self.view_button, self.change_selection_button = nil, nil, nil
    self.title_divider_y=self.header_rect.y+self.header_rect.h+self.pad/2
    local book_y=self.title_divider_y+self.pad
    local book_h=math.max(reference_nav+reference_line,math.floor(base_height*.22))
    local cover_w=math.floor(book_h*.68)
    local pager_w=math.min(math.floor(inner_w*.50),Screen:scaleBySize(300))
    local meta_w=math.max(1,inner_w-cover_w-self.pad*2-pager_w)
    self.cover_rect={x=inner_x,y=book_y,w=cover_w,h=book_h}
    self.book_title_widget:free()
    for size=22,10,-1 do
        self.book_title_widget=TextBoxWidget:new{text=self.entry.book,face=Font:getFace('infofont',size),
            bold=true,width=meta_w,alignment='left'}
        self.title_h=self.book_title_widget:getSize().h
        if self.title_h+self.author_h+self.author_gap<=book_h or size==10 then break end
        self.book_title_widget:free()
    end
    self.meta_rect={x=inner_x+cover_w+self.pad,y=book_y,w=meta_w,h=book_h}
    local controls_x=inner_x+inner_w-pager_w
    self.controls_rect={x=controls_x,y=book_y+math.max(0,math.floor((book_h-reference_line-reference_nav)/2)),w=pager_w,
        line_h=reference_line,nav_h=reference_nav}
    self.book_page_rect={x=controls_x,y=book_y,w=pager_w-action_size-self.gap,h=reference_line}
    self.book_eye={x=inner_x+inner_w-action_size,y=book_y,w=action_size,h=action_size}
    self.book_divider_y=book_y+book_h+math.max(2,math.floor(self.pad/2))*3
    self.quote_rect={x=inner_x,y=self.book_divider_y+math.max(2,math.floor(self.pad/2))*3,w=inner_w}
    self.quote_rect.h=math.max(1,button_y-self.pad-self.quote_rect.y)
    -- Resize only the quote text area for the selected font, retaining every
    -- header, separator, cover and button padding ratio at its existing size.
    local quote_size=tonumber(self.quote_font_size) or tonumber(G_reader_settings:readSetting("slate.quotes.font_size",18)) or 18
    local desired_body=math.max(1,math.floor(self.quote_rect.h*quote_size/18+.5))
    local delta=math.floor(math.min(available,self.box.h+desired_body-self.quote_rect.h))-self.box.h
    self.box.h=self.box.h+delta
    local centered_y=math.max(0,math.floor(region_top+(region_bottom-region_top-self.box.h)/2))
    local dy=centered_y-self.box.y;self.box.y=centered_y
    for _,rect in ipairs({self.header_rect,self.cover_rect,self.meta_rect,self.controls_rect,
        self.book_page_rect,self.book_eye,self.quote_rect})do rect.y=rect.y+dy end
    self.title_divider_y=self.title_divider_y+dy
    self.book_divider_y=self.book_divider_y+dy
    for _,button in ipairs(self.mode_buttons)do button.y=button.y+dy+delta end
    button_y=button_y+dy+delta
    self.quote_rect.h=self.quote_rect.h+delta
    self.pages=build_pages(self.entry.text,self.face,self.quote_rect.w,self.quote_rect.h)
    self.max_pages=#self.pages
    self.current_page=math.max(1,math.min(self.max_pages,math.floor(tonumber(self.initial_page) or 1)))
    self.prev_button,self.page_label,self.next_button=nil,nil,nil
    if self.max_pages>1 then
        local third=math.floor(pager_w/3)
        local y=book_y+reference_line
        self.prev_button={x=controls_x,y=y,w=third,h=reference_nav}
        self.page_label={x=controls_x+third,y=y,w=third,h=reference_nav}
        self.next_button={x=controls_x+third*2,y=y,w=third,h=reference_nav}
    end
    if self.cover_widget then self.cover_widget:free();self.cover_widget=nil end
    if self.entry.file then
        local ok,cover=pcall(function()return require('slate_books'):loadCover(self.entry.file,cover_w,book_h,true)end)
        if ok then self.cover_widget=cover end
        if not self.cover_widget then
            self.cover_task=function()
                self.cover_task=nil
                if self._closed then return end
                local ok,cover=pcall(function()
                    local reader=require('apps/reader/readerui').instance
                    local document=reader and reader.document and reader.document.file==self.entry.file and reader.document or nil
                    return require('apps/filemanager/filemanagerbookinfo'):getCoverImage(document,self.entry.file)
                end)
                if ok and cover then
                    self.cover_widget=ImageWidget:new{image=cover,width=cover_w,height=book_h,scale_factor=nil}
                    UIManager:setDirty(self,'ui')
                end
            end
            UIManager:scheduleIn(.05,self.cover_task)
        end
    end
    local names = {}
    for _, name in ipairs(self.selected_books or {}) do names[#names + 1] = tostring(name) end
    table.sort(names)
    self.history_key = tostring(self.filter_mode) .. "|" .. tostring(self.selected_book or "")
        .. "|" .. table.concat(names, "\0")
    local history = quote_history[self.history_key]
    if not history then history = {items = {}, index = 0}; quote_history[self.history_key] = history end
    if not self._history_restoring then
        for i = #history.items, history.index + 1, -1 do history.items[i] = nil end
        history.items[#history.items + 1] = {entry = self.entry, page = self.current_page}
        if #history.items > 100 then table.remove(history.items, 1) end
        history.index = #history.items
    end
    self._history_restoring = nil
    self._closed = false
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" } },
            PrevPage = { { "PgBack" } },
            NextPage = { { "PgFwd" } },
        }
    end
end

function QuoteWidget:paintTo(bb)
    local r = self.box
    local radius = cornerRadius("slate.popup_corner_radius", 40)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, radius)
    if self.header_rect then
        local header = self.header_rect
        local text_x = header.x
        if self.header_icons then
            local size = self.header_icon_size
            local y = header.y + math.floor((header.h - size) / 2)
            local glyph_size = math.max(1, math.floor(size))
            bb:paintRoundedRect(header.x, y, size, size,
                Blitbuffer.COLOR_WHITE, math.floor(size / 2))
            if G_reader_settings:readSetting("slate.popup_header_outline", true) ~= false then
                bb:paintBorder(header.x, y, size, size,
                    math.max(1, math.floor(size / 14)),
                    Blitbuffer.COLOR_BLACK, math.floor(size / 2))
            end
            local path = self.filter_mode=="tags" and (module_dir.."icons/untagged.svg") or G_reader_settings:readSetting("slate.widget_icons.quote")
            if type(path) ~= "string" or path == "" or not util.fileExists(path) then
                path = module_dir .. "icons/quote.svg"
            end
            local icon
            local ok, err = pcall(function()
                icon = ImageWidget:new{
                    file = path, width = glyph_size, height = glyph_size,
                    alpha = true, original_in_nightmode = false, invert = false,
                }
                icon:paintTo(bb, header.x + math.floor((size - glyph_size) / 2),
                    y + math.floor((size - glyph_size) / 2))
            end)
            if icon then icon:free() end
            if not ok then logger.warn("Slate: quote header icon failed:", err) end
            text_x = text_x + size + Screen:scaleBySize(16)
        end
        if self.header_text then
            draw_text(bb, self.filter_mode=="tags" and _("TAGS") or _("QUOTES"), {
                x = text_x, y = header.y,
                w = math.max(1, self.menu_button.x - self.gap - text_x), h = header.h,
            }, 20, true, false)
        end
    end
    bb:paintRect(self.quote_rect.x,self.title_divider_y,self.quote_rect.w,1,Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(self.header_rect.x,self.book_divider_y,self.header_rect.w,1,Blitbuffer.COLOR_LIGHT_GRAY)
    if self.cover_widget then self.cover_widget:paintTo(bb,self.cover_rect.x,self.cover_rect.y) end
    bb:paintBorder(self.cover_rect.x,self.cover_rect.y,self.cover_rect.w,self.cover_rect.h,1,Blitbuffer.COLOR_BLACK)
    local history=quote_history[self.history_key] or {items={},index=1}
    local c=self.controls_rect
    local controls=require('slate_book_highlights'):paintQuoteControls(bb,{entry=self.entry,x=c.x,y=c.y,w=c.w,pad=self.pad,
        line_h=c.line_h,nav_h=c.nav_h,mode='highlights',file=self.entry.file,book_page=self.entry.page,
        quote_total=self.tagged_total or math.max(1,#history.items),quote_index=self.tagged_index or math.max(1,history.index),
        page_total=self.max_pages,parts=self.max_pages,part=self.current_page})
    self.tag_button=controls.tag
    self.favourite_button=controls.favourite
    self.book_eye,self.book_page_rect=controls.jump,controls.book_page_link
    self.quote_prev,self.quote_next=controls.quote_prev,controls.quote_next
    self.prev_button,self.next_button=controls.prev,controls.next
    local page = self.pages[self.current_page] or ""
    local display = page
    if self.current_page == 1 then display = "“" .. display end
    if self.current_page == self.max_pages then display = display .. "”" end
    if not self.quote_widget or self._painted_page ~= self.current_page then
        if self.quote_widget then self.quote_widget:free() end
        self.quote_widget = TextBoxWidget:new{
            text = display, face = self.face, italic = true, alignment = "left",
            width = self.quote_rect.w, fgcolor = Blitbuffer.COLOR_BLACK,
        }
        self._painted_page = self.current_page
    end
    self.quote_widget:paintTo(bb, self.quote_rect.x, self.quote_rect.y)
    local title_y=self.meta_rect.y+math.max(0,math.floor((self.meta_rect.h-self.title_h-self.author_h-self.author_gap)/2))
    self.book_title_widget:paintTo(bb,self.meta_rect.x,title_y)
    draw_text(bb, self.entry.author, {
        x = self.meta_rect.x,
        y = title_y + self.title_h + self.author_gap,
        w = self.meta_rect.w, h = self.author_h,
    }, 14, false, false)
    local icon
    local ok = pcall(function()
        icon = ImageWidget:new{file = module_dir .. "icons/menu.svg",
            width = self.menu_button.w, height = self.menu_button.h,
            alpha = true, original_in_nightmode = false, invert = false}
        icon:paintTo(bb, self.menu_button.x, self.menu_button.y)
    end)
    if icon then icon:free() end
    if not ok then draw_text(bb, "≡", self.menu_button, 32, true, true) end
    local labels = { _("RANDOM QUOTE"), _("BOOK(S)"), _("TAG(S)") }
    for i, button in ipairs(self.mode_buttons) do
        draw_button(bb, labels[i], button, self.filter_mode == button.mode, true, 18, "cfont")
    end
end

function QuoteWidget:pauseTimeout()
    if self._timeout_func then UIManager:unschedule(self._timeout_func) end
    self._timeout_func = nil
end

function QuoteWidget:startTimeout()
    self:pauseTimeout()
    if self.timeout and not self._closed and not self._book_picker and not self._action_menu then
        self._timeout_func = function()
            self._timeout_func = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(self.timeout, self._timeout_func)
    end
end

function QuoteWidget:onShow()
    self:startTimeout()
    UIManager:setDirty(self, "ui", Geom:new(self.box))
    return true
end

function QuoteWidget:onHold(_,ges)
    if contains(self.cover_rect,ges and ges.pos) then
        return require('slate_book_highlights'):showCoverPreview(self)
    end
    return true
end
function QuoteWidget:onHoldRelease()return true end

function QuoteWidget:onCloseWidget()
    if self.cover_task then UIManager:unschedule(self.cover_task);self.cover_task=nil end
    self._closed = true
    if self.cover_preview then UIManager:close(self.cover_preview);self.cover_preview=nil end
    self:pauseTimeout()
    if self._book_picker then UIManager:close(self._book_picker) end
    if self._action_menu then UIManager:close(self._action_menu) end
    if self.cover_widget then self.cover_widget:free(); self.cover_widget=nil end
    if self.quote_widget then self.quote_widget:free(); self.quote_widget = nil end
    if self.book_title_widget then self.book_title_widget:free(); self.book_title_widget = nil end
    UIManager:setDirty(nil, "ui", Geom:new(self.box))
end

function QuoteWidget:applyFilter(mode, selection)
    if type(self.on_filter_change) == "function" then
        return self.on_filter_change(mode, selection)
    end
    return false
end

function QuoteWidget:showBookPicker(multiple)
    if self._book_picker then return true end
    local books = self.book_choices or {}
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books with saved quotes were found. Extract highlights from Slate’s Quotes settings first."),
        })
        return true
    end
    self:pauseTimeout()
    self._book_picker = BookPicker:new{ owner = self, books = books, multiple = multiple }
    UIManager:show(self._book_picker,"ui")
    UIManager:setDirty(nil,"ui")
    if UIManager.forceRePaint then UIManager:forceRePaint()end
    return true
end

function QuoteWidget:onTap(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then
        if self.dismissable then return self:onClose() end
        return true
    end
    if contains(self.tag_button,pos) then
        require("slate_quotes"):tagQuote(self.entry,self);return true
    end
    if contains(self.favourite_button,pos) then
        require('slate_quotes'):toggleFavourite(self.entry)
        UIManager:setDirty(self,'ui');return true
    end
    if contains(self.cover_rect,pos) then return self:openBook() end
    if contains(self.book_eye,pos) or contains(self.book_page_rect,pos) then return self:onViewQuote() end
    if contains(self.quote_prev,pos) then return self:onPreviousQuote() end
    if contains(self.quote_next,pos) then return self:onNextQuote() end
    if contains(self.prev_button, pos) then return self:onPrevPage() end
    if contains(self.next_button, pos) then return self:onNextPage() end
    if contains(self.menu_button, pos) then return self:showActionMenu() end
    for _, button in ipairs(self.mode_buttons) do
        if contains(button, pos) then
            if button.mode == "tags" then self:applyFilter("tags")
            elseif button.mode == "random" then self:applyFilter("random")
            elseif button.mode == self.filter_mode then
                return true
            else
                local selection = button.mode == "book"
                    and self.selected_book or self.selected_books
                local has_selection = button.mode == "book"
                    and type(selection) == "string" and selection ~= ""
                    or button.mode == "books" and type(selection) == "table" and #selection > 0
                if not has_selection or not self:applyFilter(button.mode, selection) then
                    self:showBookPicker(button.mode == "books")
                end
            end
            return true
        end
    end
    return true
end

function QuoteWidget:onSwipe(_, ges)
    if ges and contains(self.box, ges.pos) then
        if ges.direction == "north" then return self:onNewQuote() end
        if ges.direction == "south" then return self:onPreviousQuote() end
        if ges.direction == "west" then return self:onNextPage() end
        if ges.direction == "east" then return self:onPrevPage() end
    end
    return true
end

function QuoteWidget:onClose()
    UIManager:close(self)
    return true
end

QuoteWidget.onTapClose = QuoteWidget.onClose
QuoteWidget.onAnyKeyPressed = QuoteWidget.onClose

function QuoteWidget:showActionMenu()
    if self._action_menu then return true end
    self:pauseTimeout()
    self._action_menu = QuoteActions:new{owner = self}
    UIManager:show(self._action_menu, "ui")
    return true
end

function QuoteWidget:openBook()
    local file=self.entry.file
    if not file then return true end
    local owner=self.owner or (SlateUtils.slate_popup_layout and SlateUtils.slate_popup_layout.owner) or {}
    self:onClose()
    require('slate_books'):openBook(owner,{file=file})
    return true
end
function QuoteWidget:onViewQuote()
    if type(self.on_view_quote) == "function" then return self.on_view_quote(self.entry) end
    local loaded, quotes = pcall(require, "slate_quotes")
    if loaded and type(quotes.viewQuote) == "function" then
        return quotes:viewQuote(self.entry)
    end
    UIManager:show(SlateUtils:themePopup(InfoMessage:new{
        text = _("Quote navigation needs the updated Slate quotes module."),
    }))
    return true
end

function QuoteWidget:onNewQuote()
    local history = quote_history[self.history_key]
    if history and history.items[history.index] then
        history.items[history.index].page = self.current_page
    end
    if type(self.on_new_quote) == "function" then self.on_new_quote() end
    return true
end

function QuoteWidget:onPreviousQuote()
    if self.filter_mode=="tags" and self.on_tag_turn then return self.on_tag_turn(-1)end
    return self:turnQuoteHistory(-1)
end
function QuoteWidget:onNextQuote()
    if self.filter_mode=="tags" and self.on_tag_turn then return self.on_tag_turn(1)end
    return self:turnQuoteHistory(1)
end

function QuoteWidget:turnQuoteHistory(delta)
    local history = quote_history[self.history_key]
    if not history then return true end
    local index=math.max(1,math.min(#history.items,history.index+delta))
    if index==history.index then return true end
    history.items[history.index].page = self.current_page
    history.index = index
    local saved = history.items[history.index]
    if self.quote_widget then self.quote_widget:free(); self.quote_widget = nil end
    self._painted_page = nil
    self.entry, self.initial_page = saved.entry, saved.page
    self._history_restoring = true
    self:init()
    self:startTimeout()
    UIManager:setDirty(self, "ui", Geom:new(self.box))
    return true
end

function QuoteWidget:onPrevPage()
    if self.current_page > 1 then
        self.current_page = self.current_page - 1
        UIManager:setDirty(self, "ui", Geom:new(self.box))
    end
    return true
end

function QuoteWidget:onNextPage()
    if self.current_page < self.max_pages then
        self.current_page = self.current_page + 1
        UIManager:setDirty(self, "ui", Geom:new(self.box))
    end
    return true
end

function QuoteWidget:showTagPicker(parent,names,initial,on_apply)
    parent=parent or {box=Geom:new{w=900,h=900},startTimeout=function()end}
    if parent.pauseTimeout then parent:pauseTimeout()end
    local rows={}
    for _,name in ipairs(names)do rows[#rows+1]={name=name}end
    local picker=BookPicker:new{owner=parent,books=rows,multiple=true,title_text=_("SELECT TAGS"),
        initial_selected=initial,allow_empty=true,on_apply=on_apply}
    parent._book_picker=picker
    UIManager:show(picker,"ui");UIManager:setDirty(nil,"ui")
    if UIManager.forceRePaint then UIManager:forceRePaint()end
end

function QuoteWidget:showTagMenuRows(parent,items)
    parent=parent or {pad=31,box={w=math.min(Screen:getWidth()*.96,Screen:scaleBySize(900)),h=Screen:getHeight()*.65,y=Screen:getHeight()*.175},
        startTimeout=function()end,pauseTimeout=function()end}
    if parent.pauseTimeout then parent:pauseTimeout()end
    local menu=QuoteActions:new{owner=parent,items=items}
    parent._action_menu=menu
    UIManager:show(menu,"ui");UIManager:setDirty(nil,"ui")
    if UIManager.forceRePaint then UIManager:forceRePaint()end
end

SlateUtils:themePopup(QuoteActions)
SlateUtils:themePopup(BookPicker)
SlateUtils:themePopup(QuoteWidget)

return QuoteWidget
