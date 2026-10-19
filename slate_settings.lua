-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-10.

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local util = require("util")
local Screen = require("device").screen
local Quotes = require("slate_quotes")
local QuickLaunch = require("slate_quicklaunch")
local PinPad = require("slate_pinpad")
local Books = require("slate_books")
local PathChooser = require("ui/widget/pathchooser")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = {}
local PREFIX = "slate_weather_"
local SlateUtils = require("slate_utils")

local function showDialog(widget)
    widget.modal=true
    UIManager:show(SlateUtils:themePopup(widget),"ui")
    UIManager:setDirty(nil,"ui")
    if UIManager.forceRePaint then UIManager:forceRePaint()end
end

local function read(key, default)
    return G_reader_settings:readSetting(PREFIX .. key, default)
end

local function save(key, value, menu)
    G_reader_settings:saveSetting(PREFIX .. key, value)
    G_reader_settings:flush()
    if menu and menu.updateItems then menu:updateItems() end
end

local function displayStyle()
    return read("display_style", "reading") == "custombg" and "custombg" or "reading"
end

local function toggle(key, label, default, changed)
    return {
        text = label,
        checked_func = function() return read(key, default) ~= false end,
        callback = function(menu)
            save(key, read(key, default) == false, menu)
            if changed then changed(menu) end
        end,
    }
end

local function choice(key, label, options, default, changed)
    local items = {}
    for index, option in ipairs(options) do
        local value, name = option[1], option[2]
        items[#items + 1] = {
            text = name,
            radio = true,
            keep_menu_open = true,
            checked_func = function()
                local current = read(key, default)
                if key == "display_style" then current = displayStyle() end
                if value == "fill" and current == "stretch" then return true end
                return current == value
            end,
            callback = function(menu)
                save(key, value, menu)
                if changed then changed(menu) end
            end,
        }
    end
    return {
        text_func = function()
            local current = read(key, default)
            if key == "display_style" then current = displayStyle() end
            for index, option in ipairs(options) do
                if current == option[1] or (current == "stretch" and option[1] == "fill") then
                    return T(_("%1 (%2)"), label, option[2])
                end
            end
            return label
        end,
        sub_item_table = items,
    }
end

local function sizeItem(key, default, label, title, info, minimum, maximum, step, hold, unit)
    return {
        text_func = function() return T(label, tonumber(read(key)) or default) end,
        keep_menu_open = true,
        callback = function(menu)
            showDialog(SpinWidget:new{
                title_text = title,
                info_text = info,
                value = tonumber(read(key)) or default,
                value_min = minimum,
                value_max = maximum,
                value_step = step,
                value_hold_step = hold,
                unit = unit,
                ok_text = _("Set"),
                callback = function(spin) save(key, spin.value, menu) end,
            })
        end,
    }
end

local function inputItem(key, label, default, hint, description, normalize, hidden)
    return {
        text_func = function()
            local value = read(key, default) or ""
            if hidden then
                return value ~= "" and T(_("%1 (configured)"), label) or label
            end
            return T(_("%1 (%2)"), label, value)
        end,
        keep_menu_open = true,
        callback = function(menu)
            local dialog
            dialog = InputDialog:new{
                title = label,
                input = read(key, default) or "",
                input_hint = hint,
                input_type = "string",
                description = description,
                buttons = {{
                    {
                        text = _("Cancel"),
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local value = dialog:getInputValue() or ""
                            value = value:gsub("^%s+", ""):gsub("%s+$", "")
                            if normalize then value = normalize(value) end
                            save(key, value, menu)
                            UIManager:close(dialog)
                        end,
                    },
                }},
            }
            showDialog(dialog)
            dialog:onShowKeyboard()
        end,
    }
end

-- Keep the confirmation on top of this modal picker without modifying
-- KOReader's shared PathChooser/ButtonDialog implementations.
local BackgroundPathChooser=PathChooser:extend{}
function BackgroundPathChooser:onMenuHold(item)
    local ffiUtil=require('ffi/util')
    local lfs=require('libs/libkoreader-lfs')
    local BD=require('ui/bidi')
    local path=item and item.path
    if type(path)~='string'then return true end
    if path:sub(-2)=='/.'then path=path:sub(1,-3)end
    path=ffiUtil.realpath(path)
    local attr=path and lfs.attributes(path)
    if not attr or attr.mode~='file'or not self.select_file then return true end
    local title=_("Choose this file?")..'\n\n'..BD.filepath(path)
    local picker=self
    local dialog
    dialog=require('ui/widget/buttondialog'):new{
        modal=true,title=title,
        buttons={{
            {text=_("Cancel"),callback=function()UIManager:close(dialog);picker.button_dialog=nil end},
            {text=_("Choose"),callback=function()
                UIManager:close(dialog);picker.button_dialog=nil
                UIManager:close(picker)
                if picker.onConfirm then picker.onConfirm(path)end
            end},
        }},
    }
    self.button_dialog=dialog
    showDialog(dialog)
    return true
