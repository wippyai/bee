-- MIT. Strict decoder for the read-only Hub update status shown in About.
local bounds = require("bounds")
local semver = require("semver")
local M = {}

type Pack = {component: string, installed_version: string, available_version: string, update_available: boolean}
type BeeUpdate = {installed_version: string, available_version: string, update_available: boolean,
    needs_new_binary: boolean, reason: string}
type Binary = {native_module: string, native_version: string, runtime_commit: string}
type Status = {state: "ready" | "error", message: string, modules: {Pack}, bee_update: BeeUpdate?, binary: Binary?}

local function object(value: unknown): {[string]: unknown}?
    return bounds.object(value)
end

local function version(value: unknown, optional: boolean?): string?
    local raw = bounds.text(value, 128)
    if not raw then return nil end
    if optional and raw == "" then return raw end
    if raw == "" or not semver.parse(raw) then return nil end
    return raw
end

local function decode_binary(raw: unknown): (Binary?, string?)
    if raw == nil then return nil, nil end
    local value = object(raw)
    if not value or bounds.fields(value, {"native_module", "native_version", "runtime_commit"}) then
        return nil, "invalid baked binary identity"
    end
    local module = bounds.line(value.native_module, 256)
    local native_version = version(value.native_version)
    local runtime_commit = bounds.line(value.runtime_commit, 40)
    if not module or not module:match("^[%w_./-]+$") then return nil, "invalid baked binary identity" end
    if not native_version then return nil, "invalid baked binary identity" end
    if not runtime_commit then return nil, "invalid baked binary identity" end
    if #runtime_commit ~= 40 or not runtime_commit:match("^[0-9a-f]+$") then return nil, "invalid baked binary identity" end
    return {native_module = module, native_version = native_version, runtime_commit = runtime_commit}, nil
end

local function error_status(message: string): Status
    return {state = "error", message = message, modules = {}, bee_update = nil, binary = nil}
end

function M.failure(message: string): Status
    return error_status(message:sub(1, 512))
end

function M.decode(raw: unknown): Status
    local reply = object(raw)
    if not reply or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean"
        or bounds.fields(reply, {"ok", "replayed", "code", "message", "value"}) then
        return error_status("Invalid Hub update status reply")
    end
    if not reply.ok then
        local code = bounds.line(reply.code, 160) or "UNAVAILABLE"
        local message = bounds.text(reply.message, 512) or "Hub update status unavailable"
        return error_status(code .. ": " .. message)
    end
    local value = object(reply.value)
    if not value or bounds.fields(value, {"modules", "bee_update", "catalog_error", "binary"}) then
        return error_status("Invalid Hub update status")
    end
    local supplied, supplied_error = bounds.dense_list(value.modules, 256, "Bee pack status")
    local root = object(value.bee_update)
    if not supplied or not root or bounds.fields(root, {"installed_version", "available_version", "update_available", "needs_new_binary", "reason"})
        or type(root.update_available) ~= "boolean" or type(root.needs_new_binary) ~= "boolean" then
        return error_status(supplied_error or "Invalid Bee root update status")
    end
    local binary, binary_error = decode_binary(value.binary)
    if binary_error then return error_status(binary_error) end
    local installed_root = version(root.installed_version, true)
    local available_root = version(root.available_version, true)
    local reason = bounds.text(root.reason, 512)
    local root_update_available = root.update_available == true
    local needs_new_binary = root.needs_new_binary == true
    if not installed_root or not available_root or not reason then return error_status("Invalid Bee root version status") end
    local modules: {Pack} = {}
    local seen: {[string]: boolean} = {}
    for _, raw_item in ipairs(supplied) do
        local item = object(raw_item)
        local name = item and bounds.line(item.component, 160)
        local installed = item and version(item.installed_version, true)
        local available = item and version(item.available_version, true)
        if not item or bounds.fields(item, {"component", "installed_version", "available_version", "update_available"})
            or not name or not name:match("^bee/") or seen[name] or not installed or not available
            or type(item.update_available) ~= "boolean" then
            return error_status("Invalid Bee pack update row")
        end
        modules[#modules + 1] = {component = name, installed_version = installed, available_version = available,
            update_available = item.update_available}
        seen[name] = true
    end
    if value.catalog_error ~= nil and not bounds.text(value.catalog_error, 512) then
        return error_status("Invalid Bee package catalog status")
    end
    table.sort(modules, function(a: Pack, b: Pack): boolean return a.component < b.component end)
    return {state = "ready", message = value.catalog_error == nil and "" or bounds.text(value.catalog_error, 512) or "",
        modules = modules, bee_update = {installed_version = installed_root, available_version = available_root,
            update_available = root_update_available, needs_new_binary = needs_new_binary, reason = reason}, binary = binary}
end

return M
