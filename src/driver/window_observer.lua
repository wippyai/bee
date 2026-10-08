-- SPDX-License-Identifier: MIT
local registry = require("registry")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
type Input = {endpoint: string, hook_endpoint: string, hook_token: string, hooks: {string}, working_directory: string, argv: {string}, owner: string, topic: string}
type Measurements = {[string]: {[string]: unknown}}
local M = {}
function M.collect(pinned: registry.Snapshot, binding_ref: string, data: {[string]: unknown}): (Measurements?, string?)
    local measured: Measurements = {}
    local driver = bounds.object(data.driver) or {}
    local profiles = bounds.array(driver.profiles, 16) or {}
    for _, raw in ipairs(profiles) do
        local profile = bounds.object(raw)
        if profile and profile.observer ~= nil then
            local candidates, find_error = pinned:find({[".kind"] = "registry.entry", ["meta.type"] = "bee.driver.window_observer", ["meta.driver_ref"] = binding_ref,
                ["meta.profile_id"] = tostring(profile.id), ["meta.observer"] = tostring(profile.observer)})
            if not candidates or find_error or #candidates ~= 1 then return nil, "window profile must select exactly one observer by metadata" end
            local declaration = bounds.object(candidates[1])
            local body = declaration and bounds.object(declaration.data)
            local target = body and bounds.id(body.process)
            local process_entry = target and pinned:get(target)
            if not declaration or not process_entry or process_entry.kind ~= "process.lua" then return nil, "observer process unavailable" end
            measured[tostring(profile.id)] = {declaration = declaration, process = process_entry}
        end
    end
    return measured, nil
end
function M.digest(data: {[string]: unknown}, measurements: Measurements): (string?, string?)
    local value: unknown = data
    if next(measurements) ~= nil then value = {profiles = data, observers = measurements} end
    local encoded, err = canonical.encode(value)
    if not encoded then return nil, err end
    local digest, hash_error = hash.sha256(encoded)
    return digest, hash_error and tostring(hash_error) or nil
end
return M
