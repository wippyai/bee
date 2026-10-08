-- MIT
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
local operations = require("operations")
local application = require("application")
local access = require("access")
local schemas = require("schemas")
local protocol = require("protocol")

local M = {}
M.CALL = "application.call"
M.MAX_ACTIVE = 4
M.MAX_QUEUED = 64
M.MAX_TTL = 30000000000
type Object = {[string]: unknown}
type Request = {application: string, workspace_id: string, service: string, operation: string, arguments: Object}
type Invocation = {request: Request, operation: operations.Operation, actor: security.Actor, scope: security.Scope,
    caller: {node: string, pid: string}}

local function request(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "application call requires an object" end
    local extra = bounds.fields(value, {"application", "workspace_id", "service", "operation", "arguments"})
    if extra then return nil, extra end
    local app, workspace = bounds.id(value.application), bounds.id(value.workspace_id)
    local service, operation = bounds.line(value.service, 64), bounds.line(value.operation, 64)
    local arguments = bounds.object(value.arguments)
    if not app or not workspace or not service or not operation or not arguments then
        return nil, "application call requires application, workspace_id, service, operation and arguments"
    end
    return {application = app, workspace_id = workspace, service = service, operation = operation, arguments = arguments}, nil
end

function M.authorize(raw: unknown, caller: string, node: string): (Invocation?, string?)
    local asked, decode_error = request(raw)
    if not asked then return nil, decode_error end
    local binding, _, admission_error = application.admission(asked.application, asked.workspace_id)
    if not binding then return nil, admission_error or "application admission is absent or revoked" end
    local record, refusal = access.record(asked.workspace_id, asked.application)
    if not record then
        return nil, refusal and refusal.error and refusal.error.message or "application has no live exposure grant"
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
    local input_error = schemas.validate(selected.input, asked.arguments)
    if input_error then return nil, input_error end
    local definition, definition_error = application.definition(asked.application)
    if not definition then return nil, definition_error end
    local actor, actor_error = application.actor(asked.workspace_id, "hive", definition, 1)
    if not actor then return nil, actor_error end
    local scope, scope_error = application.scope(definition, asked.workspace_id)
    if not scope then return nil, scope_error end
    return {request = asked, operation = selected, actor = actor, scope = scope,
        caller = {node = peer, pid = caller}}, nil
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
    return protocol.ok({result = result, output = invocation.operation.output, revision = invocation.operation.revision})
end

return M
