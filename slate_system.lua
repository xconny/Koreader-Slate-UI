-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Slate System pop-ups. Wi-Fi uses KOReader's network manager; Bluetooth
-- uses an isolated Kindle adapter derived from ZenOS (see bundled license).
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Utils = require("slate_utils")
local Event = require("ui/event")
local logger = require("logger")
local _ = require("gettext")
local System = {}
local Session = {}
Session.__index = Session

local function themed(widget)
    if Utils.themePopup then return Utils:themePopup(widget) end
    return widget
end
local function kindle()
    return Device.isKindle and Device:isKindle()
end
local function secured(network)
    local flags = tostring(network.flags or ""):upper()
    return flags:find("WPA",1,true) or flags:find("SAE",1,true)
        or flags:find("WEP",1,true) or flags:find("PSK",1,true)
end
function Session:defer(action)
    return function()
        UIManager:nextTick(function()
            if self.closed then return end
            local ok, err = pcall(action)
            if not ok then
                logger.warn("Slate: system control failed:", tostring(err))
                self:notice(_("The system action could not be completed."))
            end
        end)
    end
end
function Session:track(widget)
    self.dialogs[widget] = true
    local close = widget.onCloseWidget
    widget.onCloseWidget = function(instance, ...)
        self.dialogs[instance] = nil
        if self.view == instance then self.view = nil end
        if close then close(instance, ...) end
        UIManager:setDirty(nil, "ui")
    end
    return themed(widget)
end
function Session:show(widget)
    if self.closed then return end
    UIManager:show(self:track(widget), "ui")
    UIManager:setDirty(nil, "ui")
end
function Session:clearView()
    if self.view then UIManager:close(self.view); self.view = nil end
end
function Session:notice(text)
    if self.closed then return end
    self:show(require("ui/widget/infomessage"):new{modal=true, text=text})
end
function Session:dialog(title, rows)
    if self.closed then return end
    self:clearView()
    for _, row in ipairs(rows) do
        for _, button in ipairs(row) do
            if button.callback then button.callback = self:defer(button.callback) end
        end
    end
    local widget = require("ui/widget/buttondialog"):new{
        modal=true, title=title, title_align="center", buttons=rows,
        width=math.min(math.floor(Screen:getWidth()*.86),Screen:scaleBySize(760)),
        tap_close_callback=self:defer(function()self:close()end),
    }
    if widget.movable and widget.movable[1] then
        widget.movable[1].radius=G_reader_settings:readSetting("slate.popup_corner_radius",40)
    end
    self.view=widget
    self:show(widget)
end
function Session:list(title, items, back)
    if self.closed then return end
    self:clearView()
    for _, item in ipairs(items) do
        if item.enabled==false then item.select_enabled=false end
        if item.callback then item.callback=self:defer(item.callback) end
    end
    local menu=require("ui/widget/menu"):new{
        modal=true,title=title,item_table=items,
        width=math.min(math.floor(Screen:getWidth()*.90),Screen:scaleBySize(820)),
        height=math.floor(Screen:getHeight()*.65),items_per_page=7,
        is_popout=false,show_parent=nil,
    }
    -- Center this instance only; never patch KOReader's Menu/Button classes.
    local frame=menu[1]
    if frame then
        frame.radius=G_reader_settings:readSetting("slate.popup_corner_radius",40)
        menu[1]=require("ui/widget/container/centercontainer"):new{dimen=Screen:getSize(),frame}
        if menu.dimen then
            menu.dimen.x=math.floor((Screen:getWidth()-menu.dimen.w)/2)
            menu.dimen.y=math.floor((Screen:getHeight()-menu.dimen.h)/2)
        end
        local paint=menu.paintTo
        if paint then
            menu.paintTo=function(instance,...)
                local result=paint(instance,...)
                if frame.dimen then
                    instance.dimen=require("ui/geometry"):new{
                        x=frame.dimen.x,y=frame.dimen.y,w=frame.dimen.w,h=frame.dimen.h,
                    }
                end
                return result
            end
        end
    end
    if back then menu.close_callback=self:defer(back) end
    -- Native Menu invokes close_callback after every selection. Here it is
    -- navigation back, so keep it exclusively for the close/back control.
    menu.onMenuSelect=function(_,item)
        if item.enabled~=false and item.select_enabled~=false and item.callback then item.callback()end
        return true
    end
    self.view=menu
    self:show(menu)
