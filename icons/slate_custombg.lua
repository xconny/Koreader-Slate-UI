-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modified for Slate on 2026-10-09.
-- Custom background with the shared reading and weather card.

local CenterContainer = require("ui/widget/container/centercontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")

local SlateReading = require("slate_reading")

local SlateCustomBg = {}

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

function SlateCustomBg:create(slate, weather_data)
    weather_data = weather_data or { current = {} }

    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    local doc_info = SlateReading:getDocumentInfo() or {}

    local bg_path = SlateReading:getCustomBgPath()
    local background_widget = SlateReading:createLetterboxedBackgroundFromFile(
        bg_path,
        screen_width,
        screen_height
    )

    local card = SlateReading:buildOverlayCard(
        slate,
        weather_data,
        doc_info,
        screen_width,
        screen_height
    )

    local bottom_offset = tonumber(
        G_reader_settings:readSetting("slate_weather_widget_bottom_offset")
    ) or 115

    if bottom_offset < 0 then
        bottom_offset = 0
    end

    local card_container = BottomContainer:new{
        dimen = Geom:new{
            w = screen_width,
            h = screen_height,
        },
        CenterContainer:new{
            dimen = Geom:new{
                w = screen_width,
                h = card:getSize().h + math.floor(bottom_offset),
            },
            card,
        },
    }

    return FrameContainer:new{
        width = screen_width,
        height = screen_height,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = getScreenWhite(),
        OverlapGroup:new{
            dimen = Screen:getSize(),
            background_widget,
            card_container,
        },
    }
end

return SlateCustomBg