-- MIT. The node workspace catalog operations. Each decodes its request,
-- authorizes the caller for it, then runs the private backend under the
-- node's catalog scope. Apps never hold the node database: the application
-- boundary denies it, and this facade is their only path to workspace rows.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local catalog = require("catalog")

type Object = {[string]: unknown}

local BACKEND = "bee.node.binding:catalog"
local SCOPE = "bee.node.security:workspace_catalog"

local function run(operation: string, value: unknown): Object
    local request, decode_error = catalog.decode(operation, value)
    if not request then return catalog.fail("INVALID", decode_error or "invalid catalog request") end
    if not security.actor() then return catalog.fail("UNAUTHENTICATED", "the caller is not authenticated") end
    local action, resource = catalog.authority(request)
    if not security.can(action, resource) then
        return catalog.fail("DENIED", "the caller may not " .. operation .. " " .. resource)
    end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return catalog.fail("UNAVAILABLE", "catalog scope: " .. tostring(scope_error)) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return catalog.fail("UNAVAILABLE", "catalog executor: " .. tostring(executor_error)) end
    local result, call_error = executor:call(BACKEND, {operation = operation, request = value})
    if call_error then return catalog.fail("UNCERTAIN", "catalog " .. operation .. " outcome is unknown: " .. tostring(call_error)) end
    local reply = bounds.object(result)
    if not reply or type(reply.ok) ~= "boolean" then
        return catalog.fail("UNCERTAIN", "catalog " .. operation .. " returned an invalid reply")
    end
    return reply
end

local function read(value: unknown): Object return run("read", value) end
local function roots(value: unknown): Object return run("roots", value) end
local function folders(value: unknown): Object return run("folders", value) end

return {read = read, roots = roots, folders = folders}
