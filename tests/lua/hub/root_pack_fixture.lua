-- MIT. Published package inspection uses an immutable snapshot, independent of the live registry.
local json = require("json")
local bounds = require("bounds")
local inspection = require("inspection")
local M = {}
local encoded = require("root_pack_data").encoded
function M.entries(): {inspection.Entry}
    local raw = assert(json.decode(encoded))
    assert(type(raw) == "table")
    local entries: {inspection.Entry} = {}
    for _, row in ipairs(raw) do
        local entry = assert(bounds.object(row))
        entries[#entries + 1] = {id = assert(bounds.id(entry.id)), kind = assert(bounds.id(entry.kind)),
            meta = assert(bounds.object(entry.meta)), data = entry.data}
    end
    return entries
end
return M
