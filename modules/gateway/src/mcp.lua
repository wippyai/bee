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
type ToolPolicyRefs = {read: string, message: string, inbox: string, discover: string, send_grant: string, launch: string, run: string, overlay: string, docs: string, components: string, delivery: string, publish: string, application_open: string, capabilities: string, launch_definitions: string, capability: string, install: string}
local TOOL_POLICY_REFS: ToolPolicyRefs = {
    read = "bee.gateway:tool_read_policy_ref",
    message = "bee.gateway:tool_message_policy_ref",
    inbox = "bee.gateway:tool_inbox_policy_ref",
    discover = "bee.gateway:tool_discover_policy_ref",
    send_grant = "bee.gateway:tool_send_grant_policy_ref",
    launch = "bee.gateway:tool_launch_policy_ref",
    run = "bee.gateway:tool_run_policy_ref",
    overlay = "bee.gateway:tool_overlay_policy_ref",
    docs = "bee.gateway:tool_docs_policy_ref",
    components = "bee.gateway:tool_components_policy_ref",
    delivery = "bee.gateway:tool_delivery_policy_ref",
    publish = "bee.gateway:tool_publish_policy_ref",
    application_open = "bee.gateway:tool_application_open_policy_ref",
    capabilities = "bee.gateway:tool_read_policy_ref",
    launch_definitions = "bee.gateway:tool_launch_policy_ref",
    capability = "bee.gateway:tool_read_policy_ref",
    install = "bee.gateway:tool_install_policy_ref",
}
local BUILTIN_POLICY_REFS: {[string]: boolean} = {}
for _, reference in pairs(TOOL_POLICY_REFS) do BUILTIN_POLICY_REFS[reference] = true end
M.TOOL_POLICY_REFS = TOOL_POLICY_REFS
function M.is_tool_policy_reference(value: string): boolean return BUILTIN_POLICY_REFS[value] == true end
local TOOLS: {Tool} = {
    {name = "thread_read", description = "Read committed records of the bound thread after a cursor, or of a member_thread the caller launched and belongs to. A member_thread is refused unless the caller is an active member; the thread owner checks it again.", operation = "bee.threads.service:read_after",
        policies = {TOOL_POLICY_REFS.read},
        schema = {type = "object", additionalProperties = false, properties = {cursor = {type = "integer", minimum = 0}, limit = {type = "integer", minimum = 1, maximum = 64},
            member_thread = {type = "string", minLength = 1, maxLength = 160, description = "A thread the caller is a member of, such as a child it launched on a new thread; omit for the bound thread"}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_wait", description = "Wait, read-only and bounded, for the bound thread, or a member_thread the caller belongs to, to move past a cursor; claims nothing. A member_thread is refused unless the caller is an active member.", operation = "bee.threads.delivery:watch",
        policies = {TOOL_POLICY_REFS.read},
        schema = {type = "object", additionalProperties = false, properties = {after_sequence = {type = "integer", minimum = 0}, wait_ms = {type = "integer", minimum = 0},
            member_thread = {type = "string", minLength = 1, maxLength = 160, description = "A thread the caller is a member of; omit for the bound thread"}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_sessions", description = "Page the running agent sessions in your workspace whose threads you may read, yourself included (self), in stable action order. Each has a session address (its action_id), attempt, thread and title. Pass cursor from the previous reply's next_cursor; a missing next_cursor ends the listing. Pass an action_id, attempt_id, or a thread_id holding one session as session to thread_message or thread_notify.", operation = "bee.threads.service:get",
        policies = {TOOL_POLICY_REFS.read},
        schema = {type = "object", additionalProperties = false,
            properties = {cursor = {type = "integer", minimum = 0, description = "offset into the stable session order; omit for the first page"},
                limit = {type = "integer", minimum = 1, maximum = 64, description = "page size, at most 64"}},
            examples = {{limit = 32}, {cursor = 32, limit = 32}}}, annotations = READ_ANNOTATIONS},
    {name = "thread_message", description = "Append one message as the authenticated subject: to the bound thread with recipient_ids, or with session to that running session's thread, addressed to it, or with member_thread to a thread the caller belongs to such as a child it launched; the recipient reads the message at its next thread_read and a thread_wait there wakes", operation = "bee.threads.service:record",
        policies = {TOOL_POLICY_REFS.message}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"idempotency_key", "message_id", "message_kind", "content"}, properties = {
            idempotency_key = {type = "string", minLength = 1, maxLength = 160}, message_id = {type = "string", minLength = 1, maxLength = 160},
            session = {type = "string", minLength = 1, maxLength = 160},
            member_thread = {type = "string", minLength = 1, maxLength = 160, description = "A thread the caller is an active member of; the message lands there, and the field is refused with session" },
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
    {name = "session_directory", description = "Page the local agents in your workspace that your host permits you to discover, in stable name order. Each entry has a host-assigned name, an exact node/action address, current acceptance epoch, attempt state and latest inbox delivery state; discovery grants no thread read or send permission. Pass cursor from the previous reply's next_cursor; a missing next_cursor ends the listing.", operation = "bee.threads.service:inbox_describe",
        policies = {TOOL_POLICY_REFS.inbox, TOOL_POLICY_REFS.discover, TOOL_POLICY_REFS.send_grant},
        schema = {type = "object", additionalProperties = false,
            properties = {cursor = {type = "integer", minimum = 0, description = "offset into the stable directory order; omit for the first page"},
                limit = {type = "integer", minimum = 1, maximum = 64, description = "page size, at most 64"}},
            examples = {{limit = 32}}}, annotations = READ_ANNOTATIONS},
    {name = "capabilities", description = "Read-only report of what this workspace's host admits for this agent: the admitted tool set with the policy each tool runs under, the trait catalog with allowed, active and requestable traits, the bound workspace and thread, and whether this agent may launch children and under which launch policy. Read it before authoring; it names no secret and grants nothing.",
        operation = "bee.gateway.binding:surface",
        policies = {TOOL_POLICY_REFS.capabilities},
        schema = {type = "object", additionalProperties = false, properties = table.create(0, 1),
            examples = {{}}}, annotations = READ_ANNOTATIONS},
    {name = "launch_definitions", description = "Read-only discovery of this caller's admitted launch definitions, placements, overrides and saved profiles: each definition the caller's host-selected launch policy admits, with title, default mode, driver profile, policy, admitted overrides, workdir and thread policies and the placements a launch accepts (native or docker), plus the saved profile IDs and revisions held for those definitions. Starts nothing and grants nothing; launch with thread_launch.",
        operation = "bee.harness.launch:launch_definitions_call",
        policies = {TOOL_POLICY_REFS.launch_definitions},
        schema = {type = "object", additionalProperties = false,
            properties = {workspace_id = {type = "string", minLength = 32, maxLength = 32,
                description = "This session's own workspace, the default; any other is refused"}},
            examples = {{}}}, annotations = READ_ANNOTATIONS},
    {name = "session_send", description = "Commit one request into an action's durable inbox by exact node/action address and current grant_epoch. The host must grant bee.sessions.send for that workspace/node/action, and the recipient owner must accept your action's sender. Delivery is committed, not yet offered to a running model.", operation = "bee.threads.service:inbox_send",
        policies = {TOOL_POLICY_REFS.inbox, TOOL_POLICY_REFS.send_grant}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"address", "grant_epoch", "idempotency_key", "message_id", "content"}, properties = {
            address = {type = "object", additionalProperties = false, required = {"node_id", "action_id"}, properties = {node_id = {type = "string"}, action_id = {type = "string"}}},
            grant_epoch = {type = "integer", minimum = 1}, idempotency_key = {type = "string"}, message_id = {type = "string"},
            content = {type = "object", additionalProperties = false, properties = {text = {type = "string"}, artifact_ref = {type = "string"}}}}}},
    {name = "session_inbox", description = "Page your own action's durable inbox in inbox sequence order; this does not mark items acknowledged.", operation = "bee.threads.service:inbox_list",
        policies = {TOOL_POLICY_REFS.inbox}, annotations = READ_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, properties = {after_sequence = {type = "integer", minimum = 0}, limit = {type = "integer", minimum = 1, maximum = 64}}}},
    {name = "session_ack", description = "Acknowledge one item in your own action inbox by inbox_sequence. Acknowledgment is an explicit agent action.", operation = "bee.threads.service:inbox_ack",
        policies = {TOOL_POLICY_REFS.inbox}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"inbox_sequence", "idempotency_key"}, properties = {
            inbox_sequence = {type = "integer", minimum = 1}, idempotency_key = {type = "string"}}}},
    {name = "session_reply", description = "Commit a correlated reply into the original sender's action inbox. The in_reply_to reference identifies the request in your own inbox; both owners' checks run in one local transaction.", operation = "bee.threads.service:inbox_reply",
        policies = {TOOL_POLICY_REFS.inbox, TOOL_POLICY_REFS.send_grant}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"address", "grant_epoch", "idempotency_key", "message_id", "content", "in_reply_to", "outcome"}, properties = {
            address = {type = "object", additionalProperties = false, required = {"node_id", "action_id"}, properties = {node_id = {type = "string"}, action_id = {type = "string"}}},
            grant_epoch = {type = "integer", minimum = 1}, idempotency_key = {type = "string"}, message_id = {type = "string"},
            content = {type = "object", additionalProperties = false, properties = {text = {type = "string"}, artifact_ref = {type = "string"}}},
            in_reply_to = {type = "object", additionalProperties = false, required = {"thread_id", "record_id"}, properties = {thread_id = {type = "string"}, record_id = {type = "string"}}},
            outcome = {type = "string", enum = {"succeeded", "failed", "cancelled", "uncertain"}}}}},
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
    {name = "run_status", description = "Read, read-only, the current state of one managed run this caller started: the child's thread and attempt, starting, running, cancelling or ended, and its settled outcome and answer once it has ended. A caller reads only a run it launched; the thread and attempt identities come from thread_launch. Nothing is claimed or changed.",
        operation = "bee.harness.launch:agent_run_call",
        policies = {TOOL_POLICY_REFS.run},
        schema = {type = "object", additionalProperties = false, required = {"thread_id", "attempt_id"}, properties = {
            thread_id = {type = "string", minLength = 1, maxLength = 160,
                description = "The child thread a thread_launch returned"},
            attempt_id = {type = "string", minLength = 1, maxLength = 160,
                description = "The child attempt a thread_launch returned"},
        }}, annotations = READ_ANNOTATIONS},
    {name = "run_wait", description = "Wait, read-only and bounded, for one managed run this caller started to end, then report its state, outcome and answer. wait_ms bounds the block and defaults to the transport budget; a run already ended returns at once. A caller waits on only a run it launched; nothing is claimed or changed.",
        operation = "bee.harness.launch:agent_run_call",
        policies = {TOOL_POLICY_REFS.run},
        schema = {type = "object", additionalProperties = false, required = {"thread_id", "attempt_id"}, properties = {
            thread_id = {type = "string", minLength = 1, maxLength = 160},
            attempt_id = {type = "string", minLength = 1, maxLength = 160},
            wait_ms = {type = "integer", minimum = 0, maximum = 60000,
                description = "How long to block, in milliseconds; at most 60000"},
        }}, annotations = READ_ANNOTATIONS},
    {name = "run_cancel", description = "Cancel one managed run this caller started: record a durable cancel intent, stop the admitted attempt and report its resulting state. A run whose child has not started is settled as cancelled directly. A caller cancels only a run it launched, and a cancel names an idempotency key so a retry replays one intent; a run that already ended returns its terminal state unchanged.",
        operation = "bee.harness.launch:agent_run_call",
        policies = {TOOL_POLICY_REFS.run},
        schema = {type = "object", additionalProperties = false, required = {"thread_id", "attempt_id", "idempotency_key"}, properties = {
            thread_id = {type = "string", minLength = 1, maxLength = 160},
            attempt_id = {type = "string", minLength = 1, maxLength = 160},
            idempotency_key = {type = "string", minLength = 1, maxLength = 64},
            wait_ms = {type = "integer", minimum = 0, maximum = 60000,
                description = "How long to wait for the attempt to settle, in milliseconds; at most 60000"},
        }}, annotations = WRITE_ANNOTATIONS},
    {name = "overlay", description = "Read-only guide index, sections and worked example (guide names no overlay_id; without section it returns the short index, with section one section, with include_example the entries JSON), or create, list files in, read, put, append, remove or freeze a caller-owned overlay. List files in overlay requires overlay_id; without one list returns your own overlay IDs. For files over 65,536 bytes, put the first chunk then append bounded chunks with the exact byte offset. The owner returns the assembled SHA-256 digest; result_digest is an optional assertion if you already know it. Reads change nothing; creates, puts, appends, removes and freezes change the overlay.",
        operation = "bee.gov.binding:overlay_call",
        policies = {TOOL_POLICY_REFS.overlay}, annotations = WRITE_ANNOTATIONS,
        schema = workspace_protocol.overlay_schema(M.MAX_WORKSPACE_TEXT_BYTES, M.MAX_WORKSPACE_BASE64_BYTES)},
    {name = "docs", description = "Read the platform documentation that ships inside Bee, offline: list the corpus by topic (at most 64 per page), search it for a phrase (at most 16 matches per page), or read one bounded window of one document by stable id (at most 16,384 bytes per window, honoring offset after section selection). Use it to look up how the runtime modules an application author calls work (process, channel, tty, registry, sql, fs, http, events), Bee's own contracts (application, threads, hive and cross-node subscriptions, placement, gateway, storage, UI) and the terminal toolkit for drawing, layout, styles and input.", operation = "bee.docs.binding:call",
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
    {name = "application_open", description = "Open one application already applied and admitted in this agent's bound workspace through the existing workspace host. Arguments are literal launch strings. Pending retries coalesce; completed retries use the broker's bounded replay cache.", operation = "bee.apps:open_call",
        policies = {TOOL_POLICY_REFS.application_open}, annotations = WRITE_ANNOTATIONS,
        schema = {type = "object", additionalProperties = false, required = {"definition_id", "arguments", "idempotency_key"}, properties = {
            definition_id = {type = "string", minLength = 1, maxLength = 160},
            arguments = {type = "array", maxItems = 16, items = {type = "string", maxLength = 1024}},
            idempotency_key = {type = "string", minLength = 1, maxLength = 64},
        }}},
}
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
M.OUTPUT_SCHEMAS = {
    session = output_schema({type = "object"}),
    call_tool = output_schema({type = "object"}),
    thread_read = output_schema({type = "object"}),
    thread_wait = output_schema({type = "object"}),
    thread_sessions = output_schema({type = "object", additionalProperties = false,
        properties = {sessions = {type = "array"}, next_cursor = {type = "integer"}, eof = {type = "boolean"}}}),
    thread_message = output_schema({type = "object"}),
    thread_notify = output_schema({type = "object"}),
    session_directory = output_schema({type = "object", additionalProperties = false,
        properties = {peers = {type = "array"}, next_cursor = {type = "integer"}, eof = {type = "boolean"}}}),
    session_send = output_schema({type = "object"}),
    session_inbox = output_schema({type = "object"}),
    session_ack = output_schema({type = "object"}),
    session_reply = output_schema({type = "object"}),
    thread_launch = output_schema({type = "object"}),
    run_status = output_schema({type = "object", additionalProperties = false,
        properties = {thread_id = {type = "string"}, attempt_id = {type = "string"}, state = {type = "string"},
            outcome = {type = "string"}, answer = {type = "string"}}}),
    run_wait = output_schema({type = "object", additionalProperties = false,
        properties = {thread_id = {type = "string"}, attempt_id = {type = "string"}, state = {type = "string"},
            outcome = {type = "string"}, answer = {type = "string"}}}),
    run_cancel = output_schema({type = "object", additionalProperties = false,
        properties = {thread_id = {type = "string"}, attempt_id = {type = "string"}, state = {type = "string"},
            outcome = {type = "string"}, answer = {type = "string"}, cancel_intent = {type = "boolean"},
            uncertain = {type = "boolean"}}}),
    capabilities = output_schema({type = "object", additionalProperties = false,
        properties = {workspace_id = {type = "string"}, thread_id = {type = "string"},
            tools = {type = "array"}, traits = {type = "object"}, launch = {type = "object"}}}),
    launch_definitions = output_schema({type = "object", additionalProperties = false,
        properties = {workspace_id = {type = "string"}, policy_ref = {type = "string"},
            definitions = {type = "array"}, saved_profiles = {type = "array"},
            profiles_complete = {type = "boolean"}}}),
    overlay = output_schema({type = "object"}),
    docs = output_schema({type = "object"}),
    components = output_schema({type = "object"}),
    delivery = output_schema({type = "object", additionalProperties = false,
        properties = {ready = {type = "boolean"}, staged = {type = "boolean"},
            diagnostics = {type = "array"}, human_steps = {type = "array"}}}),
    publish = output_schema({type = "object"}),
    application_open = output_schema({type = "object"}),
    request_capability = output_schema({type = "object", additionalProperties = false,
        properties = {approval_id = {type = "string"}, status = {type = "string"}}}),
    capability_status = output_schema({type = "object", additionalProperties = false,
        properties = {approval_id = {type = "string"}, status = {type = "string"},
            grant_id = {type = "string"}, expires_at = {type = "string"}, authorization_epoch = {type = "integer"}}}),
    install_request = output_schema({type = "object"}),
    uninstall_request = output_schema({type = "object"}),
    install_status = output_schema({type = "object"}),
}
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
    -- Trait selection changes the admitted tool set, so the list changes.
    -- Clients re-list after session select; select names the new revision.
    return {protocolVersion = M.PROTOCOL, capabilities = {tools = {listChanged = true}}, serverInfo = M.SERVER}
