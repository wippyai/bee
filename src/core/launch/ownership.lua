-- MIT. Which composition owns the retained workspace supervisor. Exactly one
-- actor may spawn bee.launch:retained, because its workspace host registers
-- bee.workspace.host/<workspace_id> and a second registration kills the owner.
-- The desktop bridge owns it when the host configured desktop admission, since
-- the bridge is the actor that admits clients and the owner route only reports
-- readiness. Otherwise the owner route spawns it itself.
local M = {}
-- spawn_retained reports whether the calling actor must spawn the retained
-- supervisor. desktop_host is true when this composition has a desktop bridge.
function M.spawn_retained(desktop_host: boolean): boolean
    return not desktop_host
end
-- desktop_bridge reports whether the Hive supervisor service entry data
-- configures desktop admission. The service runs in every composition; only
-- its `desktop` input composes the bridge that owns the retained workspace.
function M.desktop_bridge(data: unknown): boolean
    if type(data) ~= "table" or type(data.input) ~= "table" then return false end
    local input: unknown = data.input[1]
    return type(input) == "table" and input.desktop ~= nil
end
return M