end
-- Expensive scans and connection requests run in a cancellable subprocess.
-- Only data comes back; UI and current NetworkMgr bookkeeping stay in parent.
function Session:run(message, work, finished)
    if self.closed or self.busy then return end
    self.busy=true
    local trap=require("ui/widget/infomessage"):new{modal=true,text=message}
    self:show(trap)
    local Trapper=require("ui/trapper")
    Trapper:wrap(function()
        local ran, completed, result = pcall(function()
            return Trapper:dismissableRunInSubprocess(function()
                local ok, data = pcall(work)
                if not ok then return {error=_("The device could not complete this request.")} end
                return data
            end,trap)
        end)
        if self.dialogs[trap] then UIManager:close(trap) end
        self.busy=false
        if self.closed then return end
        if not ran or not completed or type(result)~="table" or result.error then
            if self.connecting then NetworkMgr.pending_connection=false;self.connecting=false end
            if not completed and ran then return end
            self:notice(type(result)=="table"and result.error or _("The system request failed."))
            return
        end
        local ok,err=pcall(finished,result)
        if not ok then logger.warn("Slate: system result failed:",tostring(err));self:notice(_("Could not display the result."))end
    end)
end
function Session:schedule(delay, callback)
    local timer
    timer=function()
        self.timers[timer]=nil
        if not self.closed then callback()end
    end
    self.timers[timer]=true
    UIManager:scheduleIn(delay,timer)