end
-- The tools a binding may call: the closed catalog filtered by the
-- binding's admitted tool names, in catalog order, each with its input and
-- output contracts.
function M.list(admitted: {string}): Object
    local allowed: {[string]: boolean} = {}
    for _, name in ipairs(admitted) do allowed[name] = true end
    local tools: {Object} = {}
    for _, tool in ipairs(TOOLS) do
        if allowed[tool.name] then tools[#tools + 1] = {name = tool.name, description = tool.description,
            inputSchema = tool.schema, outputSchema = M.OUTPUT_SCHEMAS[tool.name], annotations = tool.annotations} end
    end
    return {tools = tools}
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
    if arguments.member_thread ~= nil then
        local thread_id = bounds.id(arguments.member_thread)
        if not thread_id then return nil, "member_thread must be a thread identifier" end
        request.member_thread = thread_id
    end
    return request, nil
end
M.TRANSPORT_BUDGET_MS = 5000
-- The managed-run tools share the application facade's wait ceiling and the
-- launch retry-key bound, so an MCP cancel and an application cancel cannot
-- name different limits for one attempt.
M.MAX_RUN_WAIT_MS = 60000
M.MAX_KEY_BYTES = 64
function M.wait_arguments(params: Object): (Object?, string?)
    local arguments: Object = {}
    if params.arguments ~= nil then
        local declared = bounds.object(params.arguments)
        if not declared then return nil, "arguments must be an object" end
        arguments = declared
    end
    local unknown_field = bounds.fields(arguments, {"after_sequence", "wait_ms", "member_thread"})
    if unknown_field then return nil, unknown_field end
    local after = bounds.cursor(arguments.after_sequence == nil and 0 or arguments.after_sequence)
    if not after then return nil, "after_sequence is out of range" end
    local wait_ms = bounds.integer(arguments.wait_ms == nil and M.TRANSPORT_BUDGET_MS or arguments.wait_ms)
    if not wait_ms or wait_ms < 0 then return nil, "wait_ms must be a nonnegative integer" end
    local request: Object = {after_sequence = after, wait_ms = wait_ms, transport_budget_ms = M.TRANSPORT_BUDGET_MS}
    if arguments.member_thread ~= nil then
        local thread_id = bounds.id(arguments.member_thread)
        if not thread_id then return nil, "member_thread must be a thread identifier" end
        request.member_thread = thread_id
    end
    -- The transport budget bounds every wait; the owner subtracts its margin.
    return request, nil
