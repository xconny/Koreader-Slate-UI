-- PIN pad behavior adapted from Lena2309's PIN pad interface.
-- Modified for Slate on 2026-10-09.

local InputContainer = require("ui/widget/container/inputcontainer")
local PinPadButtonDialog = require("slate_pinpadbuttondialog")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SlateUtils = require("slate_utils")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local IconWidget = require("ui/widget/iconwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")

local PinPad = {}
local PREFIX = "slate.pin."
local MAX_ATTEMPTS = 3
local BLOCK_SECONDS = 30
local MIN_LENGTH = 4
local MAX_LENGTH = 12

local function read(key, default)
    return G_reader_settings:readSetting(PREFIX .. key, default)
end

local function save(key, value)
    G_reader_settings:saveSetting(PREFIX .. key, value)
    G_reader_settings:flush()
end

local function validPin(pin)
    return type(pin) == "string" and #pin >= MIN_LENGTH
        and #pin <= MAX_LENGTH and pin:match("^%d+$") ~= nil
end

function PinPad:hasPin()
    return validPin(read("code"))
end

function PinPad:isEnabled()
    return read("enabled", false) == true and self:hasPin()
end

function PinPad:hasBeenEnabled()
    return read("ever_enabled", false) == true or self:isEnabled()
end

function PinPad:showSleepScreenButton()
    return self:hasBeenEnabled()
        and (self:isEnabled() or read("remove_from_sleep_screen", false) ~= true)
end

function PinPad:showCircleOutline()
    return read("circle_outline", false) == true
end

if PinPad:isEnabled() and not read("ever_enabled", false) then
    save("ever_enabled", true)
end

local function centeredStatusMessage(message)
    local face = Font:getFace("infofont")
    local label = TextWidget:new{text = message, face = face}
    local icon = IconWidget:new{icon = "notice-info", alpha = true}
    local text_width, icon_width = label:getSize().w, icon:getSize().w
    label:free()
    icon:free()
    local dialog = InfoMessage:new{
        text = message,
        face = face,
        width = math.ceil(text_width + icon_width + Screen:scaleBySize(2)),
        force_one_line = true,
        timeout = 2,
    }
    local frame = dialog.movable and dialog.movable[1]
    local row = frame and frame[1]
    if row then
        local dimensions = row:getSize()
        frame[1] = CenterContainer:new{
            dimen = Geom:new{
                w = dimensions.w + Screen:scaleBySize(6) * 2,
                h = dimensions.h,
            },
            row,
        }
    end
    return SlateUtils:themePopup(dialog)
end

function PinPad:toggleEnabled(owner)
    if self:intercept(owner) then return true end
    local enabled = self:isEnabled()
    if not enabled and not self:hasPin() then
        UIManager:show(InfoMessage:new{
            text = _("Set and confirm a PIN in Slate’s PIN Pad Lock settings first."),
        })
        return true
    end
    if not enabled then
        save("ever_enabled", true)
        save("remove_from_sleep_screen", false)
    end
    save("enabled", not enabled)
    if enabled then self:close(owner) end
    if owner and owner._slate_screen then
        UIManager:setDirty(owner._slate_screen, "ui")
    end
    UIManager:show(centeredStatusMessage(
        enabled and _("PIN lock disabled.") or _("PIN lock enabled.")))
    return true
end

local function updateMenu(menu)
    if menu and menu.updateItems then menu:updateItems() end
end

local Guard = InputContainer:extend{ modal = true, covers_fullscreen = false }

function Guard:init()
    self.dimen = Screen:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Guard:paintTo()
end

function Guard:onTap()
    PinPad:showKeypad(self.owner)
    return true
end

function Guard:handleEvent(event)
    local handled = InputContainer.handleEvent(self, event)
    if handled then return handled end
    local handler = event and event.handler or ""
    if handler:match("^on.*Key") or handler:match("^on.*Touch")
        or handler:match("^on.*Tap") or handler:match("^on.*Hold")
        or handler:match("^on.*Swipe") or handler:match("^on.*Pan")
        or handler:match("^on.*Pinch") or handler:match("^on.*Spread")
        or handler:match("^on.*Gesture") or handler == "onClose"
        or handler == "onBack" then
        return true
    end
    return handled
