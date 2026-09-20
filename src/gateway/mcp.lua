-- MIT. The MCP tool protocol as JSON-RPC 2.0 over one HTTP request, pure:
-- requests are decoded strictly, replies are built as the protocol shapes
-- them, with the built-in tool descriptions. Configured component tools join
-- these at admission. Nothing here executes a tool or reads a store.
local bounds = require("bounds")
local message = require("message")
local workspace_protocol = require("workspace_protocol")
local docs_protocol = require("docs_protocol")
local delivery_protocol = require("delivery_protocol")
local arguments = require("arguments")
local M = {}
M.PROTOCOL = "2025-06-18"
M.SERVER = {name = "bee", version = "1"}
M.MAX_BODY_BYTES = 524288
M.MAX_WORKSPACE_TEXT_BYTES = 65536
M.MAX_BRIEF_BYTES = 16384
M.MAX_WORKSPACE_BASE64_BYTES = 87384
type Object = {[string]: unknown}
type Call = {id: unknown, method: string, params: Object, notification: boolean}
type Tool = {name: string, description: string, operation: string, policies: {string}, schema: Object, annotations: Object}
local READ_ANNOTATIONS: Object = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false}
local WRITE_ANNOTATIONS: Object = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false}
local TOOLS: {Tool} = {
    {name = "thread_read", description = "Read committed records of the bound thread after a cursor", operation = "bee.threads.service:read_after",
        policies = {"bee:gateway_tool_read_policy"},
        schema = {type = "object", additionalProperties = false, properties = {cursor = {type = "integer", minimum = 0}, limit = {type = "integer", minimum = 1, maximum = 64}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_wait", description = "Wait, read-only and bounded, for the bound thread to move past a cursor; claims nothing", operation = "bee.threads.delivery:watch",
        policies = {"bee:gateway_tool_read_policy"},
        schema = {type = "object", additionalProperties = false, properties = {after_sequence = {type = "integer", minimum = 0}, wait_ms = {type = "integer", minimum = 0}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_message", description = "Append one message to the bound thread as the authenticated subject", operation = "bee.threads.service:record",
        policies = {"bee:gateway_tool_message_policy"}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"idempotency_key", "message_id", "message_kind", "recipient_ids", "content"}, properties = {
            idempotency_key = {type = "string", minLength = 1, maxLength = 160}, message_id = {type = "string", minLength = 1, maxLength = 160},
            message_kind = {type = "string", enum = {"request", "progress", "reply", "notification"}},
            recipient_ids = {type = "array", maxItems = 64, items = {type = "string", minLength = 1, maxLength = 160}},
            content = {type = "object", additionalProperties = false, properties = {text = {type = "string", maxLength = 16384}, artifact_ref = {type = "string", minLength = 1, maxLength = 160}}},
            in_reply_to = {type = "object", additionalProperties = false, required = {"thread_id", "record_id"}, properties = {thread_id = {type = "string", minLength = 1, maxLength = 160}, record_id = {type = "string", minLength = 1, maxLength = 160}}},
            outcome = {type = "string", enum = {"succeeded", "failed", "cancelled", "uncertain"}},
        }}},
    {name = "thread_launch", description = "Start one host-allow-listed managed agent in your own workspace and thread. Returns the admitted definition and title, submitted brief, and child thread, action and attempt IDs for thread_read, thread_message and thread_wait.", operation = "bee.harness.launch:agent_launch_call",
        policies = {"bee:gateway_tool_launch_policy"}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"definition_ref", "brief", "idempotency_key"}, properties = {
            definition_ref = {type = "string", minLength = 1, maxLength = 160},
            brief = {type = "string", minLength = 1, maxLength = 16384},
            idempotency_key = {type = "string", minLength = 1, maxLength = 64},
        }}},
    {name = "workspace", description = "Learn this destination's component authoring contract (read-only guide), or create, inspect, edit or freeze a caller-owned Governance authoring workspace", operation = "bee.governance:workspace_call",
        policies = {"bee:gateway_tool_workspace_policy"}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"guide", "create", "list", "read", "put", "remove", "freeze"}},
            workspace_id = {type = "string", minLength = 1, maxLength = 160},
            expected_revision = {type = "integer", minimum = 0, maximum = 9007199254740990},
            idempotency_key = {type = "string", minLength = 1, maxLength = 160},
            path = {type = "string", minLength = 1, maxLength = 240},
            content = {type = "string", maxLength = M.MAX_WORKSPACE_TEXT_BYTES},
            content_base64 = {type = "string", maxLength = M.MAX_WORKSPACE_BASE64_BYTES},
            snapshot_digest = {type = "string", pattern = "^[0-9a-f]{64}$"},
        }}},
    {name = "docs", description = "Read the platform documentation that ships inside Bee, offline: list the corpus by topic, search it for a phrase, or read one bounded window of one document by stable id. Use it to look up how the runtime modules an application author calls work (process, channel, tty, registry, sql, fs, http, events), Bee's own contracts (application, threads, hive and cross-node subscriptions, placement, gateway, storage, UI) and the terminal toolkit for drawing, layout, styles and input.", operation = "bee:docs_call",
        policies = {"bee:gateway_tool_docs_policy"}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"list", "search", "read"}},
            topic = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 64},
            query = {type = "string", minLength = 1, maxLength = 256},
            id = {type = "string", minLength = 1, maxLength = 160},
            section = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 120},
            offset = {type = "integer", minimum = 0},
            limit = {type = "integer", minimum = 1, maximum = 16384},
        }}},
    {name = "components", description = "Inspect installed registry components, explore Hub packages and review a resolved installation plan without applying it. Catalog and details discover packages; installed reads effective component state; inspect and state show exact package entries, resources and requirements; files and read_file inspect packaged documentation and examples; plan resolves the exact dependency closure, migrations and capabilities. This tool cannot apply, install, update, uninstall or write the registry.", operation = "bee.hub:call",
        policies = {"bee:gateway_tool_components_policy"}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "plan"}},
            request = {type = "object"},
        }}},
    {name = "delivery", description = "Request delivery of your frozen component pack to this destination: publish the frozen artifact, stage it and read the destination's preflight verdict; or read a staged version's review, selection and activation status. It names the human steps it cannot take: review in App Delivery, approval in Approvals and apply by the activation owner.", operation = "bee.governance:delivery_call",
        policies = {"bee:gateway_tool_delivery_policy"}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation", "workspace_id", "source_workspace", "version"}, properties = {
            operation = {type = "string", enum = {"request", "status"}},
            workspace_id = {type = "string", minLength = 1, maxLength = 160},
            source_workspace = {type = "string", minLength = 1, maxLength = 160},
            version = {type = "string", minLength = 1, maxLength = 160},
            snapshot_digest = {type = "string", pattern = "^[0-9a-f]{64}$"},
            source_node = {type = "string", minLength = 1, maxLength = 160},
            intent_id = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "publish", description = "Publish the exact application version a person has already reviewed, selected, approved and had applied at this destination. Use delivery request first and wait for the person; publication refuses any version that is not locally reviewed and applied.", operation = "bee.governance:delivery_call",
        policies = {"bee:gateway_tool_publish_policy"}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"workspace_id", "source_workspace", "version"}, properties = {
            workspace_id = {type = "string", minLength = 1, maxLength = 160},
            source_workspace = {type = "string", minLength = 1, maxLength = 160},
            version = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "application_open", description = "Open one application already applied and admitted in this agent's bound workspace through the existing workspace host. Arguments are literal launch strings. Pending retries coalesce; completed retries use the broker's bounded replay cache.", operation = "bee.applications:open_call",
        policies = {"bee:gateway_tool_application_open_policy"}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"definition_id", "arguments", "idempotency_key"}, properties = {
            definition_id = {type = "string", minLength = 1, maxLength = 160},
            arguments = {type = "array", maxItems = 16, items = {type = "string", maxLength = 1024}},
            idempotency_key = {type = "string", minLength = 1, maxLength = 64},
        }}},
}
M.TOOLS = TOOLS
-- Opening a reviewed application is deliberately not a base capability.  The
-- surface installs this one built-in trait when the binding admits the tool;
-- an access receipt must then make it selectable.
M.APPLICATION_RUNTIME_TRAIT = {id = "bee.application:runtime", title = "Application runtime",
    prompt = "Open only reviewed and admitted workspace applications. They may read and post in this agent's bound thread and continue after the initiating agent finishes under the durable thread lifetime contract.",
    tools = {"application_open"}}
