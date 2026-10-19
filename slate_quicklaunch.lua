-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-10.
-- Quick launch for Slate.

local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local SlateUtils = require("slate_utils")
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

local QuickLaunch = {}
local SECTIONS = {"games", "apps", "system"}
local SELECTION_KEY = "slate.quicklaunch_plugins"
local module_source = debug.getinfo(1, "S").source
local module_dir = module_source:sub(1, 1) == "@"
    and (module_source:sub(2):match("(.*/)") or "") or ""

local function selectionKey(section)
    return section == "apps" and "slate.quicklaunch_apps" or SELECTION_KEY
end

local function selectedIds(section)
    local key = selectionKey(section)
    local saved = G_reader_settings:readSetting(key)
    if saved == nil and section ~= "apps" then
        local previous = G_reader_settings:readSetting("slate.launcher_plugins")
        if type(previous) == "table" then
            saved = previous
            G_reader_settings:saveSetting(key, saved)
            G_reader_settings:flush()
        end
    end
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

local function drawText(bb, text, rect, size, bold, center, enabled, color, fixed)
    local widget
    for font_size = size, fixed and size or 6, -1 do
        widget = TextWidget:new{
            text = tostring(text or ""),
            face = Font:getFace("cfont", font_size),
            bold = bold,
            max_width = fixed and math.max(1,rect.w) or nil,
            truncate_with_ellipsis = true,
            fgcolor = color or (enabled == false
                and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK),
        }
        local dim = widget:getSize()
        if (dim.h <= rect.h - 8 and dim.w <= rect.w) or font_size == 6 then
            break
        end
        widget:free()
    end
    local dim = widget:getSize()
    local x = rect.x
    if center then
        x = x + math.max(0, math.floor((rect.w - dim.w) / 2))
    end
    widget:paintTo(bb, x,
        rect.y + math.max(0, math.floor((rect.h - dim.h) / 2)))
    widget:free()
    return x, dim.w
end

function QuickLaunch:getIconPath(section)
    section = section or G_reader_settings:readSetting("slate.quicklaunch_page", "games")
    if section == "apps" or section == "system" then return module_dir .. "icons/apps.svg" end
    local custom = G_reader_settings:readSetting("slate.widget_icons.quicklaunch")
    if type(custom) == "string" and custom ~= "" then return custom end
    return module_dir .. "icons/gamepad.svg"
end

function QuickLaunch:paintButton(bb, rect, stroke, foreground, background, invert, icon_name, draw_outline, section, glyph_scale)
    foreground = foreground or Blitbuffer.COLOR_BLACK
    background = background or Blitbuffer.COLOR_WHITE
    local radius = math.floor(rect.w / 2)
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, background, radius)
    if draw_outline ~= false then
        bb:paintBorder(rect.x, rect.y, rect.w, rect.h, stroke, foreground, radius)
    end
    local size = math.max(1, math.floor(rect.w * (glyph_scale or 0.58)))
    local icon
    if not icon_name and section == "system" then icon_name = "appbar.settings" end
    if icon_name then
        icon = IconWidget:new{
            icon = icon_name,
            width = size,
            height = size,
            alpha = true,
            original_in_nightmode = false,
            invert = invert or false,
        }
    else
        icon = ImageWidget:new{
            file = self:getIconPath(section),
            width = size,
            height = size,
            alpha = true,
            original_in_nightmode = false,
            invert = invert or false,
        }
    end
    icon:paintTo(bb,
        rect.x + math.floor((rect.w - size) / 2),
        rect.y + math.floor((rect.h - size) / 2))
    icon:free()
end

