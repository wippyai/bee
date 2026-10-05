-- MIT.
local security = require("security")
local function inspect(): {actor_id: string, workspace_id: unknown, registry_read: boolean, http_request: boolean, scope_create: boolean}
    local actor = assert(security.actor())
    return {actor_id = actor:id(), workspace_id = actor:meta().workspace_id,
        registry_read = security.can("registry.get", "bee.security.capability:capability_catalog"),
        http_request = security.can("http_client.request", "https://example.com"),
        scope_create = security.can("security.scope.create", "custom")}
end
return {inspect = inspect}
