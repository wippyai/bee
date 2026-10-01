-- MIT.
local funcs = require("funcs")
local system = require("system")
local bounds = require("bounds")
local status = require("status")
type Object = {[string]: unknown}
local function owner(target: string): Object
    local raw, err = funcs.call(target, {})
    local reply = bounds.object(raw)
    local value = reply and reply.ok == true and bounds.object(reply.value) or nil
    if err or not value then error("node status owner unavailable: " .. target) end
    return value
end
local function handle(value: unknown): status.Summary
    if not status.query(value, false) then error("node summary accepts an empty object") end
    local node, err = system.node.id()
    if not node then error(tostring(err)) end
    local description = owner("bee.node.binding:describe")
    local metadata = bounds.object(description.metadata)
    if description.node_id ~= node or not metadata then error("node description is malformed") end
    local summary = status.decode_summary({node_id = node, name = metadata.display_name,
        running_sessions = owner("bee.threads.service:node_summary").running_sessions,
        pending_approvals = owner("bee.approvals.binding:node_summary").pending_approvals}, node)
    if not summary then error("node summary is malformed") end
    return summary
end
return {handle = handle}
