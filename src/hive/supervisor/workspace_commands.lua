-- MIT. The bee workspace commands: an enrolled local client of this node
-- names one workspace operation of service bee.workspace, and the
-- supervisor's worker runs the matching catalog operation. The worker holds
-- the catalog grants the host attached to it; neither the client nor the
-- supervisor holds them. This library is pure: it checks the call and turns a
-- catalog answer into a Hive reply.
local bounds = require("bounds")
local types = require("types")
local M = {}
M.SERVICE = "bee.workspace"
M.WORKER = "bee.hive.supervisor:workspace_command"
-- The host-named permission a caller of the worker needs for each command;
-- the host grants it to its supervisor, which serves only enrolled local clients.
M.ACTION = "bee.workspaces.command"
-- The longest a command may run on the owner.
M.MAX_MS = 30000
-- Each command and the catalog operation it runs.
M.OPERATIONS = {
    ["bee.workspace:create"] = "bee.workspace.catalog:create",
    ["bee.workspace:list"] = "bee.workspace.catalog:list",
    ["bee.workspace:archive"] = "bee.workspace.catalog:archive",
    ["bee.workspace:restore"] = "bee.workspace.catalog:restore",
    ["bee.workspace:roots"] = "bee.workspace.catalog:roots",
}
-- Catalog refusal codes as Hive fault codes; the message keeps the catalog code.
local CODES: {[string]: string} = {INVALID = "INVALID_ARGUMENT", UNAUTHENTICATED = "DENIED", DENIED = "DENIED", FORBIDDEN = "DENIED",
    NOT_FOUND = "NOT_FOUND", CONFLICT = "CONFLICT", BUSY = "INVALID_STATE", STORAGE = "INTERNAL", UNAVAILABLE = "UNAVAILABLE"}

-- The command a call names, or the fault that refuses it. Only this node's own
-- service answers, and only an operation reference, never an interface.
function M.target(call: types.Call, node: string): (string?, types.Fault?)
    if call.owner_ref.node_id ~= node or call.owner_ref.resource_ref then
        return nil, types.fault("DENIED", "workspace commands are served only by their own node")
    end
    local operation = call.target.operation_ref
    if not operation or call.target.interface_ref or not M.OPERATIONS[operation] then
        return nil, types.fault("INVALID_ARGUMENT", "unknown workspace operation")
    end
    return operation, nil
end

-- The Hive reply for a catalog answer. An unknown catalog outcome stays
-- unknown, with the identity the caller can ask about.
function M.reply(request_id: string, identity: types.FaultIdentity, answer: unknown): types.Reply
    local object = bounds.object(answer)
    if not object or type(object.ok) ~= "boolean" then
        return types.reply_error(request_id, types.fault("INTERNAL", "the workspace catalog returned an invalid reply"))
    end
    if object.ok then return types.reply_ok(request_id, object.value) end
    local fault = bounds.object(object.error)
    local code = fault and bounds.id(fault.code) or nil
    local message = fault and type(fault.message) == "string" and fault.message or nil
    if not code or not message then
        return types.reply_error(request_id, types.fault("INTERNAL", "the workspace catalog returned an invalid refusal"))
    end
    local text = (code .. ": " .. message):sub(1, 4096)
    if code == "UNCERTAIN" then return types.reply_error(request_id, types.uncertain(text, identity)) end
    return types.reply_error(request_id, types.fault(CODES[code] or "INTERNAL", text))
end

return M
