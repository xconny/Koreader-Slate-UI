-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-09.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local QuoteWidget = require("slate_quote_widget")
local Screen = require("device").screen
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local Font = require("ui/font")
local SlateUtils = require("slate_utils")
local util = require("util")

local SETTINGS_NS = "slate.quotes"

local function read_setting(k, def)
    return G_reader_settings:readSetting(SETTINGS_NS .. "." .. k, def)
end

local function write_setting(k, v)
    G_reader_settings:saveSetting(SETTINGS_NS .. "." .. k, v)
    G_reader_settings:flush()
end

local active_quote_widget
local module_source = debug.getinfo(1, "S").source
local plugin_dir = module_source:sub(1, 1) == "@"
    and (module_source:sub(2):match("(.*/)") or "") or ""
local extraction_cache = {}
local automatic_running = false
local last_automatic_error
local automatic_owner
local automatic_timer

local plugin_font_face_name = read_setting(
    "font_face", G_reader_settings:readSetting("cre_font") or "infofont")
local plugin_font_size = tonumber(read_setting("font_size", 18)) or 18
local plugin_book_dir = read_setting("book_dir", "/mnt/us/Books")

local plugin_title_mode = read_setting("title_mode", "default")
local plugin_title_custom = read_setting("title_custom", "Quote from Library")

local filter_mode = read_setting("filter_mode", "random")
local tagged_index=1
if filter_mode ~= "book" and filter_mode ~= "books" and filter_mode ~= "tags" then
    filter_mode = "random"
end

local selected_book = read_setting("selected_book", "")
local selected_books = read_setting("selected_books", {})
if type(selected_book) ~= "string" then selected_book = "" end
if type(selected_books) ~= "table" then selected_books = {} end

