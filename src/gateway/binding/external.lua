-- SPDX-License-Identifier: MIT
local uuid = require("uuid")
local security = require("security")
local bounds = require("bounds")
local database = require("database")
local store = require("store")
local gateway = require("gateway")
local profile = require("profile")
local subject_call = require("subject_call")
local M = {}
type Object = {[string]: unknown}
type Reply = gateway.Reply
local function fail(code: string, message: string): Reply return {ok = false, value = nil, error = {code = code, message = message}} end
local function ok(value: unknown): Reply return {ok = true, value = value} end
local function manage(workspace: string): boolean return security.can("bee.gateway.external.manage", workspace) end
local function read(id: string): (Object?, Reply?)
    local db, err = database.open()
    if not db then return nil, fail("STORAGE", err or "open client store") end
    local rows, read_error = store.read(db, id)
    db:release()
    if not rows or read_error then return nil, fail("STORAGE", "read external client") end
    if #rows == 0 then return nil, fail("NOT_FOUND", "external client is unavailable") end
    local row = #rows == 1 and bounds.object(rows[1]) or nil
    if not row then return nil, fail("STORAGE", "external client row is invalid") end
    return row, nil
end
function M.request(value: unknown): Reply
    local request = bounds.object(value)
    if not request or bounds.fields(request, {"name", "workspace_id", "caller"}) then return fail("INVALID", "pairing needs name, workspace_id and caller") end
    local name, workspace, caller = bounds.line(request.name, 80), bounds.id(request.workspace_id), bounds.text(request.caller, 256)
    if not name or name:match("^%s*$") or not workspace or not caller or #caller == 0 then return fail("INVALID", "pairing identity is invalid") end
    if not manage(workspace) then return fail("DENIED", "caller cannot pair external clients in this workspace") end
    local endpoint, endpoint_error = gateway.endpoint()
    if not endpoint or not endpoint:match("^127%.") then return fail("DENIED", endpoint_error or "external MCP requires a loopback listener") end
    local configured, config_error = profile.current()
    if not configured then return fail("UNAVAILABLE", config_error or "external profile is unavailable") end
    local id, id_error = uuid.v7()
    if not id then return fail("STORAGE", tostring(id_error)) end
    local identity = "mcp." .. id
    local subject = "bee.mcp:" .. id
    local attributed = {binding_id = identity, subject = subject, action_id = identity, attempt_id = identity,
        thread_id = identity, workspace_id = workspace}
    local created = subject_call.call(attributed, {"bee.gateway.security:external_principal_policy"}, "bee.threads.binding:create",
        {thread_id = identity, idempotency_key = identity, title = name})
    if not created.ok then return created end
    local admitted_action = subject_call.call(attributed, {"bee.gateway.security:external_principal_policy"}, "bee.threads.binding:admit_action",
        {thread_id = identity, action_id = identity, idempotency_key = identity .. ".admit", admitted = {request_id = identity,
            principal_id = subject, binding_ref = "bee.gateway.binding:external", binding_digest = configured.digest,
            grant_refs = {}, budget_ref = configured.id, input = {text = "Pair " .. name}}})
    if not admitted_action.ok then return admitted_action end
    local prepared = subject_call.call(attributed, {"bee.gateway.security:external_principal_policy"}, "bee.threads.binding:prepare_attempt",
        {thread_id = identity, action_id = identity, attempt_id = identity, idempotency_key = identity .. ".prepare",
            prepared = {binding_ref = "bee.gateway.binding:external", binding_digest = configured.digest,
                profile_id = configured.id, profile_digest = configured.digest, placement_binding = "bee.gateway.service:external",
                placement_attempt_id = identity, plan_digest = configured.digest}})
    if not prepared.ok then return prepared end
    local admitted = gateway.admit({subject = subject, action_id = identity, attempt_id = identity, thread_id = identity,
        owner_incarnation = 1, carrier_epoch = 1, workspace_id = workspace, workspace_name = identity,
        tools = configured.tools, surface = configured.surface, ttl_ms = gateway.MAX_TTL_MS, idempotency_key = identity})
    if not admitted.ok then return admitted end
    local admission = bounds.object(admitted.value)
    local binding_view = admission and bounds.object(admission.binding)
    local binding_id = binding_view and bounds.id(binding_view.binding_id)
    if not binding_id then return fail("STORAGE", "gateway admission returns no binding") end
    local db, open_error = database.open()
    if not db then return fail("STORAGE", open_error or "open client store") end
    local _, insert_error = store.insert(db, id, name, workspace, caller, binding_id)
    db:release()
    if insert_error then return fail("STORAGE", "record external client") end
    local binding, binding_error = gateway.managed_binding(binding_id)
    if not binding then return binding_error or fail("STORAGE", "read external binding") end
    local asked = gateway.request_access(binding, {idempotency_key = "pairing", traits = configured.traits,
        reason = "Pair external MCP client " .. name .. ". Bee shows its configuration once in the requesting terminal."})
    if not asked.ok then return asked end
    local approval = bounds.object(asked.value)
    local approval_id = approval and bounds.id(approval.approval_id)
    if not approval_id then return fail("STORAGE", "pairing request returns no approval") end
    db, open_error = database.open()
    if not db then return fail("STORAGE", open_error or "open client store") end
    local _, bind_error = store.bind_approval(db, id, approval_id)
    db:release()
    if bind_error then return fail("STORAGE", "bind pairing approval") end
    return ok({client_id = id, name = name, subject = subject, thread_id = identity, approval_id = approval_id, status = "pending"})