function QuickLaunch:getAvailableEntries(owner)
    local registered,candidates,seen_plugins,uis,seen_ui={},{},{},{},{}
    local ok,loader=pcall(require,"pluginloader")
    if not ok then loader={}end
    local function normalized(value)return type(value)=="string"and value:lower():gsub("[^%w]","")or ""end
    local by_path,by_name={},{}
    for _,definition in pairs(loader.enabled_plugins or {})do
        if type(definition)=="table"then
            if definition.path then by_path[definition.path]=definition end
            by_name[normalized(definition.name)]=definition
        end
    end
    local function canonicalName(plugin)
        local definition=by_path[plugin.path]or by_name[normalized(plugin.name)]
        return definition and definition.name or plugin.name
    end
    local function add(plugin)
        if type(plugin)=="table"and not seen_plugins[plugin]and plugin.disabled~=true then
            seen_plugins[plugin]=true;candidates[#candidates+1]=plugin
        end
    end
    local function addUI(ui)
        if type(ui)~="table"or seen_ui[ui]then return end
        seen_ui[ui]=true;uis[#uis+1]=ui
        for _,plugin in pairs(ui.menu and ui.menu.registered_widgets or {})do add(plugin)end
        -- Some plugins live on the UI but register through a different menu.
        for name,plugin in pairs(ui)do
            if type(name)=="string"and type(plugin)=="table"and plugin.ui==ui
                and type(plugin.addToMainMenu)=="function"then add(plugin)end
        end
        for _,definition in pairs(loader.enabled_plugins or {})do
            if type(definition)=="table"and type(definition.name)=="string"then add(ui[definition.name])end
        end
    end
    addUI(owner and owner.ui)
    for _,module in ipairs({"apps/reader/readerui","apps/filemanager/filemanager"})do
        local class=package.loaded[module]
        if class then addUI(class.instance)end
    end
    for _,plugin in pairs(loader.loaded_plugins or {})do add(plugin)end
    local function actionable(item)
        return type(item)=="table"and(type(item.callback)=="function"
            or type(item.sub_item_table_func)=="function"or type(item.sub_item_table)=="table")
    end
    local function clone(value,seen)
        if type(value)~="table"then return value end
        seen=seen or {};if seen[value]then return seen[value]end
        local result={};seen[value]=result
        for k,v in pairs(value)do result[k]=clone(v,seen)end
        return result
    end
    local function snapshot(items,out,prefix,seen)
        out=out or {};seen=seen or {};prefix=prefix or ""
        if type(items)~="table"or seen[items]then return out end
        seen[items]=true
        for id,item in pairs(items)do
            if type(item)=="table"then
                local path=prefix..tostring(id);out[path]=item
                snapshot(item.sub_item_table,out,path.."/",seen)
            end
        end
        return out
    end
    local function collect(items,plugin,before,prefix,seen,context_plugin)
        seen=seen or {};prefix=prefix or ""
        if type(items)~="table"or seen[items]then return end
        seen[items]=true
        for id,item in pairs(items)do
            local path=prefix..tostring(id)
            if actionable(item)and(not before or before[path]~=item)then
                local key=type(id)=="string"and id or tostring(plugin.name or "plugin")..":"..path
                if not registered[key]then registered[key]={item=item,plugin=plugin,context_plugin=context_plugin}end
            elseif type(item)=="table"then collect(item.sub_item_table,plugin,before,path.."/",seen,context_plugin)end
        end
    end
    for _,plugin in ipairs(candidates)do
        if type(plugin.addToMainMenu)=="function"then
            local items={}
            local registered_ok,err=pcall(plugin.addToMainMenu,plugin,items)
            collect(items,plugin)
            -- Registration may depend on existing core menu sections. Probe a
            -- private copy so discovery never mutates the real KOReader menu.
            if not registered_ok or not next(items)then
                local ui=plugin.ui
                local menu=ui and ui.menu and ui.menu.menu_items
                if type(menu)=="table"then
                    items=clone(menu)
                    local before=snapshot(items)
                    local retry_ok=pcall(plugin.addToMainMenu,plugin,items)
                    collect(items,plugin,before)
                    registered_ok=registered_ok or retry_ok
                end
            end
            if not registered_ok then logger.warn("Slate: quicklaunch menu registration failed:",plugin.name,err)end
            -- A reader-gated plugin can use a different menu ID from its folder
            -- name (e.g. zlibrary_main). Discover those IDs in a private browser-
            -- shaped registration context. These callbacks are NEVER launched.
            -- Real ReaderUI and plugin instances remain untouched.
            local ui=plugin.ui
            if type(ui)=="table"and(ui.document or ui.view)then
                local browser_ui={}
                for key,value in pairs(ui)do
                    if key~="document"and key~="view"then browser_ui[key]=value end
                end
                local browser_plugin=setmetatable({ui=browser_ui},{__index=function(_,key)
                    if key~="document"and key~="view"then return plugin[key]end
                end})
                local browser_items={}
                pcall(plugin.addToMainMenu,browser_plugin,browser_items)
                collect(browser_items,plugin,nil,nil,nil,canonicalName(plugin))
            end
        end
    end
    local entries,current={},{}
    for id,source in pairs(registered)do
        local item=source.item
        if type(id)=="string"and id~="slate"then
            local label=item.text or id
            if type(item.text_func)=="function"then
                local label_ok,value=pcall(item.text_func)
                if label_ok and type(value)=="string"then label=value end
            end
            local enabled=item.enabled~=false
            if enabled and type(item.enabled_func)=="function"then
                local enabled_ok,value=pcall(item.enabled_func)
                enabled=enabled_ok and not not value
            end
            entries[#entries+1]={id=id,text=label,enabled=source.context_plugin and true or not not enabled,
                item=source.context_plugin and {}or item,plugin=source.plugin,
                context_plugin=source.context_plugin}
            current[id]=true
        end
    end
    -- Retain discovered names through temporary UI-context gaps, without
    -- retaining callbacks bound to an old reader or filemanager instance.
    -- Keep only strings in the persistent catalog. ReaderUI replaces and closes
    -- FileManager, so callbacks from that previous UI must never be retained.
    self._known_entries=self._known_entries or G_reader_settings:readSetting("slate.quicklaunch_catalog",{})
    if type(self._known_entries)~="table"then self._known_entries={}end
    local catalog_changed=false
    local enabled_names,disabled_names={},{}
    for _,definition in pairs(loader.enabled_plugins or {})do if type(definition)=="table"then enabled_names[definition.name or ""]=true end end
    for _,definition in pairs(loader.disabled_plugins or {})do if type(definition)=="table"then disabled_names[definition.name or ""]=true end end
    local catalog_known=type(loader.enabled_plugins)=="table"
    for _,entry in ipairs(entries)do
        local name=entry.plugin and canonicalName(entry.plugin)
        local previous=self._known_entries[entry.id]
        if not previous or previous.text~=entry.text or previous.name~=name then catalog_changed=true end
        self._known_entries[entry.id]={text=entry.text,name=name}
    end
    for id,known in pairs(self._known_entries)do
        local definition=by_name[normalized(known.name)]
        if definition then known.name=definition.name end
        if disabled_names[known.name or ""]or(catalog_known and known.name and not enabled_names[known.name])then
            self._known_entries[id]=nil
            catalog_changed=true
        elseif not current[id]then
            entries[#entries+1]={id=id,text=known.text,enabled=true,item={},
                context_plugin=known.name,unavailable=not known.name}
            current[id]=true
        end
    end
    -- Also discover context-gated plugins on a cold start directly into a book,
    -- before this process has ever displayed their file-browser menu entries.
    local represented={}
    for _,entry in ipairs(entries)do
        represented[entry.context_plugin or entry.plugin and canonicalName(entry.plugin)or ""]=true
    end
    for _,definition in pairs(loader.enabled_plugins or {})do
        local name=type(definition)=="table"and definition.name
        if name and name~="slate"and not represented[name]and not current[name]
            and type(definition.addToMainMenu)=="function"and not definition.is_doc_only then
            entries[#entries+1]={id=name,text=definition.fullname or name,enabled=true,
                item={},context_plugin=name}
        end
    end
    if catalog_changed then
        G_reader_settings:saveSetting("slate.quicklaunch_catalog",self._known_entries)
        G_reader_settings:flush()
    end
    return sortEntries(entries)
end

function QuickLaunch:getEntries(owner, section)
    local selected, entries = {}, {}
    for _, id in ipairs(selectedIds(section)) do
        if type(id) == "string" then selected[id] = true end
    end
    for _, entry in ipairs(self:getAvailableEntries(owner)) do
        if selected[entry.id] or entry.plugin and selected[entry.plugin.name] then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

function QuickLaunch:launch(owner, entry)
    if not entry or entry.enabled==false then return end
    if entry and entry.system_action then
        if entry.system_action=="restart"or entry.system_action=="exit"then
            local event=entry.system_action=="restart"and "Restart"or "Exit"
            self:close(owner)
            UIManager:nextTick(function()
                UIManager:broadcastEvent(require("ui/event"):new(event))
            end)
            return
        end
        require("slate_system"):open(owner,entry.system_action)
        return
    end
    if entry and entry.context_plugin then
        return self:launchInFileManager(owner,entry)
    end
    if entry and entry.unavailable then
        UIManager:show(SlateUtils:themePopup(InfoMessage:new{modal=true,
            text=_("This plugin is unavailable in the current KOReader view. Open the KOReader file browser and try again."),
        }))
        return
    end
    if not entry or not entry.enabled then return end
    self:close(owner)
    local screen = owner._slate_screen
    local special_gui=entry.id=="crossword" and entry.plugin and type(entry.plugin.showQuickMenu)=="function"
    local menu_only=not special_gui and type(entry.item.callback)~="function" and (type(entry.item.sub_item_table)=="table" or type(entry.item.sub_item_table_func)=="function")
    if screen and not menu_only then ScreenSaverWidget.onClose(screen) end

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
                if type(items) ~= "table" then
                    error("Quick launch menu is unavailable")
                end
                local menu_items={{text=tostring(entry.text),enabled=false,separator=true}}
                for _,item in ipairs(items)do menu_items[#menu_items+1]=item end
                require("slate_settings"):showEditor(owner,menu_items)
            end
        end)

        if not ok then
            logger.warn("Slate: could not quick launch plugin:", entry.id, err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open this plugin."),
            })
        end
    end)