end
-- Message arguments are the public message shape without sender, thread or
-- lifecycle context. The full message decoder remains the authority for its
-- nested content, references and kind-specific invariants. A message to a
-- session names no recipients: the endpoint addresses the resolved session
-- and names the caller's own action as the sender's.
function M.message_arguments(params: Object): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(arguments, {"idempotency_key", "message_id", "message_kind", "recipient_ids", "session", "member_thread", "content", "in_reply_to", "outcome"})
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
    local member_thread: string? = nil
    if arguments.member_thread ~= nil then
        member_thread = bounds.id(arguments.member_thread)
        if not member_thread then return nil, "member_thread must be a thread identifier" end
        if session then return nil, "a message names either a session or a member_thread, not both" end
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
    local request: Object = {idempotency_key = key, body = body, session = session}
    if member_thread then request.member_thread = member_thread end
    return request, nil
end
-- Session discovery pages the binding's workspace in stable order: the
-- binding selects the workspace, cursor and limit select the window.
function M.sessions_arguments(params: Object): (Object?, string?)
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
        if not declared then return nil, "cursor is out of range; pass next_cursor from the previous reply" end
        cursor = declared
    end
    local limit = 32
    if arguments.limit ~= nil then
        local declared = bounds.integer(arguments.limit)
        if not declared or declared < 1 or declared > 64 then return nil, "limit must be between 1 and 64" end
        limit = declared
    end
    return {cursor = cursor, limit = limit}, nil
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
-- Launch discovery takes only an optional workspace identity defaulting to
-- the binding's own workspace; any other workspace is refused downstream.
function M.launch_definitions_arguments(params: Object, workspace_id: string?): (Object?, string?)
    local supplied = bounds.object(params.arguments or {})
    if not supplied then return nil, "arguments must be an object" end
    local unknown_field = bounds.fields(supplied, {"workspace_id"})
    if unknown_field then return nil, unknown_field end
    local arguments: Object = {}
    if supplied.workspace_id == nil then
        if workspace_id then arguments.workspace_id = workspace_id end
    else
        arguments.workspace_id = supplied.workspace_id
    end
    return arguments, nil
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