end
function M.complete(client: string, caller: string): Reply
    local row, failure = read(client)
    if not row then return failure or fail("NOT_FOUND", "external client is unavailable") end
    local workspace = bounds.id(row.workspace_id)
    if not workspace or not manage(workspace) or row.caller ~= caller then return fail("DENIED", "pairing belongs to another terminal") end
    if row.revoked_at ~= nil then return ok({client_id = client, status = "revoked"}) end
    if row.issued == 1 then return ok({client_id = client, status = "connected"}) end
    local binding_id, approval = bounds.id(row.binding_id), bounds.id(row.approval_id)
    if not binding_id or not approval then return fail("UNAVAILABLE", "pairing request has no approval") end
    local binding, binding_error = gateway.managed_binding(binding_id)
    if not binding then return binding_error or fail("STORAGE", "read external binding") end
    local access = gateway.access_status(binding, approval)
    if not access.ok then return access end
    local grant = bounds.object(access.value)
    local status = grant and bounds.text(grant.status, 40)
    if status ~= "granted" then
        if status == "denied" or status == "expired" or status == "withdrawn" then
            local revoked = gateway.revoke({binding_id = binding_id})
            if not revoked.ok then return revoked end
        end
        return ok({client_id = client, status = status or "pending"})
    end
    local db, open_error = database.open()
    if not db then return fail("STORAGE", open_error or "open client store") end
    local claimed, claim_error = store.claim(db, client)
    db:release()
    if not claimed or claim_error then return fail("STORAGE", "claim external configuration") end
    if claimed.rows_affected ~= 1 then return ok({client_id = client, status = "connected"}) end
    local authorized = gateway.authorize_materialization({binding_id = binding_id, attempt_id = binding.attempt_id, carrier_epoch = binding.carrier_epoch})
    if not authorized.ok then return authorized end
    local materialization = bounds.object(authorized.value)
    local key = materialization and bounds.text(materialization.materialization_key, 128)
    if not key then return fail("STORAGE", "materialization returns no authorization") end
    local minted = gateway.materialize({binding_id = binding_id, attempt_id = binding.attempt_id,
        carrier_epoch = binding.carrier_epoch, materialization_key = key})
    if not minted.ok then return minted end
    local credential = bounds.object(minted.value)
    local token = credential and bounds.text(credential.token, 128)
    local endpoint, endpoint_error = gateway.endpoint()
    if not token or not endpoint or not endpoint:match("^127%.") then return fail("UNAVAILABLE", endpoint_error or "external configuration is unavailable") end
    return ok({client_id = client, status = "connected", name = row.name, action_id = binding.action_id, thread_id = binding.thread_id,
        endpoint = endpoint, token = token, expires_at = binding.expires_at})
end
function M.list(workspace: string): Reply
    if not manage(workspace) then return fail("DENIED", "caller cannot list external clients") end
    local db, err = database.open()
    if not db then return fail("STORAGE", err or "open client store") end
    local rows, read_error = store.list(db, workspace)
    db:release()
    if not rows or read_error then return fail("STORAGE", "list external clients") end
    local clients: {Object} = {}
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        if not row then return fail("STORAGE", "external client row is invalid") end
        local binding_id = bounds.id(row.binding_id)
        if not binding_id then return fail("STORAGE", "external binding is invalid") end
        local checked = gateway.check({binding_id = binding_id})
        if not checked.ok then return checked end
        local binding = bounds.object(checked.value)
        row.status = row.revoked_at ~= nil and "revoked" or binding and binding.valid ~= true and "expired" or row.issued == 1 and "connected" or "needs you"
        clients[#clients + 1] = row
    end
    return ok({clients = clients})
end
function M.revoke(client: string, workspace: string): Reply
    if not manage(workspace) then return fail("DENIED", "caller cannot revoke external clients") end
    local row, failure = read(client)
    if not row then return failure or fail("NOT_FOUND", "external client is unavailable") end
    if row.workspace_id ~= workspace then return fail("DENIED", "external client belongs to another workspace") end
    local binding_id = bounds.id(row.binding_id)
    if not binding_id then return fail("STORAGE", "external binding is invalid") end
    local binding, missing = gateway.managed_binding(binding_id)
    if not binding then return missing or fail("STORAGE", "read external binding") end
    local revoked = gateway.revoke({binding_id = binding_id})
    if not revoked.ok then return revoked end
    local approval = bounds.id(row.approval_id)
    if approval then
        local withdrawn = subject_call.call(binding, {"bee.gateway.security:external_withdraw_policy"},
            "bee.approvals.binding:withdraw", {approval_id = approval})
        if not withdrawn.ok then return withdrawn end
    end
    return revoked
end
function M.records(client: string, workspace: string): Reply
    if not manage(workspace) then return fail("DENIED", "caller cannot read external clients") end
    local row, failure = read(client)
    if not row then return failure or fail("NOT_FOUND", "external client is unavailable") end
    if row.workspace_id ~= workspace then return fail("DENIED", "external client belongs to another workspace") end
    local id = bounds.id(row.binding_id)
    if not id then return fail("STORAGE", "external binding is invalid") end
    local binding, missing = gateway.managed_binding(id)
    if not binding then return missing or fail("STORAGE", "read external binding") end
    return subject_call.call(binding, {"bee.gateway.security:external_reader_policy"}, "bee.threads.binding:read_after",
        {thread_id = binding.thread_id, cursor = 0, limit = 64})
end
return M
