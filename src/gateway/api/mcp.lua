-- MIT. The MCP tool protocol as JSON-RPC 2.0 over one HTTP request, pure:
-- requests are decoded strictly, replies are built as the protocol shapes
-- them, with the built-in tool descriptions. Configured component tools join
-- these at admission. Nothing here executes a tool or reads a store.
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local message = require("message")
local workspace_protocol = require("workspace_protocol")
local docs_protocol = require("docs_protocol")
local gateway_protocol = require("gateway_protocol")
local delivery_protocol = require("delivery_protocol")
local arguments = require("arguments")
local session_tools = require("session_tools")
local node_tests = require("node_tests")
local json_schema = require("json_schema")
local canonical = require("canonical")
local M = {}
function M.is_retired_tool(name: string): boolean
    return name == "thread_launch" or name == "run_status" or name == "run_wait" or name == "run_cancel"
        or name == "session_directory" or name == "session_inbox" or name == "session_ack" or name == "session_reply"
        or name == "thread_sessions" or name == "launch_definitions" or name == "thread_wait" or name == "thread_notify"
end
M.PROTOCOL = "2025-06-18"
M.SERVER = {name = "bee", version = "1"}
M.MAX_BODY_BYTES = 524288
M.MAX_WORKSPACE_TEXT_BYTES = 65536
M.MAX_WORKSPACE_BASE64_BYTES = 87384
type Object = {[string]: unknown}
type RpcId = string | number
type RequestCall = {id: RpcId, method: string, params: Object, notification: false}
type NotificationCall = {method: string, params: Object, notification: true}
type Call = RequestCall | NotificationCall
type Tool = {name: string, description: string, operation: string, policies: {string}, schema: Object, annotations: Object}
type ListedTool = {name: string, description: string, inputSchema: Object, outputSchema: Object, annotations: Object}
type ToolList = {tools: {ListedTool}}
local READ_ANNOTATIONS: Object = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false}
local WRITE_ANNOTATIONS: Object = {readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false}
-- The component owns these links; the host fills each one through a typed
-- requirement. A built-in description never hard-codes a host policy ID.
type ToolPolicyRefs = {session: string, read: string, message: string, overlay: string, docs: string, components: string, delivery: string, publish: string, application_open: string, tests: string, app_tools: string, capabilities: string, capability: string, install: string, hub_publish: string}
local TOOL_POLICY_REFS: ToolPolicyRefs = {
    session = "bee.gateway.env:tool_session_policy_ref",
    read = "bee.gateway.env:tool_read_policy_ref",
    message = "bee.gateway.env:tool_message_policy_ref",
    overlay = "bee.gateway.env:tool_overlay_policy_ref",
    docs = "bee.gateway.env:tool_docs_policy_ref",
    components = "bee.gateway.env:tool_components_policy_ref",
    delivery = "bee.gateway.env:tool_delivery_policy_ref",
    publish = "bee.gateway.env:tool_publish_policy_ref",
    application_open = "bee.gateway.env:tool_application_open_policy_ref",
    app_tools = "bee.gateway.env:tool_app_tools_policy_ref",
    tests = "bee.gateway.env:tool_tests_policy_ref",
    capabilities = "bee.gateway.env:tool_read_policy_ref",
    capability = "bee.gateway.env:tool_read_policy_ref",
    install = "bee.gateway.env:tool_install_policy_ref",
    hub_publish = "bee.gateway.env:tool_hub_publish_policy_ref",
}
local BUILTIN_POLICY_REFS: {[string]: boolean} = {}
for _, reference in pairs(TOOL_POLICY_REFS) do BUILTIN_POLICY_REFS[reference] = true end
M.TOOL_POLICY_REFS = TOOL_POLICY_REFS
function M.is_tool_policy_reference(value: string): boolean return BUILTIN_POLICY_REFS[value] == true end
local TOOLS: {Tool} = {
    {name = "thread_read", description = "Read committed records of the bound thread after a cursor, or of a member_thread the caller belongs to, such as the thread of a session it opened. A member_thread is refused unless the caller is an active member; the thread owner checks it again.", operation = "bee.threads.binding:read_after",
        policies = {TOOL_POLICY_REFS.read},
        schema = {type = "object", additionalProperties = false, properties = {cursor = {type = "integer", minimum = 0}, limit = {type = "integer", minimum = 1, maximum = 64},
            member_thread = {type = "string", minLength = 1, maxLength = 160, description = "A thread the caller is a member of, such as the thread of a session it opened; omit for the bound thread"}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_message", description = "Record one note on the bound thread transcript as the authenticated subject. Recorded only; does not schedule execution. To give a session work call session_send.", operation = "bee.threads.binding:record",
        policies = {TOOL_POLICY_REFS.message}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"idempotency_key", "message_id", "message_kind", "content"}, properties = {
            idempotency_key = {type = "string", minLength = 1, maxLength = 160}, message_id = {type = "string", minLength = 1, maxLength = 160},
            message_kind = {type = "string", enum = {"progress", "notification"}},
            content = {type = "object", additionalProperties = false, properties = {text = {type = "string", maxLength = 16384}, artifact_ref = {type = "string", minLength = 1, maxLength = 160}}},
        }}},
    {name = "capabilities", description = "Read-only report of what this workspace's host admits for this agent: the admitted tool set with the policy each tool runs under, the trait catalog with allowed, active and requestable traits, the bound workspace and thread, and the guide and preflight tools for authoring. Read it before authoring; it names no secret and grants nothing.",
        operation = "bee.gateway.binding:surface",
        policies = {TOOL_POLICY_REFS.capabilities},
        schema = {type = "object", additionalProperties = false, properties = table.create(0, 1),
            examples = {{}}}, annotations = READ_ANNOTATIONS},
    {name = "overlay", description = "Read-only guide index, sections and worked example (guide names no overlay_id; without section it returns the short index, with section one section, with include_example the entries JSON), or create, list files in, read, put, append, remove or freeze a caller-owned overlay. List files in overlay requires overlay_id; without one list returns your own overlay IDs. For files over 65,536 bytes, put the first chunk then append bounded chunks with the exact byte offset. The owner returns the assembled SHA-256 digest; result_digest is an optional assertion if you already know it. Reads change nothing; creates, puts, appends, removes and freezes change the overlay.",
        operation = "bee.gov.binding:overlay_call",
        policies = {TOOL_POLICY_REFS.overlay}, annotations = WRITE_ANNOTATIONS,
        schema = workspace_protocol.overlay_schema(M.MAX_WORKSPACE_TEXT_BYTES, M.MAX_WORKSPACE_BASE64_BYTES)},
    {name = "docs", description = "Read the platform documentation that ships inside Bee, offline: list the corpus by topic (at most 64 per page), search it for a phrase (at most 16 matches per page), or read one bounded window of one document by stable id (at most 16,384 bytes per window, honoring offset after section selection). For anything the bundled corpus does not cover, web_search, web_read, web_toc and web_index read the live documentation site the corpus is selected from (search results, one page by path, the table of contents, the curated llms.txt index), each as one window with next_offset. Use it to look up how the runtime modules an application author calls work (process, channel, tty, registry, sql, fs, http, events), Bee's own contracts (application, threads, hive and cross-node subscriptions, placement, gateway, storage, UI) and the terminal toolkit for drawing, layout, styles and input.", operation = "bee.docs.binding:call",
        policies = {TOOL_POLICY_REFS.docs}, annotations = READ_ANNOTATIONS,
        schema = docs_protocol.schema()},
    {name = "components", description = "Read-only inspection of installed registry components, Hub packages and resolved installation plans. catalog {query?, page?, keyword?} discovers Hub packages; details {component} describes one; inspect {component, version} reads one exact Hub artifact (an exact version is required) as entry summaries first, at most 32 per page with next_offset, then page entries or read selected source windows; state {component, version} reads its metadata, resources and entry summaries the same way; files {component, version, resource, path?, offset?, limit?} pages a packaged directory; read_file {component, version, resource, path, offset?, limit?} reads one packaged file window of at most 16,384 bytes with next_offset; installed takes no request body and reads effective component inventory; installed_source {component, version, entry_id?, expected_revision?, offset?, limit?} lists and pages Lua source of an exact installed component, including local dev versions, under its registry revision; plan resolves dependencies and capabilities without applying. Hub artifact inspection and installed inspection are different sources and may differ. This tool cannot apply or write the registry; install_request asks the person to install a package.", operation = "bee.hub.binding:call",
        policies = {TOOL_POLICY_REFS.components}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"catalog", "details", "inspect", "state", "files", "read_file", "installed", "installed_source", "plan"}},
            request = {type = "object", additionalProperties = false,
                properties = {
                    query = {type = "string", maxLength = 160},
                    page = {type = "integer", minimum = 1},
                    keyword = {type = "string", maxLength = 160},
                    component = {type = "string", minLength = 1, maxLength = 160},
                    version = {type = "string", minLength = 1, maxLength = 128},
                    resource = {type = "string", minLength = 1, maxLength = 160},
                    path = {type = "string", minLength = 1, maxLength = 1024},
                    offset = {type = "integer", minimum = 0},
                    limit = {type = "integer", minimum = 1, maximum = 16384,
                        description = "read_file windows accept at most 16384 bytes"},
                    entry_id = {type = "string", minLength = 1, maxLength = 160},
                    expected_revision = {type = "integer", minimum = 0},
                    expected_digest = {type = "string", pattern = "^[0-9a-f]{64}$"},
                    parameters = {type = "array", maxItems = 32},
                    entry_offset = {type = "integer", minimum = 0,
                        description = "inspect/state entry page cursor; omit for the first page"},
                    entry_limit = {type = "integer", minimum = 1, maximum = 32,
                        description = "inspect/state entries per page, at most 32"},
                    include_data = {type = "boolean",
                        description = "inspect/state only: include entry source in the paged window; summaries travel otherwise"},
                },
                description = "Per-operation fields the Hub facade enforces: catalog takes query/page/keyword; "
                    .. "details takes component; inspect and state take component and an exact version, with "
                    .. "entry_offset, entry_limit and include_data paging entry summaries; files and "
                    .. "read_file take component, version, resource and path; installed takes nothing; "
                    .. "installed_source takes component and version, then entry_id with expected_revision to page; "
                    .. "plan takes its resolution request. Unknown fields are refused."},
        },
        examples = {
            {operation = "catalog", request = {query = "counter", page = 1}},
            {operation = "installed"},
            {operation = "installed_source", request = {component = "bee/application", version = "0.1.0-dev"}},
            {operation = "read_file", request = {component = "acme/tool", version = "1.2.3",
                resource = "package", path = "init.lua", offset = 0, limit = 16384}},
        }}},
    {name = "install_request", description = "Ask the person to install or update one Hub package in this agent's workspace. The host resolves the exact plan (the newest release when version is omitted, an update when the package is already installed through the Hub) and files one approval showing the package, version, source, dependency changes, the security policies it adds, replaces or removes, migrations and auto-start entries. Filing changes nothing; poll install_status with the returned request_id. A retry for the same plan replays the same request. A package that needs requirement values is refused; the person installs it in Modules.",
        operation = "bee.gateway.binding:install_request",
        policies = {TOOL_POLICY_REFS.install}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"component"}, properties = {
            component = {type = "string", minLength = 3, maxLength = 160, description = "Hub package as owner/name"},
            version = {type = "string", minLength = 1, maxLength = 128, description = "Exact version; omit for the newest release"},
        }}},
    {name = "uninstall_request", description = "Ask the person to remove one Hub package this installer holds, with the dependencies only it uses. The approval shows the removed packages and policies; applied migrations block the removal. Filing changes nothing; poll install_status with the returned request_id.",
        operation = "bee.gateway.binding:uninstall_request",
        policies = {TOOL_POLICY_REFS.install}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"component"}, properties = {
            component = {type = "string", minLength = 3, maxLength = 160, description = "Hub package as owner/name"},
        }}},
    {name = "install_status", description = "Poll one installation request by request_id: pending, refused (the person denied it or it expired), approved (applying), applied, or failed with the Hub code and message. On the first poll after approval the host consumes the decision once and applies exactly the approved plan; a replayed poll replays the recorded result.",
        operation = "bee.gateway.binding:install_status",
        policies = {TOOL_POLICY_REFS.install}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"request_id"}, properties = {
            request_id = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "publish_request", description = "Ask the person to publish one package to the Wippy Hub from this agent's workspace. The worker seals the source tree into one .wapp file without uploading and files one approval showing the module, version, pack digest, visibility, organization and source tree. Filing changes nothing on the Hub; poll publish_status with the returned request_id. The publishing credential never reaches the agent; only the host uploader uses it after approval.",
        operation = "bee.gateway.binding:publish_request",
        policies = {TOOL_POLICY_REFS.hub_publish}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"component", "version", "visibility", "source"}, properties = {
            component = {type = "string", minLength = 3, maxLength = 160, description = "Hub package as owner/name under the host publishing organization"},
            version = {type = "string", minLength = 1, maxLength = 128, description = "Exact version to publish"},
            visibility = {type = "string", enum = {"public", "private"}, description = "Module visibility for a newly created module"},
            source = {type = "string", minLength = 1, maxLength = 8192, description = "Absolute locked source tree the host admits"},
        }}},
    {name = "publish_status", description = "Read one publication request by request_id: pending, refused (the person denied it or it expired), approved (the owner worker is uploading), applied, or failed with the Hub code and message. Polling only reports state; after approval the owner worker uploads the sealed pack without any poll.",
        operation = "bee.gateway.binding:publish_status",
        policies = {TOOL_POLICY_REFS.hub_publish}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"request_id"}, properties = {
            request_id = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "delivery", description = "Check a frozen component pack without staging it (preflight needs the frozen snapshot_digest and stages nothing; call it before request), request delivery of your frozen pack to this destination (request publishes the frozen artifact, stages it and reads the destination's preflight verdict and needs snapshot_digest), or read a staged version's review, selection and activation status (status needs neither digest nor node; source_node and intent_id narrow it). It names the human steps it cannot take: review in Overlays, approval in Approvals and apply by the activation owner. Request and preflight stage and check; status only reads.",
        operation = "bee.gov.binding:delivery_call",
        policies = {TOOL_POLICY_REFS.delivery}, annotations = WRITE_ANNOTATIONS,
        schema = delivery_protocol.schema()},
    {name = "publish", description = "Publish the exact application version a person has already reviewed, selected, approved and had applied at this destination. Use delivery request first and wait for the person; publication refuses any version that is not locally reviewed and applied.", operation = "bee.gov.binding:delivery_call",
        policies = {TOOL_POLICY_REFS.publish}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"source_overlay_id", "version"}, properties = {
            workspace_id = {type = "string", minLength = 1, maxLength = 160, description = "This session's own workspace, the default; any other is refused"},
            source_overlay_id = {type = "string", minLength = 1, maxLength = 160},
            version = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "request_capability", description = "Ask the person to elevate this attempt with one host catalog capability for a bounded time: the approval shows the catalog's own wording bound to this thread and attempt, and on approval this attempt's placement resolves one grant for the authenticated thread actor. Filing the request grants nothing; poll capability_status for the decision. A retry replays the same approval.",
        operation = "bee.gateway.binding:request_capability",
        policies = {TOOL_POLICY_REFS.capability}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"capability"}, properties = {
            capability = {type = "string", minLength = 1, maxLength = 160},
            parameters = {type = "object"},
            ttl_ms = {type = "integer", minimum = 1, maximum = 86400000},
        }}},
    {name = "capability_status", description = "Poll one elevation request by approval_id. While the person has not decided it reports the pending decision; on approval it consumes the decision exactly once and writes the thread-actor grant the attempt resolves, returning its grant. A replayed poll replays the same grant.",
        operation = "bee.gateway.binding:capability_status",
        policies = {TOOL_POLICY_REFS.capability}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"approval_id"}, properties = {
            approval_id = {type = "string", minLength = 1, maxLength = 160},
        }}},
    {name = "tests", description = "Run the Lua tests your application's pack carries, inside the node, as the application: each test runs with the actor and the exact scope the person approved for the application, nothing more. It works on an application delivered from an overlay you own and only after the person approved the delivery. list names an application's tests; run starts a run and returns its run_id at once (filter keeps the tests whose id contains it); status with that run_id returns progress and, when complete, one result per test entry with its cases (pass, fail or skip, error, duration_ms) and totals. A test is a function.lua entry of meta.type test; the overlay guide's tests section shows one. A run keeps at most 64 tests, 512 cases and 2048 bytes per error text and reports any truncation; 16 runs are kept, a run is readable only by the actor that started it, and an unknown run_id is NOT_FOUND.",
        operation = "bee.node.binding:tests_call",
        policies = {TOOL_POLICY_REFS.tests}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
            operation = {type = "string", enum = {"list", "run", "status"}},
            application = {type = "string", minLength = 1, maxLength = 160, description = "list and run: the application definition id (app.<overlay>:app) or the overlay id it was delivered from"},
            filter = {type = "string", minLength = 1, maxLength = 160, description = "list and run: keep the tests whose entry id contains this text"},
            run_id = {type = "string", minLength = 1, maxLength = 160, description = "status: the run_id run returned"},
        }, examples = {{operation = "run", application = "tally"}, {operation = "status", run_id = "0198f1c2-0000-7000-8000-000000000000"}}}},
    {name = "process_run", description = "Run the command a person approved for this attempt through request_capability with process.exec: the approved command followed by these arguments, in the approved folder of this workspace, with only the host PATH in its environment. Pass the approval_id capability_status reported as granted. Returns the exit code and the combined stdout and stderr, at most 1 MiB per stream; a run past timeout_ms is stopped. Refused once the approval's time runs out or for any other command.",
        operation = "bee.gateway.binding:process_run",
        policies = {TOOL_POLICY_REFS.capability}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"approval_id"}, properties = {
            approval_id = {type = "string", minLength = 1, maxLength = 160},
            arguments = {type = "array", maxItems = 64, items = {type = "string", maxLength = 4096}},
            timeout_ms = {type = "integer", minimum = 1, maximum = 600000},
        }}},
    {name = "http_request", description = "Send one HTTP request a person approved for this attempt through request_capability with http.api: the url must be under the approved https origin and path prefix and the method one of the approved methods. Pass the approval_id capability_status reported as granted. Returns status_code, headers and body; a response that arrived from outside the approved origin and path is withheld. Refused once the approval's time runs out.",
        operation = "bee.gateway.binding:http_request",
        policies = {TOOL_POLICY_REFS.capability}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"approval_id", "method", "url"}, properties = {
            approval_id = {type = "string", minLength = 1, maxLength = 160},
            method = {type = "string", enum = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"}},
            url = {type = "string", minLength = 1, maxLength = 2048},
            headers = {type = "object"},
            body = {type = "string", maxLength = 1048576},
            timeout = {type = "number", minimum = 1, maximum = 60},
        }}},
    {name = "app_tools", description = "List the tools this workspace's applications offer agents, the application each belongs to, and why any tool is not offered. Each listed tool is callable by its own name, like any other tool: it runs as its application, with only the grants the person approved for that application, on the same state the application shows the person. Call it again after an application is installed or removed; tools/list follows the same discovery on every request.",
        operation = "bee.node.binding:app_tools",
        policies = {TOOL_POLICY_REFS.app_tools}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, properties = table.create(0, 1)}},
    {name = "application_open", description = "Open one application already applied and admitted in this agent's bound workspace through the existing workspace host. Arguments are literal launch strings. Pending retries coalesce; completed retries use the broker's bounded replay cache.", operation = "bee.apps:open_call",
        policies = {TOOL_POLICY_REFS.application_open}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"definition_id", "arguments", "idempotency_key"}, properties = {
            definition_id = {type = "string", minLength = 1, maxLength = 160},
            arguments = {type = "array", maxItems = 16, items = {type = "string", maxLength = 1024}},
            idempotency_key = {type = "string", minLength = 1, maxLength = 64},
        }}},
}
-- The ten default session tools project the bee.sessions owner contracts.
for _, tool in ipairs(session_tools.tools(TOOL_POLICY_REFS.session, READ_ANNOTATIONS, WRITE_ANNOTATIONS)) do
    TOOLS[#TOOLS + 1] = tool
end
M.TOOLS = TOOLS
-- The typed output contract every tool result shares: ok names success, value
-- carries the operation's ids, cursors, statuses or diagnostics, and error is
-- the normalized shape {code, message, field, retryable, remedy} naming the
-- next call. Results travel both as text JSON and as structured content.
local ERROR_SCHEMA: Object = {type = "object", additionalProperties = false,
    properties = {
        code = {type = "string"}, message = {type = "string"},
        field = {type = "string"}, retryable = {type = "boolean"}, remedy = {type = "string"},
    }}
local function output_schema(value: Object): Object
    return {type = "object", additionalProperties = false, required = {"ok"},
        properties = {ok = {type = "boolean"}, value = value, error = ERROR_SCHEMA}}
end
local function array_schema(items: Object): Object
    return {type = "array", items = items}
end
local STRING_SCHEMA: Object = {type = "string"}
local BOOLEAN_SCHEMA: Object = {type = "boolean"}
local INTEGER_SCHEMA: Object = {type = "integer"}
local STRING_ARRAY_SCHEMA = array_schema(STRING_SCHEMA)


local CAPABILITY_TOOL_SCHEMA: Object = {type = "object", additionalProperties = false,
    required = {"name", "description", "policies", "annotations"},
    properties = {name = STRING_SCHEMA, description = STRING_SCHEMA, policies = STRING_ARRAY_SCHEMA,
        annotations = {type = "object", additionalProperties = false,
            properties = {readOnlyHint = BOOLEAN_SCHEMA, destructiveHint = BOOLEAN_SCHEMA,
                idempotentHint = BOOLEAN_SCHEMA, openWorldHint = BOOLEAN_SCHEMA}}}}
local CAPABILITY_TRAIT_SCHEMA: Object = {type = "object", additionalProperties = false,
    required = {"id", "title", "tools"},
    properties = {id = STRING_SCHEMA, title = STRING_SCHEMA, tools = STRING_ARRAY_SCHEMA}}


local DELIVERY_DIAGNOSTIC_SCHEMA: Object = {type = "object", additionalProperties = false,
    required = {"code", "target", "message", "remedy"},
    properties = {code = STRING_SCHEMA, target = STRING_SCHEMA, message = STRING_SCHEMA, remedy = STRING_SCHEMA}}
local OUTPUT_SCHEMAS: {[string]: Object} = {
    session = output_schema({type = "object"}),
    call_tool = output_schema({type = "object"}),
    thread_read = output_schema({type = "object"}),
    thread_message = output_schema({type = "object"}),
    capabilities = output_schema({type = "object", additionalProperties = false,
        required = {"thread_id", "action_id", "revision", "digest", "tools", "traits", "allowed_traits",
            "active_traits", "thread_access", "authoring"},
        properties = {workspace_id = STRING_SCHEMA, thread_id = STRING_SCHEMA, action_id = STRING_SCHEMA,
            revision = INTEGER_SCHEMA, digest = STRING_SCHEMA, tools = array_schema(CAPABILITY_TOOL_SCHEMA),
            traits = array_schema(CAPABILITY_TRAIT_SCHEMA), allowed_traits = STRING_ARRAY_SCHEMA,
            active_traits = STRING_ARRAY_SCHEMA,
            requestable_access = {type = "object", additionalProperties = false, required = {"policy", "traits"},
                properties = {policy = STRING_SCHEMA, traits = STRING_ARRAY_SCHEMA}},
            thread_access = {type = "object", additionalProperties = false, required = {"thread_id", "note"},
                properties = {thread_id = STRING_SCHEMA, note = STRING_SCHEMA}},
            authoring = {type = "object", additionalProperties = false,
                required = {"guide_tool", "guide_operation", "preflight_tool", "preflight_operation", "note"},
                properties = {guide_tool = STRING_SCHEMA, guide_operation = STRING_SCHEMA, preflight_tool = STRING_SCHEMA,
                    preflight_operation = STRING_SCHEMA, note = STRING_SCHEMA}}}}),
    overlay = output_schema({type = "object"}),
    docs = output_schema({type = "object"}),
    components = output_schema({type = "object"}),
    delivery = output_schema({type = "object", additionalProperties = false,
        properties = {ready = {type = "boolean"}, staged = {type = "boolean"},
            plan_digest = STRING_SCHEMA, artifact_digest = STRING_SCHEMA, version = STRING_SCHEMA,
            source_overlay_id = STRING_SCHEMA, component = STRING_SCHEMA, pending_migrations = INTEGER_SCHEMA,
            diagnostics = array_schema(DELIVERY_DIAGNOSTIC_SCHEMA), human_steps = STRING_ARRAY_SCHEMA,
            human_steps_where = {type = "object", additionalProperties = false,
                properties = {approve = STRING_SCHEMA, open = STRING_SCHEMA}},
            intent_id = STRING_SCHEMA, approval_id = STRING_SCHEMA, activation_phase = STRING_SCHEMA,
            activation_refusal = STRING_SCHEMA}}),
    publish = output_schema({type = "object"}),
    application_open = output_schema({type = "object"}),
    app_tools = output_schema({type = "object", additionalProperties = false, properties = {
        tools = array_schema({type = "object", additionalProperties = false, properties = {
            name = STRING_SCHEMA, description = STRING_SCHEMA, application = STRING_SCHEMA, function_id = STRING_SCHEMA}}),
        diagnostics = array_schema({type = "object", additionalProperties = false, properties = {
            code = STRING_SCHEMA, tool = STRING_SCHEMA, message = STRING_SCHEMA}})}}),
    tests = output_schema({type = "object", additionalProperties = false,
        properties = {run_id = STRING_SCHEMA, application = STRING_SCHEMA, state = {type = "string", enum = {"running", "complete", "interrupted"}}, error = STRING_SCHEMA,
            total = INTEGER_SCHEMA, progress = {type = "object", additionalProperties = false,
                properties = {done = INTEGER_SCHEMA, total = INTEGER_SCHEMA}},
            tests = array_schema({type = "object", additionalProperties = false,
                properties = {id = STRING_SCHEMA, suite = STRING_SCHEMA, timeout = STRING_SCHEMA}}),
            entries = array_schema({type = "object", additionalProperties = false,
                properties = {id = STRING_SCHEMA, suite = STRING_SCHEMA, error = STRING_SCHEMA, truncated = BOOLEAN_SCHEMA,
                    cases = array_schema({type = "object", additionalProperties = false,
                        properties = {name = STRING_SCHEMA, status = {type = "string", enum = {"pass", "fail", "skip"}},
                            error = STRING_SCHEMA, duration_ms = INTEGER_SCHEMA}})}}),
            totals = {type = "object", additionalProperties = false,
                properties = {passed = INTEGER_SCHEMA, failed = INTEGER_SCHEMA, skipped = INTEGER_SCHEMA, errors = INTEGER_SCHEMA}},
            truncated = {type = "object", additionalProperties = false, properties = {cases = INTEGER_SCHEMA}}}}),
    request_capability = output_schema({type = "object", additionalProperties = false,
        properties = {approval_id = {type = "string"}, status = {type = "string"}}}),
    capability_status = output_schema({type = "object", additionalProperties = false,
        properties = {approval_id = {type = "string"}, status = {type = "string"},
            grant_id = {type = "string"}, expires_at = {type = "string"}, authorization_epoch = {type = "integer"},
            tools = STRING_ARRAY_SCHEMA}}),
    process_run = output_schema({type = "object", additionalProperties = false,
        properties = {exit_code = INTEGER_SCHEMA, output = STRING_SCHEMA}}),
    http_request = output_schema({type = "object", additionalProperties = false,
        properties = {status_code = INTEGER_SCHEMA, headers = {type = "object"}, body = STRING_SCHEMA}}),
    install_request = output_schema({type = "object"}),
    uninstall_request = output_schema({type = "object"}),
    install_status = output_schema({type = "object"}),
    publish_request = output_schema({type = "object"}),
    publish_status = output_schema({type = "object"}),
}
for name, schema in pairs(session_tools.OUTPUT_SCHEMAS) do OUTPUT_SCHEMAS[name] = schema end
M.OUTPUT_SCHEMAS = OUTPUT_SCHEMAS
-- Opening a reviewed application is deliberately not a base capability.  The
-- surface installs this one built-in trait when the binding admits the tool;
-- an access receipt must then make it selectable.
M.APPLICATION_RUNTIME_TRAIT = {id = "bee.app:runtime", title = "Application runtime",
    prompt = "Open only reviewed and admitted workspace applications. They may read and post in this agent's bound thread and continue after the initiating agent finishes under the durable thread lifetime contract.",
    tools = {"application_open"}}
-- The built-in trait that offers the application tools of the bound
-- workspace; a person enables it in the profile or approves it as access.
M.APPLICATION_TOOLS_TRAIT = {id = gateway_protocol.APPLICATION_TOOLS_TRAIT_ID, title = "Application tools",
    prompt = "Call the tools this workspace's applications offer agents. Each runs as its application with only the grants the person approved for it; app_tools lists them.",
    tools = {"app_tools"}}
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
    local method = bounds.text(object.method, 64)
    if not method or method == "" then return nil, "method must be a short string" end
    local id = object.id
    local params: Object = {}
    if object.params ~= nil then
        local declared = bounds.object(object.params)
        if not declared then return nil, "params must be an object" end
        params = declared
    end
    if id == nil then
        if not method:find("^notifications/") then return nil, "id is required" end
        return {method = method, params = params, notification = true}, nil
    end
    if type(id) == "string" then return {id = id, method = method, params = params, notification = false}, nil end
    if type(id) == "number" then return {id = id, method = method, params = params, notification = false}, nil end
    return nil, "id must be a string or number"
end
function M.result(id: RpcId, result: unknown): Object
    return {jsonrpc = "2.0", id = id, result = result}
end
M.PARSE_ERROR = -32700
M.INVALID_REQUEST = -32600
M.METHOD_NOT_FOUND = -32601
M.INVALID_PARAMS = -32602
M.INTERNAL_ERROR = -32603
function M.failure(id: RpcId?, code: integer, message: string): Object
    return {jsonrpc = "2.0", id = id, error = {code = code, message = message}}
end
-- The orientation a connecting agent reads once: where answers live and the
-- one path an application or driver takes to the person's desktop. Each tool
-- it names is in the catalog; the session tool says how to reach one this
-- session does not list.
M.INSTRUCTIONS = table.concat({
    "Bee is the terminal desktop this session runs in; the person sees its windows and approves what you deliver.",
    "Look an answer up before reading source or guessing a signature: docs searches the platform documentation bundled with Bee"
        .. " (search a phrase, then read the id it returns) and, with web_search and web_read, the live documentation site; components inspects the installed registry and Hub packages,"
        .. " and capabilities reports the tools, traits and workspace this session holds.",
    "To build an application or a driver: call overlay with operation guide for the section index, read the sections"
        .. " the task needs, and take include_example for a complete working application. Author entries.json in your"
        .. " overlay, freeze it, run delivery preflight on the frozen snapshot, then delivery request. The person approves"
        .. " it in Needs you and it opens from the start menu; a new version is a new freeze and request. Run your"
        .. " application's tests with tests run, then tests status.",
    "A tool this session does not list may sit behind a trait: session read shows the traits, select activates an allowed"
        .. " one and request_access asks the person for one that is not allowed.",
}, "\n\n")

-- Trait selection changes the admitted tool set, so the list changes.
-- Clients re-list after session select; select names the new revision.
function M.initialize(instructions: string?): Object
    return {protocolVersion = M.PROTOCOL, capabilities = {tools = {listChanged = true}}, serverInfo = M.SERVER,
        instructions = instructions}
end
-- The tools a binding may call: the closed catalog filtered by the
-- binding's admitted tool names, in catalog order, each with its input and
-- output contracts.
function M.list(admitted: {string}): ToolList
    local allowed: {[string]: boolean} = {}
    for _, name in ipairs(admitted) do allowed[name] = true end
    local tools: {ListedTool} = {}
    for _, tool in ipairs(TOOLS) do
        if allowed[tool.name] then
            local output = OUTPUT_SCHEMAS[tool.name]
            assert(output, "missing output schema for " .. tool.name)
            tools[#tools + 1] = {name = tool.name, description = tool.description,
                inputSchema = tool.schema, outputSchema = output, annotations = tool.annotations}
        end
    end
    return {tools = tools}
end
M.MAX_APP_TOOL_REPLY_BYTES = 262144
type AppTool = {alias: string, ref: string, definition_id: string, description: string,
    input_schema: Object, output_schema: Object?, annotations: Object}
type AppDiagnostic = {code: string, tool: string, message: string}
type AppProjection = {listed: {Object}, tools: {[string]: AppTool}, diagnostics: {AppDiagnostic}}
-- app_projection: the application tools a discovery offers, under their own
-- names, as listed tools. A name a gateway tool or another surface tool
-- already holds is not projected and is reported instead.
function M.app_projection(discovered: unknown, taken: {string}): AppProjection
    local used: {[string]: boolean} = {session = true, call_tool = true}
    for _, name in ipairs(taken) do used[name] = true end
    local result: AppProjection = {listed = {}, tools = {}, diagnostics = {}}
    local value = bounds.object(discovered)
    local diagnostics = value and value.diagnostics or nil
    for _, raw in ipairs(type(diagnostics) == "table" and diagnostics or {}) do
        local item = bounds.object(raw)
        if item then
            result.diagnostics[#result.diagnostics + 1] = {code = tostring(item.code), tool = tostring(item.tool),
                message = tostring(item.message)}
        end
    end
    local tools = value and value.tools or nil
    for _, raw in ipairs(type(tools) == "table" and tools or {}) do
        local item = bounds.object(raw)
        local alias = item and bounds.line(item.alias, 64) or nil
        local ref = item and bounds.id(item.ref) or nil
        local definition = item and bounds.id(item.definition_id) or nil
        local description = item and bounds.text(item.description, 4096) or nil
        local input = item and bounds.object(item.input_schema) or nil
        local output = item and item.output_schema ~= nil and bounds.object(item.output_schema) or nil
        local annotations = item and bounds.object(item.annotations) or nil
        if alias and ref and definition and description and input and annotations then
            if used[alias] then
                result.diagnostics[#result.diagnostics + 1] = {code = "NAME_TAKEN", tool = alias,
                    message = alias .. " from " .. ref .. " is not offered: a gateway tool already holds that name"}
            else
                used[alias] = true
                result.tools[alias] = {alias = alias, ref = ref, definition_id = definition, description = description,
                    input_schema = input, output_schema = output, annotations = annotations}
                result.listed[#result.listed + 1] = {name = alias, description = description, inputSchema = input,
                    outputSchema = output_schema(output or {type = "object"}), annotations = annotations}
            end
        end
    end
    return result
end
-- app_tool_arguments: the call's arguments, when they conform to the input
-- schema the tool advertises.
function M.app_tool_arguments(tool: AppTool, params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments == nil and {} or params.arguments)
    if not arguments then return nil, "tool arguments must be an object" end
    local failure = json_schema.validate(tool.input_schema, arguments)
    if failure then return nil, failure end
    return arguments, nil
end
-- app_tool_reply: nil when the application's reply is bounded and, on
-- success, conforms to the output schema the tool advertises.
function M.app_tool_reply(tool: AppTool, reply: unknown): string?
    local encoded = canonical.encode(reply, M.MAX_APP_TOOL_REPLY_BYTES)
    if not encoded or #encoded > M.MAX_APP_TOOL_REPLY_BYTES then
        return "the reply exceeds " .. tostring(M.MAX_APP_TOOL_REPLY_BYTES) .. " bytes"
    end
    local value = bounds.object(reply)
    local output = tool.output_schema
    if value and value.ok == true and output then
        local failure = json_schema.validate(output, value.value)
        if failure then return "the reply does not match the tool's output schema: " .. failure end
    end
    return nil
end
-- configured_arguments: a configured tool's arguments, when they conform to
-- the schema it advertises.
function M.configured_arguments(tool: Tool, params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "tool arguments must be an object" end
    local failure = json_schema.validate(tool.schema, arguments)
    if failure then return nil, failure end
    return arguments, nil
end
-- A tool result carries one text content block with the operation's JSON
-- reply plus the same reply as structured content; a refused call is a tool
-- error, not a protocol error.
function M.tool_result(text: string, is_error: boolean, structured: unknown?): Object
    local content: Object = {content = {{type = "text", text = text}}, isError = is_error}
    if structured ~= nil then content.structuredContent = structured end
    return content
end
-- One normalized tool error: code and message name the failure, field the
-- offending argument when one exists, retryable whether a retry may help,
-- and remedy the next call that unblocks the agent.
function M.tool_error(code: string, message: string, field: string?, retryable: boolean, remedy: string?): Object
    local error: Object = {code = code, message = message, retryable = retryable}
    if field ~= nil then error.field = field end
    if remedy ~= nil then error.remedy = remedy end
    return {ok = false, error = error}
end
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
    local allowed: {string} = {"component", "version"}
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
function M.tests_arguments(params: Object): (Object?, string?)
    local arguments_value = bounds.object(params.arguments)
    if not arguments_value then return nil, "arguments must be an object" end
    local request, decode_error = node_tests.decode(arguments_value)
    if not request then return nil, decode_error end
    local decoded: Object = {operation = request.operation, application = request.application, filter = request.filter, run_id = request.run_id}
    return decoded, nil
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
return M