end

function Guard:onAnyKeyPressed()
    PinPad:showKeypad(self.owner)
    return true
end

function Guard:onClose()
    return true
end

function PinPad:cancelTimer()
    if self._timer then UIManager:unschedule(self._timer) end
    self._timer = nil
end

function PinPad:closeDialog()
    self:cancelTimer()
    local dialog = self._dialog
    self._dialog = nil
    if dialog then
        dialog._slate_internal_close = true
        UIManager:close(dialog)
    end
end

function PinPad:closeSession()
    self:closeDialog()
    self._session = nil
end

function PinPad:close(owner)
    if owner and self._owner and owner ~= self._owner then return end
    self:closeSession()
    local guard = self._guard
    self._guard = nil
    if guard then UIManager:close(guard) end
    if self._owner then
        self._owner._slate_pin_locked = false
        self._owner._pinpad_active = false
    end
    self._owner = nil
end

function PinPad:suspend(owner)
    self:close(owner)
    if owner then owner._slate_pin_locked = self:isEnabled() end
end

function PinPad:arm(owner)
    if not owner or not self:isEnabled() then return false end
    if self._owner == owner and self._guard then return true end
    self:close()
    if owner.closeWeatherPopups then owner:closeWeatherPopups() end
    self._owner = owner
    owner._slate_pin_locked = true
    owner._pinpad_active = true
    self._guard = Guard:new{ owner = owner }
    UIManager:show(self._guard)
    return true
end

function PinPad:intercept(owner)
    if owner and owner._slate_pin_locked then
        if not self._guard then self:arm(owner) end
        self:showKeypad(owner)
        return true
    end
    return false
end

function PinPad:lock(owner)
    if self:arm(owner) then self:showKeypad(owner) end
    return true
end

function PinPad:blockRemaining()
    local until_time = tonumber(read("blocked_until", 0)) or 0
    return math.max(0, math.min(BLOCK_SECONDS, math.ceil(until_time - os.time())))
end

function PinPad:clearAttempts()
    G_reader_settings:saveSetting(PREFIX .. "failed_attempts", 0)
    G_reader_settings:saveSetting(PREFIX .. "blocked_until", 0)
    G_reader_settings:flush()
end

function PinPad:failedAttempt(session)
    local attempts = (tonumber(read("failed_attempts", 0)) or 0) + 1
    if attempts >= MAX_ATTEMPTS then
        G_reader_settings:saveSetting(PREFIX .. "failed_attempts", 0)
        G_reader_settings:saveSetting(PREFIX .. "blocked_until", os.time() + BLOCK_SECONDS)
        G_reader_settings:flush()
    else
        save("failed_attempts", attempts)
    end
    session.pin = ""
    session.error = _("Wrong PIN. Try again.")
    self:renderSession()
end

function PinPad:finishPin(pin)
    local session = self._session
    save("code", pin)
    self:clearAttempts()
    self:closeSession()
    if session then updateMenu(session.menu) end
    UIManager:show(InfoMessage:new{ text = _("PIN saved successfully."), timeout = 2 })
end

function PinPad:submit()
    local session = self._session
    if not session then return true end
    if (session.stage == "unlock" or session.stage == "verify")
        and self:blockRemaining() > 0 then
        self:renderSession()
        return true
    end
    if session.pin == "" then return true end

    if session.stage == "unlock" or session.stage == "verify" then
        if session.pin ~= read("code") then
            self:failedAttempt(session)
            return true
        end
        self:clearAttempts()
        if session.stage == "unlock" then
            local owner = session.owner
            self:close(owner)
            if owner and owner._slate_screen then
                UIManager:setDirty(owner._slate_screen, "ui")
            end
            if read("show_success_message", false) then
                UIManager:show(InfoMessage:new{
                    text = tostring(read("success_message", _("Correct PIN, have fun!"))),
                    timeout = 2,
                })
            end
        elseif session.action == "reset" then
            self:finishPin("1234")
        else
            session.stage = "new"
            session.pin = ""
            session.error = nil
            self:renderSession()
        end
    elseif session.stage == "new" then
        if not validPin(session.pin) then
            session.error = _("Use 4–12 digits for your PIN.")
            self:renderSession()
            return true
        end
        session.pending = session.pin
        session.pin = ""
        session.stage = "confirm"
        session.error = nil
        self:renderSession()
    elseif session.stage == "confirm" then
        if session.pin == session.pending then
            self:finishPin(session.pin)
        else
            session.stage = "new"
            session.pending = nil
            session.pin = ""
            session.error = _("The PINs did not match. Set your PIN again.")
            self:renderSession()
        end
    end
    return true
