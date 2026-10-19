-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-09.
-- Reading Display: book cover and weather card, shared with Custom background.

local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Font = require("ui/font")
local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local Geom = require("ui/geometry")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local SlateUtils = require("slate_utils")
local datetime = require("datetime")

local SlateReading = {}

local DEFAULT_CUSTOM_BG_PATH = "/mnt/us/wallpapers/sleepscreen.jpg"

function SlateReading:advanceCustomBackground()
    self._custom_bg_rotation_pending=true
end

function SlateReading:getCustomBgPath()
    local selected=G_reader_settings and G_reader_settings:readSetting("slate_weather_custom_bg_path")
    if type(selected)~="string"or selected==""then selected=DEFAULT_CUSTOM_BG_PATH end
    if not selected:match("^/")then selected="/mnt/us/wallpapers/"..selected end
    if not G_reader_settings or G_reader_settings:readSetting("slate_weather_custom_bg_rotate",false)~=true then
        self._custom_bg_rotation=nil
        return selected
    end
    local folder=G_reader_settings:readSetting("slate_weather_custom_bg_folder")
    if type(folder)~="string"or folder==""then folder=selected:match("^(.*)/[^/]+$")or "/mnt/us/wallpapers"end
    if not folder:match("^/")then folder="/mnt/us/wallpapers/"..folder end
    folder=folder:gsub("/+$","");if folder==""then folder="/"end
    local cached=self._custom_bg_rotation
    if not self._custom_bg_rotation_pending and cached and cached.folder==folder and cached.selected==selected
        and util.fileExists(cached.path)then return cached.path end
    local images={}
    local ok=pcall(function()
        local lfs=require("libs/libkoreader-lfs")
        local supported={png=true,jpg=true,jpeg=true,gif=true,bmp=true,webp=true,tif=true,tiff=true,svg=true}
        for name in lfs.dir(folder)do
            local extension=name:lower():match("%.([^.]+)$")
            local path=(folder=="/"and "/"or folder.."/")..name
            if supported[extension]and lfs.attributes(path,"mode")=="file"then images[#images+1]=path end
        end
    end)
    if not ok or #images==0 then
        self._custom_bg_rotation=nil;self._custom_bg_rotation_pending=nil
        return selected
    end
    table.sort(images,function(a,b)
        local al,bl=a:lower(),b:lower()
        return al==bl and a<b or al<bl
    end)
    local previous=cached and cached.folder==folder and cached.selected==selected and cached.path
        or (not cached and G_reader_settings:readSetting("slate_weather_custom_bg_rotation_last"))or selected
    local index=1
    for i,path in ipairs(images)do
        if path==previous then index=self._custom_bg_rotation_pending and (i%#images+1)or i;break end
    end
    local path=images[index]
    self._custom_bg_rotation_pending=nil
    self._custom_bg_rotation={folder=folder,selected=selected,path=path}
    G_reader_settings:saveSetting("slate_weather_custom_bg_rotation_last",path)
    G_reader_settings:flush()
    return path
end

local function getCustomImageScaleMultiplier()
    if not G_reader_settings then
        return 1.0
    end
    local mode = G_reader_settings:readSetting("slate_weather_custom_img_mode") or "stretch_fit"
    if mode ~= "zoom" then
        return 1.0
    end
    local percent = tonumber(G_reader_settings:readSetting("slate_weather_custom_img_zoom_percent")) or 110
    if percent < 100 then percent = 100 end
    if percent > 150 then percent = 150 end
    return percent / 100
end

function SlateReading:getDocumentInfo()
    local ui = ReaderUI.instance
    if ui and ui.document then
        local doc_props = ui.doc_props or {}
        local doc_settings = ui.doc_settings and ui.doc_settings.data or {}
        local state = ui.view and ui.view.state

        local title = doc_props.display_title or doc_props.title or "Unknown Title"
        local authors = doc_props.authors or ""
        if authors:find("\n") then
            local authors_array = util.splitToArray(authors, "\n")
            if authors_array and authors_array[1] then
                authors = authors_array[1]
                if #authors_array > 1 then
                    authors = authors_array[1] .. " et al."
                end
            end
        end

        local page_no = (state and state.page) or 1
        local page_total = doc_settings.doc_pages or 1
        if page_total <= 0 then page_total = 1 end
        if page_no < 1 then page_no = 1 end
        if page_no > page_total then page_no = page_total end

        local progress = page_no / page_total

        local cover_bb
        if ui.bookinfo and ui.document then
            cover_bb = ui.bookinfo:getCoverImage(ui.document)
        end

        local doc_info = {
            file       = ui.document.file,
            title      = title,
            authors    = authors,
            page_no    = page_no,
            page_total = page_total,
            progress   = progress,
            cover_bb   = cover_bb,
        }

        local cacheable = {
            file       = ui.document.file,
            title      = title,
            authors    = authors,
            page_no    = page_no,
            page_total = page_total,
            progress   = progress,
        }
        pcall(function()
            SlateUtils:saveDocInfoCache(cacheable)
        end)

        return doc_info
    end

    local cached = SlateUtils:loadDocInfoCache()
    if cached then
        cached.file = cached.file or G_reader_settings:readSetting("lastfile")
        logger.dbg("Slate reading: Using cached document info for overlay card")
        return cached
    end

    logger.dbg("Slate reading: No active document and no cached doc info; using empty doc info")
    return {
        title      = nil,
        authors    = nil,
        page_no    = nil,
        page_total = nil,
        progress   = nil,
        cover_bb   = nil,
    }
end

local function getEffectiveNightModeForWidget()
    local real = G_reader_settings and G_reader_settings:isTrue("night_mode")
    local mode = G_reader_settings and G_reader_settings:readSetting("slate_weather_widget_theme_override") or "default"

    local effective
    if mode == "day" then
        effective = false
    elseif mode == "night" then
        effective = true
    else
        effective = real
        mode = "default"
    end

    return effective, mode, real
end

local function getScreenWhite()
    local fix_bg = true
    if G_reader_settings then
        fix_bg = G_reader_settings:nilOrTrue("slate_weather_cover_nightmode_fix_bg")
    end

    if not fix_bg then
        return Blitbuffer.COLOR_WHITE
    end

    if G_reader_settings and G_reader_settings:isTrue("night_mode") then
        return Blitbuffer.COLOR_BLACK
    else
        return Blitbuffer.COLOR_WHITE
    end
end

function SlateReading:createLetterboxedBackgroundFromFile(image_path, screen_width, screen_height)
    local bg_color = getScreenWhite()

    local mode = "stretch_fit"
    if G_reader_settings then
        mode = G_reader_settings:readSetting("slate_weather_custom_img_mode") or "stretch_fit"
    end

    local zoom = getCustomImageScaleMultiplier()
    if mode == "stretch_fit" then
        zoom = 1.0
    end

    local target_w = math.floor(screen_width * zoom)
    local target_h = math.floor(screen_height * zoom)

    local bb = RenderImage:renderImageFile(image_path, false, target_w, target_h)

    if not bb then
        local dummy = TextWidget:new{
            text = "",
            face = Font:getFace("cfont", 1),
        }
        return FrameContainer:new{
            width = screen_width,
            height = screen_height,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = bg_color,
            CenterContainer:new{
                dimen = Geom:new{ w = screen_width, h = screen_height },
                dummy,
            },
        }
    end

    local img_w = bb:getWidth()
    local img_h = bb:getHeight()

    if mode == "stretch_fit" then
        bb = RenderImage:scaleBlitBuffer(bb, screen_width, screen_height, true)
        img_w = screen_width
        img_h = screen_height
    end

    local scaled_image = ImageWidget:new{
        image = bb,
        width = img_w,
        height = img_h,
        alpha = true,
    }

    return FrameContainer:new{
        width = screen_width,
        height = screen_height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = bg_color,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_width, h = screen_height },
            scaled_image,
        },
    }
