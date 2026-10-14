-- MIT. The display names of bees: for each node asked, the name its own node
-- reports for itself (the folder it runs in). The read names nothing else of a
-- node, so an application that shows where a version came from holds this one
-- action instead of the Hive.
local security = require("security")
local bounds = require("bounds")
local client = require("client")

type Object = {[string]: unknown}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}

local ACTION = "bee.node.names.read"
local MAX_NODES = 64
local MAX_NAME = 80

local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end

-- names answers {names = {[node] = name}} for the nodes that answered with a
-- name; a node that is away or reports none is left out.
local function names(raw: unknown): Reply
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"nodes"}) then return fail("INVALID", "names takes a list of nodes") end
    local listed = bounds.dense_list(request.nodes, MAX_NODES, "nodes")
    if not listed then return fail("INVALID", "nodes must be a short list of node identities") end
    if not security.actor() then return fail("UNAUTHENTICATED", "the caller is not authenticated") end
    if not security.can(ACTION, "nodes") then return fail("DENIED", "the caller may not read node names") end
    local found: {[string]: string} = {}
    for _, raw_node in ipairs(listed) do
        local node = bounds.id(raw_node)
        if not node then return fail("INVALID", "node identity is invalid") end
        local value = client.call(node, "stats", {})
        local name = value and bounds.line(value.name, MAX_NAME) or nil
        if name then found[node] = name end
    end
    return {ok = true, value = {names = found}, error = nil}
end

return {names = names}