end

function PinPad:append(digit)
    local session = self._session
    if not session then return end
    if (session.stage == "unlock" or session.stage == "verify")
        and self:blockRemaining() > 0 then return end
    if #session.pin >= MAX_LENGTH then return end
    session.pin = session.pin .. digit
    session.error = nil
    self:renderSession()
end

function PinPad:delete(clear)
    local session = self._session
    if not session then return end
    session.pin = clear and "" or session.pin:sub(1, -2)
    session.error = nil
    self:renderSession()
end

function PinPad:renderSession()
    local session = self._session
    if not session then return end
    self:closeDialog()
    local titles = {
        unlock = _("Enter your PIN"),
        verify = _("Enter the current PIN"),
        new = _("Set a new PIN (4–12 digits)"),
        confirm = _("Confirm your new PIN"),
    }
    local remaining = (session.stage == "unlock" or session.stage == "verify")
        and self:blockRemaining() or 0
    local title = titles[session.stage]
    if remaining > 0 then
        title = string.format(_("Too many failed attempts. Wait %d seconds."), remaining)
    elseif session.error then
        title = title .. "\n" .. session.error
    end
    title = title .. "\n" .. (#session.pin > 0 and string.rep("*", #session.pin) or "—")
    local buttons = {}
    for row = 0, 2 do
        local line = {}
        for column = 1, 3 do
            local digit = tostring(row * 3 + column)
            line[#line + 1] = {
                text = digit,
                enabled = remaining == 0,
                callback = function() self:append(digit) end,
            }
        end
        buttons[#buttons + 1] = line
    end
    buttons[#buttons + 1] = {
        { text = _("DELETE"), callback = function() self:delete(false) end,
            hold_callback = function() self:delete(true) end },
        { text = "0", enabled = remaining == 0, callback = function() self:append("0") end },
        { text = _("OK"), enabled = remaining == 0, callback = function() self:submit() end },
    }
    if session.stage ~= "unlock" then
        buttons[#buttons + 1] = {{
            text = _("CANCEL"), callback = function() self:closeSession() end,
        }}
    end
    local dialog = PinPadButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
        dismissable = false,
        override_show_message = session.stage ~= "unlock",
    }
    local original_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(this, ...)
        if self._dialog == this then self._dialog = nil end
        if not this._slate_internal_close then
            self:cancelTimer()
            if session.stage ~= "unlock" and self._session == session then
                self._session = nil
            end
        end
        if original_close then return original_close(this, ...) end
    end
    self._dialog = dialog
    UIManager:show(dialog)
    if remaining > 0 then
        self._timer = function()
            self._timer = nil
            if self._session == session and self._dialog == dialog then
                session.error = nil
                self:renderSession()
            end
        end
        UIManager:scheduleIn(remaining, self._timer)
    end
end

function PinPad:showKeypad(owner)
    if not owner or not owner._slate_pin_locked or not self:hasPin() then return true end
    if self._dialog then return true end
    self._session = { stage = "unlock", pin = "", owner = owner }
    self:renderSession()
    return true
end

function PinPad:changePin(menu)
    if self._guard then return end
    self:closeSession()
    self._session = {
        stage = self:hasPin() and "verify" or "new",
        action = "change", pin = "", menu = menu,
    }
    self:renderSession()
end

function PinPad:resetPin(menu)
    if self._guard then return end
    UIManager:show(ConfirmBox:new{
        text = _("Reset the PIN to 1234? You must enter your current PIN first."),
        ok_text = _("Reset PIN"),
        ok_callback = function()
            self:closeSession()
            self._session = { stage = "verify", action = "reset", pin = "", menu = menu }
            self:renderSession()
        end,
    })
end

