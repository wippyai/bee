-- MIT. Eventual publication is isolated from the supervisor loop because a
-- joining or leaderless mesh can take its full network deadline to answer.
local process = require("process")
local types = require("types")

local function handle(input: unknown): {ok: boolean, error: string}
    if type(input) ~= "table" then return {ok = false, error = "invalid advertisement"} end
    local value = input :: {[string]: unknown}
    if type(value.name) ~= "string" or type(value.pid) ~= "string" then
        return {ok = false, error = "invalid advertisement"}
    end
    local node, host = types.pid_parts(value.pid :: string)
    local local_node = types.pid_parts(tostring(process.pid()))
    if not local_node or local_node == "" or node ~= local_node
        or host ~= types.SUPERVISOR_HOST or value.name ~= types.SUPERVISOR_NAME .. "/" .. local_node then
        return {ok = false, error = "advertisement is not the local Hive supervisor"}
    end
    local named, err = process.registry.register(value.name :: string, value.pid :: string, process.registry.EVENTUAL)
    if not named then return {ok = false, error = tostring(err)} end
    return {ok = true, error = ""}
end

return {handle = handle}
