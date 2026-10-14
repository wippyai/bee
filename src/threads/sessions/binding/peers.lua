-- MIT
local security = require("security")
local protocol = require("protocol")
local nodes = require("nodes")
local system = require("system")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
function M.list(_raw: unknown): Object
    local found: {Object} = {}
    local local_node = system.node.id()
    local members = nodes.nodes()
    if #members > 16 then return {ok = false, error = "peer directory exceeds sixteen bees"} end
    for _, node in ipairs(members) do
        if node ~= local_node and security.can("bee.sessions.remote", node) then
            local reply = protocol.call(node, "application.discover", {}, "5s", true)
            local value = reply and reply.ok and bounds.object(reply.value)
            local tools = value and bounds.dense_list(value.tools, 64, "peer tools")
            local workspace: string? = nil
            local listed, messaging, opening = false, false, false
            for _, raw in ipairs(tools or {}) do
                local tool = bounds.object(raw)
                if tool and tool.definition_id == "bee.harness.app:app" and tool.service == "sessions" then
                    workspace = bounds.id(tool.workspace_id)
                    listed = listed or tool.operation == "list"
                    messaging = messaging or tool.operation == "send"
                    opening = opening or tool.operation == "open"
                end
            end
            if listed and workspace then found[#found + 1] = {node = node, workspace_id = workspace, scope = opening and "open" or messaging and "message" or "list"} end
        end
    end
    table.sort(found, function(a: Object, b: Object): boolean return tostring(a.node) < tostring(b.node) end)
    return {ok = true, value = {items = found}}
end
return M