local function editMessage(key, title, description, default)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = description,
        input = tostring(read(key, default) or ""),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                save(key, dialog:getInputText() or "")
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function toggle(key, text, default)
    return {
        text = text,
        checked_func = function() return read(key, default) == true end,
        callback = function() save(key, not read(key, default)) end,
    }
end

local function radio(key, text, value, default)
    return {
        text = text,
        radio = true,
        checked_func = function() return read(key, default) == value end,
        callback = function() save(key, value) end,
    }
end

function PinPad:buildMenu(owner)
    return {
        {
            text=_("Long press lock for Slate settings"),
            checked_func=function()return read("long_press_settings",false)==true end,
            callback=function(menu)save("long_press_settings",read("long_press_settings",false)~=true);updateMenu(menu)end,
        },
        {
            text = _("Enabled"),
            checked_func = function() return self:isEnabled() end,
            callback = function(menu)
                if self:isEnabled() then
                    save("enabled", false)
                    self:close(owner)
                elseif not self:hasPin() then
                    UIManager:show(InfoMessage:new{
                        text = _("Set and confirm a PIN under Manage PIN Code before enabling PIN Pad Lock."),
                    })
                else
                    save("ever_enabled", true)
                    save("remove_from_sleep_screen", false)
                    save("enabled", true)
                end
                updateMenu(menu)
            end,
            separator = true,
        },
        {
            text = _("Remove From Sleep Screen"),
            checked_func = function()
                return not self:isEnabled() and read("remove_from_sleep_screen", false) == true
            end,
            callback = function(menu)
                if self:isEnabled() then
                    UIManager:show(InfoMessage:new{
                        text = _("Disable PIN Pad Lock before removing its sleep screen button."),
                    })
                else
                    save("remove_from_sleep_screen", not read("remove_from_sleep_screen", false))
                    if owner and owner._slate_screen then
                        UIManager:setDirty(owner._slate_screen, "ui")
                    end
                end
                updateMenu(menu)
            end,
        },
        {
            text = _("Toggle Circle Outline"),
            checked_func = function() return self:showCircleOutline() end,
            callback = function(menu)
                save("circle_outline", not self:showCircleOutline())
                if owner and owner._slate_screen then
                    UIManager:setDirty(owner._slate_screen, "ui")
                end
                updateMenu(menu)
            end,
            separator = true,
        },
        {
            text = _("Manage PIN Code"),
            sub_item_table = {
                {
                    text_func = function()
                        return self:hasPin() and _("Change PIN Code") or _("Set PIN Code")
                    end,
                    callback = function(menu) self:changePin(menu) end,
                },
                {
                    text = _("Reset PIN Code"),
                    enabled_func = function() return self:hasPin() end,
                    callback = function(menu) self:resetPin(menu) end,
                },
            },
        },
        {
            text = _("PIN pad lock message"),
            sub_item_table = {
                toggle("show_message", _("Add custom message to lock"), false),
                {
                    text = _("Edit PIN pad lock message"),
                    enabled_func = function() return read("show_message", false) == true end,
                    callback = function()
                        editMessage("message", _("PIN pad lock message"),
                            _("Enter the message shown on the keypad. Use \\n for a new line."), _("Locked"))
                    end,
                },
                {
                    text = _("Message position"),
                    enabled_func = function() return read("show_message", false) == true end,
                    sub_item_table = {
                        radio("message_position", _("Top"), "top", "top"),
                        radio("message_position", _("Middle"), "middle", "top"),
                        radio("message_position", _("Bottom"), "bottom", "top"),
                    },
                },
                {
                    text = _("Message alignment"),
                    enabled_func = function() return read("show_message", false) == true end,
                    sub_item_table = {
                        radio("message_alignment", _("Left"), "left", "center"),
                        radio("message_alignment", _("Center"), "center", "center"),
                        radio("message_alignment", _("Right"), "right", "center"),
                    },
                },
                toggle("show_success_message", _("Show success message"), false),
                {
                    text = _("Edit success message"),
                    enabled_func = function() return read("show_success_message", false) == true end,
                    callback = function()
                        editMessage("success_message", _("Success message"),
                            _("Message shown after the correct PIN is entered."), _("Correct PIN, have fun!"))
                    end,
                },
            },
        },
    }
end

return PinPad
