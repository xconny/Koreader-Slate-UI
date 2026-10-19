-- SPDX-License-Identifier: GPL-3.0-only
-- Adapted from ZenOS (xZenLabs and contributors), 2026-10-19.
-- https://github.com/xZenLabs/zen-os
-- Original license: slate_system_licenses.lua. Changes: Slate logging and
-- profile operations only; UI scans use KOReader's native network manager.
-- GPLv3 section 13 permits combination with Slate's AGPLv3 code.
local ffiutil = require("ffi/util")
local logger = require("logger")

local M = {}

local function is_secured(network)
    local flags = type(network.flags) == "string" and network.flags or ""
    return flags:find("WPA", 1, true) ~= nil or flags:find("SAE", 1, true) ~= nil
end

local function lipc_handle()
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if not ok_lipc or type(lipc.init) ~= "function" then
        return nil, "liblipclua unavailable"
    end
    local ok_handle, handle = pcall(lipc.init, "com.github.koreader.networkmgr")
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

    return adapter
end

return M
