local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local ctx = require("ctx")
local bounds = require("bounds")
local hash = require("hash")
local uuid = require("uuid")
local registry = require("registry")
local protocol = require("open_protocol")
local arguments = require("arguments")
local M = {}
local BINDING_KEY = "bee.gateway.binding"
local HOST_PREFIX = "bee.workspace.host/"
local CALLER_PREFIX = "bee.app.open/"
local MAX_WAIT_MS = 30000

local function fail(code: string, message: string): {[string]: unknown}
    return {ok = false, error = {code = code, message = message}}
end

local function attribution(): (protocol.GatewayContext?, string?)
    local values, value_error = ctx.get(BINDING_KEY)
    if value_error then return nil, "the call context is unavailable" end
    local decoded = protocol.gateway_context(values)
    if not decoded then return nil, "the call is not bound to an approved application runtime" end
    return decoded, nil
end

local function request_id(action_id: string, idempotency_key: string): (string?, string?)
    local digest, digest_error = hash.sha256(action_id .. "\0" .. idempotency_key)
    if not digest then return nil, tostring(digest_error or "request identity failed") end
    return "agent-open-" .. digest:sub(1, 56), nil
end

function M.handle(raw: unknown): {[string]: unknown}
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "open request must be an object") end
    local presentation_session = object.presentation_session
    local action_id: string
    local workspace_id: string
    local origin: protocol.OriginView? = nil
    local provenance: protocol.Provenance? = nil
    if presentation_session ~= nil then
        local actor = security.actor()
        local meta = actor and bounds.object(actor:meta())
        local workspace = meta and bounds.id(meta.workspace_id)
        if not workspace then return fail("DENIED", "session presentation requires workspace identity") end
        if type(presentation_session) ~= "string"
            or not presentation_session:match("^bs:[^:]+:" .. workspace .. ":[^:]+$")
            or not security.can("bee.apps.session_present", workspace) then return fail("DENIED", "session presentation requires its host grant") end
        local entry = type(object.definition_id) == "string" and registry.get(object.definition_id) or nil
        local application = entry and bounds.object(entry.meta.application)
        if not application or application.role ~= "sessions" then return fail("DENIED", "presentation must use the admitted Sessions application") end
        local args = arguments.decode(object.arguments)
        if not args or #args ~= 2 or args[1] ~= "--session" or args[2] ~= presentation_session then return fail("INVALID", "presentation must navigate to its exact SessionRef") end
        action_id, workspace_id = presentation_session, workspace
    else
        local gateway_context, binding_error = attribution()
        if not gateway_context then return fail("UNAUTHENTICATED", binding_error or "gateway binding unavailable") end
        action_id, workspace_id = gateway_context.action_id, gateway_context.workspace_id
        origin, provenance = gateway_context.origin_view, gateway_context.provenance
    end
    local extra = bounds.fields(object, {"definition_id", "arguments", "idempotency_key", "presentation_session"})
    if extra then return fail("INVALID", extra) end
    local definition_id = bounds.id(object.definition_id)
    local idempotency_key = bounds.id(object.idempotency_key)
    local args = arguments.decode(object.arguments)
    if not definition_id then return fail("INVALID", "definition_id must be an identifier") end
    if not idempotency_key or #idempotency_key > 64 then return fail("INVALID", "idempotency_key must be a bounded identifier") end
    if not args then return fail("INVALID", "arguments must be bounded literal strings") end
    if not security.actor() then return fail("UNAUTHENTICATED", "the caller is not authenticated") end
    local request, request_error = request_id(action_id, idempotency_key)
    if not request then return fail("INVALID", request_error or "request identity failed") end
    local nonce = uuid.v7()
    local caller_token = (presentation_session ~= nil and "bee.app.presentation/" or CALLER_PREFIX) .. nonce
    local registered, register_error = process.registry.register(caller_token)
    if not registered then return fail("UNAVAILABLE", "open caller registration failed: " .. tostring(register_error)) end
    local host, lookup_error = process.registry.lookup(HOST_PREFIX .. workspace_id)
    if not host then
        process.registry.unregister(caller_token, process.registry.LOCAL)
        return fail("UNAVAILABLE", "workspace host is unavailable: " .. tostring(lookup_error or "not registered"))
    end
    local replies, listen_error = process.listen("bee.host.application.reply", {message = true})
    if not replies then
        process.registry.unregister(caller_token, process.registry.LOCAL)
        return fail("UNAVAILABLE", tostring(listen_error or "open reply channel unavailable"))
    end
    local sent, send_error = process.send(host, "bee.host.application", {version = 1, workspace_id = workspace_id,
        request_id = request, definition_id = definition_id, arguments = args, caller_token = caller_token, origin_view = origin,
        provenance = provenance, presentation = presentation_session ~= nil and true or nil})
    if not sent then
        process.unlisten(replies)
        process.registry.unregister(caller_token, process.registry.LOCAL)
        return fail("UNAVAILABLE", tostring(send_error or "workspace host rejected request"))
    end
    local timer = assert(time.timer(tostring(MAX_WAIT_MS) .. "ms"))
    local deadline = timer:channel()
    local reply: protocol.Reply? = nil
    while true do
        local selected = channel.select({replies:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then break end
        if selected.value:from() == tostring(host) then
            local candidate = protocol.reply(selected.value:payload():data(), workspace_id)
            if candidate and candidate.request_id == request then
                reply = candidate
                break
            end
        end
    end
    timer:stop()
    process.unlisten(replies)
    process.registry.unregister(caller_token, process.registry.LOCAL)
    if not reply then return fail("uncertain", "Application open outcome is unknown: workspace host did not answer") end
    local result = reply.reply
    if result.error_code ~= "" then return fail(result.error_code, result.error) end
    return {ok = true, value = {workspace_id = workspace_id, definition_id = result.definition_id,
        view_id = result.id, instance_id = result.instance_id, title = result.title, display_id = reply.display_id,
        reused = result.op == "focus"}}
end

return {handle = M.handle}
