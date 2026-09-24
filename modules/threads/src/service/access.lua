-- MIT. Who the caller is and what a role or host grant permits. Membership
-- rows are read by the operations inside their transaction; this facade
-- only interprets them and the caller's security context.
local security = require("security")
local bounds = require("bounds")
local M = {}
M.CREATE = "bee.threads.create"
M.OBSERVE = "bee.threads.observe"
M.LIFECYCLE = "bee.threads.lifecycle"
M.CARRIER = "bee.threads.carrier"
M.APPROVAL = "bee.threads.approval"
M.WORKSPACE = "bee.threads.workspace"
-- The authenticated actor; a payload never selects it.
function M.actor(): string?
    local actor = security.actor()
    if not actor then return nil end
    return bounds.id(actor:id())
end
-- The workspace the caller's host-issued identity is bound to: application
-- principals carry it from the broker, gateway subjects from their binding.
-- A request never names it.
function M.workspace(): string?
    local actor = security.actor()
    if not actor then return nil end
    local value: unknown = actor:meta().workspace_id
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return tostring(value)
end
function M.may_list_workspace(workspace_id: string): boolean
    return security.can(M.WORKSPACE, workspace_id)
end
function M.may_create(thread_id: string): boolean
    return security.can(M.CREATE, thread_id)
end
function M.may_observe(thread_id: string): boolean
    return security.can(M.OBSERVE, thread_id)
end
function M.may_direct_lifecycle(thread_id: string): boolean
    return security.can(M.LIFECYCLE, thread_id)
end
function M.may_carry(thread_id: string): boolean
    return security.can(M.CARRIER, thread_id)
end
function M.may_project_approvals(thread_id: string): boolean
    return security.can(M.APPROVAL, thread_id)
end
function M.submits(role: string): boolean
    return role == "owner" or role == "participant"
end
function M.administers(role: string): boolean
    return role == "owner"
end
return M