local function book_name(entry)
    if type(entry) ~= "table" then return "" end
    return tostring(entry.book or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function get_book_choices(messages)
    local counts, choices = {}, {}
    for _, entry in ipairs(messages) do
        local name = book_name(entry)
        if name ~= "" then
            counts[name] = (counts[name] or 0) + 1
        end
    end
    for name, count in pairs(counts) do
        choices[#choices + 1] = { name = name, count = count }
    end
    table.sort(choices, function(a, b)
        local al, bl = a.name:lower(), b.name:lower()
        return al == bl and a.name < b.name or al < bl
    end)
    return choices
end

local function filter_quotes(messages)
    if filter_mode == "random" then return messages end
    if filter_mode == "tags" then
        local all=read_setting("tagged_quotes",{});local selected=read_setting("selected_tags",{});local result={}
        for _,record in pairs(type(all)=="table" and all or {})do
            if type(record)=="table" and type(record.tags)=="table" and type(record.entry)=="table" then
                local include=not next(selected)
                for name in pairs(record.tags)do if selected[name]then include=true end end
                if include and next(record.tags)then result[#result+1]=record.entry end
            end
        end
        table.sort(result,function(a,b)return (tostring(a.book)..a.text):lower()<(tostring(b.book)..b.text):lower()end)
        return result
    end

    local allowed, result = {}, {}
    if filter_mode == "book" then
        allowed[selected_book] = true
    else
        for _, name in ipairs(selected_books) do
            if type(name) == "string" then
                allowed[name] = true
            end
        end
    end

    for _, entry in ipairs(messages) do
        local name = book_name(entry)
        if name ~= "" and allowed[name] then
            result[#result + 1] = entry
        end
    end
    return result
end

local function plugin_get_face()
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if ok and cre
        and type(cre.getFontFaceFilenameAndFaceIndex) == "function" then
        local font_filename, font_faceindex =
            cre.getFontFaceFilenameAndFaceIndex(plugin_font_face_name)
        if font_filename then
            return Font:getFace(
                font_filename, plugin_font_size, font_faceindex)
        end
    end
    return Font:getFace(plugin_font_face_name, plugin_font_size)
end

local function load_quotes()
    local source = debug.getinfo(1, "S").source
    local plugin_dir = ""
    if source:sub(1, 1) == "@" then
        local this_path = source:sub(2)
        plugin_dir = this_path:match("(.*/)") or ""
    end
    local quotes_path = plugin_dir .. "slate_quote_data.lua"

    local ok, t = pcall(function()
        local fn, err = loadfile(quotes_path)
        if not fn then error(err) end
        return fn()
    end)
    if ok and type(t) == "table" and #t > 0 then
        return t
    end

    return {
        { text = _("Hello, reader!"), book = "", author = "" },
        { text = _("Stay focused."), book = "", author = "" },
        { text = _("Time to read."), book = "", author = "" },
        { text = _("Random wisdom incoming…"), book = "", author = "" },
    }
end

local function get_title_text()
    if plugin_title_mode == "none" then return nil end

    if plugin_title_mode == "custom" then
        return plugin_title_custom or ""
    end

    if filter_mode == "book" and selected_book ~= "" then
        return string.format(_("Random quote in %s"), selected_book)
    elseif filter_mode == "books" then
        return _("Random quote from selected books")
    end
    return _("Quote from Library")
end

local show_quote_now
local show_widget
local apply_filter

show_widget = function(widget)
    if active_quote_widget then
        UIManager:close(active_quote_widget)
    end

    local original_close = widget.onCloseWidget
    widget.onCloseWidget = function(this, ...)
        if active_quote_widget == this then
            active_quote_widget = nil
        end
        if original_close then
            return original_close(this, ...)
        end
    end

    active_quote_widget = widget
    UIManager:show(widget,"ui")
    UIManager:setDirty(nil,"ui")
    if UIManager.forceRePaint then UIManager:forceRePaint()end
end

local function make_quote_widget(entry, page_index, opts)
    opts = opts or {}
    page_index = page_index or 1

    local normalized_entry
    if type(entry) == "table" then
        normalized_entry = {
            text = tostring(entry.text or ""),
            book = tostring(entry.book or ""),
            author = tostring(entry.author or ""),
            file = entry.file, pos0 = entry.pos0, page = entry.page,
        }
    else
        normalized_entry = {
            text = tostring(entry or ""),
            book = "",
            author = "",
        }
    end

    local widget
    widget = QuoteWidget:new{
        entry = normalized_entry,
        face = plugin_get_face(),
        quote_font_size = plugin_font_size,
        title_text = get_title_text(),
        initial_page = page_index,
        timeout = opts.timeout,
        filter_mode = filter_mode,
        book_choices = get_book_choices(load_quotes()),
        selected_book = selected_book,
        selected_books = selected_books,
        on_filter_change = function(mode, selection)
            return apply_filter(mode, selection)
        end,
        tagged_index=filter_mode=="tags" and tagged_index or nil,
        tagged_total=filter_mode=="tags" and #filter_quotes(load_quotes()) or nil,
        on_tag_turn=function(delta)
            local total=#filter_quotes(load_quotes())
            tagged_index=math.max(1,math.min(math.max(1,total),tagged_index+delta))
            UIManager:close(widget);show_quote_now();return true
        end,
        on_new_quote = function()
            if filter_mode=="tags" then tagged_index=tagged_index%math.max(1,#filter_quotes(load_quotes()))+1 end
            UIManager:close(widget)
            show_quote_now()
        end,
        on_page_change = function(same_entry, new_page)
            UIManager:close(widget)
            show_widget(make_quote_widget(same_entry, new_page, opts))
        end,
    }
    return widget
end

apply_filter = function(mode, selection)
    if mode ~= "random" and mode ~= "book" and mode ~= "books" and mode ~= "tags" then
        return false
    end

    local available = {}
    for _, book in ipairs(get_book_choices(load_quotes())) do
        available[book.name] = true
    end

    if mode == "book" then
        if type(selection) ~= "string" or not available[selection] then
            return false
        end
        selected_book = selection
        write_setting("selected_book", selected_book)
    elseif mode == "books" then
        if type(selection) ~= "table" then return false end

        local names, seen = {}, {}
        for _, name in ipairs(selection) do
            if type(name) == "string"
                and available[name] and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end

        if #names == 0 then return false end
        selected_books = names
        write_setting("selected_books", selected_books)
    end

    if mode=="tags" then tagged_index=1 end
    filter_mode = mode
    write_setting("filter_mode", filter_mode)
    G_reader_settings:flush()

    if active_quote_widget then
        UIManager:close(active_quote_widget)
    end
    show_quote_now()
    return true
end

show_quote_now = function()
    if active_quote_widget then return true end

    local messages = load_quotes()
    if filter_mode~="tags" and (type(messages) ~= "table" or #messages == 0) then
        return
    end

    local pool = filter_quotes(messages)
    local entry
    if #pool == 0 then
        entry = {
            text = _("No saved quotes match this selection. Choose RANDOM QUOTE, BOOK(S), or TAG(S) below."),
            book = "",
            author = "",
        }
    else
        if filter_mode=="tags" then tagged_index=math.max(1,math.min(#pool,tagged_index));entry=pool[tagged_index]
        else entry = pool[math.random(#pool)] end
    end

    show_widget(make_quote_widget(entry, 1))
    return true
end

local function show_sample()
    local msgs = filter_quotes(load_quotes())
    if type(msgs) == "table" and #msgs > 0 then
        local sample = msgs[math.random(#msgs)]
        show_widget(make_quote_widget(sample, 1, { timeout = 4 }))
    end
end

local SlateQuotes = {}

local function favouriteKey(entry)
    return tostring(entry.file or entry.book or '')..'\n'..tostring(entry.text or ''):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
end
function SlateQuotes:isFavourite(entry)
    local saved=read_setting('favourites',{})
    return type(saved)=='table' and saved[favouriteKey(entry)]~=nil
end
function SlateQuotes:toggleFavourite(entry)
    if not entry or not entry.text or entry.text=='' then return false end
    local saved=read_setting('favourites',{})
    if type(saved)~='table' then saved={} end
    local key=favouriteKey(entry)
    if saved[key] then saved[key]=nil else
        local author=entry.author or ''
        if type(author)=='table' then author=table.concat(author,', ') end
        saved[key]={text=entry.text,book=entry.book or '',author=author,file=entry.file,
            pos0=type(entry.pos0)=='string' and entry.pos0 or nil,page=entry.page}
    end
    write_setting('favourites',saved)
    return saved[key]~=nil
end
local function tagData(key)
    local value=read_setting(key,{})
    if type(value)~='table' then return {} end
    local result={}
    for key,item in pairs(value)do
        if type(key)=='string' then
            if key~='' and (type(item)=='table' or item==true)then result[key]=item end
        end
    end
    return result
end
local function tagNames()
    local registry=tagData('tags');local names={}
    for name in pairs(type(registry)=='table' and registry or {})do names[#names+1]=name end
    table.sort(names,function(a,b)return a:lower()<b:lower()end)
    return names
end
function SlateQuotes:hasTags(entry)
    local tagged=tagData('tagged_quotes')
    local record=type(tagged)=='table' and tagged[favouriteKey(entry)]
    return type(record)=='table' and type(record.tags)=='table' and next(record.tags)~=nil or false
end
function SlateQuotes:addTag(name,entry)
    name=tostring(name or ''):gsub('^%s+',''):gsub('%s+$','')
    if name=='' then return false end
    local registry=tagData('tags');registry[name]=true;write_setting('tags',registry)
    if entry and entry.text and entry.text~='' then
        local all=tagData('tagged_quotes');local key=favouriteKey(entry)
        local author=entry.author or ""
        if type(author)=="table" then author=table.concat(author,", ")end
        local record=type(all[key])=='table' and all[key] or {entry={text=entry.text,book=entry.book or "",author=author,file=entry.file,page=entry.page,pos0=entry.pos0},tags={}}
        record.tags=type(record.tags)=='table' and record.tags or {}
        record.tags[name]=true;all[key]=record;write_setting('tagged_quotes',all)
    end
    return true
end
function SlateQuotes:removeTag(name)
    local registry=tagData('tags');registry[name]=nil;write_setting('tags',registry)
    local selected=tagData('selected_tags');selected[name]=nil;write_setting('selected_tags',selected)
    local all=tagData('tagged_quotes')
    for key,record in pairs(all)do
        if type(record)=="table" and type(record.tags)=="table" then
            record.tags[name]=nil
            if not next(record.tags)then all[key]=nil end
        else all[key]=nil end
    end
    write_setting('tagged_quotes',all)
end
function SlateQuotes:newTag(entry,parent)
    local InputDialog=require('ui/widget/inputdialog');local dialog
    dialog=InputDialog:new{modal=true,title=_('New Tag'),input='',buttons={{{text=_('Cancel'),callback=function()UIManager:close(dialog)end},
        {text=_('Add'),is_enter_default=true,callback=function()
            if self:addTag(dialog:getInputText(),entry)then
                UIManager:close(dialog);UIManager:setDirty(nil,'ui')
                if UIManager.forceRePaint then UIManager:forceRePaint()end
            end
        end}}}}
    UIManager:show(SlateUtils:themePopup(dialog));UIManager:setDirty(nil,'ui');dialog:onShowKeyboard()
end
function SlateQuotes:editTags(entry,parent)
    local existing=tagData('tagged_quotes')[favouriteKey(entry)]
    local initial=type(existing)=='table' and type(existing.tags)=='table' and existing.tags or {}
    require('slate_quote_widget'):showTagPicker(parent,tagNames(),initial,function(names)
        local all=tagData('tagged_quotes');all[favouriteKey(entry)]=nil;write_setting('tagged_quotes',all)
        for _,name in ipairs(names)do self:addTag(name,entry)end
        UIManager:setDirty(nil,'ui')
        if UIManager.forceRePaint then UIManager:forceRePaint()end
    end)
end
function SlateQuotes:removeQuoteTags(entry,name)
    local all=tagData('tagged_quotes');local key=favouriteKey(entry);local record=all[key]
    local names={}
    if type(record)=='table' and type(record.tags)=='table' then
        for tag in pairs(record.tags)do names[#names+1]=tag end
    end
    table.sort(names)
    if not name and #names>1 then
        local items={}
        for index,tag in ipairs(names)do items[#items+1]={text=tag,callback=function()self:removeQuoteTags(entry,tag)end}end
        return require('slate_settings'):showEditor(automatic_owner or {},items)
    end
    if name and record then
        record.tags[name]=nil
        if not next(record.tags)then all[key]=nil end
    else all[key]=nil end
    write_setting('tagged_quotes',all)
    UIManager:setDirty(nil,'ui')
    if UIManager.forceRePaint then UIManager:forceRePaint()end
end
function SlateQuotes:tagQuote(entry,parent)
    if not entry or not entry.text or entry.text=='' then return end
    require('slate_quote_widget'):showTagMenuRows(parent,{
        {icon='switch.svg',text=_('Add/Edit Existing Tags'),callback=function()self:editTags(entry,parent)end},
        {icon='plus.svg',text=_('Create New Tag'),callback=function()self:newTag(entry,parent)end},
        {icon='trash.svg',text=_('Remove Tag'),callback=function()self:removeQuoteTags(entry)end},
    })
end
function SlateQuotes:viewTags()
    local owner=automatic_owner
    if owner and owner._slate_highlights_popup then owner._slate_highlights_popup:onClose()end
    return apply_filter("tags")
end
function SlateQuotes:selectTags()
    require('slate_quote_widget'):showTagPicker(active_quote_widget,tagNames(),tagData('selected_tags'),function(names)
        local selected={};for _,name in ipairs(names)do selected[name]=true end
        write_setting('selected_tags',selected);self:viewTags()
    end)
end
function SlateQuotes:manageTags()
    local items={{text=_('+ Add Tag'),callback=function()self:newTag()end}}
    for index,name in ipairs(tagNames())do
        items[#items+1]={text=_('− Remove Tag')..': '..name,callback=function()
            local ConfirmBox=require('ui/widget/confirmbox')
            UIManager:show(SlateUtils:themePopup(ConfirmBox:new{modal=true,text=_('Remove tag')..' “'..name..'”?',
                ok_callback=function()self:removeTag(name);UIManager:setDirty(nil,'ui')end}))
        end}
    end
    items[#items+1]={text=_('Apply'),_slate_apply=true,callback=function()end}
    require('slate_settings'):showEditor(automatic_owner or {},items)
end
function SlateQuotes:showTagsMenu(parent)
    require('slate_quote_widget'):showTagMenuRows(parent or active_quote_widget,{
        {icon='view.svg',text=_('View Tags'),callback=function()self:viewTags()end},
        {icon='switch.svg',text=_('Select Tags to View'),callback=function()self:selectTags()end},
        {icon='appbar.settings',text=_('Manage Tags'),callback=function()self:manageTags()end},
    })
end

function SlateQuotes:viewFavourites()
    local saved=read_setting('favourites',{})
    local results={}
    for _,entry in pairs(type(saved)=='table' and saved or {}) do
        if type(entry)=='table' and type(entry.text)=='string' then results[#results+1]=entry end
    end
    table.sort(results,function(a,b)
        local left=tostring(a.book)..'\n'..tostring(a.author)..'\n'..a.text
        local right=tostring(b.book)..'\n'..tostring(b.author)..'\n'..b.text
        return left:lower()<right:lower()
    end)
    if #results==0 then UIManager:show(SlateUtils:themePopup(InfoMessage:new{modal=true,text=_('No favourite quotes saved.')}));return end
    local parent=active_quote_widget
    if parent then parent:pauseTimeout() end
    require('slate_book_highlights'):show(automatic_owner or {},results[1].file or '',nil,
        {results=results,index=1,parent_quote=parent,title='FAVOURITES',icon='unfavourited.svg'})
end

function SlateQuotes:searchAllQuotes()
    local parent=active_quote_widget
    if parent then parent:pauseTimeout() end
    local InputDialog=require('ui/widget/inputdialog')
    local dialog
    dialog=InputDialog:new{modal=true,title=_('Search all quotes'),input='',input_hint=_('Words to find; leave empty to browse all quotes'),
        buttons={{{text=_('Cancel'),callback=function() UIManager:close(dialog);if parent and not parent._closed then parent:startTimeout() end end},
        {text=_('Search'),is_enter_default=true,callback=function()
            local query=dialog:getInputText():lower():gsub('^%s+',''):gsub('%s+$','')
            UIManager:close(dialog)
            local results={}
            for _,q in ipairs(load_quotes()) do
                local haystack=(tostring(q.text or '')..' '..tostring(q.book or '')..' '..tostring(q.author or '')):lower()
                local matched=true
                for word in query:gmatch('%S+') do if not haystack:find(word,1,true) then matched=false;break end end
                if matched then results[#results+1]=q end
            end
            if #results==0 then if parent and not parent._closed then parent:startTimeout() end;UIManager:show(SlateUtils:themePopup(InfoMessage:new{text=_('No matching quotes found.')}));return end
            local owner=automatic_owner or {}
            require('slate_book_highlights'):show(owner,results[1].file or '',nil,{results=results,index=1,parent_quote=parent})
        end}}}}
    UIManager:show(SlateUtils:themePopup(dialog));dialog:onShowKeyboard()
end

function SlateQuotes:showQuote()
    return show_quote_now()
end

function SlateQuotes:isAutomaticEnabled()
    return read_setting("automatic_extraction", true) == true
end

function SlateQuotes:stopAutomaticUpdates(owner)
    if owner and automatic_owner ~= owner then return end
    if automatic_timer then UIManager:unschedule(automatic_timer) end
    automatic_timer = nil
    automatic_owner = nil
end

function SlateQuotes:startAutomaticUpdates(owner)
    if automatic_owner == owner and owner ~= nil then return end
    self:stopAutomaticUpdates()
    automatic_owner = owner
    local function tick()
        if automatic_owner ~= owner then return end
        automatic_timer = nil
        if owner and owner._slate_suspended then return end
        self:autoUpdate()
    end
    automatic_timer = tick
    UIManager:scheduleIn(1, tick)
end

function SlateQuotes:autoUpdate(force)
    if not self:isAutomaticEnabled() or automatic_running then return true end
    automatic_running = true
    local ok, result = pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local reader = ReaderUI and ReaderUI.instance
        if reader and reader.document and type(reader.saveSettings) == "function" then
            reader:saveSettings()
        end
        return self.extract_highlights_to_quotes(force)
    end)
    automatic_running = false
    if ok then
        last_automatic_error = nil
    else
        local message = tostring(result)
        if message ~= last_automatic_error then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Automatic quote update failed: %s"), message),
                timeout = 5,
            })
            last_automatic_error = message
        end
    end
    return ok, result
end

function SlateQuotes:isEnabled()
    return true
end

function SlateQuotes:close()
    if active_quote_widget then
        UIManager:close(active_quote_widget)
    end
end

function SlateQuotes:buildMenu()
    local items = {}

    table.insert(items, {
        text = _("Automatically Update Quotes"),
        checked_func = function() return self:isAutomaticEnabled() end,
        callback = function(menu)
            local enabled = not self:isAutomaticEnabled()
            write_setting("automatic_extraction", enabled)
            if enabled then self:autoUpdate(true) end
            if menu and menu.updateItems then menu:updateItems() end
        end,
    })

    table.insert(items, {
        text = _("Extract Highlighted Texts"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Scanning for highlights…"),
                timeout = 2,
            })
            local ok, res = pcall(SlateQuotes.extract_highlights_to_quotes, true)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Error during extraction: %s"), tostring(res)),
                    timeout = 4,
                })
                return
            end

            local nb = tonumber(res) or 0
            if nb > 0 then
                UIManager:show(InfoMessage:new{
                    text = nb == 1
                        and _("1 highlight found and saved.")
                        or string.format(
                            _("%d highlights found and saved."), nb),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("No highlights found."),
                    timeout = 3,
                })
            end
        end,
    })

    table.insert(items, {
        text = _("Show a random quote"),
        callback = function()
            show_quote_now()
        end,
    })

    local settings_item = {
        text = _("Quote settings"),
        sub_item_table = {},
    }
    table.insert(items, settings_item)

    table.insert(settings_item.sub_item_table, {
        text_func = function()
            if plugin_title_mode == "none" then
                return string.format("%s: %s", _("Title"), _("None"))
            elseif plugin_title_mode == "custom" then
                return string.format(
                    "%s: %s", _("Title"), plugin_title_custom)
            else
                return string.format(
                    "%s: %s", _("Title"), _("Quote from Library"))
            end
        end,
        sub_item_table = {
            {
                text = _("Default"),
                radio = true,
                checked_func = function()
                    return plugin_title_mode == "default"
                end,
                callback = function(touchmenu_instance)
                    plugin_title_mode = "default"
                    write_setting("title_mode", "default")
                    if touchmenu_instance
                        and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                    show_sample()
                end,
            },
            {
                text = _("None"),
                radio = true,
                checked_func = function()
                    return plugin_title_mode == "none"
                end,
                callback = function(touchmenu_instance)
                    plugin_title_mode = "none"
                    write_setting("title_mode", "none")
                    if touchmenu_instance
                        and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                    show_sample()
                end,
            },
            {
                text = _("Custom…"),
                callback = function(touchmenu_instance)
                    local MultiInputDialog =
                        require("ui/widget/multiinputdialog")
                    local dlg
                    dlg = MultiInputDialog:new{
                        title = _("Custom Title"),
                        fields = {
                            {
                                text = plugin_title_custom or "",
                                hint = _("Title"),
                            },
                        },
                        buttons = {{
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(dlg)
                                end,
                            },
                            {
                                text = _("OK"),
                                callback = function()
                                    local fields = dlg:getFields()
                                    plugin_title_custom = fields[1] or ""
                                    plugin_title_mode = "custom"
                                    write_setting(
                                        "title_custom", plugin_title_custom)
                                    write_setting("title_mode", "custom")
                                    UIManager:close(dlg)
                                    if touchmenu_instance
                                        and touchmenu_instance.updateItems then
                                        touchmenu_instance:updateItems()
                                    end
                                    show_sample()
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
        },
    })

    table.insert(settings_item.sub_item_table, {
        text_func = function()
            return string.format(
                "%s: %s", _("Font"), plugin_font_face_name)
        end,
        sub_item_table_func = function()
            local subs = {}
            local FontList = require("fontlist")
            local cre = require("document/credocument"):engineInit()
            local face_list = cre.getFontFaces()

            for _, v in ipairs(face_list) do
                local font_filename, font_faceindex =
                    cre.getFontFaceFilenameAndFaceIndex(v)
                local label = FontList:getLocalizedFontName(
                    font_filename, font_faceindex) or v
                table.insert(subs, {
                    text = label,
                    font_func = function(size)
                        if font_filename and font_faceindex then
                            return Font:getFace(
                                font_filename, size, font_faceindex)
                        end
                    end,
                    callback = function()
                        plugin_font_face_name = v
                        write_setting("font_face", plugin_font_face_name)
                        show_sample()
                    end,
                    radio = true,
                    checked_func = function()
                        return plugin_font_face_name == v
                    end,
                    menu_item_id = v,
                })
            end
            return subs
        end,
    })

    local sizes = { 10, 12, 14, 16, 18, 20, 24 }
    table.insert(settings_item.sub_item_table, {
        text_func = function()
            return string.format(
                "%s: %d", _("Font size"), plugin_font_size)
        end,
        sub_item_table = (function()
            local s = {}
            for _, v in ipairs(sizes) do
                table.insert(s, {
                    text = tostring(v),
                    callback = function()
                        plugin_font_size = v
                        write_setting("font_size", plugin_font_size)
                        show_sample()
                    end,
                    radio = true,
                    checked_func = function()
                        return plugin_font_size == v
                    end,
                })
            end
            return s
        end)(),
    })

    table.insert(settings_item.sub_item_table, {
        text_func = function()
            return string.format(
                "%s: %s", _("Book dir"), plugin_book_dir)
        end,
        callback = function(touchmenu_instance)
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                select_directory = true,
                select_file = false,
                height = Screen:getHeight(),
                path = plugin_book_dir,
                onConfirm = function(dir_path)
                    if dir_path and dir_path:sub(-1) ~= "/" then
                        dir_path = dir_path .. "/"
                    end
                    plugin_book_dir = dir_path
                    write_setting("book_dir", plugin_book_dir)
                    extraction_cache = {}
                    self:autoUpdate(true)
                    if touchmenu_instance
                        and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end,
    })

    items[#items+1]={text=_("Search all quotes"),callback=function() self:searchAllQuotes() end}
    return items
end

function SlateQuotes.extract_highlights_to_quotes(force)
    local candidate_dirs = {
        plugin_book_dir, "/mnt/base-us/books", "/mnt/us/books",
        "/mnt/us/Books", "/mnt/us/documents",
    }
    local books_dir
    for index, dir in ipairs(candidate_dirs) do
        if dir and lfs.attributes(dir, "mode") == "directory" then
            books_dir = dir
            break
        end
    end
    if not books_dir then error("The configured book directory is unavailable.") end

    local function trim(text)
        return text:gsub("^%s+", ""):gsub("%s+$", "")
    end
    local function authors(value)
        if type(value) == "string" then return value end
        local parts = {}
        if type(value) == "table" then
            for index, author in ipairs(value) do
                if type(author) == "string" and author:match("%S") then
                    parts[#parts + 1] = author
                end
            end
        end
        return table.concat(parts, ", ")
    end
    local function readFile(path)
        local file, err = io.open(path, "rb")
        if not file then error(err or ("Could not read " .. path)) end
        local content, read_error = file:read("*a")
        file:close()
        if not content then error(read_error or ("Could not read " .. path)) end
        return content
    end
    local function isMetadata(name)
        return name == "metadata.lua" or name:match("^metadata.*%.lua$")
    end
    local function isAnnotations(name)
        return name:match("^annotations.*%.lua$")
    end
    local next_cache, found, seen, visited = {}, {}, {}, {}

    local function processSidecar(path, name)
        local files, names = {}, {}
        for filename in lfs.dir(path) do
            if filename and (isMetadata(filename) or isAnnotations(filename)) then
                local full_path = path .. "/" .. filename
                if lfs.attributes(full_path, "mode") == "file" then
                    names[#names + 1] = filename
                    files[filename] = readFile(full_path)
                end
            end
        end
        table.sort(names)
        local previous = extraction_cache[path]
        local same = not force and previous and previous.navigation_version == 1
            and #previous.names == #names
        if same then
            for index, filename in ipairs(names) do
                if previous.files[filename] ~= files[filename] then same = false; break end
            end
        end
        local records
        if same then
            records = previous.records
        else
            local tables, book, author, book_file = {}, nil, nil, nil
            for index, filename in ipairs(names) do
                local loader = loadstring or load
                local chunk, err = loader(files[filename], "@" .. path .. "/" .. filename)
                if not chunk then error(err or ("Invalid metadata: " .. filename)) end
                local ok, data = pcall(chunk)
                if not ok or type(data) ~= "table" then
                    error("Could not load highlights from " .. path .. "/" .. filename
                        .. (not ok and (": " .. tostring(data)) or ""))
                end
                tables[#tables + 1] = { data = data, annotation_file = isAnnotations(filename) }
                if type(data.doc_path) == "string" and data.doc_path ~= "" then
                    book_file = data.doc_path
                elseif not book_file then
                    local extension = filename:match("^metadata%.([%w]+)%.lua$")
                    if extension then book_file = path:gsub("%.sdr$", "") .. "." .. extension end
                end
                for prop_index, key in ipairs({ "doc_props", "stats" }) do
                    local props = data[key]
                    if type(props) == "table" then
                        if not book and type(props.title) == "string" and props.title:match("%S") then
                            book = props.title
                        end
                        if not author or author == "" then author = authors(props.authors) end
                    end
                end
            end
            book = book or trim(name:gsub("%.sdr$", ""):gsub("[_%-]+", " "))
            author = author or ""
            records = {}
            local function add(text, annotation, page)
                if type(text) ~= "string" then return end
                text = trim(text:gsub("\r", ""):gsub("\n", " "))
                if #text < 5 or not text:match("%S") then return end
                local pos = type(annotation) == "table" and annotation.pos0
                local number = type(annotation) == "table"
                    and tonumber(annotation.pageno or annotation.page) or tonumber(page)
                if type(pos) == "table" then number = tonumber(pos.page) or number end
                records[#records + 1] = {
                    text = text, book = book, author = author, file = book_file,
                    pos0 = type(pos) == "string" and pos or nil,
                    page = number,
                }
            end
            local visited_pools = {}
            local function extract(pool, page)
                if type(pool) ~= "table" or visited_pools[pool] then return end
                visited_pools[pool] = true
                for key, ann in pairs(pool) do
                    if type(ann) == "table" then
                        local value = ann.text or ann.highlight or ann.highlighted_text
                            or ann.selection or ann.note or ann.notes
                        if type(value) == "string" then add(value, ann, page)
                        else extract(ann, tonumber(key) or page) end
                    elseif type(ann) == "string" then add(ann, nil, page) end
                end
            end
            for index, source in ipairs(tables) do
                local data = source.data
                extract(data.annotations)
                extract(data.highlights)
                extract(data.highlight)
                extract(data.bookmarks)
                if source.annotation_file and not data.annotations and not data.highlights
                    and not data.highlight and not data.bookmarks then
                    extract(data)
                end
            end
        end
        next_cache[path] = { names = names, files = files, records = records, navigation_version = 1 }
        for index, quote in ipairs(records) do
            local key = quote.text .. "\x1f" .. quote.book .. "\x1f" .. quote.author
            if not seen[key] then seen[key] = true; found[#found + 1] = quote end
        end
    end

    local function walk(dir)
        if visited[dir] then return end
        visited[dir] = true
        local entries = {}
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then entries[#entries + 1] = name end
        end
        table.sort(entries)
        for index, name in ipairs(entries) do
            local path = dir .. "/" .. name
            local mode = lfs.symlinkattributes and lfs.symlinkattributes(path, "mode")
                or lfs.attributes(path, "mode")
            if mode == "directory" then
                if name:match("%.sdr$") then processSidecar(path, name)
                else walk(path) end
            end
        end
    end
    walk(books_dir)
    table.sort(found, function(a, b)
        if a.book ~= b.book then return a.book < b.book end
        if a.author ~= b.author then return a.author < b.author end
        return a.text < b.text
    end)

    local quotes_path = plugin_dir .. "slate_quote_data.lua"
    local contents = {
        "-- SPDX-License-Identifier: AGPL-3.0-or-later\n",
        "-- Generated by Slate’s highlight extractor.\nlocal quotes = {\n",
    }
    for index, quote in ipairs(found) do
        contents[#contents + 1] = string.format(
            "    { text = %q, book = %q, author = %q, file = %s, pos0 = %s, page = %s },\n",
            quote.text, quote.book, quote.author,
            quote.file and string.format("%q", quote.file) or "nil",
            quote.pos0 and string.format("%q", quote.pos0) or "nil",
            quote.page and tostring(quote.page) or "nil")
    end
    contents[#contents + 1] = "}\n\nreturn quotes\n"
    local output = table.concat(contents)
    local current_file = io.open(quotes_path, "rb")
    local current = current_file and current_file:read("*a")
    if current_file then current_file:close() end
    if current ~= output then
        local temporary_path = quotes_path .. ".tmp"
        local file, err = io.open(temporary_path, "wb")
        if not file then error(err or "Could not save Slate’s quotes.") end
        local written, write_error = file:write(output)
        local closed, close_error = file:close()
        if not written or not closed then
            os.remove(temporary_path)
            error(write_error or close_error or "Could not finish saving Slate’s quotes.")
        end
        local renamed, rename_error = os.rename(temporary_path, quotes_path)
        if not renamed then
            os.remove(temporary_path)
            error(rename_error or "Could not replace Slate’s quote data file.")
        end
        package.loaded["slate_quote_data"] = nil
    end
    extraction_cache = next_cache
    return #found
end

local function sameQuote(first, second)
    local function normalized(value)
        return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return normalized(first.text) == normalized(second.text)
        and normalized(first.book) == normalized(second.book)
end

function SlateQuotes:viewQuote(entry)
    local owner = SlateUtils.slate_popup_layout and SlateUtils.slate_popup_layout.owner
    if owner then
        local loaded, pinpad = pcall(require, "slate_pinpad")
        if loaded and pinpad:intercept(owner) then return true end
    end
    local function message(value)
        UIManager:show(SlateUtils:themePopup(InfoMessage:new{text = value}))
    end
    local loading = SlateUtils:themePopup(InfoMessage:new{text = _("Finding the highlighted passage…")})
    UIManager:show(loading)
    UIManager:scheduleIn(0.1, function()
        local target = entry
        local ok, err = pcall(function()
            if not target.file or (not target.pos0 and not target.page)
                or not util.fileExists(target.file) then
                SlateQuotes.extract_highlights_to_quotes(true)
                target = nil
                for _, saved in ipairs(load_quotes()) do
                    if sameQuote(saved, entry) and saved.file
                        and (saved.pos0 or saved.page) and util.fileExists(saved.file) then
                        if target and target.file ~= saved.file then
                            error("More than one book matches this quote.")
                        end
                        target = saved
                    end
                end
            end
            if not target or not target.file or not util.fileExists(target.file)
                or (not target.pos0 and not target.page) then
                error("No saved highlight location was found.")
            end
        end)
        UIManager:close(loading)
        if not ok then
            message(_("Could not locate this quote in its book.") .. "\n" .. tostring(err))
            return
        end
        SlateQuotes:close()
        if owner and owner._slate_screen then
            require("ui/widget/screensaverwidget").onClose(owner._slate_screen)
        end
        UIManager:nextTick(function()
            local ReaderUI = require("apps/reader/readerui")
            local Event = require("ui/event")
            local reader = ReaderUI.instance
            local opened, open_error = pcall(function()
                require("slate_books"):installOpeningGuard()
                if not reader or not reader.document or reader.document.file ~= target.file then
                    ReaderUI:showReader(target.file)
                end
            end)
            if not opened then message(_("Could not open the quote’s book.") .. "\n" .. tostring(open_error)); return end
            local attempts = 0
            local function jump()
                attempts = attempts + 1
                local ui = ReaderUI.instance
                if ui and ui.document and ui.document.file == target.file
                    and (not target.pos0 or ui.rolling) then
                    local jumped = pcall(function()
                        if type(target.pos0) == "string" then
                            ui:handleEvent(Event:new("GotoXPointer", target.pos0))
                        else ui:handleEvent(Event:new("GotoPage", target.page)) end
                    end)
                    if not jumped then message(_("Could not jump to the highlighted passage.")) end
                elseif attempts < 100 then UIManager:scheduleIn(0.1, jump)
                else message(_("The book did not become ready for navigation.")) end
            end
            jump()
        end)
    end)
    return true
end

return SlateQuotes
