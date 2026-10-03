-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local security = require("security")

local function handle(): unknown
    assert(not security.can("funcs.call", "bee.hub.binding:backend"))
    assert(not security.can("registry.apply", ""))
    assert(not security.can("bee.hub.migrate_receipts", "bee.hub.binding:receipt_metadata"))
    local policy = assert(security.policy("bee.security.hub:receipt_metadata_policy"))
    local executor = assert(funcs.new():with_scope(security.new_scope({policy})))
    local result, err = executor:call("bee.hub.binding:receipt_metadata")
    if err then error(tostring(err)) end
    return result
end

return {handle = handle}