end

local function getUserSize(setting_key, base_val)
    local val = tonumber(G_reader_settings and G_reader_settings:readSetting(setting_key))
    if val and val > 0 then
        return val
    end
    return math.max(1, math.floor(base_val))
end

function SlateReading:formatObservationLabel(weather_data)
    local current = weather_data.current or {}
    local timestamp = current.timestamp
    if type(timestamp) ~= "string" and current.observation_epoch and current.utc_offset then
        timestamp = os.date("!%Y-%m-%d %H:%M", current.observation_epoch + current.utc_offset)
    end
    local date, hour, minute
    if type(timestamp) == "string" then
        date, hour, minute = timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d?):(%d%d)")
    end
    hour, minute = tonumber(hour), tonumber(minute)
    if not date or not hour or not minute or hour > 23 or minute > 59 then
        return _("Weather unavailable")
    end
    local clock
    if G_reader_settings:isTrue("twelve_hour_clock") then
        local display_hour = hour % 12
        if display_hour == 0 then display_hour = 12 end
        clock = string.format("%d:%02d %s", display_hour, minute, hour < 12 and "AM" or "PM")
    else
        clock = string.format("%02d:%02d", hour, minute)
    end
    local today = SlateUtils:getWeatherLocalDate(weather_data)
    if date ~= today then
        clock = date:sub(6) .. " " .. clock
    end
    local label = weather_data.is_stale and _("Stale")
        or (weather_data.is_cached and _("Cached") or _("Updated"))
    return label .. " " .. clock
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local ThreeSectionCard = WidgetContainer:extend{}

function ThreeSectionCard:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ThreeSectionCard:free()
    for _, icon in pairs(self.icons or {}) do icon:free() end
    self.icons = nil
    if self.book_labels then
        self.book_labels.title:free()
        self.book_labels.author:free()
        self.book_labels = nil
    end
end

