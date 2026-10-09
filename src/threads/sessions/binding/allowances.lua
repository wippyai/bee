-- MIT
local registry = require("registry")
local security = require("security")
local hash = require("hash")
local funcs = require("funcs")
local ctx = require("ctx")
local json = require("json")
local system = require("system")
local uuid = require("uuid")
local workspaces = require("workspaces")
local bounds = require("bounds")
local windows = require("windows")
local M = {}
M.APP = "bee.harness.app:app"
M.SCOPES = {list = {"list", "get", "history", "catalog"}, message = {"list", "get", "history", "catalog", "send", "await", "join"},
    open = {"list", "get", "history", "catalog", "send", "await", "join", "open", "run", "cancel", "close"}}
type Object = {[string]: unknown}
local function id(peer: string, workspace: string): string
    return "bee.threads.sessions.allowances:" .. assert(hash.sha256(peer .. "\n" .. workspace))
end
local function permitted(scope: string, operation: string): boolean
    for _, name in ipairs(M.SCOPES[scope] or {}) do if name == operation then return true end end
    return false
end
local function failure(message: string): Object return {ok = false, error = message} end
local function approval(method: string, request: Object, workspace: string): (Object?, string?, Object?)
    local actor = assert(security.new_actor("bee.sessions.allowance.owner", {workspace_id = workspace}))
    local raw, err = funcs.new():with_actor(actor):call("bee.approvals.binding:" .. method, request)
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return nil, tostring(err or (fault and fault.message) or "approval owner refused"), reply
    end
    return bounds.object(reply.value), nil
end
local function ask(peer: string, workspace: string): (Object?, string?)
    return approval("request", {workspace_id = workspace, idempotency_key = id(peer, workspace),
        request_kind = "question", policy = "hive-session-agents",
        proposal = {kind = "operation", ref = "bee.threads.sessions:allowance", revision = "1", payload = {peer = peer, workspace_id = workspace}},
        prompt = {text = "Allow agents from bee " .. peer .. " to see / message agents here. Choose list only, message and await, or open new sessions and control sessions; choose a duration or permanent. You can revoke in Sessions."},
        response_schema = {type = "object", required = {"text"}, properties = {text = {type = "string"}}}}, workspace)
end
local function payload(view: Object): Object?
    local proposal = bounds.object(view.proposal)
    if view.policy ~= "hive-session-agents" or not proposal or proposal.ref ~= "bee.threads.sessions:allowance" then return nil end
    local data = bounds.object(proposal.payload)
    if not data or not bounds.id(data.peer) or data.workspace_id ~= view.workspace_id then return nil end
    return data
end
local function window_request(peer: string, workspace: string, scope: string, key: string, evidence: string): (Object?, string?)
    return approval("request", {workspace_id = workspace, idempotency_key = key, request_kind = "permission",
        policy = "hive-session-agents", proposal = {kind = "operation", ref = "bee.threads.sessions:allowance", revision = "1",
            payload = {peer = peer, workspace_id = workspace, scope = scope}},
        prompt = {text = "Allow agents from bee " .. peer .. " with " .. scope .. " scope; person consent: " .. evidence}}, workspace)
end
local function window_decide(view: Object, workspace: string, duration: integer?): (Object?, string?)
    return approval("decide", {approval_id = view.approval_id, expected_revision = view.revision,
        proposal_digest = view.proposal_digest, decision = "approved", window_ttl_ms = duration, window_permanent = duration == nil}, workspace)
end
local function grant(peer: string, workspace: string, scope: string, duration: integer?, key: string, evidence: string): (Object?, string?)
    local view, err = window_request(peer, workspace, scope, key, evidence)
    if not view then return nil, err end
    return window_decide(view, workspace, duration)
