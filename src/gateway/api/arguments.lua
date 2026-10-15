-- MIT. MCP tool argument validation.
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local message = require("message")
local workspace_protocol = require("workspace_protocol")
local docs_protocol = require("docs_protocol")
local delivery_protocol = require("delivery_protocol")
local arguments = require("arguments")
local node_tests = require("node_tests")
local app_requests = require("app_requests")
local requirements = require("requirements")
local M = {}
M.MAX_WORKSPACE_TEXT_BYTES = 65536
M.MAX_WORKSPACE_BASE64_BYTES = 87384
type Object = {[string]: unknown}
-- Tool arguments are bounded before they reach an owner operation.
function M.read_arguments(params: Object): (Object?, string?)
    local arguments: Object = {}
    if params.arguments ~= nil then
        local declared = bounds.object(params.arguments)
        if not declared then return nil, "arguments must be an object" end
        arguments = declared
    end
    local unknown_field = bounds.fields(arguments, {"cursor", "limit", "member_thread"})
    if unknown_field then return nil, unknown_field end
    local cursor = 0
    if arguments.cursor ~= nil then
        local declared = record_bounds.cursor(arguments.cursor)
        if not declared then return nil, "cursor is out of range" end
        cursor = declared
    end
    local request: Object = {cursor = cursor}
    if arguments.limit ~= nil then
        local limit = bounds.integer(arguments.limit)
        if not limit or limit < 1 or limit > record_bounds.MAX_PAGE_RECORDS then return nil, "limit must be between 1 and " .. tostring(record_bounds.MAX_PAGE_RECORDS) end
        request.limit = limit
    end
    if arguments.member_thread ~= nil then
        local thread_id = bounds.id(arguments.member_thread)
        if not thread_id then return nil, "member_thread must be a thread identifier" end
        request.member_thread = thread_id
    end
    return request, nil
end
-- Note arguments are the public message shape without sender, thread or
-- lifecycle context. A note names no recipients: it is recorded on the bound
-- thread and schedules nothing. The full message decoder remains the
-- authority for content and kind invariants.
function M.message_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"idempotency_key", "message_id", "message_kind", "content"})
    if unknown_field then return nil, unknown_field end
    local key = bounds.id(arguments.idempotency_key)
    if not key then return nil, "idempotency_key is required and must be an identifier" end
    local kind = bounds.member(arguments.message_kind, {"progress", "notification"})
    if not kind then return nil, "message_kind is not progress or notification" end
    -- message.decode requires a sender; the endpoint strips this sentinel
    -- before calling the owner, which supplies the authenticated actor.
    local decoded, decode_error = message.decode({message_id = arguments.message_id, message_kind = kind,
        recipient_ids = {}, content = arguments.content, sender_id = "gateway-mcp-subject"})
    if not decoded then return nil, "message: " .. tostring(decode_error) end
    local body: Object = {message_id = decoded.message_id, message_kind = decoded.message_kind, recipient_ids = decoded.recipient_ids, content = decoded.content}
    return {idempotency_key = key, body = body}, nil
end
-- An elevation request names one catalog capability with its parameters
-- and an optional TTL; the endpoint supplies the binding. Status polls
-- the request by approval id.
function M.capability_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"capability", "parameters", "ttl_ms"})
    if unknown_field then return nil, unknown_field end
    local name = bounds.id(arguments.capability)
    if not name then return nil, "capability is required and must be an identifier" end
    local parameters = bounds.object(arguments.parameters == nil and {} or arguments.parameters)
    if not parameters then return nil, "parameters must be an object" end
    local request: Object = {capability = name, parameters = parameters}
    if arguments.ttl_ms ~= nil then
        local ttl = bounds.integer(arguments.ttl_ms)
        if not ttl or ttl < 1 or ttl > 86400000 then return nil, "ttl_ms must be between 1 and 86400000" end
        request.ttl_ms = ttl
    end
    return request, nil
end
function M.capability_status_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"approval_id"})
    if unknown_field then return nil, unknown_field end
    local approval_id = bounds.id(arguments.approval_id)
    if not approval_id then return nil, "approval_id is required and must be an identifier" end
    return {approval_id = approval_id}, nil
end
-- A held elevation's tools name the approval they exercise; the gateway
-- reads everything else from that approval.
local function held_approval(arguments: Object): (string?, string?)
    local approval_id = bounds.id(arguments.approval_id)
    if not approval_id then return nil, "approval_id is required and must be an identifier" end
    return approval_id, nil