end

function QuickLaunch:launchInFileManager(owner,entry)
    self:close(owner)
    if owner._slate_screen then ScreenSaverWidget.onClose(owner._slate_screen)end
    UIManager:nextTick(function()
        local ok,err=pcall(function()
            local ReaderUI=require("apps/reader/readerui")
            local FileManager=require("apps/filemanager/filemanager")
            if ReaderUI.instance then
                -- Native onHome saves reading position and tears down the old
                -- plugin instances before creating the file-browser instances.
                ReaderUI.instance:onHome()
            elseif not FileManager.instance then FileManager:showFiles()end
            local ui=FileManager.instance
            if not ui then error("File browser did not open")end
            local current_owner=ui.slate or {ui=ui}
            for _,fresh in ipairs(self:getAvailableEntries(current_owner))do
                if not fresh.context_plugin and fresh.enabled and
                    (fresh.id==entry.id or fresh.plugin and fresh.plugin.name==entry.context_plugin)then
                    self:launch(current_owner,fresh)
                    return
                end
            end
            error("Plugin did not register a file-browser menu")
        end)
        if not ok then
            logger.warn("Slate: context launch failed:",entry.context_plugin,err)
            UIManager:show(InfoMessage:new{modal=true,text=_("This plugin could not be opened. Check that it is enabled in KOReader.")})
        end
    end)
