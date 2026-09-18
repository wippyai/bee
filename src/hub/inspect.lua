-- MIT. Read one exact Hub artifact without publishing or starting its entries.
local hub = require("hub")
local bounds = require("bounds")
local requirements = require("requirements")
local M = {}
type Request = {component: string, version: string, parameters: {requirements.Parameter}}
type Entry = {id: string, kind: string, meta: {[string]: unknown}, data: unknown}
type Inspection = {component: string, version: string, digest: string, requirements: requirements.Result, entries: {Entry}}

function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "package request must be an object" end
    local extra = bounds.fields(value, {"component", "version", "parameters"})
    if extra then return nil, extra end
    local component = bounds.line(value.component, 160)
    if not component or not component:match("^[%w_%-%.]+/[%w_%-%.]+$") then
        return nil, "component must be an org/module name"
    end
    local org, name = component:match("^([^/]+)/([^/]+)$")
    if org == "." or org == ".." or name == "." or name == ".." then
        return nil, "component must be an org/module name"
    end
    local version = bounds.line(value.version, 128)
    -- An exact artifact reader does not resolve labels or version constraints.
    if not version or not version:match("^v?%d+%.%d+%.%d+[%w%.%+%-]*$") then
        return nil, "an exact package version is required"
    end
    local supplied: unknown = value.parameters
    if supplied == nil then supplied = {} end
    local parameters, parameter_error = requirements.parameters(supplied)
    if not parameters then return nil, parameter_error end
    return {component = component, version = version, parameters = parameters}, nil
end

function M.read(raw: unknown): (Inspection?, string?)
    local request, request_error = M.decode(raw)
    if not request then return nil, request_error end
    -- Hub authorization uses the caller's exact module grant. No caller-selected
    -- registry, credentials, cache path or stronger scope enters this operation.
    local package, open_error = hub.versions.open(request.component, request.version, {timeout = 30})
    if not package then return nil, tostring(open_error) end
    local version, digest = package.version, package.digest
    local entries, entries_error = package:entries({include_data = true})
    local closed, close_error = package:close()
    if entries_error or not entries then return nil, tostring(entries_error) end
    if not closed then return nil, tostring(close_error) end
    if version:gsub("^v", "") ~= request.version:gsub("^v", "") then
        return nil, "Hub returned another package version"
    end
    digest = digest:gsub("^sha256:", "")
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
        return nil, "Hub artifact has no SHA-256 measurement"
    end
    local result, requirement_error = requirements.read(entries, request.parameters)
    if not result then return nil, requirement_error end
    local decoded: {Entry} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_entry in ipairs(entries) do
        local entry = bounds.object(raw_entry)
        if not entry then return nil, "invalid package entry" end
        local id, kind = bounds.id(entry.id), bounds.id(entry.kind)
        if not id or not kind or seen[id] then return nil, "invalid or duplicate package entry identity" end
        seen[id] = true
        local meta: {[string]: unknown} = {}
        if entry.meta ~= nil then
            local supplied = bounds.object(entry.meta)
            if not supplied then return nil, "invalid package metadata" end
            meta = supplied
        end
        decoded[#decoded + 1] = {id = id, kind = kind, meta = meta, data = entry.data}
    end
    return {component = request.component, version = version, digest = digest, requirements = result, entries = decoded}, nil
end
return M
