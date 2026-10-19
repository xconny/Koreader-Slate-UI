-- SPDX-License-Identifier: GPL-3.0-only
-- Adapted from ZenOS (xZenLabs and contributors), 2026-10-19.
-- https://github.com/xZenLabs/zen-os
-- Original license: slate_system_licenses.lua. Changes: Slate logging and
-- profile operations and asynchronous scans; the picker reads real scanList
-- results even while connected, bypassing KOReader's current-profile shortcut.
-- GPLv3 section 13 permits combination with Slate's AGPLv3 code.
local ffiutil = require("ffi/util")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

local function is_secured(network)
    local flags = type(network.flags) == "string" and network.flags or ""
    return flags:find("WPA", 1, true) ~= nil or flags:find("SAE", 1, true) ~= nil
end

local function lipc_handle(client)
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if not ok_lipc or type(lipc.init) ~= "function" then
        return nil, "liblipclua unavailable"
    end
    local ok_handle, handle = pcall(lipc.init, client or "com.github.koreader.slate.wifi")
    if not ok_handle or not handle then return nil, tostring(handle) end
    return handle
end

local function profile_handle()
    local ok_lipc, lipc = pcall(require, "libopenlipclua")
    if not ok_lipc or type(lipc) ~= "table"
            or type(lipc.open_no_name) ~= "function" then
        return nil, "libopenlipclua unavailable"
    end
    local ok_handle, handle = pcall(lipc.open_no_name)
    if not ok_handle or not handle then return nil, tostring(handle) end
    return handle
end

local function read_hash(property)
    local handle, handle_error = profile_handle()
    if not handle then return nil, handle_error end
    local input
    local result
    local profiles
    local read, read_error = pcall(function()
        input = handle:new_hasharray()
        result = handle:access_hash_property("com.lab126.wifid", property, input)
        profiles = result and result:to_table()
    end)
    if result then pcall(result.destroy, result) end
    if input then pcall(input.destroy, input) end
    pcall(handle.close, handle)
    if not read then return nil, read_error end
    return profiles or {}
end

local function get_profile(ssid)
    local profiles, profiles_error = read_hash("profileData")
    if not profiles then return nil, profiles_error end
    for _i, profile in ipairs(profiles) do
        if profile.essid == ssid then return profile end
    end
    return nil
end

local function wait_for_profile(ssid, expected)
    local last_error
    for _i = 1, 20 do
        local profile, profile_error = get_profile(ssid)
        if profile_error then
            last_error = profile_error
        elseif (profile ~= nil) == expected then
            return profile or true
        end
        ffiutil.usleep(100 * 1000)
    end
    return nil, last_error or "Kindle Wi-Fi profile did not update"
end

local function delete_profile(ssid)
    local profile, profile_error = get_profile(ssid)
    if profile_error then return false, profile_error end
    if not profile then return true end
    local profile_id = tonumber(profile.netid)
    if not profile_id then return false, "Kindle Wi-Fi profile has no netid" end

    local function request_delete(value, numeric)
        local handle, handle_error = profile_handle()
        if not handle then return false, handle_error end
        local setter = numeric and handle.set_int_property or handle.set_string_property
        local requested, request_error = pcall(setter, handle,
            "com.lab126.wifid", "deleteProfile", value)
        pcall(handle.close, handle)
        return requested, request_error
    end

    local requested, request_error = request_delete(profile_id, true)
    local deleted, delete_error
    if requested then deleted, delete_error = wait_for_profile(ssid, false) end
    if not deleted then
        requested, request_error = request_delete(ssid, false)
        if requested then deleted, delete_error = wait_for_profile(ssid, false) end
    end
    if not deleted then return false, delete_error or request_error end
    logger.dbg("Kindle Wi-Fi profile deleted", "profile_id=", profile_id)
    return true
end

local function validate_password(network)
    if not is_secured(network) then return true end
    local password = network.password
    if type(password) ~= "string" then return false, "missing password" end
    if #password == 64 and password:match("^%x+$") then return true end
    if #password < 8 or #password > 63 then return false, "invalid password length" end
    return true
end

local function create_profile(network)
    local handle, handle_error = profile_handle()
    if not handle then return false, handle_error end

    local profile_input
    local result
    local created, create_error = pcall(function()
        profile_input = handle:new_hasharray()
        profile_input:add_hash()
        profile_input:put_string(0, "essid", network.ssid)
        -- Use KOReader's passphrase request; let wifid infer the security method.
        if is_secured(network) then
            profile_input:put_string(0, "secured", "yes")
            profile_input:put_string(0, "psk", network.password)
            profile_input:put_int(0, "store_nw_user_pref", 0)
        else
            profile_input:put_string(0, "secured", "no")
        end
        result = handle:access_hash_property(
            "com.lab126.wifid", "createProfile", profile_input)
    end)
    if result then pcall(result.destroy, result) end
    if profile_input then pcall(profile_input.destroy, profile_input) end
    pcall(handle.close, handle)
    if not created then return false, create_error end

    local profile, profile_error = wait_for_profile(network.ssid, true)
    if not profile then return false, profile_error end
    logger.dbg("Kindle Wi-Fi profile created", "security=", network.flags,
        "profile_id=", profile.netid)
    return true