local function textInkBounds(widget)
    local dim = widget:getSize()
    if type(widget.getBaseline) ~= "function" then return 0, dim.h end
    if widget._slate_ink_top then return widget._slate_ink_top, widget._slate_ink_bottom end
    local ok, render = pcall(require, "ui/rendertext")
    if not ok or type(render.getGlyph) ~= "function" then return 0, dim.h end
    local baseline = widget:getBaseline()
    local top, bottom, index = math.huge, -math.huge, 1
    local value = tostring(widget.text or "")
    while index <= #value do
        local code, count = value:byte(index), 1
        if code >= 240 then code, count = code % 8, 4
        elseif code >= 224 then code, count = code % 16, 3
        elseif code >= 192 then code, count = code % 32, 2 end
        for offset = 1, count - 1 do code = code * 64 + ((value:byte(index + offset) or 128) % 64) end
        local success, glyph = pcall(render.getGlyph, render, widget.face, code, widget.bold)
        if success and glyph and glyph.bb and glyph.t then
            local height = glyph.bb:getHeight()
            if height > 0 then
                top = math.min(top, baseline - glyph.t)
                bottom = math.max(bottom, baseline - glyph.t + height)
            end
        end
        index = index + count
    end
    if top == math.huge then return 0, dim.h end
    widget._slate_ink_top, widget._slate_ink_bottom = top, bottom
    return top, bottom
end

local function cardText(bb, text, rect, size, color, bold, align, vertical_align, minimum_size)
    local widget
    local minimum = math.min(size, minimum_size or 6)
    for font_size = size, minimum, -1 do
        widget = TextWidget:new{
            text = tostring(text or ""), face = Font:getFace("cfont", font_size),
            bold = bold, fgcolor = color,
            max_width = minimum_size and font_size == minimum and math.max(1, rect.w) or nil,
        }
        local dim = widget:getSize()
        if (dim.h <= rect.h and dim.w <= rect.w) or font_size == minimum then break end
        widget:free()
    end
    local dim = widget:getSize()
    local x = rect.x
    if align == "right" then x = x + math.max(0, rect.w - dim.w) end
    if align == "center" then x = x + math.max(0, math.floor((rect.w - dim.w) / 2)) end
    local ink_top, ink_bottom = textInkBounds(widget)
    local offset_y = vertical_align == "bottom" and rect.h - ink_bottom
        or math.floor((rect.h - dim.h) / 2)
    widget:paintTo(bb, x, rect.y + math.max(0, offset_y))
    widget:free()
    return dim.w, dim.h, rect.y + math.max(0, offset_y) + ink_top,
        rect.y + math.max(0, offset_y) + ink_bottom
end