end
function M.process_run_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"approval_id", "arguments", "timeout_ms"})
    if unknown_field then return nil, unknown_field end
    local approval_id, approval_error = held_approval(arguments)
    if not approval_id then return nil, approval_error end
    local rows = bounds.dense_list(arguments.arguments == nil and {} or arguments.arguments, 64, "arguments")
    if not rows then return nil, "arguments must be a list of strings" end
    local values: {string} = {}
    for _, item in ipairs(rows) do
        if type(item) ~= "string" or #item > 4096 then return nil, "arguments must be a list of strings" end
        values[#values + 1] = item
    end
    local request: Object = {approval_id = approval_id, arguments = values}
    if arguments.timeout_ms ~= nil then
        local timeout = bounds.integer(arguments.timeout_ms)
        if not timeout or timeout < 1 or timeout > 600000 then return nil, "timeout_ms must be between 1 and 600000" end
        request.timeout_ms = timeout
    end
    return request, nil
end
function M.http_request_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"approval_id", "method", "url", "headers", "body", "timeout"})
    if unknown_field then return nil, unknown_field end
    local approval_id, approval_error = held_approval(arguments)
    if not approval_id then return nil, approval_error end
    if type(arguments.method) ~= "string" then return nil, "method is required" end
    if type(arguments.url) ~= "string" then return nil, "url is required" end
    local request: Object = {approval_id = approval_id, method = arguments.method, url = arguments.url}
    if arguments.headers ~= nil then request.headers = arguments.headers end
    if arguments.body ~= nil then request.body = arguments.body end
    if arguments.timeout ~= nil then request.timeout = arguments.timeout end
    return request, nil
end
-- Installation requests name a package; the host resolves everything else.
function M.install_arguments(params: Object, uninstall: boolean): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local allowed: {string} = {"component", "version", "parameters"}
    if uninstall then allowed = {"component"} end
    local unknown_field = bounds.fields(arguments, allowed)
    if unknown_field then return nil, unknown_field end
    local component = bounds.line(arguments.component, 160)
    if not component then return nil, "component is required as owner/name" end
    local request: Object = {component = component}
    if arguments.version ~= nil then
        local version = bounds.line(arguments.version, 128)
        if not version then return nil, "version must be an exact package version" end
        request.version = version
    end
    if arguments.parameters ~= nil then
        local parameters, problem = requirements.parameters(arguments.parameters)
        if not parameters then return nil, problem end
        request.parameters = parameters
    end
    return request, nil
end
function M.install_status_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"request_id"})
    if unknown_field then return nil, unknown_field end
    local request_id = bounds.id(arguments.request_id)
    if not request_id then return nil, "request_id is required and must be an identifier" end
    return {request_id = request_id}, nil
end
-- Publication requests name the exact package version, its visibility and
-- the admitted locked source tree; the worker seals the tree into one pack.
function M.hub_publish_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"component", "version", "visibility", "source"})
    if unknown_field then return nil, unknown_field end
    local component = bounds.line(arguments.component, 160)
    if not component then return nil, "component is required as owner/name" end
    local version = bounds.line(arguments.version, 128)
    if not version then return nil, "version is required as an exact package version" end
    local visibility = bounds.member(arguments.visibility, {"public", "private"})
    if not visibility then return nil, "visibility is required as public or private" end
    local source = bounds.text(arguments.source, 8192)
    if not source then return nil, "source is required as an absolute locked source tree" end
    return {component = component, version = version, visibility = visibility, source = source}, nil
end
function M.hub_publish_status_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"request_id"})
    if unknown_field then return nil, unknown_field end
    local request_id = bounds.id(arguments.request_id)
    if not request_id then return nil, "request_id is required and must be an identifier" end
    return {request_id = request_id}, nil
end
-- The capability report takes no arguments: the binding selects the surface.
function M.capabilities_arguments(params: Object): (Object?, string?)
    local arguments: Object = {}
    if params.arguments ~= nil then
        local declared = bounds.object(params.arguments)
        if not declared then return nil, "arguments must be an object" end
        arguments = declared
    end
    local unknown_field = bounds.fields(arguments, {})
    if unknown_field then return nil, unknown_field end
    return {}, nil
end
-- Delivery arguments use the governance delivery protocol's own allow-list;
-- the publish tool admits only its three identity fields, and the facade
-- supplies the operation so a caller cannot smuggle one through. An omitted
-- workspace_id is the binding's own workspace, the only one a subject names.
local function with_workspace(arguments: Object, workspace_id: string?): Object
    local result: Object = {}
    for key, value in pairs(arguments) do result[key] = value end
    if result.workspace_id == nil then result.workspace_id = workspace_id end
    return result
end
function M.delivery_arguments(params: Object, workspace_id: string?): (Object?, string?)
    local supplied = bounds.object(params.arguments)
    if not supplied then return nil, "arguments must be an object" end
    local arguments = with_workspace(supplied, workspace_id)
    local _, decode_error = delivery_protocol.decode(arguments)
    if decode_error then return nil, decode_error end
    -- The public delivery facade owns the public-to-private translation.
    -- Preserve its source_overlay_id payload instead of decoding it twice.
    return arguments, nil
end
function M.publish_arguments(params: Object, workspace_id: string?): (Object?, string?)
    local supplied = bounds.object(params.arguments)
    if not supplied then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(supplied, {"workspace_id", "source_overlay_id", "version"})
    if unknown_field then return nil, unknown_field end
    local arguments = with_workspace(supplied, workspace_id)
    local request: Object = {operation = "publish", workspace_id = arguments.workspace_id,
        source_overlay_id = arguments.source_overlay_id, version = arguments.version}
    local _, decode_error = delivery_protocol.decode(request)
    if decode_error then return nil, decode_error end
    return request, nil
