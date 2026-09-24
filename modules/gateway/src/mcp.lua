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
local agent_protocol = require("agent_protocol")
local M = {}
M.PROTOCOL = "2025-06-18"
M.SERVER = {name = "bee", version = "1"}
M.MAX_BODY_BYTES = 524288
M.MAX_WORKSPACE_TEXT_BYTES = 65536
M.MAX_WORKSPACE_BASE64_BYTES = 87384
type Object = {[string]: unknown}
type Call = {id: unknown, method: string, params: Object, notification: boolean}
type Tool = {name: string, description: string, operation: string, policies: {string}, schema: Object, annotations: Object}
local READ_ANNOTATIONS: Object = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false}
local WRITE_ANNOTATIONS: Object = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false}
-- The component owns these links; the host fills each one through a typed
-- requirement. A built-in description never hard-codes a host policy ID.
type ToolPolicyRefs = {read: string, message: string, launch: string, overlay: string, docs: string, components: string, delivery: string, publish: string, application_open: string}
local TOOL_POLICY_REFS: ToolPolicyRefs = {
    read = "bee.gateway.registry:tool_read_policy_ref",
    message = "bee.gateway.registry:tool_message_policy_ref",
    launch = "bee.gateway.registry:tool_launch_policy_ref",
    overlay = "bee.gateway.registry:tool_overlay_policy_ref",
    docs = "bee.gateway.registry:tool_docs_policy_ref",
    components = "bee.gateway.registry:tool_components_policy_ref",
    delivery = "bee.gateway.registry:tool_delivery_policy_ref",
    publish = "bee.gateway.registry:tool_publish_policy_ref",
    application_open = "bee.gateway.registry:tool_application_open_policy_ref",
}
local BUILTIN_POLICY_REFS: {[string]: boolean} = {}
for _, reference in pairs(TOOL_POLICY_REFS) do BUILTIN_POLICY_REFS[reference] = true end
M.TOOL_POLICY_REFS = TOOL_POLICY_REFS
function M.is_tool_policy_reference(value: string): boolean return BUILTIN_POLICY_REFS[value] == true end
local TOOLS: {Tool} = {
    {name = "thread_read", description = "Read committed records of the bound thread after a cursor", operation = "bee.threads.service:read_after",
        policies = {TOOL_POLICY_REFS.read},
        schema = {type = "object", additionalProperties = false, properties = {cursor = {type = "integer", minimum = 0}, limit = {type = "integer", minimum = 1, maximum = 64}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_wait", description = "Wait, read-only and bounded, for the bound thread to move past a cursor; claims nothing", operation = "bee.threads.delivery:watch",
        policies = {TOOL_POLICY_REFS.read},
        schema = {type = "object", additionalProperties = false, properties = {after_sequence = {type = "integer", minimum = 0}, wait_ms = {type = "integer", minimum = 0}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_sessions", description = "List the running agent sessions in your workspace whose threads you may read, yourself included (self). Each has a session address (its action_id), attempt, thread and title. Pass an action_id, attempt_id, or a thread_id holding one session as session to thread_message or thread_notify.", operation = "bee.threads.service:get",
        policies = {TOOL_POLICY_REFS.read},
        -- An empty table encodes as a JSON list unless allocated as a map.
        schema = {type = "object", additionalProperties = false, properties = table.create(0, 1)}, annotations = READ_ANNOTATIONS},
    {name = "thread_message", description = "Append one message as the authenticated subject: to the bound thread with recipient_ids, or with session to that running session's thread, addressed to it; it reads the message at its next thread_read and a thread_wait there wakes", operation = "bee.threads.service:record",
        policies = {TOOL_POLICY_REFS.message}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"idempotency_key", "message_id", "message_kind", "content"}, properties = {
            idempotency_key = {type = "string", minLength = 1, maxLength = 160}, message_id = {type = "string", minLength = 1, maxLength = 160},
            session = {type = "string", minLength = 1, maxLength = 160},
            message_kind = {type = "string", enum = {"request", "progress", "reply", "notification"}},
            recipient_ids = {type = "array", maxItems = 64, items = {type = "string", minLength = 1, maxLength = 160}},
            content = {type = "object", additionalProperties = false, properties = {text = {type = "string", maxLength = 16384}, artifact_ref = {type = "string", minLength = 1, maxLength = 160}}},
            in_reply_to = {type = "object", additionalProperties = false, required = {"thread_id", "record_id"}, properties = {thread_id = {type = "string", minLength = 1, maxLength = 160}, record_id = {type = "string", minLength = 1, maxLength = 160}}},
            outcome = {type = "string", enum = {"succeeded", "failed", "cancelled", "uncertain"}},
        }}},
    {name = "thread_notify", description = "Be told once when a running session ends its current turn or exits: a notification message lands on your own thread, where thread_wait wakes on it. session is an action_id, attempt_id, or a thread_id holding one session; a session that has already exited is reported at once.", operation = "bee.threads.service:notify",
        policies = {TOOL_POLICY_REFS.message}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"session", "idempotency_key"}, properties = {
            session = {type = "string", minLength = 1, maxLength = 160},
            idempotency_key = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "thread_launch", description = "Start one host-allow-listed managed agent, in your own workspace or in workspace_id when your host lets you launch there. By default it joins your thread; thread names an existing thread you belong to (thread_id) or a new one (title). workdir names a workspace resource (resource) or a folder under a root the host admits (root_ref, path). placement is native or docker; a placement this host does not provide is refused with PLACEMENT_UNAVAILABLE. A saved profile (saved_profile_id, saved_profile_revision) selects preferences for its definition. Each choice is refused unless the definition and its launch policy allow it. The child holds its workspace's host while it runs. Returns the admitted definition and title, submitted brief, and child thread, action and attempt IDs for thread_read, thread_message, thread_notify and thread_wait.", operation = "bee.harness.launch:agent_launch_call",
        policies = {TOOL_POLICY_REFS.launch}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"definition_ref", "brief", "idempotency_key"}, properties = {
            definition_ref = {type = "string", minLength = 1, maxLength = 160},
            brief = {type = "string", minLength = 1, maxLength = 16384},
            idempotency_key = {type = "string", minLength = 1, maxLength = 64},
            workspace_id = {type = "string", minLength = 32, maxLength = 32},
            saved_profile_id = {type = "string", minLength = 1, maxLength = 160},
            saved_profile_revision = {type = "integer", minimum = 1},
            workdir = {type = "object", additionalProperties = false, properties = {
                resource = {type = "string", minLength = 1, maxLength = 160},
                root_ref = {type = "string", minLength = 1, maxLength = 160},
                path = {type = "string", maxLength = 1024}}},
            thread = {type = "object", additionalProperties = false, properties = {
                thread_id = {type = "string", minLength = 1, maxLength = 160},
                title = {type = "string", minLength = 1, maxLength = 512}}},
            placement = {type = "string", enum = {"native", "docker"}},
        }}},
    {name = "overlay", description = "Learn this destination's governed overlay contract (read-only guide), or create, inspect, edit or freeze a caller-owned overlay", operation = "bee.governance.binding:overlay_call",
        policies = {TOOL_POLICY_REFS.overlay}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"guide", "create", "list", "read", "put", "remove", "freeze"}},
            overlay_id = {type = "string", minLength = 1, maxLength = 160},
            expected_revision = {type = "integer", minimum = 0, maximum = 9007199254740990},
            idempotency_key = {type = "string", minLength = 1, maxLength = 160},
            path = {type = "string", minLength = 1, maxLength = 240},
            content = {type = "string", maxLength = M.MAX_WORKSPACE_TEXT_BYTES},
            content_base64 = {type = "string", maxLength = M.MAX_WORKSPACE_BASE64_BYTES},
            snapshot_digest = {type = "string", pattern = "^[0-9a-f]{64}$"},
        }}},
    {name = "docs", description = "Read the platform documentation that ships inside Bee, offline: list the corpus by topic, search it for a phrase, or read one bounded window of one document by stable id. Use it to look up how the runtime modules an application author calls work (process, channel, tty, registry, sql, fs, http, events), Bee's own contracts (application, threads, hive and cross-node subscriptions, placement, gateway, storage, UI) and the terminal toolkit for drawing, layout, styles and input.", operation = "bee.docs.binding:call",
        policies = {TOOL_POLICY_REFS.docs}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"list", "search", "read"}},
            topic = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 64},
            query = {type = "string", minLength = 1, maxLength = 256},
            id = {type = "string", minLength = 1, maxLength = 160},
            section = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 120},
            offset = {type = "integer", minimum = 0},
            limit = {type = "integer", minimum = 1, maximum = 16384},
        }}},
    {name = "components", description = "Inspect installed registry components, explore Hub packages and review a resolved installation plan without applying it. Catalog and details discover packages; installed reads effective component state; inspect and state show exact package entries, resources and requirements; files and read_file inspect packaged documentation and examples; plan resolves the exact dependency closure, migrations and capabilities. This tool cannot apply, install, update, uninstall or write the registry.", operation = "bee.hub.binding:call",
        policies = {TOOL_POLICY_REFS.components}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "plan"}},
            request = {type = "object"},
        }}},
    {name = "delivery", description = "Request delivery of your frozen component pack to this destination: publish the frozen artifact, stage it and read the destination's preflight verdict; or read a staged version's review, selection and activation status. It names the human steps it cannot take: review in Overlays, approval in Approvals and apply by the activation owner.", operation = "bee.governance.binding:delivery_call",
        policies = {TOOL_POLICY_REFS.delivery}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation", "source_overlay_id", "version"}, properties = {
            operation = {type = "string", enum = {"request", "status"}},
            workspace_id = {type = "string", minLength = 1, maxLength = 160, description = "This session's own workspace, the default; any other is refused"},
            source_overlay_id = {type = "string", minLength = 1, maxLength = 160},
            version = {type = "string", minLength = 1, maxLength = 160},
            snapshot_digest = {type = "string", pattern = "^[0-9a-f]{64}$"},
            source_node = {type = "string", minLength = 1, maxLength = 160},
            intent_id = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "publish", description = "Publish the exact application version a person has already reviewed, selected, approved and had applied at this destination. Use delivery request first and wait for the person; publication refuses any version that is not locally reviewed and applied.", operation = "bee.governance.binding:delivery_call",
        policies = {TOOL_POLICY_REFS.publish}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"source_overlay_id", "version"}, properties = {
            workspace_id = {type = "string", minLength = 1, maxLength = 160, description = "This session's own workspace, the default; any other is refused"},
            source_overlay_id = {type = "string", minLength = 1, maxLength = 160},
            version = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "application_open", description = "Open one application already applied and admitted in this agent's bound workspace through the existing workspace host. Arguments are literal launch strings. Pending retries coalesce; completed retries use the broker's bounded replay cache.", operation = "bee.applications:open_call",
        policies = {TOOL_POLICY_REFS.application_open}, annotations = WRITE_ANNOTATIONS,
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
-- nested content, references and kind-specific invariants. A message to a
-- session names no recipients: the endpoint addresses the resolved session
-- and names the caller's own action as the sender's.
function M.message_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"idempotency_key", "message_id", "message_kind", "recipient_ids", "session", "content", "in_reply_to", "outcome"})
    if unknown_field then return nil, unknown_field end
    local key = bounds.id(arguments.idempotency_key)
    if not key then return nil, "idempotency_key is required and must be an identifier" end
    local session: string? = nil
    if arguments.session ~= nil then
        session = bounds.id(arguments.session)
        if not session then return nil, "session must be an identifier" end
        local named = arguments.recipient_ids
        if named ~= nil and (type(named) ~= "table" or next(named :: {[unknown]: unknown}) ~= nil) then
            return nil, "a message to a session names no recipient_ids; the session is the recipient"
        end
    end
    local candidate: Object = {}
    for _, name in ipairs({"message_id", "message_kind", "recipient_ids", "content", "in_reply_to", "outcome"}) do
        if arguments[name] ~= nil then candidate[name] = arguments[name] end
    end
    if session then candidate.recipient_ids = {} end
    -- message.decode requires a sender; the endpoint strips this sentinel
    -- before calling the owner, which supplies the authenticated actor.
    candidate.sender_id = "gateway-mcp-subject"
    local decoded, decode_error = message.decode(candidate)
    if not decoded then return nil, "message: " .. tostring(decode_error) end
    local body: Object = {message_id = decoded.message_id, message_kind = decoded.message_kind, recipient_ids = decoded.recipient_ids, content = decoded.content}
    if decoded.in_reply_to then body.in_reply_to = decoded.in_reply_to end
    if decoded.outcome then body.outcome = decoded.outcome end
    return {idempotency_key = key, body = body, session = session}, nil
