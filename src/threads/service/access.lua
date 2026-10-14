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
M.APP_ALIAS = "bee.threads.app_alias"
M.WORKSPACE = "bee.threads.workspace"
M.SESSIONS_OWNER = "bee.threads.sessions_owner"
M.INBOX_SEND = "bee.sessions.send"
M.INBOX_DISCOVER = "bee.sessions.discover"
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
    return bounds.id(actor:meta().workspace_id)
end
function M.may_use_sessions_workspace(workspace_id: string, operation: string): boolean
    return security.can("bee.sessions.workspace." .. operation, workspace_id)
end
function M.may_list_workspace(workspace_id: string): boolean
    return security.can(M.WORKSPACE, workspace_id)
end
function M.may_send(address: string): boolean return security.can(M.INBOX_SEND, address) end
function M.may_discover(address: string): boolean return security.can(M.INBOX_DISCOVER, address) end
-- Forwarded principals act under an id only the hive admission derives:
-- actor creation is policed, so no local identity may mint it, and every
-- forwarded path keeps its database-anchored checks. This mirrors the
-- hive principal encoding and must change with it.
M.FORWARDED_PREFIX = "bee.hive.member."
function M.forwarded(actor: string?): boolean
    if type(actor) ~= "string" then return false end
    return (actor):sub(1, #M.FORWARDED_PREFIX) == M.FORWARDED_PREFIX
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
function M.may_manage_sessions(): boolean
    return security.can(M.SESSIONS_OWNER, "*")
end
function M.may_summarize_sessions(): boolean
    return security.can("bee.threads.sessions.summary", "node")
end
function M.may_project_approvals(thread_id: string): boolean
    return security.can(M.APPROVAL, thread_id)
end
-- The application broker backfills retained instances, attests current opens
-- and fences a family's threads after admission loss.
function M.may_alias(stable: string): boolean
    return security.can(M.APP_ALIAS, stable)
end
function M.submits(role: string): boolean
    return role == "owner" or role == "participant"
end
function M.administers(role: string): boolean
    return role == "owner"
end
return M
