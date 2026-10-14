-- Keypad layout adapted from Lena2309's PIN pad interface.
-- Modified for Slate on 2026-10-09.

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local SlateUtils = require("slate_utils")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Geom = require("ui/geometry")
local Screen = Device.screen

local PinPadButtonDialog = ButtonDialog:extend{
    modal = true,
    dismissable = false,
    override_show_message = false,
}

local function pluginDir()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        return source:sub(2):match("^(.*)/[^/]+$") or "."
    end
    return "plugins/slate.koplugin"
end

function PinPadButtonDialog:init()
    self.width_factor = self.width_factor or 2 / 3
    self.width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * self.width_factor)
    self.dimen = Screen:getSize()
    self.key_events = {}
    self.ges_events = {}

    local face = self.use_info_style and self.info_face or self.title_face
    local spacing = Size.margin.default + Size.padding.default
    local function span()
        return VerticalSpan:new{ width = spacing }
    end
    local icon_size = Screen:scaleBySize(32)
    local heading = VerticalGroup:new{
        align = "center",
        ImageWidget:new{
            file = self.lock_icon_file or pluginDir() .. "/icons/lock.svg",
            width = icon_size,
            height = icon_size,
            alpha = true,
            original_in_nightmode = false,
        },
        span(),
        TextBoxWidget:new{
            text = self.title or "",
            face = face,
            width = self.width,
            alignment = self.title_align or "center",
        },
    }

    self.buttontable = ButtonTable:new{
        buttons = self.buttons,
        width = self.width,
        shrink_unneeded_width = self.shrink_unneeded_width,
        shrink_min_width = self.shrink_min_width,
        show_parent = self,
    }

    local function separator()
        return LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = self.width, h = Size.line.medium },
        }
    end

    local message
    if G_reader_settings:readSetting("slate.pin.show_message", false)
        and not self.override_show_message then
        local text = tostring(G_reader_settings:readSetting("slate.pin.message", "Locked") or "")
        text = text:gsub("\\n", "\n")
        local alignment = G_reader_settings:readSetting("slate.pin.message_alignment", "center")
        if alignment ~= "left" and alignment ~= "right" then alignment = "center" end
        message = TextBoxWidget:new{
            text = text,
            face = face,
            width = self.width,
            alignment = alignment,
        }
        local available = math.max(Screen:scaleBySize(24), Screen:getHeight()
            - self.buttontable:getSize().h - heading:getSize().h
            - spacing * 5 - Size.padding.default * 2 - Size.line.medium * 2)
        if message:getSize().h > available then
            message:free()
            message = ScrollTextWidget:new{
                text = text,
                face = face,
                width = self.width,
                height = available,
                alignment = alignment,
                dialog = self,
            }
        end
    end

    local children = { align = "center" }
    local function add(widget)
        children[#children + 1] = widget
    end
    local position = G_reader_settings:readSetting("slate.pin.message_position", "top")
    add(span())
    if message and position == "top" then
        add(message)
        add(span())
        add(separator())
        add(span())
    end
    add(heading)
    add(span())
    add(separator())
    if message and position == "middle" then
        add(span())
        add(message)
        add(span())
        add(separator())
    end
    add(self.buttontable)
    if message and position ~= "top" and position ~= "middle" then
        add(separator())
        add(span())
        add(message)
        add(span())
    end

    self.movable = MovableContainer:new{
        alpha = self.alpha,
        anchor = self.anchor,
        unmovable = true,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.default,
            padding_top = 0,
            padding_bottom = 0,
            VerticalGroup:new(children),
        },
    }
    self.layout = self.buttontable.layout
    self.buttontable.layout = nil
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
end

function PinPadButtonDialog:onTapClose()
    return true
end

function PinPadButtonDialog:onClose()
    return true
end

function PinPadButtonDialog:onAnyKeyPressed()
    return true
end

SlateUtils:themePopup(PinPadButtonDialog)

return PinPadButtonDialog
