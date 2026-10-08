-- MIT
local registry = require("registry")
local security = require("security")
local hash = require("hash")
local time = require("time")
local funcs = require("funcs")
local ctx = require("ctx")
local json = require("json")
local system = require("system")
local workspaces = require("workspaces")
local bounds = require("bounds")
local application = require("application")
local M = {}
M.TYPE = "bee.sessions.allowance"
M.APP = "bee.harness.app:app"
M.SCOPES = {list = {"list", "get", "history", "catalog"}, message = {"list", "get", "history", "catalog", "send", "await", "join"},
    open = {"list", "get", "history", "catalog", "send", "await", "join", "open", "run", "cancel", "close"}}
type Object = {[string]: unknown}
local function now(): integer return math.floor(time.now():unix_nano() / 1000000) end
local function id(peer: string, workspace: string): string
    return "bee.threads.sessions.allowances:" .. assert(hash.sha256(peer .. "\n" .. workspace))
end
local function row(peer: string, workspace: string): Object?
    local entry = registry.get(id(peer, workspace))
    return entry and bounds.object(entry.data) or nil
end
local function permitted(scope: string, operation: string): boolean
    for _, name in ipairs(M.SCOPES[scope] or {}) do if name == operation then return true end end
    return false
end
local function live(value: Object?): boolean
    return value ~= nil and value.revoked ~= true and type(value.scope) == "string" and M.SCOPES[value.scope] ~= nil
        and (value.expires_ms == nil or (type(value.expires_ms) == "number" and value.expires_ms > now()))