local function wrapBookWords(value)
    local lines, words = {}, {}
    for word in tostring(value or ""):gmatch("%S+") do
        words[#words + 1] = word
        if #words == 4 then
            lines[#lines + 1] = table.concat(words, " ")
            words = {}
        end
    end
    if #words > 0 then lines[#lines + 1] = table.concat(words, " ") end
    return table.concat(lines, "\n")
end

local function fixedBookLines(value, face, color, bold)
    local result = {text = value, face = face, lines = {}, w = 0, h = 0}
    for line in (value .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            local widget = TextWidget:new{text = line, face = face, bold = bold, fgcolor = color}
            local size = widget:getSize()
            result.lines[#result.lines + 1] = {widget = widget, height = size.h}
            result.w, result.h = math.max(result.w, size.w), result.h + size.h
        end
    end
    function result:getSize() return {w = self.w, h = self.h} end
    function result:paintTo(bb, x, y)
        for _, line in ipairs(self.lines) do
            line.widget:paintTo(bb, x, y)
            y = y + line.height
        end
    end
    function result:free()
        for _, line in ipairs(self.lines) do line.widget:free() end
        self.lines = {}
    end
    return result
end

local function widthWrappedTitle(value,face,width,color,truncate)
    local function measured(value)
        local widget=TextWidget:new{text=value,face=face,bold=true,fgcolor=color}
        local w=widget:getSize().w;widget:free();return w
    end
    local lines,current={},''
    for word in tostring(value or ''):gmatch('%S+') do
        local candidate=current=='' and word or current..' '..word
        if current~='' and measured(candidate)>width then lines[#lines+1]=current;current=word
        else current=candidate end
    end
    if current~='' then lines[#lines+1]=current end
    if truncate then
        local omitted=#lines>2
        while #lines>2 do table.remove(lines) end
        for index,line in ipairs(lines) do
            local clipped=measured(line)>width or (omitted and index==#lines)
            if clipped then
                while #line>0 and measured(line..'…')>width do
                    local last=#line
                    while last>1 and line:byte(last)>=128 and line:byte(last)<=191 do last=last-1 end
                    line=line:sub(1,last-1):gsub('%s+$','')
                end
                lines[index]=line..'…'
            end
        end
    end
    return table.concat(lines,'\n'),#lines
end

local function paintBookLabels(card, bb, title, authors, area, title_size, author_size, color)
    if type(authors) == "table" then authors = table.concat(authors, ", ") end
    title=tostring(title or '')
    authors=wrapBookWords(authors)
    local title_width=area.title_w or area.w
    local key = table.concat({title, authors, area.w, title_width, area.h, title_size, author_size, tostring(color)}, "|")
    local labels = card.book_labels
    if not labels or labels.key ~= key then
        if labels then labels.title:free(); labels.author:free() end
        local gap=math.max(2,math.floor(area.h*.025))
        local maximum=math.max(6,math.floor(title_size))
        local reasonable=math.min(maximum,math.max(10,math.floor(maximum*.65)))
        local fitted=false
        for pass=1,2 do
            for size=maximum,(pass==1 and reasonable or 6),-1 do
                local title_face=Font:getFace('cfont',size)
                local author_face=Font:getFace('cfont',math.max(6,math.floor(author_size*size/maximum)))
                local wrapped,count=widthWrappedTitle(title,title_face,title_width,color,pass==2)
                labels={key=key,gap=gap,title=fixedBookLines(wrapped,title_face,color,true),
                    author=fixedBookLines(authors,author_face,color,false)}
                labels.title_h=labels.title:getSize().h
                labels.author_h=labels.author:getSize().h
                if count<=2 and labels.title.w<=title_width and labels.author.w<=area.w
                    and labels.title_h+labels.author_h+gap<=area.h then fitted=true;break end
                if pass==2 and size==6 then fitted=true;break end
                labels.title:free();labels.author:free()
            end
            if fitted then break end
        end
        card.book_labels = labels
    end
    local first_line = labels.title.lines[1] or labels.author.lines[1]
    local ink_top = first_line and textInkBounds(first_line.widget) or 0
    labels.title:paintTo(bb, area.x, area.y - ink_top)
    labels.author:paintTo(bb, area.x, area.y - ink_top + labels.title_h + labels.gap)
end

local function paintLocationBattery(bb, text, rect, size, color)
    local ok, capacity = pcall(function()
        local power = Device:getPowerDevice()
        return power and power:getCapacity()
    end)
    capacity = ok and tonumber(capacity) or nil
    if not capacity then
        return cardText(bb, text, rect, size, color, false, nil, nil, math.max(1, math.floor(size*.4)))
    end
    capacity = math.max(0, math.min(100, math.floor(capacity + 0.5)))
    local prefix, percent, dimensions, prefix_widget, percent_widget
    prefix = text .. " • "
    percent = tostring(capacity) .. "%"
    local minimum = math.max(1, math.floor(size * .4))
    for font_size = math.max(1, math.floor(size)), minimum, -1 do
        prefix_widget = TextWidget:new{
            text = prefix, face = Font:getFace("cfont", font_size), fgcolor = color,
        }
        percent_widget = TextWidget:new{
            text = percent, face = Font:getFace("cfont", math.max(1, math.floor(font_size * 0.8))),
            fgcolor = color,
        }
        local pd, bd = prefix_widget:getSize(), percent_widget:getSize()
        local icon_h = math.max(3, math.floor(bd.h * 0.6))
        local icon_w = math.max(5, math.floor(icon_h * 1.7))
        local gap = math.max(1, math.floor(icon_h * 0.3))
        local terminal = math.max(1, math.floor(icon_h * 0.16))
        if font_size == minimum then
            prefix_widget:free()
            prefix_widget = TextWidget:new{
                text = prefix, face = Font:getFace("cfont", font_size), fgcolor = color,
                max_width = math.max(1, rect.w-icon_w-terminal-gap*2-bd.w),
                truncate_left = true,
            }
            pd = prefix_widget:getSize()
        end
        dimensions = {
            prefix = pd, percent = bd, icon_h = icon_h, icon_w = icon_w,
            gap = gap, terminal = terminal,
            w = pd.w + icon_w + terminal + gap * 2 + bd.w,
            h = math.max(pd.h, bd.h, icon_h),
        }
        if dimensions.w <= rect.w and dimensions.h <= rect.h then break end
        prefix_widget:free()
        percent_widget:free()
        prefix_widget, percent_widget = nil, nil
    end
    if not prefix_widget then return end
    local d = dimensions
    local prefix_top, prefix_bottom = textInkBounds(prefix_widget)
    local percent_top, percent_bottom = textInkBounds(percent_widget)
    local prefix_y = rect.y + math.max(0, math.floor((rect.h - d.prefix.h) / 2))
    local percent_y = rect.y + math.max(0, math.floor((rect.h - d.percent.h) / 2))
    prefix_widget:paintTo(bb, rect.x, rect.y + math.max(0, math.floor((rect.h - d.prefix.h) / 2)))
    local bx = rect.x + d.prefix.w + d.gap
    local by = rect.y + math.max(0, math.floor((rect.h - d.icon_h) / 2))
    local stroke = math.max(1, math.floor(d.icon_h * 0.12))
    bb:paintBorder(bx, by, d.icon_w, d.icon_h, stroke, color)
    bb:paintRect(bx + d.icon_w, by + math.floor(d.icon_h * 0.3),
        d.terminal, math.max(1, math.floor(d.icon_h * 0.4)), color)
    local fill_w = math.floor(math.max(0, d.icon_w - stroke * 4) * capacity / 100)
    if fill_w > 0 then
        bb:paintRect(bx + stroke * 2, by + stroke * 2,
            fill_w, math.max(1, d.icon_h - stroke * 4), color)
    end
    percent_widget:paintTo(bb, bx + d.icon_w + d.terminal + d.gap,
        rect.y + math.max(0, math.floor((rect.h - d.percent.h) / 2)))
    prefix_widget:free()
    percent_widget:free()
    return d.w, d.h, math.min(prefix_y + prefix_top, percent_y + percent_top, by),
        math.max(prefix_y + prefix_bottom, percent_y + percent_bottom, by + d.icon_h)
end

function ThreeSectionCard:paintTo(bb, x, y)
    local owner, data, doc = self.owner, self.data, self.doc
    local effective, override, real = getEffectiveNightModeForWidget()
    local emulate = (override == "night" and not real) or (override == "day" and real)
    local background = emulate and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local foreground = emulate and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local radius = math.max(0, math.min(60, tonumber(
        G_reader_settings:readSetting("slate_weather_widget_corner_radius", 40)
    ) or 40))
    bb:paintRoundedRect(x, y, self.width, self.height, background, radius)
    local pad = math.min(getUserSize("slate_weather_widget_card_padding", 22),
        math.floor(self.height * 0.12), math.floor(self.width * 0.04))
    local inner_x, inner_y = x + pad, y + pad
    local inner_w, inner_h = self.width - pad * 2, self.height - pad * 2
    local section_w = inner_w / 3
    local gutter = math.max(2, math.floor(section_w * 0.05))
    local book_x = inner_x + gutter
    local weather_x = inner_x + section_w + gutter
    local content_w = math.max(1, math.floor(section_w - gutter * 2))
    local weather_enabled = G_reader_settings:readSetting("slate_weather_main_weather_enabled", true) ~= false
    local book_w, book_scale = content_w, 1
    local function bookSize(key, default)
        return math.max(1, math.floor(getUserSize(key, default) * book_scale))
    end
    local function rect(rx, fraction, height)
        return {
            x = math.floor(rx),
            y = math.floor(inner_y + inner_h * fraction),
            w = content_w,
            h = math.max(1, math.floor(inner_h * height)),
        }
    end
    owner._slate_card_bounds = { x = x, y = y, w = self.width, h = self.height }
    owner._slate_button_area = {
        x = inner_x + section_w * 2 + gutter,
        y = inner_y,
        w = content_w,
        h = inner_h,
        foreground = foreground,
        background = background,
        emulate = emulate,
    }
    owner._slate_book_tap_targets = {}
    owner._slate_tap_targets = {}
    -- Keep launcher geometry independent of the expanded book section.
    local button_area = owner._slate_button_area
    local base_button = math.min(Screen:scaleBySize(36), math.floor(Screen:getWidth() * 0.08))
    local button_size = math.max(1, math.min(base_button,
        math.floor((button_area.w - 2) / 2.56),
        math.floor((button_area.h - 2) / 2.56)))
    local button_gap = math.max(2, math.min(math.floor(button_size * 0.56),
        math.floor(button_area.w - button_size * 2), math.floor(button_area.h - button_size * 2)))
    local button_left = math.floor(button_area.x + button_area.w - button_size * 2 - button_gap)
    weather_x = math.floor((book_x + content_w + button_left - content_w) / 2)
    if not weather_enabled then
        book_w = math.max(1, button_left - button_gap - math.floor(book_x))
        book_scale = math.min(1.5, math.sqrt(book_w / content_w))
    end
    local function bookRect(fraction, height)
        local r = rect(book_x, fraction, height);r.w=book_w;return r
    end
    local book_labels_bottom = inner_y + inner_h * 0.64
    local book_label_width = book_w
    local progress = tonumber(doc.progress)
    if progress then
        progress = math.max(0, math.min(1, progress))
        local line = weather_enabled and bookRect(0.66, 0.16) or bookRect(0.60, 0.24)
        book_labels_bottom = line.y - math.max(2, math.floor(inner_h * 0.02))
        -- Shorten the weather-off progress region without changing title width.
        local progress_w = weather_enabled and book_w or math.floor(book_w*.95)
        local percent_w = math.max(1, math.floor(book_w * 0.23))
        local old_gap = math.max(2, math.floor(book_w * 0.015))
        local text_w = cardText(bb, string.format("%i%%", math.floor(progress * 100 + 0.5)),
            { x = line.x + progress_w - percent_w, y = line.y, w = percent_w, h = line.h },
            bookSize("slate_weather_widget_progress_font_size", 26),
            foreground, true, weather_enabled and "center" or "right")
        -- Include the percentage's centering inset when halving the visible gap.
        local inset = math.max(0, weather_enabled and math.floor((percent_w - text_w) / 2) or percent_w - text_w)
        local gap = math.max(1, math.floor((old_gap + (weather_enabled and inset or 0)) / 2))
        if not weather_enabled then gap=gap*2 end
        local bar_w = math.max(1, progress_w - percent_w + inset - gap)
        book_label_width = weather_enabled and bar_w or math.max(1,book_w-percent_w+inset-math.floor(gap/2))
        local bar_h = math.max(1, math.min(
            math.floor(getUserSize("slate_weather_widget_progress_height", 6) * (weather_enabled and 1 or book_w/content_w)),
            math.floor(line.h / 3)))
        local bar_y = line.y + math.floor((line.h - bar_h) / 2)
        bb:paintRect(line.x, bar_y, bar_w, bar_h, Blitbuffer.COLOR_GRAY_9)
        bb:paintRect(line.x, bar_y, math.floor(bar_w * progress), bar_h, foreground)
        owner._slate_book_tap_targets.progress = line
    end

    local custom = (self.background_mode or G_reader_settings:readSetting("slate_weather_display_style")) == "custombg"
    -- Each display has its own removal preference; no master switch can
    -- override the other mode. The old switch only seeds cover-mode defaults.
    local remove_border
    if custom then
        remove_border = G_reader_settings:readSetting("slate_weather_remove_custom_widget_border", false) == true
    else
        local old_removed = G_reader_settings:readSetting("slate_weather_widget_border_enabled", true) ~= true
        remove_border = G_reader_settings:readSetting("slate_weather_remove_cover_widget_border", old_removed) == true
    end
    if not remove_border then
        bb:paintBorder(x, y, self.width, self.height, 2, foreground, radius)
    end
    local labels_y, weather_bottom = inner_y, inner_y + inner_h
    if weather_enabled then
        local top = rect(weather_x, 0, 0.46)
        local phase = data.astronomy and data.astronomy.moon_phase
        local moon_path = phase and owner:getMoonPhaseIcon(phase)
        local weather_path = data.current.icon_path
        local temperature = tostring(data.current.temperature or "")
        local weather_size = getUserSize("slate_weather_widget_weather_icon_size", 146)
        local moon_size = getUserSize("slate_weather_widget_moon_icon_size", 85)
        local gap = math.max(2, getUserSize("slate_weather_widget_small_spacing", 5))
        local icon_count = (moon_path and 1 or 0) + (weather_path and 1 or 0)
        local temp_size = getUserSize("slate_weather_widget_temp_size", 37)
        local temp_width, temp_height

        local function measureTemperature(size)
            local text = TextWidget:new{
                text = temperature, face = Font:getFace("cfont", size), bold = true,
            }
            local dim = text:getSize()
            text:free()
            return dim.w, dim.h
        end

        temp_width, temp_height = measureTemperature(temp_size)
        local wanted = (moon_path and moon_size or 0) + (weather_path and weather_size or 0)
        local factor = math.min(1,
            top.w / math.max(1, wanted + temp_width + icon_count * gap),
            top.h / math.max(1, temp_height,
                weather_path and weather_size or 0,
                moon_path and moon_size or 0))
        moon_size = math.max(1, math.floor(moon_size * factor))
        weather_size = math.max(1, math.floor(weather_size * factor))
        temp_size = math.max(6, math.floor(temp_size * factor))
        gap = math.max(2, math.floor(gap * factor))
        temp_width, temp_height = measureTemperature(temp_size)

        local function groupWidth()
            return (moon_path and moon_size or 0) + (weather_path and weather_size or 0)
                + temp_width + icon_count * gap
        end

        while temp_size > 6 and (groupWidth() > top.w or temp_height > top.h) do
            temp_size = temp_size - 1
            temp_width, temp_height = measureTemperature(temp_size)
        end
        if groupWidth() > top.w then
            local available = math.max(icon_count, top.w - temp_width - icon_count * gap)
            local total = (moon_path and moon_size or 0) + (weather_path and weather_size or 0)
            local shrink = math.min(1, available / math.max(1, total))
            moon_size = math.max(1, math.floor(moon_size * shrink))
            weather_size = math.max(1, math.floor(weather_size * shrink))
        end

        local icon_x = top.x
        self.icons = self.icons or {}

        local function paintIcon(key, path, size)
            if not path then return end
            local alpha, original = true, false
            if key == "weather" and effective and not (override == "day" and real) then
                alpha, original = false, true
            end
            local icon = self.icons[key]
            if not icon or icon.file ~= path or icon.width ~= size
                or icon.alpha ~= alpha or icon.original_in_nightmode ~= original then
                if icon then icon:free() end
                icon = ImageWidget:new{
                    file = path, width = size, height = size, alpha = alpha,
                    original_in_nightmode = original, invert = false,
                }
                self.icons[key] = icon
            end
            local iy = top.y + math.floor((top.h - size) / 2)
            icon:paintTo(bb, icon_x, iy)
            owner._slate_tap_targets[key] = { x = icon_x, y = iy, w = size, h = size }
            icon_x = icon_x + size + gap
        end

        paintIcon("moon", moon_path, moon_size)
        paintIcon("weather", weather_path, weather_size)
        local _, _, temperature_top = cardText(bb, temperature, {
            x = icon_x, y = top.y, w = math.max(1, top.x + top.w - icon_x), h = top.h,
        }, temp_size, foreground, true)
        local weather_section = {
            x = top.x,
            y = math.floor(inner_y),
            w = content_w,
            h = math.max(1, math.ceil(inner_y + inner_h) - math.floor(inner_y)),
        }
        owner._slate_tap_targets.weather_section = weather_section
        owner._slate_tap_targets.weather_group = weather_section

        local condition = data.current.condition
        local description = phase and condition and (phase .. " • " .. condition)
            or phase or condition or ""
        -- Preserve the original single-line layout and normal fitted size.
        -- Only unusually long strings reach the small-font guard/ellipsis.
        local detail_size = getUserSize("slate_weather_widget_detail_size", 23)
        local description_width = cardText(bb, description, rect(weather_x, 0.50, 0.24),
            detail_size, foreground, false, nil, nil, math.max(6, math.floor(detail_size*.4)))
        local location = data.current.location
            or G_reader_settings:readSetting("slate_weather_location") or _("Unknown")
        local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
        local location_rect = rect(weather_x, 0.76, 0.24)
        if description_width and description_width > 0 then
            location_rect.w = math.min(location_rect.w, description_width)
        end
        local _, location_height, location_top, location_bottom = paintLocationBattery(bb, location .. " • " .. clock, location_rect,
            getUserSize("slate_weather_widget_location_size", 22), foreground)
        owner._slate_location_line_top=location_top or (location_bottom and location_bottom-(location_height or 0))
            or location_rect.y+math.floor((location_rect.h-(location_height or location_rect.h))/2)
        owner._slate_tap_targets.weather_details = {
            x = weather_x, y = inner_y + inner_h * 0.5,
            w = content_w, h = inner_h * 0.5,
        }
        local weather_top = temperature_top or top.y + math.max(0, math.floor((top.h - temp_height) / 2))
        labels_y = math.max(inner_y, weather_top)
        weather_bottom = location_bottom or location_rect.y + math.floor(
            (location_rect.h - (location_height or location_rect.h)) / 2)
            + (location_height or location_rect.h)
    else
        -- Prevent stale weather targets/anchors when toggling the block off.
        owner._slate_location_line_top = inner_y + inner_h * .82
    end
    if doc.page_no and doc.page_total then
        local line = bookRect(0.82, 0.18)
        line.h = math.max(1, weather_bottom - line.y)
        cardText(bb, string.format("Page %i of %i", doc.page_no, doc.page_total), line,
            bookSize("slate_weather_widget_progress_font_size", 26), foreground,
            false, nil, "bottom")
        owner._slate_book_tap_targets.page = line
    end
    -- Move the existing title/author block down, retaining its original
    -- measuring height so this spacing change cannot enlarge or shrink fonts.
    -- The progress and page lines stay fixed; their lower gap pays for the inset.
    local title_inset = math.max(0, labels_y - y)
    local labels_rect = {
        x = book_x, y = labels_y + (weather_enabled and 0 or math.floor(title_inset * .6 + .5)),
        w = book_w, title_w = book_label_width,
        h = math.max(1, math.floor(book_labels_bottom - labels_y)),
    }
    owner._slate_book_tap_targets.title_author = labels_rect
    paintBookLabels(self, bb, doc.title or "", doc.authors or "", labels_rect,
        bookSize("slate_weather_widget_title_size", 28),
        bookSize("slate_weather_widget_author_size", 27), foreground)
end

function SlateReading:buildOverlayCard(owner, weather_data, doc_info, screen_width, screen_height)
    local data = weather_data or {}
    data.current = data.current or {}
    SlateUtils:prepareWeatherData(data)
    local doc = doc_info or {}
    owner._slate_book_file = doc.file or G_reader_settings:readSetting("lastfile")
    local width_percent = tonumber(G_reader_settings:readSetting("slate_weather_widget_width_percent")) or 100
    width_percent = math.max(10, math.min(100, width_percent))
    local height_percent = tonumber(G_reader_settings:readSetting("slate_weather_widget_height_percent")) or 50
    height_percent = math.max(10, math.min(100, height_percent))
    local fill = tonumber(G_reader_settings:readSetting("slate_weather_fill_percent")) or 60
    if G_reader_settings:readSetting("slate_weather_override_scaling", true) == false then
        fill = 60
    end
    fill = math.max(10, math.min(100, fill))
    local width = math.min(screen_width,
        math.max(24, math.floor(screen_width * 0.9 * width_percent / 100)))
    local height = math.max(36,
        math.floor(screen_height * 0.5 * height_percent / 100 * fill / 100))
    height = math.min(height, math.floor(screen_height * 0.5))
    return ThreeSectionCard:new{
        owner = owner, data = data, doc = doc, width = width, height = height,
        background_mode = G_reader_settings:readSetting("slate_weather_display_style", "reading"),
    }
end

function SlateReading:rememberCover(file, cover)
    if not cover or type(file) ~= "string" then return end
    local copy = cover:copy()
    if self._last_cover then self._last_cover:free() end
    self._last_cover, self._last_cover_file = copy, file
end

function SlateReading:getLastCover(file)
    if type(file) ~= "string" or file == "" or not util.fileExists(file) then
        return nil
    end
    if self._last_cover and self._last_cover_file == file then
        return self._last_cover:copy()
    end
    local ok, cover = pcall(function()
        return require("apps/filemanager/filemanagerbookinfo"):getCoverImage(nil, file)
    end)
    if not ok then
        logger.warn("Slate: could not load last book cover:", file, cover)
        return nil
    end
    if cover then self:rememberCover(file, cover) end
    return cover
end

function SlateReading:create(slate, weather_data)
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local doc_info = self:getDocumentInfo()
    local active = ReaderUI.instance and ReaderUI.instance.document
    local custom_when_closed = G_reader_settings:readSetting(
        "slate_weather_cover_custom_background_when_no_book", false) == true
    if active then
        if doc_info.cover_bb then
            self:rememberCover(doc_info.file or active.file, doc_info.cover_bb)
        end
    elseif custom_when_closed then
        -- Explicitly discard any cover returned with cached reading information.
        if doc_info.cover_bb then doc_info.cover_bb:free() end
        doc_info.cover_bb = nil
    else
        if doc_info.cover_bb then doc_info.cover_bb:free() end
        doc_info.cover_bb = self:getLastCover(
            doc_info.file or G_reader_settings:readSetting("lastfile"))
    end
    local background_widget
    local background_mode = doc_info.cover_bb and "reading" or "custombg"

    if doc_info.cover_bb then
        local cover_bb = doc_info.cover_bb
        local cover_width = cover_bb:getWidth()
        local cover_height = cover_bb:getHeight()

        local cover_scaling = G_reader_settings:readSetting("slate_weather_cover_scaling") or "stretch_fit"
        local multiplier = getCustomImageScaleMultiplier()

        if cover_scaling == "stretch_fit" then
            cover_bb = RenderImage:scaleBlitBuffer(cover_bb, screen_width, screen_height, true)
        else
            local scale
            if cover_scaling == "fill" or cover_scaling == "stretch" then
                scale = math.max(screen_width / cover_width, screen_height / cover_height) * multiplier
            else
                scale = math.min(screen_width / cover_width, screen_height / cover_height) * multiplier
            end

            local scaled_w = math.floor(cover_width * scale)
            local scaled_h = math.floor(cover_height * scale)

            cover_bb = RenderImage:scaleBlitBuffer(cover_bb, scaled_w, scaled_h, true)
        end

        if cover_scaling == "fit" then
            local cover_image = ImageWidget:new {
                image = cover_bb,
                width = cover_bb:getWidth(),
                height = cover_bb:getHeight(),
                alpha = true,
            }
            local black_bg = FrameContainer:new {
                width = screen_width,
                height = screen_height,
                padding = 0,
                margin = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_BLACK,
                CenterContainer:new {
                    dimen = Geom:new { w = screen_width, h = screen_height },
                    cover_image,
                }
            }
            background_widget = black_bg
        else
            background_widget = CenterContainer:new {
                dimen = Geom:new { w = screen_width, h = screen_height },
                ImageWidget:new {
                    image = cover_bb,
                    width = cover_bb:getWidth(),
                    height = cover_bb:getHeight(),
                    alpha = true,
                }
            }
        end
    else
        background_widget = self:createLetterboxedBackgroundFromFile(
            self:getCustomBgPath(),
            screen_width,
            screen_height
        )
    end

    local card = self:buildOverlayCard(slate, weather_data, doc_info, screen_width, screen_height)
    card.background_mode = background_mode

    local bottom_offset = tonumber(G_reader_settings:readSetting("slate_weather_widget_bottom_offset")) or 115
    if bottom_offset < 0 then bottom_offset = 0 end

    local card_container = BottomContainer:new {
        dimen = Geom:new { w = screen_width, h = screen_height },
        CenterContainer:new {
            dimen = Geom:new { w = screen_width, h = card:getSize().h + math.floor(bottom_offset) },
            card,
        }
    }

    if background_widget then
        return OverlapGroup:new {
            dimen = Screen:getSize(),
            background_widget,
            card_container,
        }
    else
        return OverlapGroup:new {
            dimen = Screen:getSize(),
            FrameContainer:new {
                width = screen_width,
                height = screen_height,
                padding = 0,
                margin = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_GRAY_E,
            },
            card_container,
        }
    end
end

return SlateReading