end
-- Session discovery takes no arguments: the binding selects the workspace.
function M.sessions_arguments(params: Object): (Object?, string?)
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
-- A notice names the watched session and a retry key; the endpoint supplies
-- the caller's own thread and action as where and to whom it is delivered.
function M.notify_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"session", "idempotency_key"})
    if unknown_field then return nil, unknown_field end
    local session = bounds.id(arguments.session)
    if not session then return nil, "session is required and must be an identifier" end
    local key = bounds.id(arguments.idempotency_key)
    if not key then return nil, "idempotency_key is required and must be an identifier" end
    return {session = session, idempotency_key = key}, nil
end

-- Launch arguments are the launch facade's own bounded request; the endpoint
-- supplies the caller's binding, never a thread, action or workspace.
-- Launch arguments use the shared launch request decoder; the harness facade
-- decodes them again under the caller's authority.
function M.launch_arguments(params: Object): (Object?, string?)
    local launch = bounds.object(params.arguments)
    if not launch then return nil, "arguments must be an object" end
    local _, decode_error = agent_protocol.decode(launch)
    if decode_error then return nil, decode_error end
    return launch, nil
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
function M.overlay_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    if type(arguments.content) == "string" and #arguments.content > M.MAX_WORKSPACE_TEXT_BYTES then
        return nil, "content exceeds the MCP text bound"
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
    local operation = bounds.member(arguments.operation, {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "plan"})
    if not operation then return nil, "components operation is read-only" end
    if arguments.request ~= nil and not bounds.object(arguments.request) then return nil, "request must be an object" end
    return {operation = operation, request = arguments.request}, nil
end
return M
