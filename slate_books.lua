-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Slate book browser: Recents, Library, and Categories.

local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local SlateUtils = require("slate_utils")
local Device = require("device")
local Screen = Device.screen
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local ImageWidget = require("ui/widget/imagewidget")
local IconWidget = require("ui/widget/iconwidget")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local DocumentRegistry = require("document/documentregistry")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local RenderImage = require("ui/renderimage")
local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local Books = {}
local PREFIX = "slate.books."
local Popup = InputContainer:extend{ modal = true, dithered = true }
local cache_directory
local extraction_failures = {}

local function getCacheDirectory()
    if not cache_directory then
        cache_directory = DataStorage:getDataDir() .. "/cache/slate-book-covers"
        util.makePath(cache_directory)
    end
    return cache_directory
end

local function cacheHash(value)
    local a, b = 5381, 2166136261
    for i = 1, #value do
        a = (a * 65599 + value:byte(i)) % 4294967296
        b = (b * 33 + value:byte(#value - i + 1)) % 4294967296
    end
    return string.format("%08x%08x", a, b)
end

local function customCover(file)
    if type(DocSettings.findCustomCoverFile) ~= "function" then return nil end
    local ok, path = pcall(DocSettings.findCustomCoverFile, DocSettings, file)
    return ok and path or nil
end

local function thumbnailPaths(file)
    local custom = customCover(file)
    local signature = table.concat({ "slate-cover-v2", file,
        tostring(lfs.attributes(file, "modification") or 0),
        tostring(lfs.attributes(file, "size") or 0), tostring(custom or ""),
        tostring(custom and lfs.attributes(custom, "modification") or 0),
        tostring(custom and lfs.attributes(custom, "size") or 0),
    }, "\n")
    local path = getCacheDirectory() .. "/" .. cacheHash(signature)
    return path .. ".png", path .. ".none", path .. ".tmp.png", custom
end

local function pngSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read(24)
    f:close()
    if not header or #header ~= 24 or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    local function number(offset)
        local a, b, c, d = header:byte(offset, offset + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    local w, h = number(17), number(21)
    if w > 0 and h > 0 and w <= 10000 and h <= 10000 then return w, h end
end

local function coverManager()
    local manager = package.loaded.bookinfomanager
    if not manager then
        local ok, loaded = pcall(require, "bookinfomanager")
        if ok then manager = loaded end
    end
    return type(manager) == "table" and manager or nil
end

local function read(key, default)
    return G_reader_settings:readSetting(PREFIX .. key, default)
end

local function integer(value, default, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value then value = default end
    return math.max(minimum, math.min(maximum, math.floor(value)))
end

local function contains(rect, pos)
    return rect and pos and pos.x >= rect.x and pos.x < rect.x + rect.w
        and pos.y >= rect.y and pos.y < rect.y + rect.h
end

local function basename(path)
    return tostring(path):gsub("/+$", ""):match("([^/]+)$") or tostring(path)
end

local function join(directory, name)
    return directory:gsub("/+$", "") .. "/" .. name
end

local function alphabetical(a, b)
    local first, second = a.title:lower(), b.title:lower()
    if first == second then return a.file < b.file end
    return first < second
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

local function textSize(text, size, bold, family, max_width, ink)
    local widget = TextWidget:new{
        text = tostring(text), face = Font:getFace(family or "cfont", size), bold = bold, max_width=max_width,
    }
    local dim = widget:getSize()
    local ink_top,ink_bottom
    if ink then ink_top,ink_bottom=textInkBounds(widget)end
    widget:free()
    return dim.w, dim.h,ink_top,ink_bottom
end

local function drawText(bb, text, rect, size, bold, centered, color, family)
    local widget, dim
    for font_size = size, 6, -1 do
        widget = TextWidget:new{
            text = tostring(text or ""),
            face = Font:getFace(family or "cfont", font_size), bold = bold,
            fgcolor = color or Blitbuffer.COLOR_BLACK,
            max_width = math.max(1, rect.w),
        }
        dim = widget:getSize()
        if dim.w <= rect.w and dim.h <= rect.h or font_size == 6 then break end
        widget:free()
    end
    local x = rect.x + (centered and math.max(0, math.floor((rect.w - dim.w) / 2)) or 0)
    local y = rect.y + math.max(0, math.floor((rect.h - dim.h) / 2))
    widget:paintTo(bb, x, y)
    widget:free()
    return x, math.min(rect.w, dim.w)
end

function Books:getOptions(kind)
    kind = kind == "recents" and "recents" or "library"
    return {
        native = read(kind .. ".native", false) == true,
        columns = integer(read(kind .. ".columns", 4),
            4, 1, 6),
        rows = integer(read(kind .. ".rows", 3), 3, 1, 5),
        rounded = read(kind .. ".rounded", true) ~= false,
        progress = read(kind .. ".progress", kind == "recents") == true,
        category_columns = integer(read("categories.columns", 5), 5, 3, 8),
        category_rows = integer(read("categories.rows", 3), 3, 2, 5),
        category_rounded = read("categories.rounded", true) ~= false,
    }
end

function Books:getDirectory()
    local directory = read("library.directory")
        or G_reader_settings:readSetting("home_dir") or Device.home_dir or "/mnt/us/Books"
    if type(directory) ~= "string" or directory == "" then directory = "/mnt/us/Books" end
    return directory:gsub("/+$", "") == "" and "/" or directory:gsub("/+$", "")
end

local function isBook(file)
    if lfs.attributes(file, "mode") ~= "file" then return false end
    local ok, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, file)
    if not ok or not supported then return false end
    if type(DocumentRegistry.isImageFile) == "function" then
        local checked, image = pcall(DocumentRegistry.isImageFile, DocumentRegistry, file)
        if checked and image then return false end
    end
    return true
end

function Books:getRecents()
    local entries, seen = {}, {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        local file = item.file
        if type(file) == "string" and not seen[file] and isBook(file) then
            seen[file] = true
            entries[#entries + 1] = { file = file, title = basename(file):gsub("%.[^.]+$", "") }
        end
    end
    return entries
end

function Books:scanDirectory(directory, recursive)
    local entries, folders, seen, errors = {}, {}, {}, {}
    local function scan(path, top)
        if seen[path] then return end
        seen[path] = true
        local ok, err = pcall(function()
            for name in lfs.dir(path) do
                if name:sub(1, 1) ~= "." then
                    local file = join(path, name)
                    local mode = lfs.attributes(file, "mode")
                    if mode == "directory" and not name:match("%.sdr$") then
                        local symbolic = type(lfs.symlinkattributes) == "function"
                            and lfs.symlinkattributes(file, "mode") == "link"
                        if not symbolic then
                            if top then folders[#folders + 1] = { file = file, title = name } end
                            if recursive then scan(file, false) end
                        end
                    elseif mode == "file" and isBook(file) then
                        entries[#entries + 1] = { file = file, title = name:gsub("%.[^.]+$", "") }
                    end
                end
            end
        end)
        if not ok then
            errors[#errors + 1] = path
            logger.warn("Slate: could not list book directory:", path, err)
        end
    end
    scan(directory, true)
    table.sort(entries, alphabetical)
    table.sort(folders, alphabetical)
    return entries, folders, errors
end

function Books:getBookDetails(owner, entry)
    local details = { title = entry.title, progress = 0 }
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI.instance
    if reader and reader.document and reader.document.file == entry.file then
        local props = reader.doc_props or {}
        details.title = props.display_title or props.title or details.title
        local state = reader.view and reader.view.state
        local total = reader.doc_settings and tonumber(reader.doc_settings:readSetting("doc_pages"))
        if state and tonumber(state.page) and total and total > 0 then
            details.progress = state.page / total
        elseif reader.doc_settings then
            details.progress = tonumber(reader.doc_settings:readSetting("percent_finished")) or 0
        end
    else
        local success, settings = pcall(DocSettings.open, DocSettings, entry.file)
        if success and settings then
            local props = settings:readSetting("doc_props", {})
            if type(props) == "table" then
                if type(BookInfo.extendProps) == "function" then
                    local ok, extended = pcall(BookInfo.extendProps, props, entry.file)
                    if ok and type(extended) == "table" then props = extended end
                end
                details.title = props.display_title or props.title or details.title
            end
            details.progress = tonumber(settings:readSetting("percent_finished")) or 0
            local summary = settings:readSetting("summary", {})
            if type(summary) == "table" and summary.status == "complete" then
                details.progress = 1
            end
        end
    end
    if details.progress ~= details.progress then details.progress = 0 end
    details.progress = math.max(0, math.min(1, details.progress))
    return details
end

function Books:extractCover(file, manager)
    local target, none, temporary, custom = thumbnailPaths(file)
    local cover
    if manager and not custom and type(manager.getBookInfo) == "function" then
        local ok, info = pcall(manager.getBookInfo, manager, file, true)
        if ok and info then
            cover = info.cover_bb
            if not cover and (info.cover_fetched or info.ignore_cover) then
                local f = io.open(none, "w")
                if f then f:close() end
                return
            end
        end
    end
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local document, opened
    local ok, err = pcall(function()
        if not cover then
            if reader and reader.document and reader.document.file == file then
                document = reader.document
            else
                local initialized, CreDocument = pcall(require, "document/credocument")
                if initialized then
                    local engine = CreDocument:engineInit()
                    local directory = getCacheDirectory() .. "/engine"
                    util.makePath(directory)
                    engine.initCache(directory, 0, true,
                        G_reader_settings:readSetting("cre_storage_size_factor") or 20)
                end
                document = DocumentRegistry:openDocument(file)
                opened = document ~= nil
                if document and document.loadDocument then document:loadDocument(false) end
            end
            if document then cover = BookInfo:getCoverImage(document) end
        end
    end)
    if opened and document then pcall(document.close, document) end
    if not ok then
        if cover and cover.free then cover:free() end
        logger.warn("Slate: could not load book cover:", file, err)
        error(err)
    end
    if not cover then
        local f = io.open(none, "w")
        if f then f:close() end
        return
    end
    local success, failure = pcall(function()
        local scale = math.min(600 / cover:getWidth(), 900 / cover:getHeight(), 1)
        local scaled_w = math.max(1, math.floor(cover:getWidth() * scale))
        local scaled_h = math.max(1, math.floor(cover:getHeight() * scale))
        local scaled = RenderImage:scaleBlitBuffer(cover, scaled_w, scaled_h, false)
        if scaled ~= cover then cover:free() end
        cover = scaled
        local written, reason = cover:writePNG(temporary)
        -- KOReader v2025.10 writePNG succeeds without returning a value.
        -- Validate the output rather than interpreting nil as an error.
        if written == false or not pngSize(temporary) then
            error(reason or "Could not write cached thumbnail")
        end
        local renamed, reason = os.rename(temporary, target)
        if not renamed then error(reason or "Could not save cached thumbnail") end
    end)
    cover:free()
    if not success then
        os.remove(temporary)
        error(failure)
    end
end

function Books:loadCover(file, width, height, stretch)
    local path = thumbnailPaths(file)
    local w, h = pngSize(path)
    if not w then return nil end
    local scale = math.min(width / w, height / h)
    if stretch then w,h=width,height
    else w, h = math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)) end
    local image = ImageWidget:new{
        file = path, file_do_cache = true,
        width = w, height = h, original_in_nightmode = true,
    }
    local ok, err = pcall(image.getSize, image)
    if not ok then
        image:free()
        os.remove(path)
        logger.warn("Slate: could not read cached thumbnail:", err)
        return nil
    end
    return image, w, h
end

function Books:installOpeningGuard()
    local ok, Highlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or type(Highlight.onTap) ~= "function" or Highlight._slate_original_onTap then return end
    Highlight._slate_original_onTap = Highlight.onTap
    function Highlight:onTap(arg, ges)
        local highlight = self.view and self.view.highlight
        if ges and not self.hold_pos and (not highlight or type(highlight.visible_boxes) ~= "table") then
            return true
        end
        return Highlight._slate_original_onTap(self, arg, ges)
    end
end

function Books:openBook(owner, entry)
    if owner._slate_books_opening then return end
    if not entry or not isBook(entry.file) then
        UIManager:show(InfoMessage:new{ text = _("This book is no longer available.") })
        return
    end
    self:installOpeningGuard()
    owner._slate_books_opening = true
    self:close(owner)
    local screen = owner._slate_screen
    if screen then ScreenSaverWidget.onClose(screen) end
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            local ReaderUI = require("apps/reader/readerui")
            local reader = ReaderUI.instance
            if type(owner.closeHistoryMenu) == "function" then
                owner:closeHistoryMenu(reader)
                owner:closeHistoryMenu(require("apps/filemanager/filemanager").instance)
            end
            if type(owner.closeLibraryOverlays) == "function" then
                owner:closeLibraryOverlays(reader, require("apps/filemanager/filemanager").instance)
            end
            if not reader or not reader.document or reader.document.file ~= entry.file then
                ReaderUI:showReader(entry.file)
            end
        end)
        owner._slate_books_opening = nil
        if not ok then
            logger.warn("Slate: could not open book:", entry.file, err)
            UIManager:show(InfoMessage:new{ text = _("Could not open this book.") })
        end
    end)
end

function Popup:init()
    self.dimen = Screen:getSize()
    self.options = Books:getOptions(self.kind)
    self.root = Books:getDirectory()
    self.page, self.category_pages = 1, {}
    self.assets, self.details = {}, {}
    self.generation = 0
    self.closed = false
    self.view = read(self.kind .. ".view", self.kind == "recents" and "recents" or "library")
    if self.kind == "recents" then
        if self.view ~= "progress" then self.view = "recents" end
    elseif self.view ~= "categories" then self.view = "library" end
    if self.description_mode or self.metadata_mode then self.view = "library" end
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.box = {
        w = math.min(math.floor(w * 0.96), Screen:scaleBySize(900)),
        h = math.floor(h * 0.80),
    }
    self.box.x = math.floor((w - self.box.w) / 2)
    local slate_screen = self.owner and self.owner._slate_screen
    local lock = slate_screen and slate_screen.lock_button
    local top = lock and (lock.y + math.floor(lock.h * (self.kind=="library" and 0.55 or 0.65))) or Screen:scaleBySize(90)
    local edge = math.max(8, Screen:scaleBySize(10))
    self.box.y = math.max(edge, math.min(math.floor(top), h - edge - 1))
    self.box.h = math.max(1, math.min(self.box.h, h - self.box.y - edge))
    if self.owner and self.owner._slate_location_line_top then
        self.box.y=math.max(edge,math.floor(self.owner._slate_location_line_top)-Screen:scaleBySize(4)-self.box.h)
    end
    self.padding_base_h = self.box.h
    self.pad = math.max(10, math.floor(self.box.w * 0.035))
    self.bottom_pad = math.max(10, math.floor(math.min(
        math.floor(w * 0.96), Screen:scaleBySize(900)) * 0.045))
    self.gap = math.max(6, Screen:scaleBySize(7))
    self.header_icon_size = math.max(16,math.min(200,
        tonumber(G_reader_settings:readSetting("slate.popup_header_icon_size",72)) or 72))
    self.title_h = math.max(30, Screen:scaleBySize(44))
    if G_reader_settings:readSetting("slate.popup_header_icons",true)==true then
        self.title_h=math.max(self.title_h,self.header_icon_size)
    end
    self.title_gap = math.max(8, Screen:scaleBySize(14))
    self.button_h = math.max(30, Screen:scaleBySize(38))
    self.pager_h = math.max(52, Screen:scaleBySize(60))
    self.pager_gap = self.kind == "library" and self.gap * 2 or self.gap
    self.font_size = 18
    self.content = {
        x = self.box.x + self.pad,
        y = self.box.y + self.pad + self.title_h + self.title_gap,
        w = self.box.w - self.pad * 2,
    }
    self.content.h = self.box.h - self.pad - self.bottom_pad - self.title_h - self.title_gap
        - self.pager_h - self.pager_gap
        - self.button_h - self.pager_gap
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = w, h = h } } },
        Swipe = { GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = w, h = h } } },
        Hold = { GestureRange:new{ ges = "hold", range = Geom:new{ x = 0, y = 0, w = w, h = h } } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = Geom:new{ x = 0, y = 0, w = w, h = h } } },
    }
    if Device:hasKeys() then self.key_events = { Back = { { "Back" } } } end
    if self.kind == "recents" then
        self.entries = Books:getRecents()
        self.folders = {}
    else
        self.entries, self.folders, self.scan_errors = Books:scanDirectory(self.root, true)
    end
    if self.description_mode then
        self.entries = require("slate_book_descriptions"):missingBooks()
        self.folders = {}
    end
    self:rebuild()
