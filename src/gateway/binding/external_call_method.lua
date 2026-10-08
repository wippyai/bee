-- SPDX-License-Identifier: MIT
local security = require("security")
local bounds = require("bounds")
local external = require("external")
local function handle(raw: unknown): external.Reply
    local request = bounds.object(raw)
    local actor = security.actor()
    local workspace = actor and bounds.id(actor:meta().workspace_id)
    local definition = actor and actor:meta().definition_id
    if not workspace or definition ~= "bee.gateway.app:app" or not security.can("bee.gateway.external.view", workspace) then
        return {ok = false, value = nil, error = {code = "DENIED", message = "External clients are managed through Sessions"}}
    end
    if not request or bounds.fields(request, {"operation", "client_id"}) then
        return {ok = false, value = nil, error = {code = "INVALID", message = "Invalid client operation"}}
    end
    if request.operation == "list" then return external.list(workspace) end
    local id = bounds.id(request.client_id)
    if id and request.operation == "revoke" then return external.revoke(id, workspace) end
    if id and request.operation == "read" then return external.records(id, workspace) end
    return {ok = false, value = nil, error = {code = "INVALID", message = "Unknown client operation"}}
end
return {handle = handle}
