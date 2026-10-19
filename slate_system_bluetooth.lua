-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Slate Bluetooth power and device-management controller.
-- Kindle service interface studied in ZenOS: https://github.com/xZenLabs/zen-os
local Device = require("device")
local UIManager = require("ui/uimanager")
local BT = {}
local SERVICE = "com.lab126.btfd"
local function call(method, property, value)
    local loaded, lipc = pcall(require, "liblipclua")
    if not loaded or type(lipc.init) ~= "function" then return nil, "Kindle Bluetooth service is unavailable." end
    local opened, handle = pcall(lipc.init, "com.github.koreader.slate.bluetooth")
    if not opened or not handle then return nil, "Could not open Kindle Bluetooth service." end
    local ok, result = pcall(function() return handle[method](handle, SERVICE, property, value) end)
    pcall(handle.close, handle)
    if not ok then return nil, "This Kindle firmware does not support that Bluetooth operation." end
    return result == nil and true or result
end
function BT.new()
    local instance = {closed=false}
    function instance:state()
        if not Device.isKindle or not Device:isKindle() then return nil, "Bluetooth controls currently support Kindle only." end
        local value, err = call("get_int_property", "BTstate")
        if type(value) ~= "number" then return nil, err or "Bluetooth is unavailable on this Kindle." end
        return value ~= 0
    end
    function instance:getAdapter()
        if not self.adapter then self.adapter = require("slate_system_bt_kindle").new() end
        return self.adapter
    end
    function instance:setEnabled(enabled, done)
        if self.closed or self.changing then return end
        local state, err = self:state()
        if state == nil then done(false, err); return end
        if state == enabled then done(true); return end
        self.changing = true
        local function finish(ok, reason)
            self.changing = false; self.timer = nil
            if not self.closed then done(ok, reason) end
        end
        local function request()
            local accepted, why = call("set_string_property", "BTenable", enabled and "1:1" or "0:1")
            if not accepted then accepted, why = call("set_int_property", "BTflightMode", enabled and 0 or 1) end
            if not accepted then finish(false, why); return end
            local attempts = 0
            local function poll()
                self.timer = nil
                if self.closed then return end
                attempts = attempts + 1
                if self:state() == enabled then finish(true)
                elseif attempts >= 20 then finish(false, "Bluetooth did not change state. This firmware may not support the request.")
                else
                    if attempts == 6 then call("set_int_property", "BTflightMode", enabled and 0 or 1) end
                    self.timer = poll; UIManager:scheduleIn(0.5, poll)
                end
            end
            self.timer = poll; UIManager:scheduleIn(0.5, poll)
        end
        if not enabled and self.adapter then
            self.adapter.cancelScan()
            local devices = self.adapter.getDeviceList()
            local connected = {}
            for _, device in ipairs(devices or {}) do if device.connected then connected[#connected+1]=device end end
            local i = 0
            local function nextDevice()
                if self.closed then return end
                i = i + 1
                if connected[i] then self.adapter.disconnect(connected[i], nextDevice) else request() end
            end
            nextDevice()
        else request() end
    end
    function instance:close()
        self.closed = true
        if self.timer then UIManager:unschedule(self.timer); self.timer = nil end
        if self.adapter then self.adapter.close() end
    end
    return instance
end
return BT