-- Each advertised tool carries its own annotations.
M.WRITE_ANNOTATIONS = WRITE_ANNOTATIONS
function M.tool(name: string): Tool?
    for _, tool in ipairs(TOOLS) do if tool.name == name then return tool end end
    return nil
end
-- Decodes one JSON-RPC request. A batch, a notification without an id, or
-- a wrong version is refused; the caller answers with a protocol error.
function M.decode(value: unknown): (Call?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be one JSON-RPC object" end
    if object.jsonrpc ~= "2.0" then return nil, "jsonrpc must be 2.0" end
    if type(object.method) ~= "string" or object.method == "" or #(object.method :: string) > 64 then return nil, "method must be a short string" end
    local id = object.id
    if id ~= nil and type(id) ~= "string" and type(id) ~= "number" then return nil, "id must be a string or number" end
    -- A JSON-RPC notification carries no id and expects no reply body.
    local notification = id == nil
    if notification and not (object.method :: string):find("^notifications/") then return nil, "id is required" end
    local params: Object = {}
    if object.params ~= nil then
        local declared = bounds.object(object.params)
        if not declared then return nil, "params must be an object" end
        params = declared
    end
    return {id = id, method = object.method :: string, params = params, notification = notification}, nil
end
function M.result(id: unknown, result: unknown): Object
    return {jsonrpc = "2.0", id = id, result = result}
end
M.PARSE_ERROR = -32700
M.INVALID_REQUEST = -32600
M.METHOD_NOT_FOUND = -32601
M.INVALID_PARAMS = -32602
M.INTERNAL_ERROR = -32603
function M.failure(id: unknown, code: integer, message: string): Object
    return {jsonrpc = "2.0", id = id, error = {code = code, message = message}}
end
function M.initialize(): Object
    return {protocolVersion = M.PROTOCOL, capabilities = {tools = {listChanged = false}}, serverInfo = M.SERVER}
end
-- The tools a binding may call: the closed catalog filtered by the
-- binding's admitted tool names, in catalog order.
function M.list(admitted: {string}): Object
    local allowed: {[string]: boolean} = {}
    for _, name in ipairs(admitted) do allowed[name] = true end
    local tools: {Object} = {}
    for _, tool in ipairs(TOOLS) do
        if allowed[tool.name] then tools[#tools + 1] = {name = tool.name, description = tool.description, inputSchema = tool.schema, annotations = tool.annotations} end
    end
    return {tools = tools}
end
-- A tool result carries one text content block with the operation's JSON
-- reply; a refused call is a tool error, not a protocol error.
function M.tool_result(text: string, is_error: boolean): Object
    return {content = {{type = "text", text = text}}, isError = is_error}
end
-- Tool arguments are bounded before they reach an owner operation.
function M.read_arguments(params: Object): (Object?, string?)
    local arguments: Object = {}
    if params.arguments ~= nil then
        local declared = bounds.object(params.arguments)
        if not declared then return nil, "arguments must be an object" end
        arguments = declared
    end
    local unknown_field = bounds.fields(arguments, {"cursor", "limit"})
    if unknown_field then return nil, unknown_field end
    local cursor = 0
    if arguments.cursor ~= nil then
        local declared = bounds.cursor(arguments.cursor)
        if not declared then return nil, "cursor is out of range" end
        cursor = declared
    end
    local request: Object = {cursor = cursor}
    if arguments.limit ~= nil then
        local limit = bounds.integer(arguments.limit)
        if not limit or limit < 1 or limit > bounds.MAX_PAGE_RECORDS then return nil, "limit must be between 1 and " .. tostring(bounds.MAX_PAGE_RECORDS) end
        request.limit = limit
    end
    return request, nil
end
M.TRANSPORT_BUDGET_MS = 5000
function M.wait_arguments(params: Object): (Object?, string?)
    local arguments: Object = {}
    if params.arguments ~= nil then
        local declared = bounds.object(params.arguments)
        if not declared then return nil, "arguments must be an object" end
        arguments = declared
    end
    local unknown_field = bounds.fields(arguments, {"after_sequence", "wait_ms"})
    if unknown_field then return nil, unknown_field end
    local after = bounds.cursor(arguments.after_sequence == nil and 0 or arguments.after_sequence)
    if not after then return nil, "after_sequence is out of range" end
    local wait_ms = bounds.integer(arguments.wait_ms == nil and M.TRANSPORT_BUDGET_MS or arguments.wait_ms)
    if not wait_ms or wait_ms < 0 then return nil, "wait_ms must be a nonnegative integer" end
    -- The transport budget bounds every wait; the owner subtracts its margin.
    return {after_sequence = after, wait_ms = wait_ms, transport_budget_ms = M.TRANSPORT_BUDGET_MS}, nil
end
-- Message arguments are the public message shape without sender, thread or
-- lifecycle context. The full message decoder remains the authority for its
-- nested content, references and kind-specific invariants.
function M.message_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"idempotency_key", "message_id", "message_kind", "recipient_ids", "content", "in_reply_to", "outcome"})
    if unknown_field then return nil, unknown_field end
    local key = bounds.id(arguments.idempotency_key)
    if not key then return nil, "idempotency_key is required and must be an identifier" end
    local candidate: Object = {}
    for _, name in ipairs({"message_id", "message_kind", "recipient_ids", "content", "in_reply_to", "outcome"}) do
        if arguments[name] ~= nil then candidate[name] = arguments[name] end
    end
    -- message.decode requires a sender; the endpoint strips this sentinel
    -- before calling the owner, which supplies the authenticated actor.
    candidate.sender_id = "gateway-mcp-subject"
    local decoded, decode_error = message.decode(candidate)
    if not decoded then return nil, "message: " .. tostring(decode_error) end
    local body: Object = {message_id = decoded.message_id, message_kind = decoded.message_kind, recipient_ids = decoded.recipient_ids, content = decoded.content}
    if decoded.in_reply_to then body.in_reply_to = decoded.in_reply_to end
    if decoded.outcome then body.outcome = decoded.outcome end
    return {idempotency_key = key, body = body}, nil