function M.inbox_message_arguments(params: Object, reply: boolean): (Object?, string?)
    local object = bounds.object(params.arguments)
    if not object then return nil, "arguments must be an object" end
    local extra = bounds.fields(object, {"address", "grant_epoch", "idempotency_key", "message_id", "content", "in_reply_to", "outcome"})
    if extra then return nil, extra end
    local address = bounds.object(object.address)
    if not address or bounds.fields(address, {"node_id", "action_id"}) then return nil, "address must contain only node_id and action_id" end
    local node_id, action_id = bounds.id(address.node_id), bounds.id(address.action_id)
    local key, message_id = bounds.id(object.idempotency_key), bounds.id(object.message_id)
    local epoch = bounds.integer(object.grant_epoch)
    if not node_id or not action_id or not key or not message_id or not epoch or epoch < 1 then
        return nil, "exact address, grant_epoch, idempotency_key and message_id are required"
    end
    if reply ~= (object.in_reply_to ~= nil) or (reply and object.outcome == nil) or (not reply and object.outcome ~= nil) then
        return nil, "reply correlation and outcome belong to session_reply only"
    end
    local submitted: Object = {message_id = message_id, message_kind = reply and "reply" or "request", sender_id = "gateway-mcp-subject",
        recipient_ids = {}, recipient_action_ids = {action_id}, content = object.content}
    if reply then submitted.in_reply_to = object.in_reply_to; submitted.outcome = object.outcome end
    local decoded, invalid = message.decode(submitted)
    if not decoded then return nil, "message: " .. tostring(invalid) end
    local result: Object = {address = {node_id = node_id, action_id = action_id}, grant_epoch = epoch, idempotency_key = key,
        message_id = message_id, content = decoded.content}
    if decoded.in_reply_to then result.in_reply_to = decoded.in_reply_to end
    if decoded.outcome then result.outcome = decoded.outcome end
    return result, nil