end
local function resolved(view: Object, workspace: string): string?
    local data = payload(view)
    if not data or view.request_kind ~= "question" or view.state ~= "decided" or view.decision ~= "approved" then return nil end
    local response = bounds.object(view.response)
    local answer = response and type(response.text) == "string" and bounds.object((json.decode(response.text))) or nil
    local scope = answer and bounds.member(answer.scope, {"list", "message", "open"}) or nil
    local duration = answer and answer.duration_ms ~= nil and bounds.integer(answer.duration_ms) or nil
    if not answer or not scope or bounds.fields(answer, {"scope", "duration_ms"})
        or (answer.duration_ms ~= nil and (not duration or duration < 1 or duration > 2592000000)) then return "invalid allowance answer" end
    if view.consumed_effect ~= nil then
        local existing, read_error, refusal = approval("read", {approval_id = view.consumed_effect}, workspace)
        local fault = refusal and bounds.object(refusal.error)
        if not existing and fault and fault.code == "NOT_FOUND" then return nil end
        if not existing then return read_error end
        if existing.state ~= "pending" then return nil end
        local created, create_error = window_decide(existing, workspace, duration)
        return created and nil or create_error
    end
    local permission, permission_error = window_request(tostring(data.peer), workspace, scope,
        tostring(view.approval_id) .. ".window", tostring(view.approval_id))
    if not permission then return permission_error end
    local effect: Object = {approval_id = view.approval_id, proposal_digest = view.proposal_digest,
        effect_key = permission.approval_id, owner_incarnation = view.owner_incarnation}
    local consumed, consume_error, refusal = approval("consume", effect, workspace)
    local fault = refusal and bounds.object(refusal.error)
    if not consumed and fault and fault.code == "REVALIDATE" then
        local evidence = refusal and bounds.object(refusal.value)
        local current = evidence and bounds.integer(evidence.current_incarnation)
        if not current then return "approval authority incarnation is unavailable" end
        local checked, check_error = approval("revalidate", {approval_id = view.approval_id, proposal_digest = view.proposal_digest,
            owner_incarnation = current}, workspace)
        if not checked then return check_error end
        effect.owner_incarnation = current
        consumed, consume_error = approval("consume", effect, workspace)
    end
    if not consumed then return consume_error end
    local created, create_error = window_decide(permission, workspace, duration)
    if not created then return create_error end
    return nil
end
local function active_windows(workspace: string): ({Object}?, string?)
    local rows: {Object} = {}
    local after: string? = nil
    for _ = 1, 16 do
        local active, active_error = approval("grant_window", {operation = "list", workspace_id = workspace, after_id = after}, workspace)
        if not active then return nil, active_error end
        for _, raw in ipairs(bounds.dense_list(active.grants, 64, "approval windows") or {}) do
            local window = bounds.object(raw)
            if window and window.policy == "hive-session-agents" then
                local view, read_error = approval("read", {approval_id = window.grant_id}, workspace)
                if not view then return nil, read_error end
                local data = payload(view)
                local scope = data and bounds.member(data.scope, {"list", "message", "open"})
                if data and scope then
                    rows[#rows + 1] = {peer = data.peer, workspace_id = workspace, scope = scope, allowed = true, approval_id = window.grant_id,
                            grant_id = window.grant_id, revision = window.granted_ms,
                            expires_ms = window.until_ms ~= windows.PERMANENT_UNTIL_MS and window.until_ms or nil}
                end
            end
        end
        if active.more ~= true then
            table.sort(rows, function(a: Object, b: Object): boolean return tostring(a.peer) < tostring(b.peer) end)
            return rows, nil
        end
        after = bounds.id(active.next_id)
        if not after then return nil, "approval windows pagination is invalid" end
    end
    return nil, "approval windows exceed the Sessions directory bound"