end

-- Launch arguments are the launch facade's own bounded request; the endpoint
-- supplies the caller's binding, never a thread, action or workspace.
function M.launch_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"definition_ref", "brief", "idempotency_key"})
    if unknown_field then return nil, unknown_field end
    local definition_ref, idempotency_key = bounds.id(arguments.definition_ref), bounds.id(arguments.idempotency_key)
    if not definition_ref then return nil, "definition_ref is required and must be an identifier" end
    if not idempotency_key then return nil, "idempotency_key is required and must be an identifier" end
    local brief = bounds.text(arguments.brief, M.MAX_BRIEF_BYTES)
    if not brief or brief == "" then return nil, "brief must be nonempty bounded text" end
    return {definition_ref = definition_ref, brief = brief, idempotency_key = idempotency_key}, nil
end

-- Delivery arguments use the governance delivery protocol's own allow-list;
-- the publish tool admits only its three identity fields, and the facade
-- supplies the operation so a caller cannot smuggle one through.
function M.delivery_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local request, decode_error = delivery_protocol.decode(arguments)
    if not request then return nil, decode_error end
    return request, nil
end
function M.publish_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"workspace_id", "source_workspace", "version"})
    if unknown_field then return nil, unknown_field end
    local request, decode_error = delivery_protocol.decode({operation = "publish", workspace_id = arguments.workspace_id,
        source_workspace = arguments.source_workspace, version = arguments.version})
    if not request then return nil, decode_error end
    return request, nil
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