end

function M.isSupported(Device)
    return Device.isKindle and Device:isKindle()
end

function M.new(NetworkMgr)
    local adapter = { id = "kindle" }
    function adapter.connect(network)
        local profile, profile_error = get_profile(network.ssid)
        if profile_error then return false, profile_error end
        if not profile then return false, "saved Kindle Wi-Fi profile not found" end
        local selector = profile.netid and tostring(profile.netid) or network.ssid
        local handle, handle_error = lipc_handle()
        if not handle then return false, handle_error end
        local connected, err = pcall(handle.set_string_property, handle,
            "com.lab126.wifid", "cmConnect", selector)
        pcall(handle.close, handle)
        if connected then
            logger.dbg("Kindle Wi-Fi connection requested", "profile_selector=", profile.netid ~= nil)
        end
        return connected, err
    end

    function adapter.replaceNetwork(network)
        local valid, password_error = validate_password(network)
        if not valid then return false, password_error end
        local deleted, delete_error = delete_profile(network.ssid)
        if not deleted then return false, delete_error end
        return create_profile(network)
    end

    local closed,scan_handle,scan_poll,scan_done=false,nil,nil,nil
    local function finish_scan(ok,err)
        if scan_poll then UIManager:unschedule(scan_poll);scan_poll=nil end
        if scan_handle then pcall(scan_handle.close,scan_handle);scan_handle=nil end
        local done=scan_done;scan_done=nil
        if done then
            local called,why=pcall(done,ok,err)
            if not called then logger.warn("Slate: Wi-Fi scan callback failed:",why)end
        end
    end
    function adapter.getNetworkList()
        local list,err=read_hash("scanList")
        if not list then return nil,err end
        local profiles=read_hash("profileData")or {}
        local saved={}
        for _,profile in pairs(profiles)do
            if type(profile)=="table"and profile.essid then saved[profile.essid]=profile end
        end
        local ok,current=pcall(NetworkMgr.getCurrentNetwork,NetworkMgr)
        local current_ssid=ok and current and current.ssid
        local networks,by_ssid={},{}
        for _,raw in pairs(list)do
            if type(raw)=="table"then
                local ssid=raw.essid or raw.ssid
                if type(ssid)=="string"and ssid~=""then
                    local profile=saved[ssid]
                    local signal,maximum=tonumber(raw.signal),tonumber(raw.signal_max)
                    local quality=signal and maximum and maximum>0 and math.floor(signal*100/maximum)
                        or tonumber(raw.signal_quality)or 0
                    local item={ssid=ssid,connected=ssid==current_ssid,
                        flags=raw.key_mgmt or raw.smethod or(profile and profile.smethod)or "",
                        password=profile and profile.psk,signal_quality=quality}
                    if not by_ssid[ssid]then
                        networks[#networks+1]=item;by_ssid[ssid]=item
                    elseif quality>by_ssid[ssid].signal_quality then by_ssid[ssid].signal_quality=quality end
                end
            end
        end
        logger.info("Slate: Kindle scanList returned",#networks,"distinct networks")
        return networks
    end
    function adapter.scan(done)
        if closed then done(false,"Scanner is closed.");return end
        if scan_done then adapter.cancelScan()end
        local handle,err=lipc_handle("com.github.koreader.slate.wifi.scan")
        if not handle then done(false,err);return end
        local requested,why=pcall(handle.set_string_property,handle,"com.lab126.wifid","scan","")
        if not requested then pcall(handle.close,handle);done(false,why);return end
        scan_handle=handle;scan_done=done
        local attempts,started,idle_polls=0,false,0
        scan_poll=function()
            if closed or not scan_handle then return end
            attempts=attempts+1
            local read,state=pcall(handle.get_string_property,handle,"com.lab126.wifid","scanState")
            if not read then finish_scan(false,"Firmware did not expose Wi-Fi scan state.");return end
            local scanning=type(state)=="string"and state~="idle"and state~=""
            if scanning then started=true;idle_polls=0 else idle_polls=idle_polls+1 end
            -- Some firmware still reports idle just after accepting the scan.
            -- Keep the LIPC request alive and wait before collecting results.
            if not scanning and idle_polls>=2 and(started or attempts>=9)then finish_scan(true)
            elseif attempts>=80 then finish_scan(false,"Wi-Fi scan timed out.")
            else UIManager:scheduleIn(.25,scan_poll)end
        end
        UIManager:scheduleIn(.25,scan_poll)
    end
    function adapter.cancelScan()finish_scan(false,"Cancelled.")end
    function adapter.close()closed=true;adapter.cancelScan()end
    return adapter
end

return M