end

function Popup:clearAssets()
    self.generation = self.generation + 1
    self:cancelCoverLoad()
    self:stopExtraction()
    for _, asset in pairs(self.assets or {}) do
        if asset.image then asset.image:free() end
    end
    self.assets = {}
end

function Popup:coverRect(cell, progress, aspect)
    local progress_h = progress and math.max(20, Screen:scaleBySize(19)) or 0
    local available_h = math.max(1, cell.h - progress_h - (progress and self.gap or 0))
    aspect = aspect or 0.69
    local width = math.max(1, math.min(cell.w, math.floor(available_h * aspect)))
    local height = math.max(1, math.min(available_h, math.floor(width / aspect)))
    return {
        x = cell.x + math.floor((cell.w - width) / 2),
        y = cell.y + math.floor((available_h - height) / 2),
        w = width, h = height,
    }, progress_h
end

function Popup:addTile(entry, rect, progress, rounded, aspect)
    local cover = self:coverRect(rect, progress, aspect)
    self.tiles[#self.tiles + 1] = {
        entry = entry, rect = rect, cover = cover,
        progress = progress, rounded = rounded,
    }
end

function Popup:rebuild()
    self.padding_base_h=self.padding_base_h or self.box.h
    self.box.h=self.folder and self.folder_window_h or self.padding_base_h
    self.padding_base_y=self.padding_base_y or self.box.y
    local reset_y=self.padding_base_y-self.box.y
    self.box.y=self.padding_base_y
    self.content.y=self.content.y+reset_y
    self.generation = self.generation + 1
    self:cancelCoverLoad()
    self.tiles, self.category_headers = {}, {}
    self.pages = 1
    local c, o = self.content, self.options
    local row_gap = math.max(self.gap, math.floor(c.w * 0.035))
    self.cover_row_gap = row_gap
    local footer_gap = self.view == "progress" and self.pager_gap or row_gap
    c.h = self.box.h - self.pad - self.bottom_pad - self.title_h - self.title_gap
        - self.button_h - footer_gap
    if self.view == "progress" then
        c.h = c.h - self.pager_h - self.pager_gap
    end
    self.folder_title_rect = nil
    if self.view == "progress" then
        self.title_x = c.x
        self:loadReadingProgress()
        return
    end

    local categories = self.view == "categories" and not self.folder
    local columns = categories and o.category_columns or o.columns
    local limit = categories and o.category_rows or o.rows
    local tile_w = math.floor((c.w - self.gap * (columns - 1)) / columns)
    local title_h = math.max(24, Screen:scaleBySize(27))
    if categories or self.folder then
        local _, heading_h = textSize("Ag", self.font_size, true)
        title_h = heading_h + 8
    end
    local title_space = (categories or self.folder) and title_h + self.gap or 0
    local progress = not categories and o.progress
    local progress_space = progress and math.max(20, Screen:scaleBySize(19)) + self.gap or 0
    local groups = {}
    if categories then
        self.pages = math.max(1, math.ceil(#self.folders / limit))
        self.page = math.max(1, math.min(self.page, self.pages))
        local first = (self.page - 1) * limit + 1
        for index = 0, limit - 1 do
            local folder = self.folders[first + index]
            if not folder then break end
            if not folder.books then folder.books = Books:scanDirectory(folder.file, true) end
            local pages = math.max(1, math.ceil(#folder.books / columns))
            local page = math.max(1, math.min(self.category_pages[folder.file] or 1, pages))
            self.category_pages[folder.file] = page
            local group = {entries = {}, folder = folder, pages = pages, page = page}
            local start = (page - 1) * columns + 1
            for column = 0, columns - 1 do
                if folder.books[start + column] then
                    group.entries[#group.entries + 1] = folder.books[start + column]
                end
            end
            groups[#groups + 1] = group
        end
    else
        local entries = self.folder and self.folder.books or self.entries
        local capacity = columns * limit
        self.pages = math.max(1, math.ceil(#entries / capacity))
        self.page = math.max(1, math.min(self.page, self.pages))
        local first = (self.page - 1) * capacity + 1
        local count = math.min(capacity, math.max(0, #entries - first + 1))
        for index = 0, math.ceil(count / columns) - 1 do
            local group = {entries = {}}
            for column = 0, columns - 1 do
                local entry = entries[first + index * columns + column]
                if entry then group.entries[#group.entries + 1] = entry end
            end
            groups[#groups + 1] = group
        end
    end

    local header_bottom = self.box.y + self.pad + self.title_h
    if G_reader_settings:readSetting("slate.popup_header_text", true) == true then
        local label = self.kind == "recents" and _("HISTORY") or _("LIBRARY")
        local _, height = textSize(label, self.font_size + 2, true)
        header_bottom = self.box.y + self.pad + math.floor((self.title_h - height) / 2) + height
    end
    local button_y = self.box.y + self.box.h - self.bottom_pad - self.button_h
    -- Reserve all configured folder slots, including empty trailing rows.
    local visible_groups = #groups
    if categories then
        for row = visible_groups + 1, limit do
            groups[row] = {entries = {}}
        end
    end
    local rows = limit
    local minimum_gap = math.max(self.gap,
        self.box.y + self.pad + self.title_h + self.title_gap - header_bottom
    )
    local available = math.max(1, button_y - header_bottom)
    local gap_slots = categories and rows * 2 + 1 or rows + 1
    local heading_space = categories and rows * title_h or 0
    local heading_inset = categories and 4 or 0
    local budget = math.max(rows, available - minimum_gap * gap_slots
        - progress_space * rows - heading_space - heading_inset
        - (not categories and title_space or 0))
    local total_cap, largest_cap = 0, 1
    for _, group in ipairs(groups) do
        group.aspects = {}
        group.cap = categories and 1 or tile_w / 0.80
        for index, entry in ipairs(group.entries) do
            local path = thumbnailPaths(entry.file)
            local width, height = pngSize(path)
            local aspect = width and height and width / height or 0.69
            group.aspects[index] = aspect
            -- Landscape covers fit inside the same row; they must not shrink
            -- adjacent portrait covers or enlarge the next, partially full row.
            if categories and aspect <= 1 then
                group.cap = math.max(group.cap, tile_w / aspect)
            end
        end
        if categories and group.cap == 1 then group.cap = tile_w / 0.69 end
        total_cap = total_cap + group.cap
        largest_cap = math.max(largest_cap, group.cap)
    end
    local low, high = 1, largest_cap
    if not categories then
        local height = math.max(1, math.floor(math.min(tile_w / 0.80, budget / rows)))
        low, high = height, height
    elseif total_cap > budget then
        for step = 1, 24 do
            local level, total = (low + high) / 2, 0
            for _, group in ipairs(groups) do total = total + math.min(group.cap, level) end
            if total > budget then high = level else low = level end
        end
    else low, high = largest_cap, largest_cap end
    local used = 0
    for _, group in ipairs(groups) do
        group.height = math.max(1, math.floor(math.min(group.cap, (low + high) / 2)))
        used = used + group.height + progress_space
    end
    local reserved_used = not categories and (low + progress_space) * rows or used
    local gap = math.max(self.gap, (available - reserved_used - heading_space - heading_inset
        - (not categories and title_space or 0)) / gap_slots)
    local title_cover_gap = gap
    local footer_gap = gap + heading_inset
    local first_row_gap = gap + (not categories and title_space or 0)
    if categories then
        title_cover_gap = self.gap
        -- Anchor the first folder to the same grid start as Entire Library.
        -- Category cover aspect ratios must not push this heading down.
        local grid_rows = o.rows
        local grid_w = math.floor((c.w - self.gap * (o.columns - 1)) / o.columns)
        local grid_progress = o.progress and math.max(20, Screen:scaleBySize(19)) + self.gap or 0
        local grid_budget = math.max(grid_rows, available - minimum_gap * (grid_rows + 1)
            - grid_progress * grid_rows)
        local grid_height = math.max(1, math.floor(math.min(grid_w / 0.80, grid_budget / grid_rows)))
        first_row_gap = math.max(self.gap,
            (available - (grid_height + grid_progress) * grid_rows) / (grid_rows + 1))
            - heading_inset
        first_row_gap = math.max(0, first_row_gap - math.floor(title_h * 0.55))
        -- Keep padding fixed. Spare height belongs to the covers, rather than
        -- being divided into increasingly large spaces around every folder.
        footer_gap = row_gap
        gap = math.max(self.gap, footer_gap - heading_inset)
        local new_budget = math.max(rows, available - heading_space
            - title_cover_gap * rows - footer_gap - first_row_gap - gap * (rows - 1)
            - progress_space * rows)
        local low, high = 1, largest_cap
        if total_cap > new_budget then
            for step = 1, 24 do
                local level, total = (low + high) / 2, 0
                for _, group in ipairs(groups) do total = total + math.min(group.cap, level) end
                if total > new_budget then high = level else low = level end
            end
        else low, high = largest_cap, largest_cap end
        used = 0
        for _, group in ipairs(groups) do
            group.height = math.max(1, math.floor(math.min(group.cap, (low + high) / 2)))
            used = used + group.height + progress_space
        end
        -- Keep folders stacked with fixed gaps; spare height belongs below them.
        local spare = math.max(0, available - used - heading_space
            - title_cover_gap * rows - footer_gap - first_row_gap - gap * (rows - 1))
        footer_gap = footer_gap + spare
    end
    if self.kind=="library" and categories and visible_groups>0 then
        local previous_top,previous_bottom=first_row_gap,footer_gap
        local margin=math.ceil(previous_bottom*2)
        local edge=math.max(8,Screen:scaleBySize(10))
        local desired=math.max(0,margin*2-previous_top-previous_bottom)
        local extra=math.max(0,math.min(math.ceil(desired),Screen:getHeight()-edge-self.box.y-self.box.h))
        self.box.h=self.box.h+extra
        button_y=button_y+extra
        available=available+extra
        local heading_gaps=categories and title_cover_gap*rows or 0
        local required=heading_space+heading_gaps+gap*(rows-1)+progress_space*rows
        margin=math.min(margin,math.max(self.gap,(available-required-rows*20)/2))
        first_row_gap,footer_gap=margin,margin
        local room=math.max(rows,available-margin*2-required)
        local low,high=1,largest_cap
        for step=1,24 do
            local level,total=(low+high)/2,0
            for _,group in ipairs(groups) do total=total+math.min(group.cap,level) end
            if total>room then high=level else low=level end
        end
        local used_height=0
        for _,group in ipairs(groups) do
            group.height=math.max(1,math.floor(math.min(group.cap,low)))
            used_height=used_height+group.height
        end
        local remainder=math.max(0,math.floor(room)-used_height)
        for _,group in ipairs(groups) do
            if remainder>0 and group.height<math.ceil(group.cap) then
                group.height=group.height+1;remainder=remainder-1
            end
        end
    end
    if self.kind=="library" and categories and visible_groups>0 then
        -- Trim the visible outer gaps, including short final category pages.
        local block=gap*math.max(0,visible_groups-1)
        for index=1,visible_groups do
            block=block+groups[index].height+progress_space+title_h+title_cover_gap
        end
        local bottom_gap=math.max(0,available-first_row_gap-block)
        local top_trim=math.floor(first_row_gap*.20+.5)
        local bottom_trim=math.floor(bottom_gap*.10+.5)
        local trim=top_trim+bottom_trim
        first_row_gap=first_row_gap-top_trim
        footer_gap=bottom_gap-bottom_trim
        self.box.h=self.box.h-trim
        button_y=button_y-trim;available=available-trim
        -- The category pager is one window. A short final page must retain
        -- its established outer geometry instead of drawing a smaller frame
        -- over the previous page. Recompute only when layout options change.
        local key=table.concat({self.padding_base_h,self.box.w,rows,columns,
            self.pad,self.bottom_pad,self.title_h,self.title_gap,self.button_h,
            self.gap,Screen:getHeight()},":")
        if self.category_frame_key~=key then
            self.category_frame_key=key
            self.category_frame_h=self.box.h
        end
        local delta=self.category_frame_h-self.box.h
        self.box.h=self.category_frame_h
        button_y=button_y+delta;available=available+delta
        footer_gap=math.max(0,available-first_row_gap-block)
        if delta<0 and first_row_gap+block>available then
            local fixed=gap*math.max(0,visible_groups-1)
                +(progress_space+title_h+title_cover_gap)*visible_groups
            local total=block-fixed
            local room=math.max(visible_groups,available-first_row_gap-fixed-self.gap)
            local factor=math.min(1,room/math.max(1,total))
            block=fixed
            for i=1,visible_groups do
                groups[i].height=math.max(1,math.floor(groups[i].height*factor))
                block=block+groups[i].height
            end
            footer_gap=math.max(0,available-first_row_gap-block)
        end
    end
    if self.kind=="library" and not categories then
        if not self.folder then
            -- Measure Categories without loading any images or modifying this view.
            local reference=setmetatable({}, {__index=self})
            reference.box={x=self.box.x,y=self.box.y,w=self.box.w,h=self.padding_base_h}
            reference.content={x=c.x,y=c.y,w=c.w,h=c.h}
            reference.assets={};reference.category_pages={}
            reference.view="categories";reference.page=1
            reference.cancelCoverLoad=function()end
            reference.loadVisibleCovers=function()end
            reference.addTile=function()end
            reference:rebuild()
            local extra=reference.box.h-self.box.h
            self.box.h=reference.box.h;button_y=button_y+extra;available=available+extra
        end
        -- Center the actual rows, including a short final page, as one block.
        local block=0
        for _,group in ipairs(groups) do block=block+group.height+progress_space end
        block=block+gap*math.max(0,visible_groups-1)+(self.folder and title_space or 0)
        first_row_gap=math.max(0,(available-block)/2)+(self.folder and title_space or 0)
        footer_gap=first_row_gap-(self.folder and title_space or 0)
    end
    -- Empty slots participate in sizing but have no headers or covers.
    for row = #groups, visible_groups + 1, -1 do groups[row] = nil end
    self.cover_row_gap = gap
    self.cover_layout = {header_bottom = header_bottom, button_y = button_y,
        gap = gap, rows = #groups, categories = categories, heading_inset = heading_inset,
        title_cover_gap = title_cover_gap, footer_gap = footer_gap, first_row_gap = first_row_gap}
    local y = header_bottom + first_row_gap
    for row, group in ipairs(groups) do
        local cover_y = math.floor(y + (categories and title_h + title_cover_gap or 0) + 0.5)
        if categories then
            local header_y = math.floor(y + 0.5)
            local arrow_w = title_h
            self.category_headers[#self.category_headers + 1] = {
                folder = group.folder, pages = group.pages, page = group.page,
                rect = {x = c.x, y = header_y, w = c.w - arrow_w * 2 - self.gap * 2, h = title_h},
                previous = {x = c.x + c.w - arrow_w * 2 - self.gap, y = header_y, w = arrow_w, h = title_h},
                next = {x = c.x + c.w - arrow_w, y = header_y, w = arrow_w, h = title_h},
                body = {x = c.x, y = cover_y, w = c.w, h = group.height},
            }
        elseif self.folder and row == 1 then
            self.folder_title_rect = {x = c.x, y = cover_y - title_space, w = c.w, h = title_h}
        end
        for index, entry in ipairs(group.entries) do
            self:addTile(entry, {
                x = c.x + (index - 1) * (tile_w + self.gap), y = cover_y,
                w = tile_w, h = group.height + progress_space,
            }, progress, categories and o.category_rounded or o.rounded, group.aspects[index])
        end
        y = y + group.height + progress_space + gap
            + (categories and title_h + title_cover_gap or 0)
    end
    if self.folder_title_rect and #self.tiles>0 then
        -- Center the visible heading and covers, rather than reserved row cells.
        local heading=self.folder_title_rect
        local heading_h=heading.h
        local heading_ink_top=0
        for size=self.font_size,6,-1 do
            local width,height,ink_top=textSize(self.folder.title,size,true,nil,heading.w,true)
            heading_h=height;heading_ink_top=ink_top or 0
            if (width<=heading.w and height<=heading.h) or size==6 then break end
        end
        local visible_top=heading.y+math.max(0,math.floor((heading.h-heading_h)/2))+heading_ink_top
        local visible_bottom=visible_top+heading_h
        for _,tile in ipairs(self.tiles)do
            local bottom=tile.cover.y+tile.cover.h
            if tile.progress then
                local line_h=math.max(20,Screen:scaleBySize(19))
                local label_h,ink_bottom=line_h,line_h
                for size=11,1,-1 do
                    local width,height,_,ink=textSize("100%",size,false,nil,nil,true)
                    if width+2<=tile.cover.w*.55 and height<=line_h then label_h,ink_bottom=height,ink or height;break end
                end
                local bar_h=math.max(2,Screen:scaleBySize(3))
                bottom=bottom+self.gap+math.max(math.floor((line_h-label_h)/2)+ink_bottom,math.floor((line_h-bar_h)/2)+bar_h)
            end
            visible_bottom=math.max(visible_bottom,bottom)
        end
        local visible_header_bottom=header_bottom
        if G_reader_settings:readSetting("slate.popup_header_text",true)==true then
            local _,height,_,ink_bottom=textSize(_("LIBRARY"),self.font_size+2,true,nil,nil,true)
            visible_header_bottom=self.box.y+self.pad+math.floor((self.title_h-height)/2)+(ink_bottom or height)
        end
        local dy=math.floor(visible_header_bottom+(button_y-visible_header_bottom-(visible_bottom-visible_top))/2-visible_top+.5)
        self.cover_layout.header_bottom=visible_header_bottom
        heading.y=heading.y+dy
        local moved={}
        for _,tile in ipairs(self.tiles)do
            for _,rect in ipairs({tile.rect,tile.cover})do
                if not moved[rect]then rect.y=rect.y+dy;moved[rect]=true end
            end
        end
        first_row_gap=first_row_gap+dy
        footer_gap=button_y-visible_bottom-dy
        self.cover_layout.first_row_gap=first_row_gap
        self.cover_layout.footer_gap=footer_gap
    end
    c.h = math.max(1, math.ceil(button_y - c.y - footer_gap))
    self.title_x = c.x
    local visible = {}
    for _, tile in ipairs(self.tiles) do
        visible[tile.entry.file] = true
        local asset = self.assets[tile.entry.file]
        if asset and (asset.requested_w ~= tile.cover.w or asset.requested_h ~= tile.cover.h) then
            if asset.image then asset.image:free() end
            self.assets[tile.entry.file] = nil
        end
    end
    for file, asset in pairs(self.assets) do
        if not visible[file] then
            if asset.image then asset.image:free() end
            self.assets[file] = nil
        end
    end
    if self.kind=="library" or self.kind=="recents" then
        local h=Screen:getHeight()
        local edge=math.max(8,Screen:scaleBySize(10))
        local screen=self.owner and self.owner._slate_screen
        local lock=screen and screen.lock_button
        local recents_top=lock and lock.y+math.floor(lock.h*.65) or Screen:scaleBySize(90)
        recents_top=math.max(edge,math.min(recents_top,h-edge-1))
        local recents_bottom=recents_top+math.min(math.floor(h*.80),h-recents_top-edge)
        local location_top=self.owner and self.owner._slate_location_line_top
        local target_bottom=location_top and math.min(h-edge,math.floor(location_top)-Screen:scaleBySize(4)) or recents_bottom
        local target_y=math.max(edge,target_bottom-self.box.h)
        local dy=target_y-self.box.y
        self.box.y=target_y
        local shifted={}
        local function shift(rect)
            if rect and not shifted[rect] then rect.y=rect.y+dy;shifted[rect]=true end
        end
        shift(c);shift(self.folder_title_rect)
        for _,tile in ipairs(self.tiles)do shift(tile.rect);shift(tile.cover)end
        for _,header in ipairs(self.category_headers)do
            shift(header.rect);shift(header.previous);shift(header.next);shift(header.body)
        end
        self.cover_layout.header_bottom=self.cover_layout.header_bottom+dy
        self.cover_layout.button_y=self.cover_layout.button_y+dy
    end
    self:loadVisibleCovers()
end

function Popup:cancelCoverLoad()
    if self._cover_task then UIManager:unschedule(self._cover_task) end
    self._cover_task = nil
end

local function reapJob(job)
    if FFIUtil.isSubProcessDone(job.pid) then
        if job.prevented then UIManager:allowStandby(); job.prevented = false end
        os.remove(job.temporary)
        return
    end
    UIManager:scheduleIn(0.15, function() reapJob(job) end)
end

function Popup:stopExtraction()
    if self._cover_poll then UIManager:unschedule(self._cover_poll) end
    self._cover_poll = nil
    local job = self._cover_job
    self._cover_job = nil
    if job then
        FFIUtil.terminateSubProcess(job.pid)
        reapJob(job)
    end
end

function Popup:startExtraction()
    if self.closed or self._cover_job then return end
    if type(FFIUtil.runInSubProcess) ~= "function" then
        if not self._extraction_unavailable then
            self._extraction_unavailable = true
            logger.warn("Slate: background thumbnail extraction is unavailable")
        end
        return
    end
    local request
    for _, tile in ipairs(self.tiles) do
        local path, none, temporary = thumbnailPaths(tile.entry.file)
        if not pngSize(path) and not util.fileExists(none)
            and os.time() >= (extraction_failures[path] or 0) then
            request = { file = tile.entry.file, path = path, temporary = temporary }
            break
        end
    end
    if not request then return end
    local manager = coverManager()
    if manager and type(manager.closeDbConnection) == "function" then
        pcall(manager.closeDbConnection, manager)
    end
    local ok, pid = pcall(FFIUtil.runInSubProcess, function()
        local success, err = pcall(Books.extractCover, Books, request.file, manager)
        if not success then logger.warn("Slate: background cover extraction failed:", request.file, err) end
    end)
    if not ok or not pid then
        extraction_failures[request.path] = os.time() + 300
        logger.warn("Slate: could not start thumbnail worker")
        return
    end
    request.pid, request.started = pid, os.time()
    if type(UIManager.preventStandby) == "function" then
        UIManager:preventStandby()
        request.prevented = true
    end
    self._cover_job = request
    local function poll()
        self._cover_poll = nil
        if self.closed or self._cover_job ~= request then return end
        if FFIUtil.isSubProcessDone(pid) then
            self._cover_job = nil
            if request.prevented then UIManager:allowStandby(); request.prevented = false end
            local path, none = thumbnailPaths(request.file)
            if not pngSize(path) and not util.fileExists(none) then
                extraction_failures[path] = os.time() + 300
            end
            os.remove(request.temporary)
            self:cancelCoverLoad()
            self:rebuild()
        elseif os.time() - request.started >= 45 then
            extraction_failures[request.path] = os.time() + 300
            logger.warn("Slate: thumbnail worker timed out:", request.file)
            self:stopExtraction()
            self:startExtraction()
        else
            self._cover_poll = poll
            UIManager:scheduleIn(0.15, poll)
        end
    end
    self._cover_poll = poll
    UIManager:scheduleIn(0.15, poll)
end

function Popup:loadVisibleCovers()
    self:cancelCoverLoad()
    local generation = self.generation
    local seen, changed = {}, false
    -- Cached PNGs are cheap to read and must be ready for the first page paint.
    -- Document opening and cover extraction remain exclusively in the worker.
    for _, tile in ipairs(self.tiles) do
        local file = tile.entry.file
        if not seen[file] then
            seen[file] = true
            local previous_details = self.details[file]
            local success, details = pcall(Books.getBookDetails, Books, self.owner, tile.entry)
            self.details[file] = success and details or { title = tile.entry.title, progress = 0 }
            if previous_details and (
                previous_details.title ~= self.details[file].title
                or previous_details.progress ~= self.details[file].progress) then
                changed = true
            end
            local asset = self.assets[file]
            local path = thumbnailPaths(file)
            if not asset or not asset.image or asset.path ~= path then
                local ok, image, w, h = pcall(Books.loadCover, Books, file, tile.cover.w, tile.cover.h)
                if asset and asset.image then asset.image:free(); changed = true end
                self.assets[file] = { image = ok and image or nil, w = w, h = h,
                    path = path, requested_w = tile.cover.w, requested_h = tile.cover.h }
                if not ok then logger.warn("Slate: cover thumbnail failed:", file, image) end
                if ok and image then changed = true end
            end
        end
    end
    if changed then UIManager:setDirty(self, "ui") end
    local function extractMissing()
        self._cover_task = nil
        if self.closed or generation ~= self.generation then return end
        self:startExtraction()
    end
    self._cover_task = extractMissing
    UIManager:scheduleIn(0.02, extractMissing)
end

local function maskCorners(bb, r, radius)
    radius = math.min(radius, math.floor(math.min(r.w, r.h) / 2))
    for y = 0, radius - 1 do
        local dy = radius - y - 0.5
        local inset = math.max(0, math.ceil(radius - math.sqrt(radius * radius - dy * dy)))
        if inset > 0 then
            bb:paintRect(r.x, r.y + y, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(r.x + r.w - inset, r.y + y, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(r.x, r.y + r.h - y - 1, inset, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(r.x + r.w - inset, r.y + r.h - y - 1, inset, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

function Popup:paintPlaceholder(bb, tile, title)
    local r = tile.cover
    if self.view ~= "categories" then
        bb:paintBorder(r.x, r.y, r.w, r.h, 1, Blitbuffer.COLOR_LIGHT_GRAY,
            tile.rounded and math.max(2, Screen:scaleBySize(4)) or 0)
    end
    local inset = math.max(4, math.floor(r.w * 0.06))
    local words, line, lines = {}, "", {}
    for word in tostring(title):gmatch("%S+") do words[#words + 1] = word end
    local size = math.max(8, math.min(16, math.floor(r.w / 8)))
    for _, word in ipairs(words) do
        local candidate = line == "" and word or line .. " " .. word
        if textSize(candidate, size) > r.w - inset * 2 and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else line = candidate end
    end
    if line ~= "" then lines[#lines + 1] = line end
    local line_h = math.max(12, Screen:scaleBySize(size + 3))
    local limit = math.max(1, math.min(5, math.floor((r.h - inset * 2) / line_h)))
    local count = math.min(limit, #lines)
    local y = r.y + math.floor((r.h - count * line_h) / 2)
    for i = 1, count do
        local label = lines[i]
        if i == count and #lines > count then label = label .. "…" end
        drawText(bb, label, { x = r.x + inset, y = y, w = r.w - inset * 2, h = line_h }, size, false, true)
        y = y + line_h
    end
end

function Popup:paintTile(bb, tile)
    local asset = self.assets[tile.entry.file]
    local details = self.details[tile.entry.file]
        or { title = tile.entry.title, progress = 0 }
    local r = tile.cover
    if asset and asset.image then
        local image_rect = {
            x = r.x + math.floor((r.w - asset.w) / 2),
            y = r.y + math.floor((r.h - asset.h) / 2), w = asset.w, h = asset.h,
        }
        local ok, err = pcall(asset.image.paintTo, asset.image, bb, image_rect.x, image_rect.y)
        if ok then
            if tile.rounded then maskCorners(bb, image_rect, math.max(2, Screen:scaleBySize(4))) end
        else
            logger.warn("Slate: could not paint cover:", tile.entry.file, err)
            self:paintPlaceholder(bb, tile, details.title)
        end
    else
        self:paintPlaceholder(bb, tile, details.title)
    end
    if tile.progress then
        local line_h = math.max(20, Screen:scaleBySize(19))
        local label = tostring(math.floor(details.progress * 100 + 0.5)) .. "%"
        local shown_w = asset and asset.image and asset.w or r.w
        local line = { x = r.x + math.floor((r.w - shown_w) / 2),
            y = r.y + r.h + self.gap, w = shown_w, h = line_h }
        local gap = math.max(2, math.min(Screen:scaleBySize(4), math.floor(line.w * 0.08)))
        local font_size = 11
        local percentage_w
        for candidate = 11, 1, -1 do
            local width, height = textSize("100%", candidate)
            if width + 2 <= line.w * 0.55 and height <= line_h then
                font_size, percentage_w = candidate, math.ceil(width) + 2
                break
            end
        end
        percentage_w = percentage_w or math.max(1, math.floor(line.w * 0.55))
        local bar_w = math.max(1, line.w - percentage_w - gap)
        local bar_h = math.max(2, Screen:scaleBySize(3))
        bb:paintRect(line.x, line.y + math.floor((line_h - bar_h) / 2), bar_w, bar_h, Blitbuffer.COLOR_LIGHT_GRAY)
        local filled = math.floor(bar_w * details.progress)
        if filled > 0 then bb:paintRect(line.x, line.y + math.floor((line_h - bar_h) / 2), filled, bar_h, Blitbuffer.COLOR_BLACK) end
        drawText(bb, label, { x = line.x + bar_w + gap, y = line.y,
            w = percentage_w, h = line_h }, font_size, false, true)

    end
end

local function durationLabel(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

local function dateStamp(text)
    local y, m, d = tostring(text or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    local stamp = os.time{year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=0,min=0,sec=0}
    return stamp and os.date("%Y-%m-%d",stamp)==text and stamp or nil
end

function Books:getReadingProgress(mode, from_date, to_date)
    mode = mode or "week"
    local now = os.time()
    local first = os.date("*t", now)
    first.hour, first.min, first.sec, first.isdst = 0,0,0,nil
    local title, finish = _("LAST SEVEN DAYS"), now
    if mode == "months" then
        first.month, first.day = first.month-11,1
        title = _("MONTHS — LAST TWELVE MONTHS")
    elseif mode == "history" then
        title = _("ENTIRE HISTORY")
    elseif mode == "custom" then
        local start, last = dateStamp(from_date), dateStamp(to_date)
        if not start or not last or start>last then return nil, _("Enter a valid date range.") end
        if last>now then return nil, _("The end date must not be in the future.") end
        first = os.date("*t", start)
        local ending = os.date("*t",last)
        ending.day, ending.isdst = ending.day+1,nil
        finish = math.min(now,os.time(ending)-1)
        title = from_date .. " — " .. to_date
    else
        first.day = first.day-6
    end
    local start = os.time(first)
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if not util.fileExists(path) then return nil, _("No reading statistics database found.") end
    local connection
    local ok, result = pcall(function()
        connection = require("lua-ljsqlite3/init").open(path)
        connection:exec("PRAGMA query_only = ON;")
        if mode == "history" then
            local earliest = connection:exec("SELECT min(start_time) FROM page_stat WHERE start_time > 0;")
            local timestamp = earliest and earliest[1] and tonumber(earliest[1][1])
            if timestamp and timestamp <= now then
                local day = os.date("*t", timestamp)
                day.hour,day.min,day.sec,day.isdst=0,0,0,nil
                start=os.time(day)
            end
        end
        local rows = connection:exec(string.format([[
            SELECT dates, count(*) AS pages, sum(sum_duration) AS durations
            FROM (
                SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates,
                       sum(duration) AS sum_duration
                FROM page_stat
                WHERE start_time >= %d AND start_time <= %d
                GROUP BY id_book, page, dates
            ) GROUP BY dates ORDER BY dates;
        ]],start,finish))
        local daily = {}
        for i,date in ipairs(rows and rows[1] or {}) do
            daily[date]={pages=tonumber(rows[2][i]) or 0,duration=tonumber(rows[3][i]) or 0}
        end
        local summary={days={},pages=0,duration=0,maximum=0,longest_day=0,calendar_days=0,title=title,mode=mode}
        local months = {}
        local stamp=start
        while stamp<=finish do
            summary.calendar_days=summary.calendar_days+1
            local date=os.date("%Y-%m-%d",stamp)
            local value=daily[date] or {pages=0,duration=0}
            local item
            if mode=="months" then
                local key=os.date("%Y-%m",stamp)
                item=months[key]
                if not item then
                    item={label=os.date("%b %Y",stamp),short=os.date("%b",stamp),duration=0,pages=0}
                    months[key]=item;summary.days[#summary.days+1]=item
                end
                item.duration=item.duration+value.duration;item.pages=item.pages+value.pages
            else
                item={label=os.date("%a %d %b",stamp),short=os.date("%d",stamp),
                    duration=value.duration,pages=value.pages,today=date==os.date("%Y-%m-%d",now)}
                summary.days[#summary.days+1]=item
            end
            summary.duration=summary.duration+value.duration;summary.pages=summary.pages+value.pages
            summary.longest_day=math.max(summary.longest_day,value.duration)
            local next_day=os.date("*t",stamp);next_day.day=next_day.day+1;next_day.isdst=nil
            stamp=os.time(next_day)
        end
        for index,item in ipairs(summary.days) do summary.maximum=math.max(summary.maximum,item.duration) end
        summary.average_day=summary.duration/math.max(1,summary.calendar_days)
        return summary
    end)
    if connection then pcall(connection.close,connection) end
    if not ok then
        logger.warn("Slate: statistics database read failed:",result)
        return nil,_("Could not read reading statistics.")
    end
    return result
end

local progress_cache = {}

local function progressCachePath(mode, first, last)
    local directory=DataStorage:getDataDir().."/cache/slate-reading-progress"
    util.makePath(directory)
    local key=table.concat({"v1",mode or "week",first or "",last or ""},"|")
    return directory.."/"..cacheHash(key)..".json",key
end

local function readProgressCache(path)
    local f=io.open(path,"r")
    if not f then return nil end
    local text=f:read("*all");f:close()
    local ok,value=pcall(function() return require("json").decode(text) end)
    if ok and type(value)=="table" and type(value.data)=="table"
        and type(value.data.days)=="table" and type(value.data.duration)=="number" then
        return value
    end
end

function Popup:stopProgressLoad()
    if self._progress_task then UIManager:unschedule(self._progress_task) end
    if self._progress_poll then UIManager:unschedule(self._progress_poll) end
    self._progress_task,self._progress_poll=nil,nil
    local job=self._progress_job;self._progress_job=nil
    if job then FFIUtil.terminateSubProcess(job.pid);reapJob(job) end
end

function Popup:loadReadingProgress()
    if not self.progress_checked then
        self.progress_checked=true
        self:stopProgressLoad()
        self.progress_mode=G_reader_settings:readSetting(PREFIX.."progress.range","week")
        local mode=self.progress_mode
        local first=G_reader_settings:readSetting(PREFIX.."progress.from")
        local last=G_reader_settings:readSetting(PREFIX.."progress.to")
        local path,key=progressCachePath(mode,first,last)
        local cached=progress_cache[key] or readProgressCache(path)
        if cached then progress_cache[key]=cached end
        self.progress_data=cached and cached.data or nil
        self.progress_error=nil
        local today=os.date("%Y-%m-%d")
        local database=DataStorage:getSettingsDir().."/statistics.sqlite3"
        local signature=table.concat({today,tostring(lfs.attributes(database,"modification")),
            tostring(lfs.attributes(database,"size")),tostring(lfs.attributes(database.."-wal","modification")),
            tostring(lfs.attributes(database.."-wal","size"))},"|")
        local fresh=cached and cached.signature==signature and os.time()-(cached.updated or 0)<300
        if not fresh then
            local task
            task=function()
                self._progress_task=nil
                if self.closed or self.view~="progress" or self.progress_mode~=mode then return end
                if type(FFIUtil.runInSubProcess)~="function" then
                    self.progress_error=_("Background statistics loading is unavailable.")
                    UIManager:setDirty(self,"ui");return
                end
                local temporary=path..".tmp"
                os.remove(temporary)
                local ok,pid=pcall(FFIUtil.runInSubProcess,function()
                    local success,data,err=pcall(Books.getReadingProgress,Books,mode,first,last)
                    local result={data=success and data or nil,error=success and err or tostring(data),
                        updated=os.time(),signature=signature}
                    local encoded_ok,encoded=pcall(function() return require("json").encode(result) end)
                    if encoded_ok then
                        local f=io.open(temporary,"w")
                        if f then f:write(encoded);f:close() end
                    end
                end)
                if not ok or not pid then
                    self.progress_error=_("Could not start statistics refresh.")
                    UIManager:setDirty(self,"ui");return
                end
                local job={pid=pid,temporary=temporary,started=os.time()}
                self._progress_job=job
                if type(UIManager.preventStandby)=="function" then UIManager:preventStandby();job.prevented=true end
                local poll
                poll=function()
                    self._progress_poll=nil
                    if self.closed or self._progress_job~=job then return end
                    if FFIUtil.isSubProcessDone(pid) then
                        self._progress_job=nil
                        if job.prevented then UIManager:allowStandby();job.prevented=false end
                        local result=readProgressCache(temporary)
                        if result then
                            os.rename(temporary,path);progress_cache[key]=result
                            self.progress_data=result.data;self.progress_error=nil
                            self:loadReadingProgress()
                            UIManager:setDirty(self,"ui")
                        else
                            os.remove(temporary)
                            self.progress_error=_("Could not refresh reading statistics.")
                            if not self.progress_data then UIManager:setDirty(self,"ui") end
                        end
                    elseif os.time()-job.started>=30 then
                        self:stopProgressLoad()
                        self.progress_error=_("Reading statistics refresh timed out.")
                        if not self.progress_data then UIManager:setDirty(self,"ui") end
                    else self._progress_poll=poll;UIManager:scheduleIn(.15,poll) end
                end
                self._progress_poll=poll;UIManager:scheduleIn(.15,poll)
            end
            self._progress_task=task;UIManager:scheduleIn(.05,task)
        end
    end
    self.progress_rows=7
    self.pages=math.max(1,math.ceil(#(self.progress_data and self.progress_data.days or {})/self.progress_rows))
    self.page=math.max(1,math.min(self.pages,self.page))
end

function Popup:setProgressRange(mode, first, last)
    G_reader_settings:saveSetting(PREFIX.."progress.range",mode)
    if first then G_reader_settings:saveSetting(PREFIX.."progress.from",first) end
    if last then G_reader_settings:saveSetting(PREFIX.."progress.to",last) end
    G_reader_settings:flush()
    self.progress_checked=false;self.page=1
    self:rebuild();UIManager:setDirty(self,"ui")
end

function Popup:showProgressRange()
    local ButtonDialog=require("ui/widget/buttondialog")
    local InputDialog=require("ui/widget/inputdialog")
    local popup=self
    local function askDate(title,initial,accept)
        local dialog
        dialog=InputDialog:new{modal=true,title=title,input=initial,input_hint="YYYY-MM-DD",
            buttons={{ {text=_("CANCEL"),callback=function() UIManager:close(dialog) end},
                {text=_("NEXT"),callback=function()
                    local value=dialog:getInputText()
                    if not dateStamp(value) then
                        UIManager:show(InfoMessage:new{modal=true,text=_("Use a valid date: YYYY-MM-DD.")});return
                    end
                    UIManager:close(dialog);accept(value)
                end} }}}
        UIManager:show(SlateUtils:themePopup(dialog));if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    end
    local menu
    local function choose(mode)
        UIManager:close(menu)
        if mode~="custom" then popup:setProgressRange(mode);return end
        askDate(_("Start date"),G_reader_settings:readSetting(PREFIX.."progress.from",os.date("%Y-%m-01")),function(first)
            askDate(_("End date"),G_reader_settings:readSetting(PREFIX.."progress.to",os.date("%Y-%m-%d")),function(last)
                if dateStamp(last)<dateStamp(first) or dateStamp(last)>os.time() then
                    UIManager:show(InfoMessage:new{modal=true,text=_("End date must follow the start date and cannot be in the future.")});return
                end
                popup:setProgressRange("custom",first,last)
            end)
        end)
    end
    local items={}
    for index,option in ipairs({{"week",_("Last seven days")},{"months",_("Months — last twelve months")},{"custom",_("Custom date range…")},{"history",_("Entire history")}}) do
        local mode=option[1]
        items[#items+1]={text=option[2],checked_func=function() return popup.progress_mode==mode end,
            callback=function() choose(mode) end}
    end
    local buttons={}
    for index,item in ipairs(items) do
        buttons[#buttons+1]={{text=(item.checked_func() and "✓ " or "")..item.text,callback=item.callback}}
    end
    menu=ButtonDialog:new{modal=true,title=_("READING RANGE"),buttons=buttons,
        width=math.floor(Screen:getWidth()*0.8)}
    UIManager:show(SlateUtils:themePopup(menu))
end

local function graphLine(bb,x1,y1,x2,y2,stroke)
    local steps=math.max(math.abs(x2-x1),math.abs(y2-y1),1)
    for step=0,steps do
        local x=math.floor(x1+(x2-x1)*step/steps)
        local y=math.floor(y1+(y2-y1)*step/steps)
        bb:paintRect(x,y,stroke,stroke,Blitbuffer.COLOR_BLACK)
    end
end

function Popup:paintReadingProgress(bb)
    self:loadReadingProgress()
    local c,data=self.content,self.progress_data
    if not data then drawText(bb,self.progress_error or _("Preparing reading progress…"),c,18,false,true);return end
    local gap=self.gap
    local title_h=math.floor(c.h*.065)
    drawText(bb,data.title,{x=c.x,y=c.y,w=c.w,h=title_h},21,true,false)
    local graph_h=math.floor(c.h*.29)
    local label_h=math.max(20,Screen:scaleBySize(17))
    local axis_w=math.floor(c.w*.14)
    local chart={x=c.x+axis_w,y=c.y+title_h+gap+label_h/2,
        w=c.w-axis_w-gap,h=graph_h-label_h*2-gap}
    local count=math.min(24,#data.days)
    local points,maximum={},0
    for i=1,count do
        local first=math.floor((i-1)*#data.days/count)+1
        local last=math.floor(i*#data.days/count)
        local value=0
        for n=first,last do value=value+data.days[n].duration end
        -- Long daily ranges are reduced to average time per day for readability.
        value=value/math.max(1,last-first+1)
        points[i]={value=value,label=data.days[first].short}
        maximum=math.max(maximum,value)
    end
    local scale=math.max(3600,math.ceil(maximum/3600)*3600)
    for level=0,2 do
        local y=math.floor(chart.y+chart.h*level/2)
        bb:paintRect(chart.x,y,chart.w,1,Blitbuffer.COLOR_LIGHT_GRAY)
        drawText(bb,durationLabel(scale*(2-level)/2),
            {x=c.x,y=y-label_h/2,w=axis_w-gap,h=label_h},12,false,false)
    end
    local prior
    local stroke=math.max(1,Screen:scaleBySize(1))
    for i,point in ipairs(points) do
        local x=math.floor(chart.x+(i-1)*chart.w/math.max(1,count-1))
        local y=math.floor(chart.y+chart.h-chart.h*point.value/scale)
        if prior then graphLine(bb,prior.x,prior.y,x,y,stroke) end
        local radius=math.max(3,Screen:scaleBySize(3))
        if bb.paintCircle then bb:paintCircle(x,y,radius,Blitbuffer.COLOR_BLACK)
        else bb:paintRoundedRect(x-radius,y-radius,radius*2,radius*2,Blitbuffer.COLOR_BLACK,radius) end
        if count<=12 or i==1 or i==count or i%4==0 then
            local width=math.floor(chart.w/math.max(1,count))
            drawText(bb,point.label,{x=math.max(c.x,math.min(c.x+c.w-width,x-width/2)),
                y=chart.y+chart.h+gap,w=width,h=label_h},12,false,true)
        end
        prior={x=x,y=y}
    end
    if #data.days>24 then
        drawText(bb,_("Daily averages grouped across the selected range"),
            {x=c.x,y=c.y+title_h+graph_h,w=c.w,h=label_h},11,false,true)
    end
    local table_y=c.y+title_h+graph_h+label_h+gap
    local summary_h=math.floor(c.h*.16)
    local table_h=c.y+c.h-summary_h-gap*2-table_y
    local row_h=math.floor(table_h/8)
    local widths={math.floor(c.w*.38),math.floor(c.w*.40)}
    local xs={c.x,c.x+widths[1],c.x+widths[1]+widths[2]}
    local ws={widths[1],widths[2],c.w-widths[1]-widths[2]}
    for row=0,7 do
        local labels,bold
        if row==0 then
            labels={data.mode=="months" and _("MONTH") or _("DAY"),_("READING TIME"),_("PAGES")};bold=true
        else
            local item=data.days[(self.page-1)*7+row]
            if item then labels={item.label,durationLabel(item.duration),tostring(item.pages)};bold=item.today end
        end
        for col=1,3 do
            local rect={x=xs[col],y=table_y+row*row_h,w=ws[col],h=row_h}
            if row==0 then bb:paintRect(rect.x,rect.y,rect.w,rect.h,Blitbuffer.COLOR_LIGHT_GRAY) end
            bb:paintBorder(rect.x,rect.y,rect.w,rect.h,1,Blitbuffer.COLOR_LIGHT_GRAY)
            if labels then drawText(bb,labels[col],{x=rect.x+gap,y=rect.y,w=rect.w-gap*2,h=rect.h},17,bold,col~=1) end
        end
    end
    local y=c.y+c.h-summary_h
    local w=math.floor((c.w-gap*3)/4)
    local summaries={
        {_("TOTAL READ"),durationLabel(data.duration),_("TIME")},
        {_("TOTAL PAGES"),tostring(data.pages),_("READ")},
        {_("AVERAGE TIME"),durationLabel(data.average_day or 0),_("PER DAY")},
        {_("LONGEST READING"),durationLabel(data.longest_day or data.maximum),_("IN A DAY")},
    }
    local radius=math.max(0,math.min(60,tonumber(G_reader_settings:readSetting("slate.button_corner_radius",40)) or 40))
    for index,item in ipairs(summaries) do
        local x=c.x+(index-1)*(w+gap)
        bb:paintBorder(x,y,w,summary_h,1,Blitbuffer.COLOR_BLACK,radius)
        local heading_h=math.floor(summary_h*.42)
        if item[3] then
            drawText(bb,item[1],{x=x+gap,y=y+gap,w=w-gap*2,h=heading_h/2},12,true,true)
            drawText(bb,item[3],{x=x+gap,y=y+gap+heading_h/2,w=w-gap*2,h=heading_h/2},12,true,true)
        else drawText(bb,item[1],{x=x+gap,y=y+gap,w=w-gap*2,h=heading_h},12,true,true) end
        drawText(bb,item[2],{x=x+gap,y=y+gap+heading_h,w=w-gap*2,h=summary_h-heading_h-gap*2},23,true,true)
    end
end

function Popup:showUIOptions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local SpinWidget = require("ui/widget/spinwidget")
    local categories = self.view == "categories" and not self.folder
    local prefix = categories and "categories" or self.kind
    local popup = self
    local menu
    local function trackDialog(dialog)
        local close = dialog.onCloseWidget
        dialog.onCloseWidget = function(instance, ...)
            if popup._ui_menu == instance then popup._ui_menu = nil end
            if close then return close(instance, ...) end
        end
        popup._ui_menu = dialog
        return dialog
    end
    local function closeMenu()
        if menu then UIManager:close(menu) end
        popup._ui_menu = nil
    end
    local function apply(key, value)
        G_reader_settings:saveSetting(PREFIX .. prefix .. "." .. key, value)
        G_reader_settings:flush()
        if popup.closed then return end
        popup.options = Books:getOptions(popup.kind)
        popup.page = 1
        popup:rebuild()
        UIManager:setDirty(popup, "ui")
    end
    local function count(key, title, value, minimum, maximum)
        return {text = title .. " (" .. value .. ")", callback = function()
            closeMenu()
            local spin = SpinWidget:new{
                modal = true,
                title_text = title, value = value, value_min = minimum,
                value_max = maximum, value_step = 1, value_hold_step = 1,
                ok_text = _("Apply"), callback = function(widget) apply(key, widget.value) end,
            }
            UIManager:show(SlateUtils:themePopup(trackDialog(spin)))
        end}
    end
    local o = self.options
    local rounded = categories and o.category_rounded or o.rounded
    local buttons = {
        {count("columns", categories and _("Books per folder row") or _("Books per row"),
            categories and o.category_columns or o.columns, categories and 3 or 1, categories and 8 or 6)},
        {count("rows", categories and _("Folders per page") or _("Rows per page"),
            categories and o.category_rows or o.rows, categories and 2 or 1, 5)},
        {{text = (rounded and "✓ " or "") .. _("Rounded thumbnails"), callback = function()
            closeMenu(); apply("rounded", not rounded)
        end}},
    }
    if not categories then
        buttons[#buttons + 1] = {{text = (o.progress and "✓ " or "") .. _("Show progress bar and percentage"),
            callback = function() closeMenu(); apply("progress", not o.progress) end}}
    end
    menu = ButtonDialog:new{modal = true, title = _("VIEW OPTIONS"), buttons = buttons,
        width = math.floor(self.box.w * 0.85)}
    UIManager:show(SlateUtils:themePopup(trackDialog(menu)))
end

function Popup:paintTo(bb)
    local r, c = self.box, self.content
    local radius = math.max(0, math.min(60,
        tonumber(G_reader_settings:readSetting("slate.popup_corner_radius", 40)) or 40))
    local button_radius = math.max(0, math.min(60,
        tonumber(G_reader_settings:readSetting("slate.button_corner_radius", 40)) or 40))
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, radius)
    self.back_button = nil
    local header_pager = self.view ~= "progress"
    local header_pager_w = math.min(math.floor(c.w * 0.38), Screen:scaleBySize(220))
    local counter_width = textSize(_("Pages") .. " " .. self.pages .. " / " .. self.pages,
        14, false, "infofont")
    local counter_gap = math.max(2, Screen:scaleBySize(2))
    header_pager_w = math.min(header_pager_w,
        math.ceil(math.max((counter_width + counter_gap * 2) / 0.68,
            counter_width + counter_gap * 2 + 24)))
    local action_size = math.max(24, Screen:scaleBySize(32))
    local icon_inset = self.title_x - r.x
    local action_right = r.x + r.w - math.max(self.pad, icon_inset)
    self.ui_menu_button = self.view ~= "progress" and {
        x = action_right - action_size,
        y = r.y + self.pad + math.floor((self.title_h - action_size) / 2),
        w = action_size, h = action_size,
    } or nil
    local header_right = self.ui_menu_button and self.ui_menu_button.x - self.gap or c.x + c.w
    if header_pager and self.pages > 1 then
        header_right = header_right - header_pager_w - self.gap
    elseif self.view == "progress" then
        header_right = header_right - math.max(24, Screen:scaleBySize(32)) - self.gap
    end
    local header_x=self.title_x
    if G_reader_settings:readSetting("slate.popup_header_icons", true) == true then
        local size = self.header_icon_size
        local icon_x = header_x
        local icon_y = r.y+self.pad+math.floor((self.title_h-size)/2)
        local icon_size = math.max(1, math.floor(size))
        bb:paintRoundedRect(icon_x,icon_y,size,size,Blitbuffer.COLOR_WHITE,math.floor(size/2))
        if G_reader_settings:readSetting("slate.popup_header_outline",true)~=false then
            bb:paintBorder(icon_x,icon_y,size,size,math.max(1,math.floor(size/14)),Blitbuffer.COLOR_BLACK,math.floor(size/2))
        end
        local key = self.kind == "recents" and "recents" or "library"
        local path = G_reader_settings:readSetting("slate.widget_icons."..key)
        if type(path) ~= "string" or path == "" or not util.fileExists(path) then
            path = key == "library" and type(self.owner.getPluginDir) == "function"
                and self.owner:getPluginDir().."/icons/library.svg" or nil
        end
        local icon
        local ok, err = pcall(function()
            local options = {width=icon_size,height=icon_size,alpha=true,
                original_in_nightmode=false,invert=false}
            if path then options.file=path;icon=ImageWidget:new(options)
            else options.icon="history";icon=IconWidget:new(options) end
            icon:paintTo(bb,icon_x+math.floor((size-icon_size)/2),icon_y+math.floor((size-icon_size)/2))
        end)
        if icon then icon:free() end
        if not ok then logger.warn("Slate: popup header icon failed:",err) end
        header_x=header_x+size+Screen:scaleBySize(16)
    end
    if G_reader_settings:readSetting("slate.popup_header_text",true)==true then
        local _, title_width = drawText(bb,self.kind=="recents" and _("HISTORY")
                or (self.metadata_mode and _("UPDATE BOOK METADATA")
                    or self.description_mode and _("MISSING DESCRIPTIONS") or _("LIBRARY")),
            {x=header_x,y=r.y+self.pad,w=math.max(1,header_right-header_x
                - (self.folder and self.title_h+self.gap or 0)),h=self.title_h},
            self.font_size+2,true,false)
        header_x = header_x + title_width + self.gap
    end
    if self.folder then
        self.back_button = {x=header_x,y=r.y+self.pad,
            w=math.max(1,math.min(self.title_h,header_right-header_x)),h=self.title_h}
        drawText(bb, "‹", self.back_button, 24, true, true)
    end
    if self.ui_menu_button then
        local rect = self.ui_menu_button
        local icon
        local ok = pcall(function()
            icon = ImageWidget:new{file = self.owner:getPluginDir() .. "/icons/menu.svg",
                width = rect.w, height = rect.h, alpha = true,
                original_in_nightmode = false, invert = false}
            icon:paintTo(bb, rect.x, rect.y)
        end)
        if icon then icon:free() end
        if not ok then drawText(bb, "≡", rect, 32, true, true) end
    end
    if self.folder_title_rect then
        drawText(bb, self.folder.title, self.folder_title_rect, self.font_size, true, false)
    end
    self.progress_switch = nil
    if self.view == "progress" then
        local size = math.max(24, Screen:scaleBySize(32))
        self.progress_switch = {x=c.x+c.w-size,y=r.y+self.pad+math.floor((self.title_h-size)/2),w=size,h=size}
        local rect=self.progress_switch
        local icon=ImageWidget:new{file=(self.owner:getPluginDir()).."/icons/switch.svg",width=size,height=size,
            alpha=true,original_in_nightmode=false}
        local ok=pcall(icon.paintTo,icon,bb,rect.x,rect.y)
        icon:free()
        if not ok then drawText(bb,"⇄",rect,28,true,true) end
    end
    for index, header in ipairs(self.category_headers) do
        drawText(bb, header.folder.title, header.rect, self.font_size, true, false)
        if header.pages > 1 then
            drawText(bb, "‹", header.previous, 22, true, true,
                header.page == 1 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_BLACK)
            drawText(bb, "›", header.next, 22, true, true,
                header.page == header.pages and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_BLACK)
        end
        if #header.folder.books == 0 then
            drawText(bb, _("No books in this folder."), header.body, 14, false, true)
        end
    end
    if self.view == "progress" then self:paintReadingProgress(bb) end
    for _, tile in ipairs(self.tiles) do self:paintTile(bb, tile) end
    if self.view ~= "progress" and #self.tiles == 0 and #self.category_headers == 0 then
        drawText(bb, self.description_mode and _("All books have descriptions.")
                or (self.view == "categories" and _("No category folders found.") or _("No books found.")),
            c, self.font_size, false, true)
    end
    local pager_h = header_pager and math.min(self.title_h, math.max(36, Screen:scaleBySize(36))) or self.pager_h
    local pager_y = header_pager and (r.y + self.pad + math.floor((self.title_h-pager_h)/2))
        or (c.y + c.h + self.pager_gap)
    local pager_w = header_pager and header_pager_w
        or math.min(c.w, Screen:scaleBySize(280))
    local pager_x = header_pager and ((self.ui_menu_button and self.ui_menu_button.x - self.gap or c.x + c.w) - pager_w)
        or (c.x + math.floor((c.w - pager_w) / 2))
    local arrow_w = math.max(12, math.floor(pager_w * 0.16))
    self.previous, self.next = nil, nil
    if self.pages > 1 then
        self.previous = {x=pager_x,y=pager_y,w=arrow_w,h=pager_h}
        self.next = {x=pager_x+pager_w-arrow_w,y=pager_y,w=arrow_w,h=pager_h}
        drawText(bb, "‹", self.previous, 48, true, true, nil, "infofont")
        drawText(bb, _("Pages") .. " " .. self.page .. " / " .. self.pages,
            {x=pager_x+arrow_w+counter_gap,y=pager_y,
                w=math.max(1,pager_w-arrow_w*2-counter_gap*2),h=pager_h},
            14, false, true, nil, "infofont")
        drawText(bb, "›", self.next, 48, true, true, nil, "infofont")
    end
    self.mode_buttons = {}
    do
        local width = math.floor((c.w - self.gap) / 2)
        local y = r.y + r.h - self.bottom_pad - self.button_h
        local labels = self.kind == "recents"
            and { _("RECENTS"), _("READING PROGRESS") }
            or (self.metadata_mode and { _("REFRESH LIST"), _("CLOSE") }
                or self.description_mode and { _("RETRY ALL MISSING"), _("REFRESH LIST") }
                or { _("ENTIRE LIBRARY"), _("CATEGORIES") })
        for i, label in ipairs(labels) do
            local rect = { x = c.x + (i - 1) * (width + self.gap), y = y, w = width, h = self.button_h }
            self.mode_buttons[i] = rect
        local selected = i == 1 and self.view == "library"
            or i == 2 and self.view == "categories"
            if self.kind == "recents" then
                selected = i == 1 and self.view == "recents" or i == 2 and self.view == "progress"
            end
            local background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            local foreground = selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, background, button_radius)
            bb:paintBorder(rect.x, rect.y, rect.w, rect.h, 1, Blitbuffer.COLOR_BLACK, button_radius)
            local inset = math.max(4, Screen:scaleBySize(4))
            local text_rect = {
                x = rect.x + inset, y = rect.y + inset,
                w = rect.w - inset * 2, h = rect.h - inset * 2,
            }
            local reference_h = math.max(24, Screen:scaleBySize(32))
            local fit_h = math.min(text_rect.h, reference_h - inset * 2)
            local widget
            for size = 18, 6, -1 do
                widget = TextWidget:new{
                    text = label, face = Font:getFace("cfont", size),
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
        end
    end
    self:updateTouchTargets()
end

function Popup:updateTouchTargets()
    local targets = {}
    local function add(rect)
        if not rect then return end
        local padding = Screen:scaleBySize(12)
        local x = math.max(self.box.x, rect.x - padding)
        local y = math.max(self.box.y, rect.y - padding)
        local right = math.min(self.box.x + self.box.w, rect.x + rect.w + padding)
        local bottom = math.min(self.box.y + self.box.h, rect.y + rect.h + padding)
        targets[#targets + 1] = { original = rect,
            rect = {x=x,y=y,w=right-x,h=bottom-y} }
    end
    add(self.back_button)
    add(self.progress_switch)
    add(self.ui_menu_button)
    for _, rect in ipairs(self.mode_buttons or {}) do add(rect) end
    if self.pages > 1 then add(self.previous); add(self.next) end
    for _, header in ipairs(self.category_headers) do
        add(header.rect)
        if header.pages > 1 then add(header.previous); add(header.next) end
    end
    for _, tile in ipairs(self.tiles) do add(tile.rect) end
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

function Popup:touchRect(rect)
    for _, target in ipairs(self.touch_targets or {}) do
        if target.original == rect then return target.rect end
    end
    return rect
end

function Popup:changePage(delta)
    local page = math.max(1, math.min(self.pages, self.page + delta))
    if page ~= self.page then
        self.page = page
        self:rebuild()
        UIManager:setDirty(self, "ui")
    end
end

function Popup:changeView(view)
    if view ~= "progress" then self:stopProgressLoad();self.progress_checked=false end
    self.view, self.folder, self.page = view, nil, 1
    G_reader_settings:saveSetting(PREFIX .. self.kind .. ".view", view)
    G_reader_settings:flush()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function Popup:enterFolder(folder)
    if not folder.books then folder.books = Books:scanDirectory(folder.file, true) end
    self.return_page = self.page
    self.folder_window_h=self.box.h
    self.folder, self.page = folder, 1
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function Popup:onBack()
    if self.folder then
        self.folder = nil
        self.folder_window_h=nil
        self.page = self.return_page or 1
        self:rebuild()
        UIManager:setDirty(self, "ui")
        return true
    end
    return self:onClose()
end

function Popup:onTap(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then return self:onClose() end
    if contains(self:touchRect(self.ui_menu_button), pos) then self:showUIOptions();return true end
    if contains(self:touchRect(self.progress_switch), pos) then self:showProgressRange();return true end
    if contains(self:touchRect(self.back_button), pos) then return self:onBack() end
    for i, rect in ipairs(self.mode_buttons or {}) do
        if contains(self:touchRect(rect), pos) then
            if self.metadata_mode then
                if i == 2 then return self:onClose() end
                self.entries = Books:scanDirectory(self.root,true)
                self.details = {}
                self:rebuild();UIManager:setDirty(self,"ui")
                return true
            end
            if self.description_mode then
                local descriptions = require("slate_book_descriptions")
                if i == 1 then
                    local count = descriptions:retryAllMissing()
                    UIManager:show(SlateUtils:themePopup(InfoMessage:new{
                        text = tostring(count) .. _(" missing descriptions queued. Connect to Wi-Fi to download them."),
                    }))
                end
                self.entries = descriptions:missingBooks()
                self:rebuild();UIManager:setDirty(self,"ui")
                return true
            end
            self:changeView(self.kind == "recents"
                and (i == 1 and "recents" or "progress")
                or (i == 1 and "library" or "categories"))
            return true
        end
    end
    for _, header in ipairs(self.category_headers) do
        if contains(self:touchRect(header.rect), pos) then
            self:enterFolder(header.folder)
            return true
        end
        local delta = contains(self:touchRect(header.previous), pos) and -1 or contains(self:touchRect(header.next), pos) and 1
        if delta then
            local page = math.max(1, math.min(header.pages, header.page + delta))
            if page ~= header.page then
                self.category_pages[header.folder.file] = page
                self:rebuild()
                UIManager:setDirty(self, "ui")
            end
            return true
        end
    end
    for _, tile in ipairs(self.tiles) do
        if contains(self:touchRect(tile.rect), pos) then
            if self.metadata_mode then
                self:editBookMetadata(tile.entry)
            elseif self.description_mode then
                self._ui_menu = require("slate_book_descriptions"):editSearch(tile.entry.file,function()
                    if self.closed then return end
                    self.entries = require("slate_book_descriptions"):missingBooks()
                    self:rebuild();UIManager:setDirty(self,"ui")
                end)
            else Books:openBook(self.owner, tile.entry) end
            return true
        end
    end
    if self.pages > 1 then
        if contains(self:touchRect(self.previous), pos) then self:changePage(-1)
        elseif contains(self:touchRect(self.next), pos) then self:changePage(1) end
    end
    return true
end

function Popup:editBookMetadata(entry)
    self._ui_menu = require("slate_book_metadata"):edit(entry.file,function()
        if self.closed then return end
        self.details[entry.file] = nil
        self:rebuild();UIManager:setDirty(self,"ui")
    end)
    return true
end

function Popup:onHold(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box, pos) then return true end
    local loaded, pinpad = pcall(require, "slate_pinpad")
    if loaded and pinpad:intercept(self.owner) then return true end
    for _, tile in ipairs(self.tiles or {}) do
        if contains(self:touchRect(tile.rect), pos) then
            if self.metadata_mode then return self:editBookMetadata(tile.entry) end
            local ok, browser = pcall(require, "slate_book_highlights")
            if not ok or type(browser.show) ~= "function" then
                UIManager:show(SlateUtils:themePopup(InfoMessage:new{
                    text = _("The book highlights module is unavailable."),
                }))
                return true
            end
            local owner, file = self.owner, tile.entry.file
            browser:show(owner, file, self)
            return true
        end
    end
    return true
end

function Popup:onHoldRelease()
    return true
end

function Popup:onSwipe(_, ges)
    if not ges or not contains(self.box, ges.pos) then return true end
    if self.view == "categories" and not self.folder
        and (ges.direction == "west" or ges.direction == "east") then
        for _, header in ipairs(self.category_headers) do
            local preview = {
                x = header.body.x, y = header.rect.y,
                w = header.body.w,
                h = header.body.y + header.body.h - header.rect.y,
            }
            if contains(preview, ges.pos) then
                local delta = ges.direction == "west" and 1 or -1
                local page = math.max(1, math.min(header.pages, header.page + delta))
                if page ~= header.page then
                    self.category_pages[header.folder.file] = page
                    self:rebuild()
                    UIManager:setDirty(self, "ui")
                end
                return true
            end
        end
    end
    if ges.direction == "north" or ges.direction == "west" then self:changePage(1)
    elseif ges.direction == "south" or ges.direction == "east" then self:changePage(-1) end
    return true
end

function Popup:onClose()
    UIManager:close(self)
    return true
end

function Popup:onCloseWidget()
    self.closed = true
    if self._ui_menu then UIManager:close(self._ui_menu); self._ui_menu = nil end
    self:stopProgressLoad()
    self:clearAssets()
    if self.progress_image then self.progress_image:free(); self.progress_image = nil end
    if self.owner._slate_books_popup == self then self.owner._slate_books_popup = nil end
    UIManager:setDirty(nil, "ui")
end

function Books:show(owner, kind, description_mode, metadata_mode)
    if metadata_mode then
        local ok, metadata = pcall(require, "slate_book_metadata")
        if not ok or type(metadata) ~= "table" or type(metadata.edit) ~= "function" then
            UIManager:show(SlateUtils:themePopup(InfoMessage:new{modal=true,
                text = _("Install slate_book_metadata.lua from the matching update, then restart KOReader."),
            }))
            return
        end
    end
    if description_mode then
        local ok, descriptions = pcall(require, "slate_book_descriptions")
        if not ok or type(descriptions) ~= "table"
            or type(descriptions.missingBooks) ~= "function"
            or type(descriptions.retryAllMissing) ~= "function"
            or type(descriptions.editSearch) ~= "function" then
            UIManager:show(SlateUtils:themePopup(InfoMessage:new{
                text = _("The installed description module is outdated. Replace slate_book_descriptions.lua, slate_books.lua, and slate_settings.lua with the matching update, then restart KOReader."),
            }))
            return
        end
    end
    kind = kind == "recents" and "recents" or "library"
    if owner._slate_books_popup then self:close(owner) end
    local ok, popup = pcall(Popup.new, Popup, { owner = owner, kind = kind, description_mode = description_mode, metadata_mode = metadata_mode })
    if not ok then
        logger.warn("Slate: could not create book popup:", popup)
        UIManager:show(InfoMessage:new{ text = _("Could not open the book browser.") })
        return
    end
    owner._slate_books_popup = popup
    UIManager:show(popup, "ui")
    if popup.scan_errors and #popup.scan_errors > 0 then
        UIManager:show(InfoMessage:new{ text = _("Some book folders could not be read. Check the library directory.") })
    end
end

function Books:showMetadataEditor(owner)
    self:show(owner, "library", false, true)
end

function Books:showMissingDescriptions(owner)
    self:show(owner, "library", true)
end

function Books:showRecents(owner)
    self:show(owner, "recents")
end

function Books:showLibrary(owner)
    self:show(owner, "library")
end

function Books:close(owner)
    if owner and owner._slate_books_popup then UIManager:close(owner._slate_books_popup) end
end

SlateUtils:themePopup(Popup)

return Books