end
local function entries(workspace: string): ({Object}?, string?)
    local listed, list_error = approval("list", {workspace_id = workspace, limit = 64}, workspace)
    if not listed then return nil, list_error end
    local requests = bounds.dense_list(listed.requests, 64, "approval requests")
    local by_peer: {[string]: Object} = {}
    for _, raw in ipairs(requests or {}) do
        local view = bounds.object(raw)
        local data = view and payload(view)
        if view and data and view.request_kind == "question" then
            local err = resolved(view, workspace)
            if err then return nil, err end
            local peer = tostring(data.peer)
            by_peer[peer] = {peer = peer, workspace_id = workspace, approval_id = view.approval_id, allowed = false, state = view.state}
        end
    end
    local active, active_error = active_windows(workspace)
    if not active then return nil, active_error end
    for _, item in ipairs(active) do
        local peer = tostring(item.peer)
        local previous = by_peer[peer]
        if not previous or previous.allowed ~= true or (bounds.integer(previous.revision) or 0) < (bounds.integer(item.revision) or 0) then by_peer[peer] = item end
    end
    local rows: {Object} = {}
    for _, item in pairs(by_peer) do rows[#rows + 1] = item end
    table.sort(rows, function(a: Object, b: Object): boolean return tostring(a.peer) < tostring(b.peer) end)
    return rows, nil
end
function M.manage(raw: unknown): Object
    local asked = bounds.object(raw)
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    local workspace = asked and bounds.id(asked.workspace_id) or meta and bounds.id(meta.workspace_id)
    if not asked or not workspace or not security.can("bee.sessions.allowance.manage", workspace) then return failure("allowance management is denied") end
    if bounds.fields(asked, {"operation", "workspace_id", "peer", "scope", "duration_ms"}) then return failure("unknown allowance field") end
    local rows, directory_error = entries(workspace)
    if not rows then return failure(tostring(directory_error)) end
    if asked.operation == "list" then return {ok = true, value = {items = rows}} end
    local peer = bounds.id(asked.peer)
    if not peer or peer:find("[^A-Za-z0-9_.-]") then return failure("peer is malformed") end
    if asked.operation ~= "grant" and asked.operation ~= "revoke" then return failure("unknown allowance operation") end
    local scope = bounds.member(asked.scope, {"list", "message", "open"})
    local duration = asked.duration_ms == nil and nil or bounds.integer(asked.duration_ms)
    if asked.operation == "grant" and (not scope or (asked.duration_ms ~= nil and (not duration or duration < 1 or duration > 2592000000))) then
        return failure("allowance scope or duration is invalid")
    end
    local active, active_error = active_windows(workspace)
    if not active then return failure(tostring(active_error)) end
    for _, item in ipairs(active) do
        if item.peer == peer then
            local ended, end_error = approval("grant_window", {operation = "revoke", grant_id = item.grant_id}, workspace)
            if not ended then return failure(tostring(end_error)) end
        end
    end
    local listed, list_error = approval("list", {workspace_id = workspace, limit = 64}, workspace)
    if not listed then return failure(tostring(list_error)) end
    for _, raw in ipairs(bounds.dense_list(listed.requests, 64, "approval requests") or {}) do
        local view = bounds.object(raw)
        local data = view and payload(view)
        if view and data and data.peer == peer and view.request_kind == "question" and view.state == "pending" then
            local withdrawn, withdraw_error = approval("withdraw", {approval_id = view.approval_id,
                expected_revision = view.revision, proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest}, workspace)
            if not withdrawn then return failure(tostring(withdraw_error)) end
        end
    end
    if asked.operation == "revoke" then return {ok = true, value = {peer = peer, workspace_id = workspace, revoked = true}} end
    local created, create_error = grant(peer, workspace, assert(scope), duration, assert(uuid.v7()), actor and actor:id() or "")
    if not created then return failure(tostring(create_error)) end
    local window = bounds.object(created.window_grant)
    return {ok = true, value = {peer = peer, workspace_id = workspace, scope = scope, grant_id = window and window.grant_id}}
end
local function destination(request: Object): (string?, string?)
    local workspace = bounds.id(request.workspace_id)
    if workspace and workspace ~= "" then return workspace, nil end
    local rows, err = workspaces.list()
    if not rows then return nil, err end
    local cwd = system.process.cwd()
    for _, row in ipairs(rows) do if row.path == cwd then return row.id, nil end end
    return nil, "receiving workspace is unavailable"
end
function M.authorize(raw: unknown): Object
    local asked = bounds.object(raw)
    local caller = bounds.object(ctx.get("bee.hive.caller"))
    local actor = security.actor()
    if not asked or not caller or not actor or actor:id() ~= "bee.hive.supervisor" then return failure("trusted Hive peer identity is required") end
    local peer = bounds.id(caller.node)
    local workspace, err = destination(asked)
    local arguments = bounds.object(asked.arguments)
    if not peer or not workspace or not arguments then return failure(err or "invalid peer request") end
    local origin = bounds.object(asked.origin)
    if asked.origin ~= nil then
        local session = origin and bounds.id(origin.session)
        local source_node: string? = nil
        local source_workspace: string? = nil
        if session then source_node, source_workspace = session:match("^bs:([^:]+):([^:]+):[^:]+$") end
        if not origin or bounds.fields(origin, {"session", "thread_id", "workspace_id"}) or not bounds.id(origin.thread_id)
            or not source_node or source_node ~= peer or source_workspace ~= origin.workspace_id then
            return failure("source session does not belong to the authenticated peer")
        end
    end
    local operation = bounds.id(asked.operation)
    if not operation then return failure("unknown session operation") end
    for _, field in ipairs({"session", "work", "subject", "operation"}) do
        local ref = arguments[field]
        if type(ref) == "string" then
            local target = ref:match("^[a-z]+:[^:]+:([^:]+):[^:]+$")
            if target and target ~= workspace then return failure("receiving workspace session permission is denied") end
        end
    end
    local works = bounds.dense_list(arguments.works, 64, "works")
    for _, ref in ipairs(works or {}) do
        if type(ref) ~= "string" or ref:match("^[a-z]+:[^:]+:([^:]+):[^:]+$") ~= workspace then return failure("join is outside the receiving workspace") end
    end
    local filter, spec = bounds.object(arguments.filter), bounds.object(arguments.spec)
    if (filter and filter.workspace ~= nil and filter.workspace ~= workspace) or (spec and spec.workspace ~= nil and spec.workspace ~= workspace) then
        return failure("receiving workspace session permission is denied")
    end
    local directory, directory_error = entries(workspace)
    if not directory then return failure(tostring(directory_error)) end
    local allowance: Object? = nil
    local previous: Object? = nil
    for _, item in ipairs(directory) do
        if item.peer == peer then
            previous = item
            if item.allowed == true then allowance = item end
        end
    end
    if not allowance then
        local request_error: string? = nil
        if asked.inspection ~= true and not previous then _, request_error = ask(peer, workspace) end
        return failure("peer has no live allowance on this bee" .. (request_error and (": " .. request_error) or "; Needs you holds the request"))
    end
    if not permitted(tostring(allowance.scope), operation) then return failure("allowance does not include this operation") end
    local refs: {string} = {}
    local actions: {string} = {}
    for _, name in ipairs(M.SCOPES[tostring(allowance.scope)]) do actions[#actions + 1] = "bee.sessions.workspace." .. name end
    for _, entry in ipairs(assert(registry.find({["meta.application_ref"] = M.APP, ["meta.hive_service"] = "sessions"}))) do
        local meta = bounds.object(entry.meta)
        local op = meta and bounds.object(meta.hive_operation)
        if op and type(op.name) == "string" and permitted(tostring(allowance.scope), op.name) then refs[#refs + 1] = entry.id end
    end
    local subject = "bee.hive.member." .. peer
    if origin and type(origin.session) == "string" then subject = subject .. ":" .. assert(hash.sha256(origin.session)) end
    return {ok = true, value = {subject = subject, workspace_id = workspace, allowance_revision = allowance.revision, origin = origin, session_operations = refs, workspace_permissions = actions,
        policies = {"bee.threads.sessions.security:peer_session_policy", "bee.threads.sessions.security:peer_workspace_policy"}}}
end
return M