end
function M.inbox_page_arguments(params: Object): (Object?, string?)
    local object = bounds.object(params.arguments) or {}
    local extra = bounds.fields(object, {"after_sequence", "limit"})
    if extra then return nil, extra end
    local after = object.after_sequence == nil and 0 or bounds.integer(object.after_sequence)
    local limit = object.limit == nil and 64 or bounds.integer(object.limit)
    if not after or after < 0 or not limit or limit < 1 or limit > 64 then return nil, "after_sequence and limit are outside inbox bounds" end
    return {after_sequence = after, limit = limit}, nil
end
function M.inbox_ack_arguments(params: Object): (Object?, string?)
    local object = bounds.object(params.arguments)
    if not object then return nil, "arguments must be an object" end
    local extra = bounds.fields(object, {"inbox_sequence", "idempotency_key"})
    if extra then return nil, extra end
    local sequence, key = bounds.integer(object.inbox_sequence), bounds.id(object.idempotency_key)
    if not sequence or sequence < 1 or not key then return nil, "inbox_sequence and idempotency_key are required" end
    return {inbox_sequence = sequence, idempotency_key = key}, nil
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

-- Run arguments name one managed run by the child thread and attempt a
-- thread_launch returned; the endpoint supplies the caller's binding, and the
-- owner operation checks that the caller launched the run before answering.
-- wait_ms is bounded to the same ceiling the application facade uses, and a
-- cancel always carries a retry key so a retried cancel replays one intent.
function M.run_arguments(params: Object, cancel: boolean): (Object?, string?)
    local arguments = bounds.object(params.arguments)
    if not arguments then return nil, "arguments must be an object" end
    local allowed: {string} = {"thread_id", "attempt_id"}
    if cancel then allowed = {"thread_id", "attempt_id", "wait_ms", "idempotency_key"}
    else allowed = {"thread_id", "attempt_id", "wait_ms"} end
    local unknown_field = bounds.fields(arguments, allowed)
    if unknown_field then return nil, unknown_field end
    local thread_id = bounds.id(arguments.thread_id)
    if not thread_id then return nil, "thread_id is required and must be an identifier" end
    local attempt_id = bounds.id(arguments.attempt_id)
    if not attempt_id then return nil, "attempt_id is required and must be an identifier" end
    local request: Object = {thread_id = thread_id, attempt_id = attempt_id}
    if arguments.wait_ms ~= nil then
        local wait_ms = bounds.integer(arguments.wait_ms)
        if not wait_ms or wait_ms < 0 or wait_ms > M.MAX_RUN_WAIT_MS then
            return nil, "wait_ms must be between 0 and " .. tostring(M.MAX_RUN_WAIT_MS)
        end
        request.wait_ms = wait_ms
    end
    if cancel then
        local key = bounds.id(arguments.idempotency_key)
        if not key or #key > M.MAX_KEY_BYTES then return nil, "idempotency_key is required and must be a bounded identifier" end
        request.idempotency_key = key
    end
    return request, nil
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