end

local function backgroundPicker()
    return {
        text_func = function()
            return T(_("Background image (%1)"), read("custom_bg_path", "/mnt/us/wallpapers/sleepscreen.jpg"))
        end,
        keep_menu_open = true,
        callback = function(menu)
            local image = read("custom_bg_path", "/mnt/us/wallpapers/sleepscreen.jpg")
            local folder = read("custom_bg_folder") or image:match("^(.*)/[^/]+$") or "/mnt/us/wallpapers"
            showDialog(BackgroundPathChooser:new{
                title = _("Choose background image"),
                path = folder,
                select_file = true,
                select_directory = false,
                height = Screen:getHeight(),
                onConfirm = function(path)
                    if type(path) ~= "string" or path == "" then return end
                    save("custom_bg_folder", path:match("^(.*)/[^/]+$") or folder)
                    save("custom_bg_path", path, menu)
                end,
            })
        end,
    }
end

local function iconPicker(owner, name, label)
    local key = "slate.widget_icons." .. name
    return {
        text = label,
        keep_menu_open = true,
        callback = function(menu)
            local selected = G_reader_settings:readSetting(key)
            local folder = G_reader_settings:readSetting("slate.widget_icons.folder")
                or (type(selected) == "string" and selected:match("^(.*)/[^/]+$"))
                or (owner:getPluginDir() .. "/icons")
            showDialog(PathChooser:new{
                title = label,
                path = folder,
                select_file = true,
                select_directory = false,
                height = Screen:getHeight(),
                onConfirm = function(path)
                    if type(path) ~= "string" or path == "" then return end
                    local extension = path:lower():match("%.([^.]+)$")
                    if not util.fileExists(path)
                        or (extension ~= "svg" and extension ~= "png") then
                        showDialog(InfoMessage:new{
                            text = _("Choose an existing SVG or PNG icon file."),
                        })
                        return
                    end
                    G_reader_settings:saveSetting(key, path)
                    G_reader_settings:saveSetting("slate.widget_icons.folder",
                        path:match("^(.*)/[^/]+$") or folder)
                    G_reader_settings:flush()
                    if menu and menu.updateItems then menu:updateItems() end
                    if owner._slate_screen then
                        UIManager:setDirty(owner._slate_screen, "full")
                    end
                end,
            })
        end,
    }
end

local function saveBookOption(owner, key, value, menu)
    G_reader_settings:saveSetting("slate.books." .. key, value)
    G_reader_settings:flush()
    Books:close(owner)
    if menu and menu.updateItems then menu:updateItems() end
end

local function bookToggle(owner, key, label, default)
    return {
        text = label,
        keep_menu_open = true,
        checked_func = function()
            return G_reader_settings:readSetting("slate.books." .. key, default) == true
        end,
        callback = function(menu)
            local current = G_reader_settings:readSetting("slate.books." .. key, default)
            saveBookOption(owner, key, current ~= true, menu)
        end,
    }
end

local function bookChoice(owner, key, label, options, default)
    local items = {}
    for index, option in ipairs(options) do
        local value, name = option[1], option[2]
        items[#items + 1] = {
            text = name,
            radio = true,
            keep_menu_open = true,
            checked_func = function()
                return G_reader_settings:readSetting("slate.books." .. key, default) == value
            end,
            callback = function(menu) saveBookOption(owner, key, value, menu) end,
        }
    end
    return {
        text_func = function()
            local current = G_reader_settings:readSetting("slate.books." .. key, default)
            for index, option in ipairs(options) do
                if current == option[1] then return T(_("%1 (%2)"), label, option[2]) end
            end
            return label
        end,
        sub_item_table = items,
    }
end