end
function Session:close()
    if self.closed then return end
    self.closed=true
    if self.connecting then NetworkMgr.pending_connection=false;self.connecting=false end
    if self.bluetooth then self.bluetooth:close()end
    for timer in pairs(self.timers)do UIManager:unschedule(timer)end
    self.timers={}
    -- Resume/cancel a trapped subprocess before closing its blocking widget.
    if self.busy then
        for widget in pairs(self.dialogs)do
            if widget.dismiss_callback then pcall(widget.dismiss_callback)end
        end
    end
    local dialogs={}
    for widget in pairs(self.dialogs)do dialogs[#dialogs+1]=widget end
    for i=#dialogs,1,-1 do if self.dialogs[dialogs[i]]then UIManager:close(dialogs[i])end end
    if self.owner._slate_system_session==self then self.owner._slate_system_session=nil end
    UIManager:setDirty(nil,"ui")
end
function Session:wifiStatus()
    local on=NetworkMgr:isWifiOn()
    if not on then return _("Off") end
    local ok, network=pcall(NetworkMgr.getCurrentNetwork,NetworkMgr)
    return ok and network and network.ssid or _("On — not connected")
end
function Session:wifi()
    self:dialog(_("WI-FI").."\n"..self:wifiStatus(),{
        {{text=NetworkMgr:isWifiOn()and _("Turn Wi-Fi Off")or _("Turn Wi-Fi On"),callback=function()self:toggleWifi()end}},
        {{text=_("Select Network"),callback=function()self:networks()end}},
        {{text=_("Close"),callback=function()self:close()end}},
    })
end
function Session:toggleWifi(then_scan)
    if self.busy then return end
    local enable=then_scan or not NetworkMgr:isWifiOn()
    self.busy=true
    -- Kindle's turnOnWifi also reconnects/opens native non-modal dialogs; its
    -- restore hook powers the radio without putting those behind Slate.
    local ok,err=pcall(function()
        if not enable then NetworkMgr:disableWifi(nil,true)
        elseif kindle()and type(NetworkMgr.restoreWifiAsync)=="function"then NetworkMgr:restoreWifiAsync()
        else NetworkMgr:turnOnWifi(nil,false)end
    end)
    if not ok then self.busy=false;self:notice(_("Could not change Wi-Fi power."));return end
    self:clearView()
    self:dialog(_("WI-FI"),{{{text=enable and _("Turning on Wi-Fi…")or _("Turning off Wi-Fi…"),enabled=false}}})
    local attempts=0
    local function ready()
        attempts=attempts+1
        if (not not NetworkMgr:isWifiOn())==(not not enable)then
            self.busy=false
            if then_scan then self:networks()else self:wifi()end
        elseif attempts>=20 then self.busy=false;self:wifi();self:notice(_("Wi-Fi power did not change. Check airplane mode and device support."))
        else self:schedule(.5,ready)end
    end
    self:schedule(.5,ready)
end
function Session:networks()
    if not NetworkMgr:isWifiOn()then self:toggleWifi(true);return end
    self:run(_("Scanning for Wi-Fi networks…"),function()
        local networks,err=NetworkMgr:getNetworkList()
        if not networks then return {error=err or _("Wi-Fi network scanning is not supported on this device.")}end
        return {networks=networks}
    end,function(result)
        local networks=result.networks or {}
        table.sort(networks,function(a,b)
            if (not not a.connected)~=(not not b.connected)then return not not a.connected end
            return (tonumber(a.signal_quality)or 0)>(tonumber(b.signal_quality)or 0)
        end)
        local items={{text=_("Refresh Networks"),callback=function()self:networks()end}}
        for _,network in ipairs(networks)do
            if type(network.ssid)=="string"and network.ssid~=""then
                local entry=network
                items[#items+1]={text=entry.ssid..(entry.connected and "  ✓"or "")
                    ..(secured(entry)and "  [secured]"or ""),callback=function()self:network(entry)end}
            end
        end
        if #items==1 then items[#items+1]={text=_("No networks found. Try Refresh Networks."),enabled=false}end
        self:list(_("WI-FI NETWORKS"),items,function()self:wifi()end)
    end)
end
function Session:network(network)
    local rows={}
    if network.connected then
        -- KOReader's Kindle disconnectNetwork is a no-op: turn off the radio
        -- explicitly rather than report a disconnect that never happened.
        rows[#rows+1]={{text=kindle()and _("Disconnect — Turn Wi-Fi Off")or _("Disconnect"),callback=function()
            if kindle()then self:toggleWifi()
            else
                self:run(_("Disconnecting…"),function()
                    NetworkMgr:disconnectNetwork(network);NetworkMgr:releaseIP();return {ok=true}
                end,function()NetworkMgr.lease_ssid=nil;UIManager:broadcastEvent(Event:new("NetworkDisconnected"));self:networks()end)
            end
        end}}
    else
        rows[#rows+1]={{text=_("Connect"),callback=function()
            if secured(network)and not network.password then self:password(network)else self:connect(network)end
        end}}
    end
    rows[#rows+1]={{text=_("Enter / Change Password"),callback=function()self:password(network)end}}
    rows[#rows+1]={{text=_("Back to Networks"),callback=function()self:networks()end}}
    self:dialog(network.ssid,rows)
end
function Session:password(network)
    self:clearView()
    local input
    input=require("ui/widget/inputdialog"):new{
        modal=true,title=_("WI-FI PASSWORD").."\n"..network.ssid,
        input="",input_hint=_("Password (leave empty for an open network)"),
        input_type="text",text_type="password",width=math.floor(Screen:getWidth()*.86),
        buttons={{{text=_("Cancel"),id="close",callback=self:defer(function()
            UIManager:close(input);self:network(network)
        end)},{text=_("Connect"),is_enter_default=true,callback=self:defer(function()
            local value=input:getInputText()or ""
            if secured(network)and value==""then self:notice(_("Enter the network password."));return end
            network.password=value;network.psk=nil
            UIManager:close(input);self:connect(network,true)
        end)}}},
    }
    self.view=input;self:show(input)
    input:onShowKeyboard()
end
function Session:connect(network, save)
    if self.closed or self.busy then return end
    if not secured(network)and network.password==nil then network.password="";save=true end
    if type(NetworkMgr.unscheduleConnectivityCheck)=="function"then NetworkMgr:unscheduleConnectivityCheck()end
    self.connecting=true;NetworkMgr.pending_connection=true
    UIManager:broadcastEvent(Event:new("NetworkConnecting"))
    self:clearView()
    self:run(_("Connecting to Wi-Fi…"),function()
        local adapter=kindle()and require("slate_system_wifi_kindle").new(NetworkMgr)or nil
        if save then
            if adapter then
                local stored=adapter.replaceNetwork(network)
                if not stored then return {error=_("Could not save the Kindle Wi-Fi profile. Check the password and firmware support.")}end
            else NetworkMgr:saveNetwork(network)end
        end
        local ok,err
        if adapter then ok,err=adapter.connect(network)else ok,err=NetworkMgr:authenticateNetwork(network)end
        if not ok then return {error=err or _("Authentication failed. Check the password.")}end
        NetworkMgr:obtainIP()
        return {accepted=true}
    end,function()
        -- Child-side settings objects are not shared with the parent process.
        if not kindle()and type(NetworkMgr.readNWSettings)=="function"then NetworkMgr:readNWSettings()end
        NetworkMgr.lease_ssid=nil
        NetworkMgr.pending_connection=true
        self.connecting=true
        self:dialog(_("WI-FI"),{{{text=_("Connecting…"),enabled=false}}})
        local tries=0
        local function check()
            tries=tries+1
            local ok,current=pcall(NetworkMgr.getCurrentNetwork,NetworkMgr)
            if ok and current and current.ssid==network.ssid and NetworkMgr:isConnected()then
                NetworkMgr.pending_connection=false;NetworkMgr.lease_ssid=network.ssid
                self.connecting=false
                NetworkMgr.wifi_was_on=true
                G_reader_settings:saveSetting("wifi_was_on",true)
                UIManager:broadcastEvent(Event:new("NetworkConnected"))
                self:wifi();self:notice(_("Connected to ")..network.ssid)
            elseif tries>=30 then
                NetworkMgr.pending_connection=false
                self.connecting=false
                self:network(network)
                self:notice(_("The requested network did not connect. Check the password, signal and router. A connection request alone does not confirm success."))
            else self:schedule(.5,check)end
        end
        self:schedule(.5,check)
    end)
end
function Session:bt()
    self.bluetooth=self.bluetooth or require("slate_system_bluetooth").new()
    local state,err=self.bluetooth:state()
    self:dialog(_("BLUETOOTH").."\n"..(state==nil and _(err)or state and _("On")or _("Off")),{
        {{text=state and _("Turn Bluetooth Off")or _("Turn Bluetooth On"),enabled=state~=nil,
            callback=function()self:toggleBluetooth()end}},
        {{text=_("Select Device"),enabled=state~=nil,callback=function()
            if state then self:devices(false)else self:toggleBluetooth(true)end
        end}},
        {{text=_("Close"),callback=function()self:close()end}},
    })
end
function Session:toggleBluetooth(show_devices)
    if self.busy then return end
    local state,err=self.bluetooth:state()
    if state==nil then self:notice(_(err));return end
    self.busy=true
    self:dialog(_("BLUETOOTH"),{{{text=_("Changing Bluetooth state…"),enabled=false}}})
    self.bluetooth:setEnabled(show_devices or not state,function(ok,reason)
        self.busy=false
        if self.closed then return end
        if ok then
            UIManager:broadcastEvent(Event:new("BluetoothStateChanged"))
            if show_devices then self:devices(true)else self:bt()end
        else self:bt();self:notice(_(reason or "Could not change Bluetooth power."))end
    end)
end
function Session:devices(scan)
    if self.closed or self.busy then return end
    local adapter=self.bluetooth:getAdapter()
    if scan then
        self.busy=true
        self:dialog(_("BLUETOOTH DEVICES"),{{{text=_("Scanning… Put the device in pairing mode."),enabled=false}},
            {{text=_("Cancel Scan"),callback=function()adapter.cancelScan();self.busy=false;self:devices(false)end}}})
        adapter.scan(function(ok,reason)
            self.busy=false
            if self.closed then return end
            if ok then self:devices(false)
            elseif reason~="Cancelled."then self:bt();self:notice(_(reason or "Bluetooth scan failed."))end
        end)
        return
    end
    local devices,err=adapter.getDeviceList()
    if not devices then self:bt();self:notice(_(err));return end
    table.sort(devices,function(a,b)
        if (not not a.connected)~=(not not b.connected)then return not not a.connected end
        if (not not a.paired)~=(not not b.paired)then return not not a.paired end
        return a.name:lower()<b.name:lower()
    end)
    local items={{text=_("Scan for Devices"),callback=function()self:devices(true)end}}
    for _,device in ipairs(devices)do
        local entry=device
        local status=entry.connected and _("connected")or entry.paired and _("paired")or _("available")
        items[#items+1]={text=entry.name.."  ["..status.."]",callback=function()self:device(entry)end}
    end
    if #devices==0 then items[#items+1]={text=_("No devices found. Enable pairing mode and scan."),enabled=false}end
    self:list(_("BLUETOOTH DEVICES"),items,function()self:bt()end)
end
function Session:device(device)
    local adapter=self.bluetooth:getAdapter()
    local function action(method, after)
        self.busy=true
        self:dialog(device.name,{{{text=_("Please wait…"),enabled=false}}})
        adapter[method](device,function(ok,reason)
            self.busy=false
            if self.closed then return end
            if ok and after then after();return end
            if ok then UIManager:broadcastEvent(Event:new("BluetoothStateChanged"))end
            self:devices(false)
            if not ok then self:notice(_(reason or "Bluetooth operation failed."))end
        end)
    end
    local rows={}
    if device.connected then
        rows[#rows+1]={{text=_("Disconnect"),callback=function()action("disconnect")end}}
    elseif device.paired then
        rows[#rows+1]={{text=_("Connect"),callback=function()action("connect")end}}
    else
        rows[#rows+1]={{text=_("Pair and Connect"),callback=function()
            action("pair",function()action("connect")end)
        end}}
    end
    if device.paired then
        rows[#rows+1]={{text=_("Forget Device"),callback=function()
            if device.connected then action("disconnect",function()action("forget")end)else action("forget")end
        end}}
    end
    rows[#rows+1]={{text=_("Back to Devices"),callback=function()self:devices(false)end}}
    self:dialog(device.name,rows)
end
function System:open(owner,kind)
    self:close(owner)
    local session=setmetatable({owner=owner,dialogs={},timers={}},Session)
    owner._slate_system_session=session
    local ok,err=pcall(function()if kind=="bluetooth"then session:bt()else session:wifi()end end)
    if not ok then logger.warn("Slate: could not open system menu:",err);session:notice(_("System controls are unavailable on this device."))end
end
function System:close(owner)
    if owner and owner._slate_system_session then owner._slate_system_session:close()end
end
return System
