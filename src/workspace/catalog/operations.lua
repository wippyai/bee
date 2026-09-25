-- MIT. The node workspace catalog operations. Each authorizes the caller for
-- its decoded request, then runs the private backend under the host-named
-- execution scope. Applications never hold the node workspace store: their
-- storage boundary denies it, and this facade is the only path to it.
local funcs = require("funcs")
local security = require("security")
local protocol = require("protocol")

local SCOPE = "bee.security.storage:workspace_catalog_scope"
local BACKEND = "bee.workspace.catalog:backend"

local function run(operation: string, value: unknown): protocol.Reply
    local request, decode_error = protocol.decode(operation, value)
    if not request then return protocol.fail("INVALID", decode_error or "invalid catalog request") end
    if not security.actor() then return protocol.fail("UNAUTHENTICATED", "the caller is not authenticated") end
    local action, resource = protocol.authority(request)
    if not security.can(action, resource) then return protocol.fail("DENIED", "the caller may not " .. operation .. " " .. resource) end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return protocol.fail("UNAVAILABLE", "catalog execution scope: " .. tostring(scope_error)) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return protocol.fail("UNAVAILABLE", "catalog executor: " .. tostring(executor_error)) end
    local result, call_error = executor:call(BACKEND, {operation = operation, request = value})
    if call_error then return protocol.fail("UNCERTAIN", "catalog " .. operation .. " outcome is unknown: " .. tostring(call_error)) end
    local reply = protocol.reply(result)
    if not reply then return protocol.fail("UNCERTAIN", "catalog " .. operation .. " returned an invalid reply") end
    return reply
end

local function create(value: unknown): protocol.Reply return run("create", value) end
local function read(value: unknown): protocol.Reply return run("read", value) end
local function list(value: unknown): protocol.Reply return run("list", value) end
local function search(value: unknown): protocol.Reply return run("search", value) end
local function rename(value: unknown): protocol.Reply return run("rename", value) end
local function archive(value: unknown): protocol.Reply return run("archive", value) end
local function restore(value: unknown): protocol.Reply return run("restore", value) end
local function inspect(value: unknown): protocol.Reply return run("inspect", value) end
local function search_within(value: unknown): protocol.Reply return run("search_within", value) end
local function roots(value: unknown): protocol.Reply return run("roots", value) end
local function folders(value: unknown): protocol.Reply return run("folders", value) end

return {create = create, read = read, list = list, search = search, rename = rename, archive = archive, restore = restore,
    inspect = inspect, search_within = search_within, roots = roots, folders = folders}
