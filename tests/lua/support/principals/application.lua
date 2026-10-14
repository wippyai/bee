-- MIT. The scope an app runs in: the node owner's application policy group
-- joined by the policies its process entry declares, as the runtime joins them
-- when the owner spawns the app.
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")

local M = {}

M.GROUP = "bee.node.security:application"
M.MANAGING_GROUP = "bee.node.security:scope_managing_application"

-- scope is the scope definition_id runs in, plus extra policies a test
-- grants; managing selects the group of an app admitted to build call scopes.
function M.scope(definition_id: string, extra: {string}?, managing: boolean?): security.Scope
    local scope = assert(security.named_scope(managing and M.MANAGING_GROUP or M.GROUP))
    local entry = assert(registry.get(definition_id))
    local data = assert(bounds.object(entry.data))
    local declared = bounds.object(data.security)
    local names: {string} = {}
    if declared and type(declared.policies) == "table" then
        for _, id in ipairs(declared.policies :: {unknown}) do names[#names + 1] = tostring(id) end
    end
    for _, id in ipairs(extra or {}) do names[#names + 1] = id end
    for _, id in ipairs(names) do scope = scope:with(assert(security.policy(id))) end
    return scope
end

-- boundary is the application policy group alone, plus extra policies.
function M.boundary(extra: {string}?): security.Scope
    local scope = assert(security.named_scope(M.GROUP))
    for _, id in ipairs(extra or {}) do scope = scope:with(assert(security.policy(id))) end
    return scope
end

return M
