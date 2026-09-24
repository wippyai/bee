-- MIT. Scoped desktop storage operations; callers receive identities, never SQL.
local security = require("security")
local store = require("store")
local binding = require("binding")
local contract = require("contract")
type Code = "OK" | "INVALID_ARGUMENT" | "DENIED" | "UNAVAILABLE" | "CAPACITY" | "CONFLICT"
type Reply = {code: Code, message: string, desktop_id: string, desktops: {store.DesktopIdentity}}
local M = {}
local function reply(code: Code, message: string, identity: string?): Reply
    return {code = code, message = message:sub(1, 400), desktop_id = identity or "", desktops = {}}
end
local function request(value: unknown, allocating: boolean): (string?, string?)
    if type(value) ~= "table" or value.version ~= 1 or type(value.database_resource) ~= "string" then return nil, nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "database_resource" and not (allocating and key == "desktop_id") then return nil, nil end
    end
    local resource = binding.database("client", value.database_resource)
    if not resource then return nil, nil end
    if allocating then
        local id = contract.workspace_id(value.desktop_id)
        if not id then return nil, nil end
        return resource, id
    end
    return resource, nil
end
function M.list(value: unknown): Reply
    local resource = request(value, false)
    if not resource then return reply("INVALID_ARGUMENT", "Invalid desktop catalog request") end
    if not security.can("bee.client.desktops.read", resource) then return reply("DENIED", "Desktop catalog permission required") end
    local database, open_error = store.desktops(resource)
    if not database then return reply("UNAVAILABLE", open_error or "Desktop store unavailable") end
    local result: {store.DesktopIdentity}? = nil
    local read_error: string? = nil
    local ok, unexpected = pcall(function() result, read_error = store.catalog(database) end)
    local closed, close_error = store.release(database)
    if not ok then return reply("UNAVAILABLE", tostring(unexpected)) end
    if not closed then return reply("UNAVAILABLE", close_error or "Desktop store release failed") end
    if not result then return reply("UNAVAILABLE", read_error or "Desktop catalog unavailable") end
    return {code = "OK", message = "", desktop_id = "", desktops = result}
end
function M.allocate(value: unknown): Reply
    local resource, identity = request(value, true)
    if not resource or not identity then return reply("INVALID_ARGUMENT", "Invalid desktop allocation request") end
    if not security.can("bee.client.desktops.allocate", resource) then return reply("DENIED", "Desktop allocation permission required") end
    local database, open_error = store.desktops(resource)
    if not database then return reply("UNAVAILABLE", open_error or "Desktop store unavailable", identity) end
    local allocated = false
    local allocation_error: string? = nil
    local ok, unexpected = pcall(function() allocated, allocation_error = store.allocate(database, identity) end)
    local closed, close_error = store.release(database)
    -- The supplied identity makes retry safe even if cleanup fails after the
    -- insert committed. An unavailable reply never asserts that the row is absent.
    if not ok then return reply("UNAVAILABLE", tostring(unexpected), identity) end
    if not closed then return reply("UNAVAILABLE", close_error or "Desktop store release failed", identity) end
    if not allocated then
        if allocation_error == "Desktop capacity reached" then return reply("CAPACITY", allocation_error, identity) end
        if allocation_error == "Desktop identity already selected" then return reply("CONFLICT", allocation_error, identity) end
        return reply("UNAVAILABLE", allocation_error or "Desktop allocation unavailable", identity)
    end
    return reply("OK", "", identity)
end
return M
