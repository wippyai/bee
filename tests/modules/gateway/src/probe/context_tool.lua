-- MIT. Observe the real native context and scope received through MCP.
local ctx = require("ctx")
local security = require("security")
local function handle(raw: unknown)
    if type(raw) ~= "table" or next(raw) ~= nil then return {ok = false, error = {code = "INVALID", message = "empty arguments required"}} end
    local project = ctx.get("project")
    local experiment = ctx.get("experiment")
    return {ok = true, value = {project = project, experiment = experiment, binding = ctx.get("bee.gateway.binding"),
        replacement_granted = security.can("bee.probe.replacement", "sentinel"),
        can_read_gateway = security.can("db.get", "bee.gateway:db"),
        can_create_scope = security.can("security.scope.create", "custom")}}
end
return {handle = handle}