end

local QuickLaunchPopup = InputContainer:extend{ modal = true }

function QuickLaunchPopup:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Screen:getSize()
    self.section = self.section or G_reader_settings:readSetting("slate.quicklaunch_page", "games")
    if self.section ~= "apps" and self.section ~= "system" then self.section = "games" end
    if self.selection_mode and self.section=="system" then self.section="apps"end
    local available = QuickLaunch:getAvailableEntries(self.owner)
    local lists = {games={},apps={},system={
        {id="slate.system.wifi",text=_("Wi-Fi"),enabled=true,system_action="wifi"},
        {id="slate.system.bluetooth",text=_("Bluetooth"),enabled=true,system_action="bluetooth"},
        {id="slate.system.restart",text=_("Restart KOReader"),enabled=not Device.canRestart or Device:canRestart(),system_action="restart"},
        {id="slate.system.exit",text=_("Exit KOReader"),enabled=true,system_action="exit"},
    }}
    for _, section in ipairs({"games","apps"}) do
        local selected = {}
        for _,id in ipairs(selectedIds(section)) do selected[id]=true end
        for _,entry in ipairs(available) do
            if selected[entry.id] or entry.plugin and selected[entry.plugin.name] then lists[section][#lists[section]+1]=entry end
        end
    end
    self.entries = self.selection_mode and available or lists[self.section]
    self.layout_lists = self.selection_mode and {available} or {lists.games,lists.apps,lists.system}
    self.column_count = not self.selection_mode and #self.entries > 12 and 3 or 2
    local largest_rows = self.selection_mode and math.ceil(#available / 2)
        or math.max(2,math.ceil(#lists.games / (#lists.games > 12 and 3 or 2)), math.ceil(#lists.apps / (#lists.apps > 12 and 3 or 2)))
    self.pending = {}

    if self.selection_mode then
        for _, id in ipairs(selectedIds(self.section)) do
            self.pending[id] = true
        end
        for _,entry in ipairs(available)do
            if entry.plugin and self.pending[entry.plugin.name]then self.pending[entry.id]=true end
        end
    end

    local layout = SlateUtils.slate_popup_layout
    if layout and layout.owner ~= self.owner then layout = nil end
    local slate_screen = self.owner and self.owner._slate_screen
    local lock = slate_screen and slate_screen.lock_button
    local region_top = lock and lock.y + lock.h or 0
    local card = self.owner and self.owner._slate_card_bounds
    local region_bottom = card and card.y or (layout and layout.bottom) or h
    local edge = math.max(8, Screen:scaleBySize(10))
    local max_height = math.min(h * 0.85,
        math.max(1, region_bottom - region_top - edge * 2))

    self.page = 1
    self.row_h = math.max(24, Screen:scaleBySize(32))
    self.box = {
        w = math.min(math.floor(w * 0.96), Screen:scaleBySize(900)),
    }
    self.pad = math.max(10, math.floor(self.box.w * 0.045))
    self.header_glyph_size = math.max(16,math.min(200,
        tonumber(G_reader_settings:readSetting("slate.popup_header_icon_size",72)) or 72))
    self.header_icon_size = G_reader_settings:readSetting("slate.popup_header_outline",false)==true
        and math.floor(self.header_glyph_size/.58+.5) or self.header_glyph_size
    self.title_h = math.floor(self.row_h * 1.5)
    if not self.selection_mode and G_reader_settings:readSetting("slate.popup_header_icons",true)==true then
        self.title_h=math.max(self.title_h,self.header_icon_size)
    end
    local list_gap = math.floor(math.max(8, Screen:scaleBySize(14)) * 1.8 + 0.5)
    self.title_gap = list_gap
    self.footer_gap = list_gap * 2
    self.warning_h = self.selection_mode and self.row_h * 2 or 0

    local max_rows = math.max(1, math.floor(
        (max_height - self.pad * 2 - self.title_h - self.title_gap
            - self.warning_h - self.row_h * 2
            - (not self.selection_mode and self.footer_gap or 0)) / self.row_h))

    self.frame_rows = math.min(max_rows,
        math.max(1, largest_rows))
    self.row_count = not self.selection_mode and self.section=="system"
        and math.min(2,self.frame_rows)or self.frame_rows
    self.page_size = self.row_count * self.column_count
    self.pages = math.max(1, math.ceil(#self.entries / self.page_size))
    self.frame_pager_reserved = largest_rows > self.frame_rows
    self.pager_reserved = self.frame_pager_reserved and self.section~="system"

    self.box.h = self.pad * 2 + self.title_h + self.title_gap + self.warning_h
        + self.frame_rows * self.row_h
        + (self.frame_pager_reserved and self.row_h or 0)
        + self.row_h + (not self.selection_mode and self.footer_gap or 0)

    self.box.x = math.floor((w - self.box.w) / 2)
    self.box.y = math.max(0, math.floor(
        region_top + (region_bottom - region_top - self.box.h) / 2))
    self.font_size = 18

    self.ges_events = {
        Hold = {GestureRange:new{ges="hold",range=Geom:new{x=0,y=0,w=w,h=h}}},
        HoldRelease = {GestureRange:new{ges="hold_release",range=Geom:new{x=0,y=0,w=w,h=h}}},
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = w, h = h },
            },
        },
        Swipe = {
            GestureRange:new{
                ges = "swipe",
                range = Geom:new{ x = 0, y = 0, w = w, h = h },
            },
        },
    }

    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end
end

function QuickLaunchPopup:paintTo(bb)
    local r, row = self.box, self.row_h
    local popup_radius = math.max(0, math.min(60, tonumber(
        G_reader_settings:readSetting("slate.popup_corner_radius", 40)) or 40))
    local button_radius = math.max(0, math.min(60, tonumber(
        G_reader_settings:readSetting("slate.button_corner_radius", 40)) or 40))
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE, popup_radius)
    bb:paintBorder(r.x, r.y, r.w, r.h, 2, Blitbuffer.COLOR_BLACK, popup_radius)

    local x, width = r.x + self.pad, r.w - self.pad * 2
    local title = {
        x = x,
        y = r.y + self.pad,
        w = width,
        h = self.title_h,
    }

    self.add_button = nil
    if not self.selection_mode and self.section~="system" then
        local size = math.min(row, self.title_h)
        local glyph_size = math.max(1, math.floor(self.header_icon_size))
        local inset = G_reader_settings:readSetting("slate.popup_header_icons", true) == true
            and math.floor((self.header_icon_size - glyph_size) / 2) or 0
        self.add_button = {
            x = x + width - size - inset,
            y = title.y + math.floor((self.title_h - size) / 2),
            w = size,
            h = size,
        }

        local icon
        local ok = pcall(function()
            icon = ImageWidget:new{
                file = module_dir .. "icons/menu.svg",
                width = size, height = size, alpha = true,
                original_in_nightmode = false, invert = false,
            }
            icon:paintTo(bb, self.add_button.x, self.add_button.y)
        end)
        if icon then icon:free() end
        if not ok then
            drawText(bb, "≡", self.add_button, self.font_size + 8, true, true)
        end

        title.x = x + size + self.pad
        title.w = math.max(1, width - (size + self.pad) * 2)
    end

    self.rows, self.buttons = {}, {}
    local first = (self.page - 1) * self.page_size + 1
    local count = math.min(self.page_size, #self.entries - first + 1)
    local columns = self.column_count
    local rows_per_column = math.max(1, math.ceil(count / columns))
    local column_gap = math.max(8, math.floor(width * 0.055))
    local column_w = math.floor((width - column_gap * (columns - 1)) / columns)
    local list_y = title.y + self.title_h + self.title_gap

    if self.selection_mode then
        drawText(bb, self.section == "games"
            and _("Select game plugins for GAMES.") or _("Select plugins for APPS."),
            { x = x, y = list_y, w = width, h = row },
            self.font_size - 2, true, true)
        drawText(bb, _("Some plugins may not support direct launch. Tap APPLY to save."),
            { x = x, y = list_y + row, w = width, h = row },
            self.font_size - 2, false, true)
        list_y = list_y + self.warning_h
    end

    -- Center each column as a group while keeping a shared left edge.
    local column_widths = {}
    for column = 1, columns do column_widths[column] = 0 end
    local entry_font_sizes = {}

    for i = 1, count do
        local entry = self.entries[first + i - 1]
        local column = math.floor((i - 1) / rows_per_column) + 1
        local label = (
            self.selection_mode
                and (self.pending[entry.id] and "[✓] " or "[ ] ")
                or "[ "
        ) .. tostring(entry.text):upper()
            .. (self.selection_mode and "" or " ]")

        for font_size = self.font_size, 6, -1 do
            local widget = TextWidget:new{
                text = label,
                face = Font:getFace("cfont", font_size),
            }
            local dim = widget:getSize()
            widget:free()

            if (dim.h <= row - 8 and dim.w <= column_w)
                or font_size == 6 then
                entry_font_sizes[i] = font_size
                column_widths[column] = math.max(
                    column_widths[column], math.min(dim.w, column_w))
                break
            end
        end
    end

    -- Use a shared font across both tabs and all pages.
    -- Font:getFace scales for device DPI. Long labels truncate individually;
    -- a changing server address must not shrink every launcher item.
    local shared_font=self.font_size
    local reference_width=math.max(1,math.floor((width-column_gap*2)/3))
    for candidate=self.font_size,12,-1 do
        local sample=TextWidget:new{text="[ MAHJONG SOLITAIRE ]",face=Font:getFace("cfont",candidate)}
        local dim=sample:getSize();sample:free()
        if(dim.w<=reference_width and dim.h<=row-8)or candidate==12 then shared_font=candidate;break end
    end
    for i=1,count do entry_font_sizes[i]=shared_font end
    -- Use the same column anchors on both tabs and every page.
    column_widths = {}
    for column = 1, columns do column_widths[column] = 0 end
    -- System displays two rows inside the shared taller frame. Measure plugin
    -- columns using that frame's capacity, as Apps does, rather than System's
    -- four-item page size; otherwise their text anchors shift between tabs.
    local anchor_page_size = self.frame_rows and self.frame_rows * columns or self.page_size
    -- Three-column tabs measure their own labels. A long name in Apps must
    -- not move the Games columns toward the left edge.
    local anchor_lists = columns == 3 and {self.entries} or self.layout_lists
    for _, list in ipairs(anchor_lists) do
        for index, entry in ipairs(list) do
            local first_index = math.floor((index-1)/anchor_page_size)*anchor_page_size+1
            local page_count = math.min(anchor_page_size,#list-first_index+1)
            local column = math.floor((index-first_index) / math.max(1, math.ceil(page_count/columns))) + 1
            local label = self.selection_mode and "[✓] "..tostring(entry.text):upper()
                or "[ "..tostring(entry.text):upper().." ]"
            local widget=TextWidget:new{text=label,face=Font:getFace("cfont",shared_font),max_width=column_w,truncate_with_ellipsis=true}
            local dim=widget:getSize();widget:free()
            column_widths[column]=math.max(column_widths[column],math.min(dim.w,column_w))
        end
    end

    local grid_width=columns*column_w+(columns-1)*column_gap
    local column_offsets = {}
    if columns == 3 then
        -- Center the visible columns together, rather than centering empty
        -- full-width cells whose left-aligned text can look off-center.
        grid_width = 0
        for column = 1, columns do
            column_offsets[column] = grid_width
            grid_width = grid_width + column_widths[column]
            if column < columns then grid_width = grid_width + column_gap end
        end
    end
    local grid_x=x+math.floor((width-grid_width)/2)

    if self.selection_mode then
        local tx, tw = drawText(bb,
            self.section == "apps" and _("SELECT APPS") or _("SELECT GAMES"),
            title, self.font_size + 2, true, true)
        bb:paintRect(tx,title.y+self.title_h-math.floor(row*0.20),tw,1,Blitbuffer.COLOR_BLACK)
    else
        local header_x = x
        if G_reader_settings:readSetting("slate.popup_header_icons",true)==true then
            local size=self.header_icon_size
            local rect={x=header_x,y=title.y+math.floor((self.title_h-size)/2),w=size,h=size}
            local path=QuickLaunch:getIconPath(self.section)
            local image
            local outline=G_reader_settings:readSetting("slate.popup_header_outline",false)==true
            if type(path)=="string" and path~="" then
                local ok = pcall(function()
                    local icon_size=self.header_glyph_size
                    self:paintHeaderCircle(bb,rect)
                    if self.section=="system"then
                        image=IconWidget:new{icon="appbar.settings",width=icon_size,height=icon_size,
                            alpha=true,original_in_nightmode=false,invert=false}
                    else
                        image=ImageWidget:new{file=path,width=icon_size,height=icon_size,
                            alpha=true,original_in_nightmode=false,invert=false}
                    end
                    image:paintTo(bb,rect.x+math.floor((size-icon_size)/2),rect.y+math.floor((size-icon_size)/2))
                end)
                if image then image:free() end
                if not ok then QuickLaunch:paintButton(bb,rect,math.max(1,math.floor(size/14)),nil,nil,false,nil,outline,self.section,self.header_glyph_size/size) end
            else
                QuickLaunch:paintButton(bb,rect,math.max(1,math.floor(size/14)),nil,nil,false,nil,outline,self.section,self.header_glyph_size/size)
            end
            header_x=header_x+size+Screen:scaleBySize(16)
        end
        if G_reader_settings:readSetting("slate.popup_header_text",true)==true then
            local text_rect={x=header_x,y=title.y,
                w=math.max(1,(self.add_button and self.add_button.x-self.pad or x+width)-header_x),h=self.title_h}
            drawText(bb,self.section=="system"and _("SYSTEM")or self.section == "apps" and _("APPS QUICK LAUNCH")
                or _("GAMES QUICK LAUNCH"),text_rect,self.font_size+2,true,false)
        end
    end

    for i = 1, count do
        local entry = self.entries[first + i - 1]
        local column = math.floor((i - 1) / rows_per_column)
        local index = (i - 1) % rows_per_column

        local rect = {
            x = grid_x + (column_offsets[column + 1] or column * (column_w + column_gap)),
            y = list_y + index * row,
            w = columns == 3 and column_widths[column + 1] or column_w,
            h = row,
        }
        self.rows[#self.rows + 1] = {
            rect = rect,
            entry = entry,
        }

        local label = (
            self.selection_mode
                and (self.pending[entry.id] and "[✓] " or "[ ] ")
                or "[ "
        ) .. tostring(entry.text):upper()
            .. (self.selection_mode and "" or " ]")

        local inset = columns == 3 and 0 or math.max(0,
            math.floor((column_w - column_widths[column + 1]) / 2))
        local text_rect = {
            x = rect.x + inset,
            y = rect.y,
            w = rect.w - inset,
            h = rect.h,
        }

        drawText(bb, label, text_rect, entry_font_sizes[i] or self.font_size,
            false, false, self.selection_mode or entry.enabled,nil,true)
    end

    if count == 0 then
        drawText(bb,
            self.selection_mode and _("No plugins available.")
                or _("Tap the menu icon to select plugins."),
            { x = x, y = list_y, w = width, h = row },
            self.font_size, false, true)
    end

    if self.pager_reserved then
        local y = list_y + self.row_count * row
        self.buttons = {
            {
                x = x,
                y = y,
                w = math.floor(width / 3),
                h = row,
            },
            {
                x = x + math.floor(width * 2 / 3),
                y = y,
                w = math.floor(width / 3),
                h = row,
            },
        }
        drawText(bb, "‹", self.buttons[1], self.font_size, true, true, self.page>1)
        drawText(bb, "›", self.buttons[2], self.font_size, true, true, self.page<self.pages)
        drawText(bb, tostring(self.page) .. " / " .. tostring(self.pages), {
            x = x + math.floor(width / 3),
            y = y,
            w = math.floor(width / 3),
            h = row,
        }, self.font_size - 2, false, true)
    end

    self.apply_button = nil
    if self.selection_mode then
        self.apply_button = {
            x = x,
            y = list_y + self.row_count * row
                + (self.pager_reserved and row or 0),
            w = width,
            h = row,
        }
        bb:paintBorder(self.apply_button.x, self.apply_button.y,
            self.apply_button.w, self.apply_button.h,
            1, Blitbuffer.COLOR_BLACK, button_radius)
        drawText(bb, _("APPLY"), self.apply_button,
            self.font_size, true, true)
    end
    self.tab_buttons = {}
    if not self.selection_mode then
        local tab_y = list_y+self.frame_rows*row+(self.frame_pager_reserved and row or 0)+self.footer_gap
        local gap=math.max(8,Screen:scaleBySize(8))
        local tab_w=math.floor((width-gap*2)/3)
        for i, name in ipairs({_('GAMES'),_('APPS'),_('SYSTEM')}) do
            local rect={x=x+(i-1)*(tab_w+gap),y=tab_y,w=tab_w,h=row}
            self.tab_buttons[i]=rect
            local active=SECTIONS[i]==self.section
            local fg=active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            local bg=active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            bb:paintRoundedRect(rect.x,rect.y,rect.w,rect.h,bg,button_radius)
            bb:paintBorder(rect.x,rect.y,rect.w,rect.h,1,Blitbuffer.COLOR_BLACK,button_radius)
            local inset=math.max(4,Screen:scaleBySize(4))
            drawText(bb,name,{x=rect.x+inset,y=rect.y+inset,w=rect.w-inset*2,h=rect.h-inset*2},
                self.font_size,true,true,true,fg)
        end
    end
    self:updateTouchTargets()
end

function QuickLaunchPopup:updateTouchTargets()
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
    add(self.add_button)
    add(self.apply_button)
    for _,rect in ipairs(self.tab_buttons or {}) do add(rect) end
    for _,rect in ipairs(self.buttons or {}) do add(rect) end
    for _,row in ipairs(self.rows or {}) do add(row.rect) end
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

function QuickLaunchPopup:touchRect(rect)
    for _, target in ipairs(self.touch_targets or {}) do
        if target.original == rect then return target.rect end
    end
    return rect
end

function QuickLaunchPopup:paintHeaderCircle(bb,rect)
    local radius=math.floor(rect.w/2)
    bb:paintRoundedRect(rect.x,rect.y,rect.w,rect.h,Blitbuffer.COLOR_WHITE,radius)
    if G_reader_settings:readSetting("slate.popup_header_outline",false)==true then
        bb:paintBorder(rect.x,rect.y,rect.w,rect.h,math.max(1,math.floor(rect.w/14)),Blitbuffer.COLOR_BLACK,radius)
    end
end

function QuickLaunchPopup:onHold(_,ges)
    if not contains(self.box,ges and ges.pos)then
        require('slate_popup_navigation'):switch(self,self.owner,ges,'hold')
    end
    return true
end
function QuickLaunchPopup:onHoldRelease()return true end

function QuickLaunchPopup:onTap(_, ges)
    local pos = ges and ges.pos
    if not contains(self.box,pos)then
        if require('slate_popup_navigation'):switch(self,self.owner,ges)then return true end
        return self:onClose()
    end

    if contains(self:touchRect(self.add_button), pos) then
        QuickLaunch:showSelection(self.owner, self.section)
        return true
    end

    for i, rect in ipairs(self.tab_buttons or {}) do
        if contains(self:touchRect(rect), pos) then
            local section = SECTIONS[i]
            if section ~= self.section then
                self.section=section
                G_reader_settings:saveSetting("slate.quicklaunch_page", section)
                G_reader_settings:flush()
                self:init()
                UIManager:setDirty(self,"ui")
                if self.owner._slate_screen then UIManager:setDirty(self.owner._slate_screen,"ui") end
            end
            return true
        end
    end
    for _, row in ipairs(self.rows or {}) do
        if contains(self:touchRect(row.rect), pos) then
            if self.selection_mode then
                self.pending[row.entry.id] = not self.pending[row.entry.id]
                UIManager:setDirty(self, "ui")
            else
                QuickLaunch:launch(self.owner, row.entry)
            end
            return true
        end
    end

    if self.selection_mode and contains(self:touchRect(self.apply_button), pos) then
        local ids = {}
        for _, entry in ipairs(self.entries) do
            if self.pending[entry.id] then
                ids[#ids + 1] = entry.id
            end
        end

        G_reader_settings:saveSetting(selectionKey(self.section), ids)
        G_reader_settings:flush()
        self:onClose()

        local popup = self.owner._slate_quicklaunch_popup
        if popup then
            popup:init()
            UIManager:setDirty(popup, "ui")
        end
        return true
    end

    for i, rect in ipairs(self.buttons or {}) do
        if contains(self:touchRect(rect), pos) then
            if i == 1 then
                self.page = math.max(1, self.page - 1)
            else
                self.page = math.min(self.pages, self.page + 1)
            end
            UIManager:setDirty(self, "ui")
            return true
        end
    end

    return true
end

function QuickLaunchPopup:onSwipe(_, ges)
    if not ges or not contains(self.box, ges.pos) then return true end

    if not self.selection_mode and (ges.direction=="west" or ges.direction=="east") then
        local index=1
        for i,name in ipairs(SECTIONS)do if name==self.section then index=i;break end end
        local section=SECTIONS[math.max(1,math.min(#SECTIONS,index+(ges.direction=="west"and 1 or -1)))]
        if section~=self.section then
            self.section=section;self.page=1
            G_reader_settings:saveSetting("slate.quicklaunch_page",section)
            G_reader_settings:flush()
            self:init()
            if self.owner._slate_screen then UIManager:setDirty(self.owner._slate_screen,"ui") end
        end
    elseif ges.direction == "north" or ges.direction == "west" then
        self.page = math.min(self.pages, self.page + 1)
    elseif ges.direction == "south" or ges.direction == "east" then
        self.page = math.max(1, self.page - 1)
    end

    UIManager:setDirty(self, "ui")
    return true
end

function QuickLaunchPopup:onClose()
    UIManager:close(self)
    return true
end

function QuickLaunchPopup:onCloseWidget()
    if self.owner._slate_quicklaunch_popup == self then
        self.owner._slate_quicklaunch_popup = nil
        local system=package.loaded.slate_system
        if system then system:close(self.owner)end
    end
    if self.owner._slate_quicklaunch_picker == self then
        self.owner._slate_quicklaunch_picker = nil
    end
    UIManager:setDirty(nil, "ui")
end

function QuickLaunch:show(owner)
    if owner._slate_quicklaunch_popup then return end
    owner._slate_quicklaunch_popup = SlateUtils:themePopup(QuickLaunchPopup:new{ owner = owner })
    UIManager:show(owner._slate_quicklaunch_popup, "ui")
end

function QuickLaunch:showSelection(owner, section)
    if owner._slate_quicklaunch_picker then return end
    owner._slate_quicklaunch_picker = SlateUtils:themePopup(QuickLaunchPopup:new{
        owner = owner,
        selection_mode = true,
        section = section or (owner._slate_quicklaunch_popup and owner._slate_quicklaunch_popup.section)
            or G_reader_settings:readSetting("slate.quicklaunch_page", "games"),
    })
    UIManager:show(owner._slate_quicklaunch_picker, "ui")
end

function QuickLaunch:close(owner)
    local system=package.loaded.slate_system
    if system then system:close(owner)end
    if owner._slate_quicklaunch_popup then
        UIManager:close(owner._slate_quicklaunch_popup)
    end
    if owner._slate_quicklaunch_picker then
        UIManager:close(owner._slate_quicklaunch_picker)
    end
end

return QuickLaunch