end
local function replace(peer: string, workspace: string, value: Object): (boolean?, string?)
    local key = id(peer, workspace)
    local pinned = assert(registry.snapshot())
    local changes = pinned:changes()
    local entry = {id = key, kind = "registry.entry", meta = {type = M.TYPE}, data = value}
    if pinned:get(key) then changes:update(entry) else changes:create(entry) end
    local policy_id = "bee.security.hive:session_" .. key:match(":(.+)$")
    if pinned:get(policy_id) then changes:delete(policy_id) end
    if live(value) then
        local refs: {string} = {}
        for _, entry in ipairs(assert(pinned:find({["meta.application_ref"] = M.APP, ["meta.hive_service"] = "sessions"}))) do
            local meta = bounds.object(entry.meta)
            local op = meta and bounds.object(meta.hive_operation)
            if op and type(op.name) == "string" and permitted(tostring(value.scope), op.name) then refs[#refs + 1] = entry.id end
        end
        local names: {string} = {}
        for _, ref in ipairs(refs) do names[#names + 1] = string.format("%q", ref) end
        local allowed: {string} = {}
        for _, name in ipairs(M.SCOPES[tostring(value.scope)]) do allowed[#allowed + 1] = string.format('%q', 'bee.sessions.workspace.' .. name) end
        local expression = 'actor.meta.node == ' .. string.format("%q", peer) .. ' && actor.meta.workspace_id == '
            .. string.format("%q", workspace) .. ' && ((action == "hive.expose.policy" && resource in [' .. table.concat(names, ",") .. ']) || (action in [' .. table.concat(allowed, ",") .. '] && resource == ' .. string.format("%q", workspace) .. '))'
        changes:create({id = policy_id, kind = "security.policy.expr", data = {groups = {"hive_exposure_scope"},
            policy = {actions = {"hive.expose.policy", "bee.sessions.workspace.*"}, resources = "*", effect = "allow", expression = expression}}})
    end
    local ok, err = changes:apply()
    return ok ~= nil, err and tostring(err) or nil
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
local function ask(peer: string, workspace: string, previous: Object?): (Object?, string?)
    if previous and (previous.approval_id ~= nil or previous.revoked == true) then return previous, nil end
    local revision = previous and bounds.integer(previous.revision) or 0
    local view, err = approval("request", {workspace_id = workspace, idempotency_key = id(peer, workspace) .. "." .. tostring(revision or 0),
        request_kind = "question", policy = "hive-session-agents",
        proposal = {kind = "operation", ref = "bee.threads.sessions:allowance", revision = "1", payload = {peer = peer, workspace_id = workspace}},
        prompt = {text = "Allow agents from bee " .. peer .. " to see / message agents here. Choose list only, message and await, or open new sessions; choose a duration or permanent. You can revoke in Sessions."},
        response_schema = {type = "object", required = {"text"}, properties = {text = {type = "string"}}}}, workspace)
    if not view then return nil, err end
    local value: Object = {}
    for k, v in pairs(previous or {}) do value[k] = v end
    value.peer, value.workspace_id, value.revision, value.approval_id = peer, workspace, revision or 0, view.approval_id
    local saved, save_error = replace(peer, workspace, value)
    if not saved then return nil, save_error end
    return value, nil
end
local function resolved(value: Object): (Object?, string?)
    local peer, workspace, approval_id = bounds.id(value.peer), bounds.id(value.workspace_id), bounds.id(value.approval_id)
    if not peer or not workspace or not approval_id or value.applied == true then return value, nil end
    local view, err = approval("read", {approval_id = approval_id}, workspace)
    if not view then return nil, err end
    if view.state ~= "decided" or view.decision ~= "approved" then return value, nil end
    local response = bounds.object(view.response)
    local answer = response and type(response.text) == "string" and bounds.object((json.decode(response.text))) or nil
    local scope = answer and bounds.member(answer.scope, {"list", "message", "open"}) or nil
    local duration = answer and answer.duration_ms ~= nil and bounds.integer(answer.duration_ms) or nil
    if not answer or not scope or bounds.fields(answer, {"scope", "duration_ms"})
        or (answer.duration_ms ~= nil and (not duration or duration < 1 or duration > 2592000000)) then return nil, "invalid allowance answer" end
    local decided = bounds.text(view.decided_at)
    local stamp = decided and time.parse("2006-01-02T15:04:05.000Z07:00", decided) or nil
    if not stamp then return nil, "approval decision has no timestamp" end
    local at = math.floor(stamp:unix_nano() / 1000000)
    local effect: Object = {approval_id = approval_id, proposal_digest = view.proposal_digest,
        effect_key = id(peer, workspace), owner_incarnation = view.owner_incarnation}
    local consumed, consume_error, refusal = approval("consume", effect, workspace)
    local fault = refusal and bounds.object(refusal.error)
    if not consumed and fault and fault.code == "REVALIDATE" then
        local evidence = bounds.object(refusal.value)
        local current = evidence and bounds.integer(evidence.current_incarnation)
        if not current then return nil, "approval authority incarnation is unavailable" end
        local checked, check_error = approval("revalidate", {approval_id = approval_id, proposal_digest = view.proposal_digest,
            owner_incarnation = current}, workspace)
        if not checked then return nil, check_error end
        effect.owner_incarnation = current
        consumed, consume_error = approval("consume", effect, workspace)
    end
    if not consumed then return nil, consume_error end
    local next_value: Object = {peer = peer, workspace_id = workspace, revision = (bounds.integer(value.revision) or 0) + 1,
        scope = scope, expires_ms = duration and at + duration or nil, approval_id = approval_id, applied = true}
    local saved, save_error = replace(peer, workspace, next_value)
    if not saved then return nil, save_error end
    return next_value, nil
end
function M.manage(raw: unknown): Object
    local asked = bounds.object(raw)
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    local workspace = asked and bounds.id(asked.workspace_id) or meta and bounds.id(meta.workspace_id)
    if not asked or not workspace or not security.can("bee.sessions.allowance.manage", workspace) then return failure("allowance management is denied") end
    if bounds.fields(asked, {"operation", "workspace_id", "peer", "scope", "duration_ms"}) then return failure("unknown allowance field") end
    if asked.operation == "list" then
        local rows: {Object} = {}
        for _, entry in ipairs(application.host_entries(M.TYPE)) do
            local data = bounds.object(entry.data)
            if data and data.workspace_id == workspace then
                local updated, err = resolved(data)
                if not updated then return failure(tostring(err)) end
                data = updated
                local value: Object = {}
                for k, v in pairs(data) do value[k] = v end
                value.allowed = live(data)
                rows[#rows + 1] = value
            end
        end
        table.sort(rows, function(a: Object, b: Object): boolean return tostring(a.peer) < tostring(b.peer) end)
        return {ok = true, value = {items = rows}}
    end
    local peer = bounds.id(asked.peer)
    if not peer or peer:find("[^A-Za-z0-9_.-]") then return failure("peer is malformed") end
    local previous = row(peer, workspace)
    local revision = previous and bounds.integer(previous.revision) or 0
    local value: Object = {peer = peer, workspace_id = workspace, revision = (revision or 0) + 1, revoked = asked.operation == "revoke"}
    if asked.operation == "grant" then
        local scope = bounds.member(asked.scope, {"list", "message", "open"})
        local duration = asked.duration_ms == nil and nil or bounds.integer(asked.duration_ms)
        if not scope or (asked.duration_ms ~= nil and (not duration or duration < 1 or duration > 2592000000)) then return failure("allowance scope or duration is invalid") end
        value.scope = scope
        value.expires_ms = duration and now() + duration or nil
    elseif asked.operation ~= "revoke" then return failure("unknown allowance operation") end
    if previous and previous.approval_id ~= nil and previous.applied ~= true then
        local withdrawn, withdraw_error = approval("withdraw", {approval_id = previous.approval_id}, workspace)
        if not withdrawn then return failure(tostring(withdraw_error)) end
    end
    local saved, err = replace(peer, workspace, value)
    if not saved then return failure(tostring(err)) end
    return {ok = true, value = value}
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
    local allowance = row(peer, workspace)
    if allowance then
        local updated, resolve_error = resolved(allowance)
        if not updated then return failure(tostring(resolve_error)) end
        allowance = updated
    end
    if not live(allowance) then
        local request_error: string? = nil
        if asked.inspection ~= true then _, request_error = ask(peer, workspace, allowance) end
        return failure("peer has no live allowance on this bee" .. (request_error and (": " .. request_error) or "; Needs you holds the request"))
    end
    if not permitted(tostring(allowance.scope), operation) then return failure("allowance does not include this operation") end
    return {ok = true, value = {subject = "bee.hive.member." .. peer, workspace_id = workspace,
        policies = {"bee.threads.sessions.security:peer_session_policy", "bee.security.hive:session_" .. id(peer, workspace):match(":(.+)$")}}}
end
return M
