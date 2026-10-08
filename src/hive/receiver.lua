-- MIT
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
local operations = require("operations")
local address = require("address")
local application = require("application")
local access = require("access")
local schemas = require("schemas")
local protocol = require("protocol")
local canonical = require("canonical")
local receipts = require("receipts")

local M = {}
M.CALL = "application.call"
M.MAX_ACTIVE = 4
M.MAX_QUEUED = 64
M.MAX_TTL = 30000000000
type Object = {[string]: unknown}
type Request = {application: string, workspace_id: string, service: string, operation: string, arguments: Object, idempotency_key: string?, address: address.Resolved?}
type Invocation = {request: Request, operation: operations.Operation, actor: security.Actor, scope: security.Scope,
    caller: {node: string, pid: string}, receipt_key: string?, owner_receipts: boolean?}

local function request(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "application call requires an object" end
    local extra = bounds.fields(value, {"application", "workspace_id", "service", "operation", "arguments", "idempotency_key"})
    if extra then return nil, extra end
    local workspace = value.workspace_id == nil and "" or bounds.id(value.workspace_id)
    local service, operation = bounds.line(value.service, 64), bounds.line(value.operation, 64)
    local arguments = bounds.object(value.arguments)
    if not workspace or not service or not operation or not arguments then
        return nil, "application call requires application, workspace_id, service, operation and arguments"
    end
    local key = value.idempotency_key == nil and nil or bounds.line(value.idempotency_key, 128)
    if value.idempotency_key ~= nil and not key then return nil, "idempotency key is malformed" end
    if not canonical.encode(value, protocol.MAX_BYTES) then return nil, "application call exceeds its byte bound" end
    local resolved, address_error = address.resolve(value.application, workspace)
    if not resolved then return nil, address_error end
    return {application = resolved.application, workspace_id = workspace, service = service, operation = operation,
        arguments = arguments, idempotency_key = key, address = resolved}, nil
end

local function host_exposure(asked: Request, caller: string, node: string, inspection: boolean?): (boolean, Invocation?, string?)
    local selected: Object? = nil
    for _, entry in ipairs(application.host_entries("bee.hive.host_exposure")) do
        local data = bounds.object(entry.data)
        if data and data.application_ref == asked.application then
            if selected then return true, nil, "duplicate host exposure" end
            selected = data
        end
    end
    if not selected then return false, nil, nil end
    local authorizer = bounds.id(selected.authorizer)
    local refs = bounds.ids(selected.operations, true)
    if not authorizer or not refs then return true, nil, "invalid host exposure" end
    local operation: operations.Operation? = nil
    for _, ref in ipairs(refs) do
        local raw = registry.get(ref)
        local decoded, err = operations.decode(raw, true)
        if err then return true, nil, err end
        if decoded and decoded.application_ref == asked.application and decoded.service == asked.service and decoded.name == asked.operation then
            if operation then return true, nil, "duplicate exposed operation" end
            operation = decoded
        end
    end
    if not operation then return true, nil, "unknown exposed operation" end
    local input_error = schemas.validate(operation.input, asked.arguments)
    if not inspection and input_error then return true, nil, input_error end
    local peer = protocol.node_of(caller, node)
    local executor = funcs.new():with_context({["bee.hive.caller"] = {node = peer, pid = caller}})
    local raw, err = executor:call(authorizer, {workspace_id = asked.workspace_id, operation = asked.operation, arguments = asked.arguments, inspection = inspection == true})
    local reply = bounds.object(raw)
    local mapped = reply and reply.ok == true and bounds.object(reply.value) or nil
    if err or not mapped then return true, nil, reply and tostring(reply.error) or tostring(err) end
    local workspace, subject = bounds.id(mapped.workspace_id), bounds.id(mapped.subject)
    local policies = bounds.ids(mapped.policies, true)
    if not workspace or not subject or not policies then return true, nil, "host subject mapping is malformed" end
    asked.workspace_id = workspace
    local binding, _, admission_error = application.admission(asked.application, workspace)
    if not binding then return true, nil, admission_error or "application admission is absent or revoked" end
    local actor = assert(security.new_actor(subject, {node = peer, workspace_id = workspace}))
    local exposure = assert(security.named_scope("bee.security.hive:hive_exposure_scope"))
    if exposure:evaluate(actor, "hive.expose." .. operation.mode, operation.ref) ~= "allow" then
        return true, nil, "operation exposure is revoked: " .. peer .. " / " .. workspace .. " / " .. operation.ref
    end
    local loaded: {security.Policy} = {}
    for _, name in ipairs(policies) do loaded[#loaded + 1] = assert(security.policy(name)) end
    local scope = assert(security.new_scope(loaded))
    if scope:evaluate(actor, tostring(selected.permission_action) .. "." .. asked.operation, workspace) ~= "allow" then
        return true, nil, "receiving workspace session permission is denied"
    end
    return true, {request = asked, operation = operation, actor = actor, scope = scope,
        caller = {node = peer, pid = caller}, owner_receipts = selected.owner_receipts == true}, nil
end

function M.authorize(raw: unknown, caller: string, node: string, inspection: boolean?): (Invocation?, string?)
    local asked, decode_error = request(raw)
    if not asked then return nil, decode_error end
    local host, invocation, host_error = host_exposure(asked, caller, node, inspection)
    if host then return invocation, host_error end
    if asked.workspace_id == "" then return nil, "application call requires workspace_id" end
    local binding, admission, admission_error = application.admission(asked.application, asked.workspace_id)
    if not binding then return nil, admission_error or "application admission is absent or revoked" end
    local record, refusal = access.record(asked.workspace_id, asked.application)
    if not record then
        return nil, refusal and refusal.error and refusal.error.message or "application has no live exposure grant"
    end
    local mapped = asked.address
    if mapped and mapped.overlay_owner and mapped.overlay_owner ~= record.overlay_owner then
        return nil, "application address owner differs from its installed grant"
    end
    if admission and admission.overlay_owner ~= record.overlay_owner then
        return nil, "application admission owner differs from its installed grant"
    end
    if admission and mapped and mapped.identity
        and (admission.source_node ~= mapped.identity.source_node
            or admission.source_workspace ~= mapped.identity.source_workspace) then
        return nil, "application address source differs from its admitted source"
    end
    local owned, owner_error = registry.overlay(record.overlay_owner)
    if not owned then return nil, "exposure ownership is unavailable: " .. tostring(owner_error) end
    if not owned:get(asked.application) then return nil, "application is outside its installed grant owner" end
    local selected: operations.Operation? = nil
    for _, entry in ipairs(assert(owned:find({["meta.application_ref"] = asked.application,
        ["meta.hive_service"] = asked.service}))) do
        local operation, operation_error = operations.decode(entry)
        if operation_error then return nil, operation_error end
        if operation and operation.name == asked.operation then
            if selected then return nil, "duplicate exposed operation" end
            selected = operation
        end
    end
    if not selected then return nil, "unknown exposed operation" end
    local peer = protocol.node_of(caller, node)
    local exposed, audience = false, false
    for _, grant in ipairs(record.capabilities) do
        if grant.capability == "hive.expose" and grant.resource == selected.mode then
            local refs = bounds.ids(grant.scope.operations, true)
            local audiences = bounds.ids(grant.scope.audiences, true)
            for _, ref in ipairs(refs or {}) do
                if ref == selected.ref then
                    exposed = true
                    for _, approved in ipairs(audiences or {}) do
                        if approved == peer or approved == "*" then audience = true end
                    end
                end
            end
        end
    end
    if not exposed then return nil, "operation is not exposed in its declared mode" end
    if not audience then return nil, "authenticated peer node is outside the approved audience" end
    local exposure, exposure_error = security.named_scope("bee.security.hive:hive_exposure_scope")
    if not exposure then return nil, tostring(exposure_error) end
    local peer_actor = security.new_actor("bee.hive.peer:" .. peer, {node = peer})
    if exposure:evaluate(peer_actor, "hive.expose." .. selected.mode, selected.ref) ~= "allow" then
        return nil, "operation exposure is revoked"
    end
    if selected.mode == "policy" then return nil, "policy operation requires a trusted subject mapping" end
    if not inspection and selected.effect == "mutation" and not asked.idempotency_key then return nil, "mutation requires an idempotency key" end
    local input_error = schemas.validate(selected.input, asked.arguments)
    if not inspection and input_error then return nil, input_error end
    local definition, definition_error = application.definition(asked.application)
    if not definition then return nil, definition_error end
    local actor, actor_error = application.actor(asked.workspace_id, "hive", definition, 1)
    if not actor then return nil, actor_error end
    local scope, scope_error = application.scope(definition, asked.workspace_id)
    if not scope then return nil, scope_error end
    return {request = asked, operation = selected, actor = actor, scope = scope,
        caller = {node = peer, pid = caller}, receipt_key = nil}, nil
end

function M.claim(invocation: Invocation): (boolean, protocol.Reply?, string?)
    local asked = invocation.request
    if invocation.owner_receipts or invocation.operation.effect == "read" then return true, nil, nil end
    local key = assert(canonical.encode({peer = invocation.caller.node, workspace = asked.workspace_id,
        application = asked.application, service = asked.service, operation = asked.operation, key = asked.idempotency_key}, 4096))
    local fingerprint, fingerprint_error = canonical.encode({ref = invocation.operation.ref, revision = invocation.operation.revision,
        input = invocation.operation.input, output = invocation.operation.output, arguments = asked.arguments}, protocol.MAX_BYTES)
    if not fingerprint then return false, nil, "mutation fingerprint exceeds its bound: " .. tostring(fingerprint_error) end
    local fresh, reply, err = receipts.claim(key, fingerprint)
    if fresh then invocation.receipt_key = key end
    return fresh, reply, err
end

function M.save(invocation: Invocation, reply: protocol.Reply): protocol.Reply
    if invocation.receipt_key then
        local saved, err = receipts.complete(invocation.receipt_key, reply)
        if not saved then return protocol.fail("receipt completion failed; outcome unknown: " .. tostring(err):sub(1, 2048)) end
    end
    return reply
end

function M.start(invocation: Invocation): (funcs.Future?, string?)
    local executor = funcs.new():with_actor(invocation.actor):with_scope(invocation.scope)
        :with_context({["bee.hive.caller"] = invocation.caller})
        :with_options({retry = {max_attempts = 1}})
    local future, err = executor:async(invocation.operation.ref, invocation.request.arguments)
    if not future then return nil, tostring(err) end
    return future, nil
end

function M.finish(invocation: Invocation, future: funcs.Future): protocol.Reply
    local payload, err = future:result()
    if err then return protocol.fail("application call failed: " .. tostring(err):sub(1, 2048)) end
    local result: unknown = nil
    if payload then
        local decode_error: unknown
        result, decode_error = payload:data()
        if decode_error then return protocol.fail("invalid application reply: " .. tostring(decode_error)) end
    end
    local output_error = schemas.validate(invocation.operation.output, result)
    if output_error then return protocol.fail("invalid application reply: " .. output_error) end
    local reply = protocol.ok({result = result, output = invocation.operation.output, revision = invocation.operation.revision})
    if not canonical.encode(reply, protocol.MAX_BYTES) then return protocol.fail("application reply exceeds its byte bound") end
    return reply
end

return M
