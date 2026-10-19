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

-- Measure the full string before painting: max_width would silently truncate
-- dates/counters before the fitting loop had a chance to reduce the font.
local function drawFittedText(bb,label,r,size,bold,centered)
    local widget,dim
    for font_size=size,1,-1 do
        widget=TextWidget:new{text=tostring(label or ''),face=Font:getFace('cfont',font_size),bold=bold,fgcolor=Blitbuffer.COLOR_BLACK}
        dim=widget:getSize()
        if (dim.w<=r.w and dim.h<=r.h)or font_size==1 then break end
        widget:free()
    end
    widget:paintTo(bb,r.x+(centered=='right' and math.max(0,r.w-dim.w)or centered and math.max(0,math.floor((r.w-dim.w)/2))or 0),r.y+math.max(0,math.floor((r.h-dim.h)/2)))
    widget:free()
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
    self.box.y = self.box.x
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
    if self.kind=="recents" and self.view=="recents" then cover.y=rect.y end
    self.tiles[#self.tiles + 1] = {
        entry = entry, rect = rect, cover = cover,
        progress = progress, rounded = rounded,
    }
end

function Popup:rebuild()
    local c,o=self.content,self.options
    local screen_w,screen_h=Screen:getWidth(),Screen:getHeight()
    -- One stable frame for every tab/page, independent of visible row count.
    self.box.x=math.floor((screen_w-self.box.w)/2)
    self.box.y=self.box.x
    local dock=self.owner and self.owner._slate_card_bounds
    local dock_top=dock and dock.y or math.floor(screen_h*.82)
    local bottom=math.min(screen_h-self.box.x,dock_top-self.bottom_pad)
    self.box.h=math.max(1,bottom-self.box.y)
    self.padding_base_h,self.padding_base_y=self.box.h,self.box.y
    c.x=self.box.x+self.pad;c.w=self.box.w-self.pad*2
    local header_bottom=self.box.y+self.pad+self.title_h
    local button_y=self.box.y+self.box.h-self.bottom_pad-self.button_h
    c.y=header_bottom+self.bottom_pad
    c.h=math.max(1,button_y-self.bottom_pad-c.y)
    self.generation=self.generation+1
    self:cancelCoverLoad()
    self.tiles,self.category_headers={},{}
    self.pages=1;self.title_x=c.x;self.folder_title_rect=nil
    if self.view=='progress'then
        self.cover_layout=nil
        self:loadReadingProgress()
        return
    end
    local categories=self.view=='categories' and not self.folder
    local columns=categories and o.category_columns or o.columns
    local rows=categories and o.category_rows or o.rows
    local tile_w=math.max(1,math.floor((c.w-self.gap*(columns-1))/columns))
    local _,font_h=textSize('Ag',self.font_size,true)
    local heading_h=font_h+8
    local progress=not categories and o.progress
    local progress_space=progress and math.max(20,Screen:scaleBySize(19))+self.gap or 0
    local row_gap=math.max(self.gap,math.floor(self.bottom_pad*.5))
    local heading_gap=self.gap
    local groups={}
    if categories then
        self.pages=math.max(1,math.ceil(#self.folders/rows))
        self.page=math.max(1,math.min(self.page,self.pages))
        for index=(self.page-1)*rows+1,math.min(#self.folders,self.page*rows)do
            local folder=self.folders[index]
            if not folder.books then folder.books=Books:scanDirectory(folder.file,true)end
            local pages=math.max(1,math.ceil(#folder.books/columns))
            local page=math.max(1,math.min(self.category_pages[folder.file]or 1,pages))
            self.category_pages[folder.file]=page
            local entries={}
            for i=(page-1)*columns+1,math.min(#folder.books,page*columns)do entries[#entries+1]=folder.books[i]end
            groups[#groups+1]={folder=folder,entries=entries,pages=pages,page=page}
        end
    else
        local entries=self.folder and self.folder.books or self.entries
        local capacity=columns*rows
        self.pages=math.max(1,math.ceil(#entries/capacity))
        self.page=math.max(1,math.min(self.page,self.pages))
        local first=(self.page-1)*capacity+1
        for index=first,math.min(#entries,first+capacity-1),columns do
            local entries_row={}
            for i=index,math.min(#entries,index+columns-1,first+capacity-1)do entries_row[#entries_row+1]=entries[i]end
            groups[#groups+1]={entries=entries_row}
        end
    end
    -- Keep category and Recents row slots stable across partially filled pages.
    local available=math.max(1,button_y-header_bottom-self.bottom_pad*2)
    local folder_space=self.folder and heading_h+heading_gap or 0
    local row_heading=categories and heading_h+heading_gap or 0
    local cover_budget=math.max(rows,available-folder_space-row_gap*(rows-1)-(row_heading+progress_space)*rows)
    local row_height=math.max(1,math.floor(math.min(tile_w/.69,cover_budget/rows)))
    for _,group in ipairs(groups)do
        group.aspects={}
        for i,entry in ipairs(group.entries)do
            local path=thumbnailPaths(entry.file)
            local width,height=pngSize(path)
            group.aspects[i]=width and height and width/height or .69
        end
    end
    local block=folder_space+#groups*(row_height+row_heading+progress_space)+math.max(0,#groups-1)*row_gap
    local stable_recents=self.kind=='recents' and self.view~='categories'
    local slot_rows=stable_recents and math.min(rows,math.ceil(#self.entries/columns))or rows
    local reserved=(categories or stable_recents)and (slot_rows*(row_height+row_heading+progress_space)+math.max(0,slot_rows-1)*row_gap)or block
    local y=header_bottom+(button_y-header_bottom-reserved)/2
    local first_row_gap=y-header_bottom
    if self.folder then
        self.folder_title_rect={x=c.x,y=math.floor(y+.5),w=c.w,h=heading_h}
        y=y+folder_space
    end
    for _,group in ipairs(groups)do
        if categories then
            local arrow=heading_h
            self.category_headers[#self.category_headers+1]={folder=group.folder,pages=group.pages,page=group.page,
                rect={x=c.x,y=math.floor(y+.5),w=c.w-arrow*2-self.gap*2,h=heading_h},
                previous={x=c.x+c.w-arrow*2-self.gap,y=math.floor(y+.5),w=arrow,h=heading_h},
                next={x=c.x+c.w-arrow,y=math.floor(y+.5),w=arrow,h=heading_h},
                body={x=c.x,y=math.floor(y+row_heading+.5),w=c.w,h=row_height}}
        end
        local cover_y=math.floor(y+row_heading+.5)
        for i,entry in ipairs(group.entries)do
            self:addTile(entry,{x=c.x+(i-1)*(tile_w+self.gap),y=cover_y,w=tile_w,h=row_height+progress_space},
                progress,categories and o.category_rounded or o.rounded,group.aspects[i])
        end
        y=y+row_heading+row_height+progress_space+row_gap
    end
    -- Account for real cover sizes and heading ink when centering the block.
    local visible_top,visible_bottom=math.huge,-math.huge
    local function include(top,bottom)visible_top=math.min(visible_top,top);visible_bottom=math.max(visible_bottom,bottom)end
    local function includeHeading(r,label)
        local _,h,it,ib=textSize(label,self.font_size,true,nil,r.w,true)
        local offset=math.max(0,math.floor((r.h-h)/2))
        include(r.y+offset+(it or 0),r.y+offset+(ib or h))
    end
    if self.folder_title_rect then includeHeading(self.folder_title_rect,self.folder.title)end
    for _,h in ipairs(self.category_headers)do
        includeHeading(h.rect,h.folder.title)
        if #h.folder.books==0 then include(h.body.y,h.body.y+h.body.h)end
    end
    for _,tile in ipairs(self.tiles)do
        include(tile.cover.y,tile.cover.y+tile.cover.h+(tile.progress and progress_space or 0))
    end
    if visible_top<math.huge then
        local dy=categories and -math.floor((heading_h-font_h)/4)or stable_recents and 0 or math.floor(header_bottom+(button_y-header_bottom-(visible_bottom-visible_top))/2-visible_top+.5)
        local shifted={}
        local function shift(r)if r and not shifted[r]then r.y=r.y+dy;shifted[r]=true end end
        shift(self.folder_title_rect)
        for _,t in ipairs(self.tiles)do shift(t.rect);shift(t.cover)end
        for _,h in ipairs(self.category_headers)do shift(h.rect);shift(h.previous);shift(h.next);shift(h.body)end
        first_row_gap=visible_top+dy-header_bottom
        self.cover_layout={header_bottom=header_bottom,button_y=button_y,first_row_gap=first_row_gap,
            footer_gap=button_y-visible_bottom-dy,gap=row_gap,rows=#groups,categories=categories}
    else
        self.cover_layout={header_bottom=header_bottom,button_y=button_y,first_row_gap=available/2,footer_gap=available/2,rows=0}
    end
    self.cover_row_gap=row_gap
    local visible={}
    for _,tile in ipairs(self.tiles)do
        visible[tile.entry.file]=true
        local asset=self.assets[tile.entry.file]
        if asset and(asset.requested_w~=tile.cover.w or asset.requested_h~=tile.cover.h)then
            if asset.image then asset.image:free()end
            self.assets[tile.entry.file]=nil
        end
    end
    for file,asset in pairs(self.assets)do
        if not visible[file]then if asset.image then asset.image:free()end;self.assets[file]=nil end
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

local function progressHeading(mode,start,finish)
    if mode=='months'then return _('MONTHS')..' - '..os.date('%b.%d',start):upper()..' - '..os.date('%b.%d.%y',finish):upper()end
    local prefix=mode=='custom' and _('CUSTOM RANGE')or mode=='history' and _('ENTIRE HISTORY')or _('LAST SEVEN DAYS')
    return prefix..' - '..os.date('%d/%m/%y',start)..' - '..os.date('%d/%m/%y',finish)
end
local function goalPeriod(now,period)
    local first=os.date('*t',now);first.hour,first.min,first.sec,first.isdst=0,0,0,nil
    if period=='month'then first.day=1 else first.day=first.day-(first.wday+5)%7 end
    local start=os.time(first)
    local last=os.date('*t',start)
    if period=='month'then last.month=last.month+1 else last.day=last.day+7 end
    last.isdst=nil
    return start,os.time(last)-1
end

function Books:getReadingProgress(mode, from_date, to_date)
    mode = mode or "week"
    local now = os.time()
    local first = os.date("*t", now)
    first.hour, first.min, first.sec, first.isdst = 0,0,0,nil
    local title, finish = _("LAST SEVEN DAYS"), now
    if mode == "months" then
        first.month,first.day=1,1
        local ending={year=first.year+1,month=1,day=1,hour=0,min=0,sec=0,isdst=nil}
        finish=os.time(ending)-1
        title=_("MONTHS")
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
        local summary={days={},pages=0,duration=0,maximum=0,longest_day=0,calendar_days=0,title=progressHeading(mode,start,finish),mode=mode,start=start,finish=finish}
        local months = {}
        local stamp=start
        while stamp<=finish do
            summary.calendar_days=summary.calendar_days+1
            if stamp<=now then summary.elapsed_days=(summary.elapsed_days or 0)+1 end
            local date=os.date("%Y-%m-%d",stamp)
            local value=daily[date] or {pages=0,duration=0}
            local item
            if mode=="months" then
                local key=os.date("%Y-%m",stamp)
                item=months[key]
                if not item then
                    item={label=os.date("%b",stamp),short=os.date("%b",stamp),duration=0,pages=0}
                    months[key]=item;summary.days[#summary.days+1]=item
                end
                item.duration=item.duration+value.duration;item.pages=item.pages+value.pages
            else
                item={label=os.date("%a %d",stamp),short=os.date("%d",stamp),
                    duration=value.duration,pages=value.pages,today=date==os.date("%Y-%m-%d",now)}
                summary.days[#summary.days+1]=item
            end
            summary.duration=summary.duration+value.duration;summary.pages=summary.pages+value.pages
            summary.longest_day=math.max(summary.longest_day,value.duration)
            local next_day=os.date("*t",stamp);next_day.day=next_day.day+1;next_day.isdst=nil
            stamp=os.time(next_day)
        end
        for index,item in ipairs(summary.days) do summary.maximum=math.max(summary.maximum,item.duration) end
        summary.average_day=summary.duration/math.max(1,summary.elapsed_days or summary.calendar_days)
        if G_reader_settings:readSetting(PREFIX..'goal.enabled',false)==true then
            local period=G_reader_settings:readSetting(PREFIX..'goal.period','week')
            local goal_start,goal_finish=goalPeriod(now,period)
            local values=connection:exec(string.format([[
                SELECT count(*), coalesce(sum(read_duration),0) FROM (
                    SELECT id_book,page,strftime('%%Y-%%m-%%d',start_time,'unixepoch','localtime') AS reading_day,
                           sum(duration) AS read_duration
                    FROM page_stat WHERE start_time >= %d AND start_time <= %d
                    GROUP BY id_book,page,reading_day
                );
            ]],goal_start,now))
            summary.goal={start=goal_start,finish=goal_finish,pages=tonumber(values and values[1]and values[1][1])or 0,
                duration=tonumber(values and values[2]and values[2][1])or 0}
        end
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
    local key=table.concat({"v3",mode or "week",first or "",last or "",tostring(G_reader_settings:readSetting(PREFIX.."goal.enabled",false)),G_reader_settings:readSetting(PREFIX.."goal.period","week")},"|")
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

function Popup:trackProgressDialog(dialog)
    require("slate_popup_navigation"):wrapDialog(dialog,self.owner)
    self._ui_menu=dialog
    local original=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if self._ui_menu==instance then self._ui_menu=nil end
        if original then return original(instance,...)end
    end
    return dialog
end
function Popup:showProgressMenu(title,buttons)
    if self._ui_menu then UIManager:close(self._ui_menu);self._ui_menu=nil end
    local menu=require('ui/widget/buttondialog'):new{modal=true,title=title,buttons=buttons,width=math.floor(Screen:getWidth()*.8)}
    self:trackProgressDialog(menu)
    UIManager:show(SlateUtils:themePopup(menu))
end
function Popup:showProgressSettings()
    self:showProgressMenu(_('READING PROGRESS'),{
        {{text=_('Reading Range'),callback=function()self:showProgressRange()end}},
        {{text=_('Reading Streak / Goals'),callback=function()self:showGoalSettings()end}},
    })
end
function Popup:saveGoalSetting(key,value)
    G_reader_settings:saveSetting(PREFIX..'goal.'..key,value);G_reader_settings:flush()
    self.progress_checked=false
    self:loadReadingProgress();UIManager:setDirty(self,'ui')
end
function Popup:showGoalSettings()
    local enabled=G_reader_settings:readSetting(PREFIX..'goal.enabled',false)==true
    self:showProgressMenu(_('READING STREAK / GOALS'),{
        {{text=(enabled and '✓ 'or '').._('Enable Reading Goal'),callback=function()
            self:saveGoalSetting('enabled',not enabled);self:showGoalSettings()
        end}},
        {{text=_('Set Streak Goals'),callback=function()self:showGoalEditor()end}},
    })
end
function Popup:showGoalEditor()
    local metric=G_reader_settings:readSetting(PREFIX..'goal.metric','time')
    local period=G_reader_settings:readSetting(PREFIX..'goal.period','week')
    local key=metric=='pages' and 'pages'or 'minutes'
    local value=tonumber(G_reader_settings:readSetting(PREFIX..'goal.'..key,metric=='pages' and 100 or 120))or 1
    self:showProgressMenu(_('SET STREAK GOALS'),{
        {{text=_('Goal Type')..': '..(metric=='pages' and _('Pages')or _('Reading Time')),callback=function()
            self:showProgressMenu(_('GOAL TYPE'),{
                {{text=_('Reading Time'),callback=function()self:saveGoalSetting('metric','time');self:showGoalEditor()end}},
                {{text=_('Pages'),callback=function()self:saveGoalSetting('metric','pages');self:showGoalEditor()end}},
            })
        end}},
        {{text=_('Target')..': '..value..' '..(metric=='pages' and _('pages')or _('minutes')),callback=function()
            if self._ui_menu then UIManager:close(self._ui_menu);self._ui_menu=nil end
            local dialog=require('ui/widget/spinwidget'):new{modal=true,title_text=_('Reading Goal Target'),
                value=value,value_min=1,value_max=100000,value_step=1,value_hold_step=10,
                unit=metric=='pages' and _('pages')or _('minutes'),ok_text=_('Apply'),callback=function(spin)
                    self:saveGoalSetting(key,spin.value);UIManager:nextTick(function()if not self.closed then self:showGoalEditor()end end)
                end}
            self:trackProgressDialog(dialog);UIManager:show(SlateUtils:themePopup(dialog))
        end}},
        {{text=_('Period')..': '..(period=='month' and _('Per Month')or _('Per Week')),callback=function()
            self:showProgressMenu(_('GOAL PERIOD'),{
                {{text=_('Per Week'),callback=function()self:saveGoalSetting('period','week');self:showGoalEditor()end}},
                {{text=_('Per Month'),callback=function()self:saveGoalSetting('period','month');self:showGoalEditor()end}},
            })
        end}},
    })
end
function Popup:paintReadingGoal(bb,y)
    local bottom=self.box and (self.box.y+self.box.h-self.bottom_pad-self.button_h)or self.content.y+self.content.h
    local block_h=math.max(20,Screen:scaleBySize(20))*2+self.gap
    y=y+math.max(0,math.floor((bottom-y-block_h)/2))
    if G_reader_settings:readSetting(PREFIX..'goal.enabled',false)~=true then return end
    local c=self.content
    local goal=self.progress_data and self.progress_data.goal
    local heading_h=math.max(20,Screen:scaleBySize(20))
    drawFittedText(bb,_('READING GOAL'),{x=c.x,y=y,w=c.w*.35,h=heading_h},18,true,false)
    if not goal then
        drawFittedText(bb,_('Refreshing current goal period…'),{x=c.x,y=y+heading_h+self.gap,w=c.w,h=heading_h},14,false,false)
        return
    end
    local metric=G_reader_settings:readSetting(PREFIX..'goal.metric','time')
    local value=metric=='pages' and goal.pages or goal.duration
    local target=metric=='pages' and tonumber(G_reader_settings:readSetting(PREFIX..'goal.pages',100))or (tonumber(G_reader_settings:readSetting(PREFIX..'goal.minutes',120))or 120)*60
    target=math.max(1,target or 1);value=math.max(0,value or 0)
    local ratio=value/target
    local row_y=y+heading_h+self.gap
    local percentage=string.format('%i%%',math.floor(ratio*100+.5))
    local percent_w=math.min(c.w*.25,math.ceil(textSize(percentage,16,true)))
    local bar_w=math.max(1,c.w-percent_w-self.gap*2)
    local bar_h=math.max(5,Screen:scaleBySize(6))
    bb:paintRoundedRect(c.x,row_y+math.floor((heading_h-bar_h)/2),bar_w,bar_h,Blitbuffer.COLOR_LIGHT_GRAY,math.floor(bar_h/2))
    local filled=math.floor(bar_w*math.min(1,ratio))
    if filled>0 then
        bb:paintRoundedRect(c.x,row_y+math.floor((heading_h-bar_h)/2),filled,bar_h,Blitbuffer.COLOR_BLACK,math.min(math.floor(bar_h/2),math.floor(filled/2)))
    end
    local values=metric=='pages' and string.format('%i / %i %s',value,target,_('pages'))or durationLabel(value)..' / '..durationLabel(target)
    local period=G_reader_settings:readSetting(PREFIX..'goal.period','week')
    local label=values..' / '..(period=='month' and _('per month')or _('per week'))
    drawFittedText(bb,label,{x=c.x+c.w*.35+self.gap,y=y,w=c.w*.65-self.gap,h=heading_h},16,true,'right')
    drawFittedText(bb,percentage,{x=c.x+bar_w+self.gap*2,y=row_y,w=percent_w,h=heading_h},16,true,'right')
    self.reading_goal_bounds={x=c.x,y=y,w=c.w,h=heading_h*2+self.gap}
end

function Popup:showProgressRange()
    if self._ui_menu then UIManager:close(self._ui_menu);self._ui_menu=nil end
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
    for index,option in ipairs({{"week",_("Last seven days")},{"months",_("Months — current year")},{"custom",_("Custom date range…")},{"history",_("Entire history")}}) do
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
    self:trackProgressDialog(menu)
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
    local heading=data.start and progressHeading(data.mode,data.start,data.finish)or data.title
    drawFittedText(bb,heading,{x=c.x,y=c.y,w=c.w,h=title_h},21,true,false)
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
    local measured_width,summary_text_h=textSize('Ag',14,true)
    local goal_reserve=G_reader_settings:readSetting(PREFIX..'goal.enabled',false)==true
        and math.max(20,Screen:scaleBySize(20))*2+gap*3 or 0
    local row_h=math.max(12,math.min(math.max(28,Screen:scaleBySize(28)),
        math.floor((c.y+c.h-table_y-summary_text_h-gap*4-goal_reserve)/3)))
    local table_h=row_h*3
    local label_w=math.floor(c.w*.18)
    local columns=self.progress_rows or 7
    local value_w=(c.w-label_w)/columns
    local row_labels={data.mode=='months' and _('MONTH')or _('DAY'),_('READING TIME'),_('PAGES')}
    local row_label_size=14
    for size=14,1,-1 do
        row_label_size=size
        local fits=true
        for _,label in ipairs(row_labels)do
            local width,height=textSize(label,size,true)
            if width>label_w-gap*2 or height>row_h then fits=false;break end
        end
        if fits then break end
    end
    for row=1,3 do
        local rect={x=c.x,y=table_y+(row-1)*row_h,w=label_w,h=row_h}
        bb:paintRect(rect.x,rect.y,rect.w,rect.h,Blitbuffer.COLOR_LIGHT_GRAY)
        bb:paintBorder(rect.x,rect.y,rect.w,rect.h,1,Blitbuffer.COLOR_LIGHT_GRAY)
        drawFittedText(bb,row_labels[row],{x=rect.x+gap,y=rect.y,w=rect.w-gap*2,h=row_h},row_label_size,true,false)
        for column=1,columns do
            local item=data.days[(self.page-1)*columns+column]
            local period_label=item and item.label or ''
            if data.mode=='months' then period_label=period_label:gsub('%s+%d%d%d%d$','')
            else period_label=period_label:gsub('%s+%a+$','')end
            local text=item and(row==1 and period_label or row==2 and durationLabel(item.duration)or tostring(item.pages))or ''
            local x=math.floor(c.x+label_w+(column-1)*value_w)
            local right=math.floor(c.x+label_w+column*value_w)
            bb:paintBorder(x,rect.y,right-x,row_h,1,Blitbuffer.COLOR_LIGHT_GRAY)
            drawFittedText(bb,text,{x=x+gap,y=rect.y,w=math.max(1,right-x-gap*2),h=row_h},14,row==1 or(item and item.today),true)
        end
    end
    local y=table_y+table_h+gap*2
    local w=math.floor((c.w-gap*3)/4)
    local summaries={
        _('Total read')..' '..durationLabel(data.duration),
        _('Total pages')..' '..tostring(data.pages),
        _('Average/day')..' '..durationLabel(data.average_day or 0),
        _('Longest day')..' '..durationLabel(data.longest_day or data.maximum),
    }
    local shared_size=14
    for size=14,6,-1 do
        shared_size=size
        local fits=true
        for _,label in ipairs(summaries)do local width=textSize(label,size,true);if width>w-gap*2 then fits=false;break end end
        if fits then break end
    end
    local _,text_h=textSize('Ag',shared_size,true)
    local summary_h=text_h+gap*2
    local radius=math.max(0,math.min(math.floor(summary_h/2),tonumber(G_reader_settings:readSetting('slate.button_corner_radius',40))or 40))
    for index,label in ipairs(summaries)do
        local x=c.x+(index-1)*(w+gap)
        bb:paintBorder(x,y,w,summary_h,1,Blitbuffer.COLOR_BLACK,radius)
        drawFittedText(bb,label,{x=x+gap,y=y+gap,w=w-gap*2,h=text_h},shared_size,true,true)
    end
    self.progress_summary_bounds={x=c.x,y=y,w=c.w,h=summary_h}
    self:paintReadingGoal(bb,y+summary_h)
end

function Popup:showUIOptions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local SpinWidget = require("ui/widget/spinwidget")
    local categories = self.view == "categories" and not self.folder
    local prefix = categories and "categories" or self.kind
    local popup = self
    local menu
    local function trackDialog(dialog)
        require("slate_popup_navigation"):wrapDialog(dialog,popup.owner)
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
    local header_pager = true
    local pager_label=_("Pages").." "..self.page.."/"..self.pages
    local pager_label_w=textSize(_("Pages").." "..self.pages.."/"..self.pages,14,false)
    local arrow_w=textSize("›",28,true)
    local header_pager_w=math.ceil(pager_label_w+arrow_w*2+self.gap*8)
    local action_size = math.max(24, Screen:scaleBySize(32))
    local icon_inset = self.title_x - r.x
    local action_right = r.x + r.w - math.max(self.pad, icon_inset)
    self.ui_menu_button = {
        x = action_right - action_size,
        y = r.y + self.pad + math.floor((self.title_h - action_size) / 2),
        w = action_size, h = action_size,
    }
    local header_right = self.ui_menu_button and self.ui_menu_button.x - self.gap or action_right-action_size-self.gap
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
    local pager_x = header_pager and ((self.ui_menu_button and self.ui_menu_button.x - self.gap or action_right-action_size-self.gap) - pager_w)
        or (c.x + math.floor((c.w - pager_w) / 2))
    self.previous, self.next, self.pager_rect = nil, nil, nil
    if self.pages > 1 then
        self.pager_rect={x=pager_x,y=pager_y,w=pager_w,h=pager_h}
        self.previous={x=pager_x,y=pager_y,w=pager_w/2,h=pager_h}
        self.next={x=pager_x+pager_w/2,y=pager_y,w=pager_w/2,h=pager_h}
        -- Native drawing participates in the popup's night-mode inversion.
        -- No rasterized SVG background can obscure the counter or outline.
        bb:paintBorder(pager_x,pager_y,pager_w,pager_h,1,Blitbuffer.COLOR_BLACK,math.floor(pager_h/2))
        drawFittedText(bb,"‹",{x=pager_x+self.gap*2,y=pager_y,w=arrow_w,h=pager_h},28,true,true)
        drawFittedText(bb,"›",{x=pager_x+pager_w-self.gap*2-arrow_w,y=pager_y,w=arrow_w,h=pager_h},28,true,true)
        drawFittedText(bb,pager_label,
            {x=pager_x+arrow_w+self.gap*4,y=pager_y,w=math.max(1,pager_w-arrow_w*2-self.gap*8),h=pager_h},14,false,true)
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
    if not contains(self.box,pos)then
        if require('slate_popup_navigation'):switch(self,self.owner,ges)then return true end
        return self:onClose()
    end
    if contains(self.pager_rect,pos) then
        self:changePage(pos.x<self.pager_rect.x+self.pager_rect.w/2 and -1 or 1)
        return true
    end
    if contains(self:touchRect(self.ui_menu_button), pos) then if self.view=="progress"then self:showProgressSettings()else self:showUIOptions()end;return true end
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
    if not contains(self.box, pos) then
        require('slate_popup_navigation'):switch(self,self.owner,ges,'hold')
        return true
    end
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
