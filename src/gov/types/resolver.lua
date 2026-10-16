-- MIT. Destination-local resolution shared by staging and activation.
local bounds = require("bounds")
local preflight = require("preflight")

local M = {}
type DatabaseBinding = {database_id: string, table_prefix: string?}
type DatabaseBindings = {[string]: DatabaseBinding}
-- A resolution that fails is refused when the current host rules reject the
-- artifact, and a failure to resolve it otherwise.
type Resolver = {resolve: (Resolver, unknown) -> (preflight.Candidate?, preflight.Context?, string?, boolean?)}
M.MAX_TABLE_PREFIX_BYTES = 64

-- Decode the host policy's logical-to-physical database bindings. An absent
-- declaration is (nil, nil).
function M.database_bindings(raw: unknown): (DatabaseBindings?, string?)
    if raw == nil then return nil, nil end
    if type(raw) ~= "table" then return nil, "host policy database bindings are malformed" end
    local bindings: DatabaseBindings = {}
    for target, entry in pairs(raw) do
        local item = bounds.object(entry)
        local database_id = item and bounds.id(item.database_id) or nil
        local prefix: string? = nil
        if item and item.table_prefix ~= nil then
            prefix = bounds.text(item.table_prefix, M.MAX_TABLE_PREFIX_BYTES)
            if not prefix or not prefix:match("^[A-Za-z][A-Za-z0-9_]*$") then
                return nil, "host policy database binding prefix is invalid"
            end
        end
        if not bounds.id(target) or not item or bounds.fields(item, {"database_id", "table_prefix"})
            or not database_id then return nil, "host policy database binding is malformed" end
        bindings[target] = {database_id = database_id, table_prefix = prefix}
    end
    return bindings, nil
end

return M