end
-- Delivery and publication name the destination workspace. The gateway
-- derives a subject's workspace only from its binding, so a request may name
-- no workspace other than the binding's, and a binding without one names none.
function M.bound_workspace(arguments: Object, workspace_id: string?): string?
    if not workspace_id then return "this binding names no workspace" end
    if arguments.workspace_id ~= workspace_id then return "workspace_id must be this binding's workspace " .. workspace_id end
    return nil
end
function M.open_arguments(params: Object): (Object?, string?)
    local arguments_value = bounds.object(params.arguments)
    if not arguments_value then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments_value, {"definition_id", "arguments", "idempotency_key"})
    if unknown_field then return nil, unknown_field end
    local definition_id = bounds.id(arguments_value.definition_id)
    local idempotency_key = bounds.id(arguments_value.idempotency_key)
    local literal = arguments.decode(arguments_value.arguments)
    if not definition_id then return nil, "definition_id is required and must be an identifier" end
    if not idempotency_key or #idempotency_key > 64 then return nil, "idempotency_key must be a bounded identifier" end
    if not literal then return nil, "arguments must be an array of bounded literal strings" end
    return {definition_id = definition_id, arguments = literal, idempotency_key = idempotency_key}, nil
end

-- The tests tool shares the node runner's own request decoder, so the schema
-- the tool advertises and the fields it accepts cannot drift apart.
function M.app_tools_arguments(params: Object): (Object?, string?)
    return app_requests.decode(params.arguments)
end

function M.tests_arguments(params: Object): (Object?, string?)
    local arguments_value = bounds.object(params.arguments)
    if not arguments_value then return nil, "arguments must be an object" end
    local request, decode_error = node_tests.decode(arguments_value)
    if not request then return nil, decode_error end
    local decoded: Object = {operation = request.operation, application = request.application, filter = request.filter, run_id = request.run_id, node = request.node, idempotency_key = request.idempotency_key}
    return decoded, nil
end

-- The docs tool shares the corpus request decoder, so the schema the tool
-- advertises and the fields it accepts cannot drift apart.
function M.docs_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    -- The docs decoders own the schema; this copies their bounded fields into
    -- the plain object the endpoint passes to the facade.
    local request: Object = {}
    local web, web_error = docs_protocol.web(arguments)
    if web_error then return nil, web_error end
    if web then
        for _, name in ipairs({"operation", "query", "path", "offset", "limit"}) do
            local value = web[name]
            if value ~= nil then request[name] = value end
        end
        return request, nil
    end
    local decoded, decode_error = docs_protocol.decode(arguments)
    if not decoded then return nil, decode_error end
    for _, name in ipairs({"operation", "topic", "query", "id", "section", "offset", "limit"}) do
        local value = decoded[name]
        if value ~= nil then request[name] = value end
    end
    return request, nil
end

-- Governance owns the complete operation-specific schema. Keeping its decoder
-- here avoids a second, looser MCP dialect and converts canonical base64 to the
-- exact bytes accepted by the authoring store.
function M.overlay_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    if type(arguments.content) == "string" and #arguments.content > M.MAX_WORKSPACE_TEXT_BYTES then
        return nil, "content exceeds the 65,536-byte MCP chunk bound; put the first chunk, then append with offset"
    end
    if type(arguments.content_base64) == "string" and #arguments.content_base64 > M.MAX_WORKSPACE_BASE64_BYTES then
        return nil, "content_base64 exceeds the MCP body bound"
    end
    local decoded, decode_error = workspace_protocol.decode_overlay(arguments)
    if not decoded then return nil, decode_error end
    if type(decoded.content) == "string" and #decoded.content > M.MAX_WORKSPACE_TEXT_BYTES then
        return nil, "decoded content exceeds the MCP file bound"
    end
    -- Validation may decode base64 and translate overlay_id for its private
    -- model, but dispatch still targets the public overlay facade.
    return arguments, nil
end

-- The managed-agent component explorer is narrower than the private Hub
-- facade. Keep planning, apply and receipt operations out of this MCP path.
function M.components_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"operation", "request"})
    if unknown_field then return nil, unknown_field end
    local operation = bounds.member(arguments.operation, {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "installed_source", "plan"})
    if not operation then return nil, "components operation is read-only" end
    if arguments.request ~= nil and not bounds.object(arguments.request) then return nil, "request must be an object" end
    -- installed takes no request body at the Hub facade; an empty envelope
    -- object is the same call, so it is dropped here rather than refused there.
    if operation == "installed" then
        local body = bounds.object(arguments.request or {})
        if not body then return nil, "request must be an object" end
        if next(body) ~= nil then return nil, "installed takes no request body" end
        return {operation = operation}, nil
    end
    return {operation = operation, request = arguments.request}, nil
end
M.held_approval = held_approval
M.with_workspace = with_workspace
return M