local function bookCount(owner, key, label, default, minimum, maximum)
    local options = {}
    for count = minimum, maximum do options[#options + 1] = { count, tostring(count) } end
    return bookChoice(owner, key, label, options, default)
end

local function thumbnailCorners(owner, key)
    return bookChoice(owner, key, _("Thumbnail corners"), {
        { true, _("Slightly rounded") }, { false, _("Square") },
    }, true)
end

local function bookGridOptions(owner, kind)
    return {
        bookCount(owner, kind .. ".columns", _("Books per row"),
            4, 1, 6),
        bookCount(owner, kind .. ".rows", _("Rows per page"), 3, 1, 5),
        thumbnailCorners(owner, kind .. ".rounded"),
        bookToggle(owner, kind .. ".progress", _("Show progress bar and percentage"), kind == "recents"),
    }
end

function Settings:buildRecents(owner)
    return {
        bookToggle(owner, "recents.native", _("Open KOReader history directly"), false),
        { text = _("Popup UI"), sub_item_table = bookGridOptions(owner, "recents") },
    }
end

function Settings:buildLibrary(owner)
    return {
        {
        text = _("Long press book for description + highlights"),
        keep_menu_open = true,
        checked_func = function()
            return G_reader_settings:readSetting(
                "slate.book_highlights_long_press", true) == true
        end,
        callback = function(menu)
            local enabled = G_reader_settings:readSetting(
                "slate.book_highlights_long_press", true) == true
            G_reader_settings:saveSetting("slate.book_highlights_long_press", not enabled)
            G_reader_settings:flush()
            if menu and menu.updateItems then menu:updateItems() end
        end,},
        bookToggle(owner, "library.native", _("Go to KOReader library directory instead of Slate UI"), false),
        {
            text_func = function() return T(_("Main books directory (%1)"), Books:getDirectory()) end,
            keep_menu_open = true,
            help_text = _("Folders inside this directory become categories. Library view includes books in its subfolders."),
            callback = function(menu)
                showDialog(PathChooser:new{
                    title = _("Choose the main books directory"),
                    path = Books:getDirectory(),
                    select_file = false,
                    select_directory = true,
                    height = Screen:getHeight(),
                    onConfirm = function(path)
                        if type(path) ~= "string" or not util.directoryExists(path) then
                            showDialog(InfoMessage:new{ text = _("Choose an existing books directory.") })
                            return
                        end
                        saveBookOption(owner, "library.directory", path, menu)
                    end,
                })
            end,
        },
        {
            text = _("Folders in this directory are used for Categories."),
            keep_menu_open = true,
            callback = function()
                showDialog(InfoMessage:new{
                    text = _("Each folder inside your main books directory becomes a category. Tap its title to open the folder. Library view includes all books in this directory and its subfolders."),
                })
            end,
        },
        { text = _("Library UI"), sub_item_table = bookGridOptions(owner, "library") },
        {
            text = _("Categories UI"),
            sub_item_table = {
                bookCount(owner, "categories.columns", _("Books per folder row"), 5, 3, 8),
                bookCount(owner, "categories.rows", _("Folders per page"), 3, 2, 5),
                thumbnailCorners(owner, "categories.rounded"),
            },
        },
    }
end

function Settings:buildPopupHeaders(owner)
    local function changed(menu)
        G_reader_settings:flush()
        if menu and menu.updateItems then menu:updateItems() end
        for _, popup in pairs({owner._slate_books_popup, owner._slate_quicklaunch_popup}) do
            UIManager:setDirty(popup, "ui")
        end
    end
    local function headerToggle(key, label, default)
        return {
            text = label,
            keep_menu_open = true,
            checked_func = function()
                return G_reader_settings:readSetting(key, default) == true
            end,
            callback = function(menu)
                local enabled = G_reader_settings:readSetting(key, default) == true
                G_reader_settings:saveSetting(key, not enabled)
                changed(menu)
            end,
        }
    end
    return {
        headerToggle("slate.popup_header_icons", _("Show popup header icons"), true),
        headerToggle("slate.popup_header_outline", _("Show header icon outline"), true),
        headerToggle("slate.popup_header_text", _("Show popup header text"), true),
                {
                    text_func = function()
                        return T(_("Popup icons size (%1 px)"),
                            tonumber(G_reader_settings:readSetting("slate.popup_header_icon_size", 72)) or 72)
                    end,
                    keep_menu_open = true,
                    callback = function(menu)
                        showDialog(SpinWidget:new{
                            title_text = _("Popup icons size"),
                            info_text = _("Applies to Quick Launch, Quotes, Library and Recents popup headers."),
                            value = tonumber(G_reader_settings:readSetting("slate.popup_header_icon_size", 72)) or 72,
                            value_min = 16,
                            value_max = 200,
                            value_step = 4,
                            value_hold_step = 16,
                            unit = "px",
                            ok_text = _("Set"),
                            callback = function(spin)
                                G_reader_settings:saveSetting("slate.popup_header_icon_size", spin.value)
                                G_reader_settings:flush()
                                if menu and menu.updateItems then menu:updateItems() end
                            end,
                        })
                    end,
                },


    }
end

function Settings:buildWidget(owner)
    local scaling_options = {
        { "fit", _("Fit to screen") },
        { "fill", _("Stretch to fill") },
        { "stretch_fit", _("Stretch to fit") },
    }
    local position_items = {
        sizeItem("widget_bottom_offset", 115, _("Widget distance from bottom (%1 px)"),
            _("Widget distance from bottom"), _("Vertical offset of the bottom card."),
            0, Screen:getHeight(), 5, 10, "px"),
        sizeItem("widget_width_percent", 100, _("Widget width (%1%)"), _("Widget width"),
            _("Relative width of the overlay card."), 10, 100, 5, 10, "%"),
        sizeItem("widget_height_percent", 50, _("Widget height (%1%)"), _("Widget height"),
            _("Relative height as a percentage of half the screen height."), 10, 100, 5, 10, "%"),
    }
    if read("override_scaling", true) ~= false then
        table.insert(position_items, 1,
            sizeItem("fill_percent", 60, _("Content fill (%1%)"), _("Content fill percentage"),
                _("How much of the available screen height should be filled."), 30, 100, 5, 10, "%"))
    end

    local appearance = {
        {
            text = _("Custom sizes are untested."),
            enabled = false,
            separator = true,
        },
        {
            text = _("Corner Rounding"),
            sub_item_table = {},
        },
        {
            text = _("Pop Up UI"),
            sub_item_table = self:buildPopupHeaders(owner),
        },
        {
            text = _("Change Widget Icons"),
            sub_item_table = {
                iconPicker(owner, "quicklaunch", _("Edit Quick Launch Icon")),
                iconPicker(owner, "quote", _("Edit Random Quote Icon")),
                iconPicker(owner, "library", _("Edit Library Icon")),
                iconPicker(owner, "recents", _("Edit Recents Icon")),
            },
        },
        { text = _("Widget position & size"), sub_item_table = position_items },
        {
            text = _("Text sizes"),
            sub_item_table = {
                sizeItem("widget_title_size", 28, _("Title font size (%1 pt)"), _("Title font size"), _("Font size used for the book title."), 8, 80, 2, 4, "pt"),
                sizeItem("widget_author_size", 27, _("Author font size (%1 pt)"), _("Author font size"), _("Font size used for the author line."), 8, 60, 2, 4, "pt"),
                sizeItem("widget_progress_font_size", 26, _("Page / % font size (%1 pt)"), _("Page / percentage font size"), _("Font size used for the page line and percentage."), 8, 60, 2, 4, "pt"),
                sizeItem("widget_temp_size", 37, _("Temperature font size (%1 pt)"), _("Temperature font size"), _("Font size used for the temperature value."), 8, 80, 2, 4, "pt"),
                sizeItem("widget_detail_size", 23, _("Condition / moon text (%1 pt)"), _("Condition / moon text size"), _("Font size used for condition and moon phase text."), 8, 60, 2, 4, "pt"),
                sizeItem("widget_location_size", 22, _("Location / time text (%1 pt)"), _("Location / time font size"), _("Font size used for the location, time, and battery line."), 8, 60, 2, 4, "pt"),
            },
        },
        {
            text = _("Icon sizes"),
            sub_item_table = {
                sizeItem("widget_weather_icon_size", 146, _("Weather icon size (%1 px)"), _("Weather icon size"), _("Pixel size used for the weather icon."), 32, 400, 8, 16, "px"),
                sizeItem("widget_moon_icon_size", 85, _("Moon icon size (%1 px)"), _("Moon icon size"), _("Pixel size used for the moon-phase icon."), 32, 400, 8, 16, "px"),
            },
        },
        {
            text = _("Spacing & frame"),
            sub_item_table = {
                sizeItem("widget_card_padding", 22, _("Internal padding (%1 px)"), _("Internal padding"), _("Padding around the card content."), 0, 100, 2, 5, "px"),
                sizeItem("widget_spacing", 9, _("Element spacing (%1 px)"), _("Element spacing"), _("General spacing between card elements."), 0, 80, 2, 4, "px"),
                sizeItem("widget_small_spacing", 5, _("Small spacing (%1 px)"), _("Small spacing"), _("Spacing between inline icons and text."), 0, 40, 1, 2, "px"),
                sizeItem("widget_progress_height", 6, _("Progress bar height (%1 px)"), _("Progress bar height"), _("Height of the reading progress bar."), 2, 40, 1, 2, "px"),
                sizeItem("widget_border_width", 1, _("Card border width (%1 px)"), _("Card border width"), _("Saved border width setting for the overlay card."), 0, 10, 1, 2, "px"),
            },
        },
        {
            text = _("Night mode application"),
            sub_item_table = {
                toggle("cover_nightmode_fix_bg", _("Fix custom background inversion"), true),
                toggle("cover_nightmode_fix_text", _("Force card text to white"), true),
                choice("widget_theme_override", _("Widget theme"), {
                    { "default", _("Default (follow KOReader)") },
                    { "day", _("Emulate day mode") },
                    { "night", _("Emulate night mode") },
                }, "default"),
            },
        },
    }


    local weather_items = {
        {
            text = _("Disable weather on main Slate screen"),
            checked_func = function()return read("main_weather_enabled", true) == false end,
            callback = function(menu)
                save("main_weather_enabled", read("main_weather_enabled", true) == false, menu)
            end,
        },
        inputItem("location", _("City"), owner.default_location or "London",
            _("City, Country or latitude,longitude"), _("Enter a city, optionally followed by its country, or coordinates. Example: Athens, Greece or 37.98,23.73.")),
        choice("temp_scale", _("Temperature scale"), {
            { "C", _("Celsius") }, { "F", _("Fahrenheit") },
        }, owner.default_temp_scale or "C"),
        {
            text = _("Provider: Open-Meteo (no API key needed)"),
            callback = function()
                showDialog(SlateUtils:themePopup(InfoMessage:new{
                    text = _("Seven forecast days and dated moon phases. Free API access is for noncommercial use.\n\nWeather data: Open-Meteo, CC BY 4.0. Values and labels are adapted for Slate.\nhttps://open-meteo.com/"),
                }))
            end,
        },
        {
            text_func = function()
                local hours = math.floor((tonumber(read("cache_max_age")) or 3600) / 3600)
                return T(_("Cache duration (%1 %2)"), hours, hours == 1 and _("hour") or _("hours"))
            end,
            keep_menu_open = true,
            callback = function(menu)
                showDialog(SpinWidget:new{
                    title_text = _("Cache duration"),
                    info_text = _("How long weather data should remain cached."),
                    value = math.floor((tonumber(read("cache_max_age")) or 3600) / 3600),
                    value_min = 1, value_max = 24, value_step = 1, value_hold_step = 2,
                    unit = _("hours"), ok_text = _("Set"),
                    callback = function(spin) save("cache_max_age", spin.value * 3600, menu) end,
                })
            end,
        },
        {
            text = _("Clear cache"),
            keep_menu_open = true,
            callback = function()
                showDialog(ConfirmBox:new{
                    text = _("Clear cached weather data and icons?"),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        local cleared = owner:clearCache()
                        showDialog(Notification:new{
                            text = cleared and _("Cache cleared") or _("No cache to clear"),
                        })
                    end,
                })
            end,
        },
    }

    local function borderToggle(key, label, default)
        return {
            text = label,
            checked_func = function()return read(key, default) == true end,
            callback = function(menu)
                save(key, read(key, default) ~= true, menu)
                -- Rebuild the active display from cache, including settings
                -- opened through KOReader rather than the Slate editor.
                if owner and owner._slate_screen then
                    if type(owner.refreshWeatherScreen) == "function" then
                        owner:refreshWeatherScreen(true)
                    end
                    UIManager:setDirty(nil, "full")
                end
            end,
        }
    end
    appearance[2].sub_item_table[#appearance[2].sub_item_table + 1] =
        borderToggle("remove_custom_widget_border", _("Remove widget border on custom background display"), false)
    appearance[2].sub_item_table[#appearance[2].sub_item_table + 1] =
        borderToggle("remove_cover_widget_border", _("Remove widget border on cover display"),
            read("widget_border_enabled", true) ~= true)

    local corner_options = {
        { "slate_weather_widget_corner_radius", 40, _("Widget corner radius") },
        { "slate.popup_corner_radius", 40, _("Popup corner radius") },
        { "slate.button_corner_radius", 40, _("Button corner radius") },
    }
    for index, option in ipairs(corner_options) do
        local key, default, label = option[1], option[2], option[3]
        appearance[2].sub_item_table[#appearance[2].sub_item_table + 1] = {
            text_func = function()
                return T(_("%1 (%2 px)"), label,
                    tonumber(G_reader_settings:readSetting(key, default)) or default)
            end,
            keep_menu_open = true,
            callback = function(menu)
                showDialog(SpinWidget:new{
                    title_text = label,
                    info_text = _("Use 0 for square corners. Circular icon buttons keep their shape."),
                    value = tonumber(G_reader_settings:readSetting(key, default)) or default,
                    value_min = 0, value_max = 60,
                    value_step = 1, value_hold_step = 5,
                    unit = "px", ok_text = _("Set"),
                    callback = function(spin)
                        G_reader_settings:saveSetting(key, spin.value)
                        G_reader_settings:flush()
                        if menu and menu.updateItems then menu:updateItems() end
                    end,
                })
            end,
        }
    end

    -- Keep the advanced size controls together after populating corner options.
    appearance={appearance[2],appearance[3],appearance[4],
        {text=_("Advanced"),sub_item_table={appearance[1],appearance[7],appearance[5],appearance[6],appearance[8]}},
        appearance[9]}

    local display_style = choice("display_style", _("Display Style"), {
            { "reading", _("Cover") },
            { "custombg", _("Custom background") },
        }, "reading")
    display_style.sub_item_table[#display_style.sub_item_table + 1] =
{
            text = _("Exit Slate with long press"),
            help_text = _("Require a long press outside the buttons to leave Slate. Buttons still respond to taps."),
            checked_func = function()
                return G_reader_settings:readSetting("slate.exit_long_press", false) == true
            end,
            callback = function(menu)
                local enabled = G_reader_settings:readSetting("slate.exit_long_press", false) == true
                G_reader_settings:saveSetting("slate.exit_long_press", not enabled)
                G_reader_settings:flush()
                if menu and menu.updateItems then menu:updateItems() end
            end,
        }

    local description_items = {
        {
            text = _("Description Diagnostic Logging"),
            checked_func=function()return G_reader_settings:readSetting("slate.descriptions.diagnostic_logging",false)==true end,
            callback=function(menu)
                local key="slate.descriptions.diagnostic_logging"
                G_reader_settings:saveSetting(key,not G_reader_settings:readSetting(key,false))
                G_reader_settings:flush()
                if menu and menu.updateItems then menu:updateItems()end
            end,
        },
        {
            text = _("Update book meta data"),
            callback = function() Books:showMetadataEditor(owner) end,
        },
        {
            text = _("Missing descriptions — edit searches"),
            callback = function() Books:showMissingDescriptions(owner) end,
        },
        {
            text = _("Retry all missing descriptions"),
            callback = function()
                local ok, descriptions = pcall(require, "slate_book_descriptions")
                if not ok or type(descriptions) ~= "table"
                    or type(descriptions.retryAllMissing) ~= "function" then
                    showDialog(SlateUtils:themePopup(InfoMessage:new{
                        text = _("The installed description module is outdated. Replace slate_book_descriptions.lua, slate_books.lua, and slate_settings.lua with the matching update, then restart KOReader."),
                    }))
                    return
                end
                local success, count = pcall(descriptions.retryAllMissing, descriptions)
                if not success then
                    showDialog(SlateUtils:themePopup(InfoMessage:new{
                        text = _("Could not queue missing descriptions:") .. "\n" .. tostring(count),
                    }))
                    return
                end
                showDialog(SlateUtils:themePopup(InfoMessage:new{
                    text = tostring(count) .. _(" missing descriptions queued. Keep Wi-Fi connected while downloads finish."),
                }))
            end,
        },
        {
            text = _("Downloaded descriptions + offline cache"),
            callback = function()
                showDialog(SlateUtils:themePopup(InfoMessage:new{
                    text = _("Descriptions are downloaded from Open Library. Google Books is also used when its optional API key is configured. Built-in descriptions of at least 15 words are used first. Wikipedia is the final fallback.\n\nSlate searches by the parsed title only, preserving apostrophes. Authors and ISBNs are not required. Use Missing descriptions to enter a custom title.\n\nOn wake, missing or expired descriptions are queued in the background. Successful descriptions are cached for 30 days; failed lookups retry after one day. Saved descriptions remain available offline."),
                }))
            end,
        },
        {
            text_func = function()
                local key = G_reader_settings:readSetting("slate.descriptions.google_api_key", "")
                return key ~= "" and _("Google Books API key (configured)")
                    or _("Google Books API key (optional)")
            end,
            keep_menu_open = true,
            callback = function(menu)
                local dialog
                dialog = InputDialog:new{
                    title = _("Google Books API key"),
                    input = G_reader_settings:readSetting("slate.descriptions.google_api_key", ""),
                    input_hint = _("Optional Google Books API key"),
                    input_type = "string",
                    description = _("Open Library works without a key. Add your own Google Books API key to also use Google Books descriptions. Leave empty to use Open Library and Wikipedia."),
                    buttons = {{
                        {text = _("Cancel"), callback = function() UIManager:close(dialog) end},
                        {text = _("Save"), is_enter_default = true, callback = function()
                            local key = (dialog:getInputValue() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                            G_reader_settings:saveSetting("slate.descriptions.google_api_key", key)
                            G_reader_settings:flush()
                            if menu and menu.updateItems then menu:updateItems() end
                            UIManager:close(dialog)
                            local loaded, descriptions = pcall(require, "slate_book_descriptions")
                            if loaded and type(descriptions.credentialsChanged) == "function" then
                                descriptions:credentialsChanged()
                            end
                        end},
                    }},
                }
                showDialog(SlateUtils:themePopup(dialog))
                dialog:onShowKeyboard()
            end,
        },
    }
    display_style.sub_item_table[#display_style.sub_item_table + 1] = {
            text = _("Custom Background Mode"),
            sub_item_table = {
                backgroundPicker(),
                choice("custom_img_mode", _("Image scaling"), scaling_options, "stretch_fit"),
            },
        }
    display_style.sub_item_table[#display_style.sub_item_table + 1] = {
            text = _("Cover Mode"),
            sub_item_table = {
                toggle("cover_custom_background_when_no_book",
                    _("Use custom background when no book is open"), false),
                toggle("override_scaling", _("Override KOReader scaling"), true),
                choice("cover_scaling", _("Cover scaling"), scaling_options, "stretch_fit"),
            },
        }
    local widget_items = {
        display_style,
        { text = _("Weather Settings"), sub_item_table = weather_items },
        { text = _("Book Descriptions"), sub_item_table = description_items },
        {
            text = _("Quick Launch"),
            sub_item_table = {
                {
                    text = _("Select GAMES…"),
                    keep_menu_open = true,
                    callback = function() QuickLaunch:showSelection(owner, "games") end,
                },
                {
                    text = _("Select APPS…"),
                    keep_menu_open = true,
                    callback = function() QuickLaunch:showSelection(owner, "apps") end,
                },
            },
        },
        {
            text = _("Random Quote"),
            sub_item_table_func = function()
                return Quotes:buildMenu()
            end,
        },
        {
            text = _("Recents Button"),
            sub_item_table = self:buildRecents(owner),
        },
        {
            text = _("Library Button"),
            sub_item_table = self:buildLibrary(owner),
        },
        {
            text = _("PIN Pad Lock"),
            sub_item_table_func = function() return PinPad:buildMenu(owner) end,
        },
        {
            text = _("Edit Widget UI"),
            sub_item_table = appearance,
        },
    }

    return widget_items
end

function Settings:descriptionDiagnostics()
    local json = require("json")
    local key = G_reader_settings:readSetting("slate.descriptions.google_api_key", "")
    key = type(key) == "string" and key:gsub("^%s+", ""):gsub("%s+$", "") or ""
    local loaded, descriptions = pcall(require, "slate_book_descriptions")
    local origin, build = "Unavailable", "Unknown / older module"
    if loaded and type(descriptions) == "table" then
        build = descriptions.BUILD or build
        local fn = descriptions.download or descriptions.refreshAsync
        if type(fn) == "function" then
            local info = debug.getinfo(fn, "S")
            origin = info and info.source or origin
            if origin:sub(1,1) == "@" then
                origin = origin:sub(2)
                if origin:sub(1,1) ~= "/" then
                    local available, lfs = pcall(require, "libs/libkoreader-lfs")
                    if available and type(lfs.currentdir) == "function" then
                        local ok, cwd = pcall(lfs.currentdir)
                        if ok then origin = cwd .. "/" .. origin end
                    end
                end
            end
        end
    end
    local function sanitize(value)
        value = tostring(value or "")
        if key ~= "" then
            local pattern = key:gsub("([^%w])", "%%%1")
            value = value:gsub(pattern, "[redacted]")
        end
        return value:gsub("AIza[%w_%-]+", "[redacted]"):sub(1, 500)
    end
    local function test()
        local available, https = pcall(require, "ssl.https")
        local report = {
            "Loaded description module: " .. origin,
            "Build: " .. tostring(build),
            "Google key: " .. (key ~= "" and "saved" or "not saved"),
        }
        if not available then
            report[#report + 1] = "HTTPS support is unavailable."
            return table.concat(report, "\n\n")
        end
        local function request(label, url, summarize)
            local chunks, bytes = {}, 0
            local previous = https.TIMEOUT; https.TIMEOUT = 12
            local has_timeout, socketutil = pcall(require, "socketutil")
            if has_timeout and type(socketutil.set_timeout) == "function" then
                pcall(socketutil.set_timeout, socketutil, 6, 12)
            end
            local ok, result, code = pcall(https.request, {
                url = url, redirect = false,
                headers = {Accept = "application/json", ["User-Agent"] = "Slate description diagnostics"},
                sink = function(chunk)
                    if chunk then
                        bytes = bytes + #chunk
                        if bytes > 2097152 then return nil, "Response too large" end
                        chunks[#chunks + 1] = chunk
                    end
                    return 1
                end,
            })
            https.TIMEOUT = previous
            if has_timeout and type(socketutil.reset_timeout) == "function" then
                pcall(socketutil.reset_timeout, socketutil)
            end
            local decoded, data = pcall(json.decode, table.concat(chunks))
            local status = tonumber(code)
            if ok and result and status == 200 then
                report[#report + 1] = label .. ": HTTP 200 — "
                    .. (decoded and type(data) == "table" and summarize(data) or "unreadable JSON")
            else
                local reason = decoded and type(data) == "table" and data.error
                local message = type(reason) == "table" and reason.message
                local state = type(reason) == "table" and reason.status
                report[#report + 1] = label .. ": " .. (status and "HTTP " .. status or "connection failed")
                    .. (state and "\n" .. sanitize(state) or "")
                    .. (message and "\n" .. sanitize(message) or "")
            end
        end
        request("Open Library / The Artist's Way", "https://openlibrary.org/works/OL14856321W.json", function(data)
            local description = data.description
            if type(description) == "table" then description = description.value end
            return type(description) == "string" and description ~= ""
                and "description received (" .. #description .. " characters)" or "record has no description"
        end)
        if key ~= "" then
            request("Google Books", "https://www.googleapis.com/books/v1/volumes?maxResults=5&printType=books&q="
                .. util.urlEncode([[intitle:"The Artist's Way"]]) .. "&key=" .. util.urlEncode(key), function(data)
                local count = 0
                for _, item in ipairs(data.items or {}) do
                    local text = item.volumeInfo and item.volumeInfo.description
                    if type(text) == "string" and text ~= "" then count = count + 1 end
                end
                return tostring(#(data.items or {})) .. " results, " .. count .. " descriptions"
            end)
        end
        return table.concat(report, "\n\n")
    end
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local notice = InfoMessage:new{modal=true, text=_("Testing description sources…")}
        showDialog(SlateUtils:themePopup(notice))
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        local completed, report = Trapper:dismissableRunInSubprocess(test, notice)
        UIManager:close(notice)
        if completed and type(report) == "string" then
            showDialog(SlateUtils:themePopup(InfoMessage:new{modal=true, text=report}))
        end
    end)
end

function Settings:build(owner)
    return Settings:buildWidget(owner)
end

function Settings:showEditor(owner,custom_items)
    if owner._slate_settings_editor then return end
    local TouchMenu=require("ui/widget/touchmenu")
    local InputContainer=require("ui/widget/container/inputcontainer")
    local CenterContainer=require("ui/widget/container/centercontainer")
    local host=InputContainer:new{modal=true,dimen=Screen:getSize()}
    -- Coalesce menu updates, then rebuild the underlying card from saved
    -- settings without fetching weather or closing the editor and its dialogs.
    local refresh_pending=false
    local function refreshCard()
        if custom_items or refresh_pending or type(owner.refreshWeatherScreen)~="function" then return end
        refresh_pending=true
        UIManager:nextTick(function()
            refresh_pending=false
            owner:refreshWeatherScreen(true)
            UIManager:setDirty(nil,"full")
        end)
    end
    local function close()
        if host.closed then return end
        host.closed=true
        UIManager:close(host)
    end
    host.onClose=close
    host.onCloseWidget=function()
        if owner._slate_settings_editor==host then owner._slate_settings_editor=nil end
        if host.menu then host.menu:free();host.menu=nil;host[1]=nil end
        UIManager:setDirty(nil,"ui")
    end
    local items=custom_items or self:build(owner)
    items.icon="appbar.settings"
    local menu=TouchMenu:new{tab_item_table={items},last_index=1,show_parent=host,
        width=math.min(math.floor(Screen:getWidth()*.96),Screen:scaleBySize(900)),
        height=math.floor(Screen:getHeight()*(custom_items and .80 or .65)),close_callback=close}
    local function center(instance)
        for _,row in ipairs(instance.item_group or {})do
            if row.item and row.item._slate_apply and row.item_frame then
                row.item_frame.bordersize=1
                row.item_frame.radius=Screen:scaleBySize(12)
            end
        end
        instance.menu_frame.radius=tonumber(G_reader_settings:readSetting("slate.popup_corner_radius",40)) or 40
        instance[1]=CenterContainer:new{dimen=Screen:getSize(),instance.menu_frame}
    end
    center(menu)
    local update=menu.updateItems
    menu.updateItems=function(instance,...)
        local result=update(instance,...)
        center(instance)
        refreshCard()
        UIManager:setDirty(nil,"ui")
        if UIManager.forceRePaint then UIManager:forceRePaint()end
        return result
    end
    local select=menu.onMenuSelect
    if type(select)=="function" then
        menu.onMenuSelect=function(instance,...)
            local result=select(instance,...)
            refreshCard()
            return result
        end
    end
    menu.onTapCloseAllMenus=function(instance,_,ges)
        local r=instance.menu_frame.dimen
        local pos=ges and ges.pos
        if r and r.x and pos and (pos.x<r.x or pos.x>=r.x+r.w or pos.y<r.y or pos.y>=r.y+r.h) then
            if require('slate_popup_navigation'):switch(host,owner,ges)then return true end
            close();return true
        end
    end
    host.menu=menu
    host[1]=SlateUtils:themePopup(menu)
    owner._slate_settings_editor=host
    UIManager:show(host,"ui")
    if UIManager.forceRePaint then UIManager:forceRePaint()end
end

return Settings
