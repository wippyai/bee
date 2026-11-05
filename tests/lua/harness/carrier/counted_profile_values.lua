-- SPDX-License-Identifier: MIT
-- The drivers' profile values with each schema read counted in the
-- bee.tests.harness.carrier:schema_reads store, for the carrier planning the
-- schema suite composes over it.
local profile_values = require("profile_values")
local store = require("store")
local M = {}
local function counter(add: integer): integer
    local reads = assert(store.get("bee.tests.harness.carrier:schema_reads"))
    local current = reads:get("reads")
    local count = (type(current) == "number" and math.floor(current) or 0) + add
    assert(reads:set("reads", count))
    reads:release()
    return count
end
function M.schema(binding_ref: string, snapshot: unknown): (unknown, string?, string?)
    counter(1)
    return profile_values.schema(binding_ref, snapshot)
end
function M.reads(): integer return counter(0) end
return M
