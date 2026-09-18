-- MIT. Host-selected harness activation is a declaration, not authority.
-- This decoder deliberately has no registry or process dependency: callers
-- pin and read the entry, then use this checked value to mark compatible
-- bindings. Publication, admission and execution remain separate owners.
local bounds = require("bounds")
local M = {}
M.TYPE = "bee.harness_activation"
M.SCHEMA = "bee.harness-activation@1"
type Entry = {[string]: unknown}
type Activation = {bindings: {[string]: boolean}}

function M.decode(ref: string, entry: Entry): (Activation?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.TYPE then return nil, ref .. " is not a harness activation declaration" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"schema_revision", "bindings"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.SCHEMA then return nil, ref .. ": schema_revision must be " .. M.SCHEMA end
    local list, list_error = bounds.ids(data.bindings, true)
    if not list then return nil, ref .. ": bindings: " .. tostring(list_error) end
    local bindings: {[string]: boolean} = {}
    for _, binding_ref in ipairs(list) do bindings[binding_ref] = true end
    return {bindings = bindings}, nil
end

return M
