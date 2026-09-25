-- MIT. Read one exact Hub artifact without publishing or starting its entries.
local hub = require("hub")
local bounds = require("bounds")
local requirements = require("requirements")
local inspection = require("inspection")
local M = {}
function M.read(raw: unknown): (inspection.Inspection?, string?)
    local request, request_error = inspection.decode(raw)
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
    local decoded: {inspection.Entry} = {}
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
    local page = inspection.page(decoded, request.entry_offset, request.entry_limit, request.include_data)
    return {component = request.component, version = version, digest = digest, requirements = result,
        entries = page.entries, next_offset = page.next_offset, eof = page.eof}, nil
end
return M
