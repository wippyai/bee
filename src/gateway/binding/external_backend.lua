local security = require("security")
local bounds = require("bounds")
local external = require("external")
local function handle(raw: unknown): external.Reply
    local request = bounds.object(raw)
    local actor = security.actor()
    local workspace = actor and bounds.id(actor:meta().workspace_id)
    if not request or bounds.fields(request, {"operation", "client_id", "workspace_id"}) then
        return {ok = false, value = nil, error = {code = "INVALID", message = "Invalid client operation"}}
    end
    if not workspace or request.workspace_id ~= workspace or not actor or actor:meta().definition_id ~= "bee.gateway.app:app" then
        return {ok = false, value = nil, error = {code = "DENIED", message = "External operation needs its authenticated application workspace"}}
    end
    if request.operation == "list" then return external.list(workspace) end
    local id = bounds.id(request.client_id)
    if id and request.operation == "revoke" then return external.revoke(id, workspace) end
    if id and request.operation == "read" then return external.records(id, workspace) end
    return {ok = false, value = nil, error = {code = "INVALID", message = "Unknown client operation"}}
end
return {handle = handle}