-- The docs tool shares the corpus request decoder, so the schema the tool
-- advertises and the fields it accepts cannot drift apart.
function M.docs_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local decoded, decode_error = docs_protocol.decode(arguments)
    if not decoded then return nil, decode_error end
    -- The corpus decoder owns the schema; this copies its bounded fields into
    -- the plain object the endpoint passes to the facade.
    local request: Object = {}
    for _, name in ipairs({"operation", "topic", "query", "id", "section", "offset", "limit"}) do
        local value = decoded[name]
        if value ~= nil then request[name] = value end
    end
    return request, nil
end

-- Governance owns the complete operation-specific schema. Keeping its decoder
-- here avoids a second, looser MCP dialect and converts canonical base64 to the
-- exact bytes accepted by the authoring store.
function M.workspace_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    if type(arguments.content) == "string" and #arguments.content > M.MAX_WORKSPACE_TEXT_BYTES then
        return nil, "content exceeds the MCP text bound"
    end
    if type(arguments.content_base64) == "string" and #arguments.content_base64 > M.MAX_WORKSPACE_BASE64_BYTES then
        return nil, "content_base64 exceeds the MCP body bound"
    end
    local request, decode_error = workspace_protocol.decode(arguments)
    if not request then return nil, decode_error end
    if type(request.content) == "string" and #request.content > M.MAX_WORKSPACE_TEXT_BYTES then
        return nil, "decoded content exceeds the MCP file bound"
    end
    return request, nil
end

-- The managed-agent component explorer is narrower than the private Hub
-- facade. Keep planning, apply and receipt operations out of this MCP path.
function M.components_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"operation", "request"})
    if unknown_field then return nil, unknown_field end
    local operation = bounds.member(arguments.operation, {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "plan"})
    if not operation then return nil, "components operation is read-only" end
    if arguments.request ~= nil and not bounds.object(arguments.request) then return nil, "request must be an object" end
    return {operation = operation, request = arguments.request}, nil
end
return M
