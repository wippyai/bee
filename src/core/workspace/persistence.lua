-- MIT. Typed workspace persistence; no physical terminal or presenter lifetime.
local store = require("store")
local recovery = require("recovery")
local json = require("json")

type Persistence = {
    workspace_id: string,
    saved: recovery.Snapshot?,
    write: (Persistence, recovery.Snapshot) -> (boolean, string?),
    close: (Persistence) -> (boolean, string?),
}
local M = {}

function M.open(resource: string?): (Persistence?, string?)
    local database, open_error = store.open(resource)
    if not database then return nil, tostring(open_error) end
    local workspace_id, identity_error = database:identity()
    if not workspace_id then database:close(); return nil, tostring(identity_error) end
    local encoded, read_error = database:read()
    if read_error then database:close(); return nil, tostring(read_error) end
    local saved: recovery.Snapshot? = nil
    if encoded then
        saved = recovery.decode(encoded)
        if not saved then
            database:close()
            return nil, "Unsupported or corrupt workspace checkpoint"
        end
    end
    local value: Persistence = {
        workspace_id = workspace_id,
        saved = saved,
        write = function(_self: Persistence, snapshot: recovery.Snapshot): (boolean, string?)
            local serialized, encode_error = json.encode(snapshot)
            if not serialized then return false, tostring(encode_error) end
            return database:write(serialized)
        end,
        close = function(_self: Persistence): (boolean, string?)
            return database:close()
        end,
    }
    return value, nil
end

return M
