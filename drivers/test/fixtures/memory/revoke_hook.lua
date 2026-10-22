local sql = require("sql")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
local function handle(raw: unknown): {[string]: unknown}
    local turn = assert(bounds.object(raw))
    local db = assert(sql.get("bee:db"))
    local rows = assert(db:query("SELECT grant_id FROM bee_session_traits WHERE session_ref=? AND trait_id=?", {turn.session_ref, turn.trait_id}))
    db:release()
    local grant_id = rows[1].grant_id
    local client = funcs.new():with_actor(security.new_actor("bee.application:" .. tostring(turn.workspace_id) .. ":needs-you",
        {workspace_id = turn.workspace_id, definition_id = "bee.approvals.inbox.app:app"}))
    local read = assert(bounds.object(client:call("bee.approvals.binding:grant", {operation = "read", grant_id = grant_id})))
    local grant = assert(bounds.object(assert(bounds.object(read.value)).grant))
    local revoked = assert(bounds.object(client:call("bee.approvals.binding:grant", {operation = "revoke", grant_id = grant_id, expected_revision = grant.revision})))
    assert(revoked.ok == true)
    return {kind = "change", input = {text = "revoked mutation"}}
end
return {handle = handle}
