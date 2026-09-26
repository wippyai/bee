-- MIT. The MCP endpoint: POST /mcp/{action}. It authenticates the bearer
-- token against the action, decodes one JSON-RPC request, and maps a tool
-- call to one owner operation run as the bound subject under host-named
-- policies. It writes no record itself; the thread owner authorizes again.
-- A wait runs in bounded slices so drain releases it with an explicit
-- outcome, and past the host's drain deadline nothing is served.
local http = require("http")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local system = require("system")
local gateway = require("gateway")
local mcp = require("mcp")
local catalog = require("catalog")
local context = require("context")
local sessions = require("sessions")
local remote = require("remote")
local bounds = require("bounds")
local sends = require("sends")
type Object = {[string]: unknown}
type RuntimeGrant = {access_approval_id: string, access_proposal_digest: string, surface_revision: integer, surface_digest: string}
local function selected_policy(reference: string): (string?, string?)
    if not mcp.is_tool_policy_reference(reference) then return reference, nil end
    local entry, entry_error = registry.get(reference)
    if entry_error or not entry then return nil, "built-in tool policy reference is unavailable" end
    local data = bounds.object(entry.data)
    local selected = data and bounds.id(data.resource_ref)
    if not selected then return nil, "built-in tool policy is not linked by the host" end
    return selected, nil
end
local function scope_for(names: {string}): (security.Scope?, string?)
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local selected, selected_error = selected_policy(name)
        if not selected then return nil, selected_error or "tool policy is unavailable" end
        local policy, err = security.policy(selected)
        if err or not policy then return nil, "policy " .. selected .. " unavailable" end
        policies[index] = policy
    end
    return security.new_scope(policies), nil
end
local function answer(response: http.Response, status: number, body: Object)
    response:set_status(status)
    response:set_content_type(http.CONTENT.JSON)
    response:write_json(body)
end
-- One normalized tool refusal: the {code, message, field, retryable, remedy}
-- shape naming the next call, as text and as structured content.
local function refused(code: string, message: string, field: string?, retryable: boolean?, remedy: string?): Object
    local fault = mcp.tool_error(code, message, field, retryable == true, remedy)
    return mcp.tool_result(json.encode(fault) or "{}", true, fault)
end
-- The executor that runs a tool as the bound subject under the tool's
-- host-named scope. The endpoint's own right to invoke these operations
-- is a separate grant; membership is the thread owner's decision.
local function subject_executor(binding: gateway.Binding, tool: mcp.Tool, values: Object?, runtime: RuntimeGrant?): (funcs.Executor?, Object?)
    local scope, scope_error = scope_for(tool.policies)
    if not scope then return nil, refused("UNAVAILABLE", scope_error or "scope") end
    -- The subject acts only in its binding's workspace: workspace-scoped
    -- policies compare the resource with this host-derived metadata.
    local subject_meta: {[string]: string} = {}
    if binding.workspace_id then subject_meta.workspace_id = binding.workspace_id end
    local subject, subject_error = security.new_actor(binding.subject, subject_meta)
    if not subject then return nil, refused("DENIED", tostring(subject_error)) end
    local executor = funcs.new()
    local attributed, attribution_error = context.bind(values, {binding_id = binding.binding_id,
        thread_id = binding.thread_id, subject = binding.subject, action_id = binding.action_id, attempt_id = binding.attempt_id,
        policy_ref = binding.policy_ref, workspace_id = binding.workspace_id, origin_view = binding.origin_view,
        application_runtime = runtime and {thread_id = binding.thread_id, subject = binding.subject, initiating_owner = binding.subject,
            binding_id = binding.binding_id, access_approval_id = runtime.access_approval_id :: string,
            access_proposal_digest = runtime.access_proposal_digest :: string, surface_revision = runtime.surface_revision :: integer,
            surface_digest = runtime.surface_digest :: string} or nil})
    if not attributed then return nil, refused("DENIED", tostring(attribution_error)) end
    local contextual, context_error = executor:with_context(attributed)
    if not contextual then return nil, refused("DENIED", tostring(context_error)) end
    executor = contextual
    local acted, actor_error = executor:with_actor(subject)
    if not acted then return nil, refused("DENIED", tostring(actor_error)) end
    local scoped, scoped_error = acted:with_scope(scope)
    if not scoped then return nil, refused("DENIED", tostring(scoped_error)) end
    return scoped, nil
end
local function reply_result(reply: unknown, call_error: unknown): Object
    if call_error then return refused("UNAVAILABLE", tostring(call_error), nil, true, "retry the same call") end
    local encoded = json.encode(reply) or "{}"
    local is_error = type(reply) ~= "table" or (reply :: Object).ok ~= true
    -- Owner replies already carry top-level code/message; surface them in the
    -- normalized shape with the remedy the owner named, if any.
    local structured: unknown = reply
    if type(reply) == "table" then
        local body = reply :: Object
        if body.ok ~= true then
            local fault = bounds.object(body.error) or {}
            local value = bounds.object(body.value) or {}
            structured = mcp.tool_error(tostring(fault.code or body.code or "REFUSED"),
                tostring(fault.message or body.message or "the call was refused"),
                nil, false, value.remedy ~= nil and tostring(value.remedy) or nil)
        end
    end
    return mcp.tool_result(encoded, is_error, structured)
end
-- The running sessions of the caller's workspace that the bound subject may
-- read, with each thread's title. The thread owner answers get as the
-- subject, so a session on a thread the caller is not a member of is never
-- listed or reachable; an owner failure other than a refusal stops the call.
type Reachable = {sessions: {sessions.Candidate}, titles: {[string]: string}}
local function reachable(binding: gateway.Binding, executor: funcs.Executor): (Reachable?, Object?)
    local candidates, refusal = gateway.workspace_sessions(binding)
    if not candidates then return nil, reply_result(refusal, nil) end
    local titles: {[string]: string} = {}
    local hidden: {[string]: boolean} = {}
    local visible: {sessions.Candidate} = {}
    for _, item in ipairs(candidates) do
        if titles[item.thread_id] == nil and not hidden[item.thread_id] then
            local reply, call_error = executor:call("bee.threads.service:get", {thread_id = item.thread_id})
            if call_error then return nil, refused("UNAVAILABLE", tostring(call_error)) end
            local answer = bounds.object(reply)
            if answer and answer.ok == true then
                local value = bounds.object(answer.value)
                local summary = value and bounds.object(value.summary)
                titles[item.thread_id] = summary and tostring(summary.title) or ""
            else
                local fault = answer and bounds.object(answer.error)
                local code = fault and tostring(fault.code) or ""
                if code ~= "DENIED" and code ~= "NOT_FOUND" then return nil, reply_result(reply, nil) end
                hidden[item.thread_id] = true
            end
        end
        if titles[item.thread_id] ~= nil then visible[#visible + 1] = item end
    end
    return {sessions = visible, titles = titles}, nil
end
local function resolve(binding: gateway.Binding, executor: funcs.Executor, address: string): (sessions.Candidate?, Object?)
    local found, failure = reachable(binding, executor)
    if not found then return nil, failure end
    local target, code, message = sessions.resolve(found.sessions, address)
    if not target then return nil, refused(code or "NOT_FOUND", message or "no such session") end
    return target, nil
end
local function list_sessions(binding: gateway.Binding, executor: funcs.Executor, request: Object): Object
    local found, failure = reachable(binding, executor)
    if not found then return failure :: Object end
    local views: {unknown} = {}
    for _, item in ipairs(found.sessions) do
        views[#views + 1] = sessions.view(item, found.titles[item.thread_id] or "", binding.action_id)
    end
    local cursor = math.floor(tonumber(request.cursor) or 0)
    local limit = math.floor(tonumber(request.limit) or sessions.PAGE_DEFAULT)
    if cursor < 0 then cursor = 0 end
    if limit < 1 or limit > sessions.MAX_SESSIONS then limit = sessions.PAGE_DEFAULT end
    local page = sessions.page(views, cursor, limit)
    return reply_result({ok = true, value = {sessions = page.items, next_cursor = page.next_cursor,
        eof = page.eof, truncated = not page.eof}}, nil)
end
local function local_node(): string
    local native, err = system.node.id()
    if err or not native or native == "" then return "local" end
    return native
end
local function capabilities(binding: gateway.Binding): Object
    local bound, surface_error = gateway.surface(binding)
    if not bound then return reply_result(surface_error, nil) end
    local config = bound.configuration
    local available, available_error = catalog.select(config.catalog, config.ceiling, config.base_tools, config.allowed_traits, bound.selection.active)
    if not available then return refused("DENIED", available_error or "surface is unavailable", nil, false, "call session read for the current surface revision") end
    local tools: {Object} = {}
    for _, item in ipairs(available) do
        tools[#tools + 1] = {name = item.name, description = item.description, policies = item.policies, annotations = item.annotations}
    end
    local launchable = false
    for _, item in ipairs(available) do if item.name == "thread_launch" then launchable = true end end
    local traits: {Object} = {}
    for _, trait in ipairs(config.catalog.traits) do
        traits[#traits + 1] = {id = trait.id, title = trait.title, tools = trait.tools}
    end
    return reply_result({ok = true, value = {workspace_id = binding.workspace_id, thread_id = binding.thread_id,
        action_id = binding.action_id, revision = bound.revision, digest = bound.digest,
        tools = tools, traits = traits, allowed_traits = config.allowed_traits, active_traits = bound.selection.active,
        requestable_access = config.access,
        launch = {allowed = launchable, policy_ref = binding.policy_ref,
            definitions_tool = launchable and "launch_definitions" or nil},
        thread_access = {thread_id = binding.thread_id,
            note = "thread_read, thread_wait and thread_message reach the bound thread; thread_sessions pages the sessions its membership opens"},
        authoring = {guide_tool = "overlay", guide_operation = "guide",
            preflight_tool = "delivery", preflight_operation = "preflight",
            note = "read the capabilities report, then the overlay guide index, then preflight a frozen digest before delivery request"}}}, nil)
end
local function list_directory(binding: gateway.Binding, executor: funcs.Executor, request: Object): Object
    local candidates, sessions_error = gateway.workspace_sessions(binding)
    if not candidates then return reply_result(sessions_error, nil) end
    local peers: {sessions.DirectoryCandidate} = {}
    local node_id = local_node()
    for _, item in ipairs(candidates) do
        local reply, err = executor:call("bee.threads.service:inbox_describe", {thread_id = item.thread_id, action_id = item.action_id,
            attempt_id = item.attempt_id, node_id = node_id})
        if err then return refused("UNAVAILABLE", tostring(err)) end
        local result = bounds.object(reply)
        if result and result.ok == true then
            local value = bounds.object(result.value) or {}
            peers[#peers + 1] = {session = item, name = item.name or item.action_id, node_id = node_id,
                grant_epoch = math.floor(tonumber(value.grant_epoch) or 0), discoverable = true,
                sendable = value.sendable == true, attempt_state = tostring(value.attempt_state or "unknown"),
                delivery_state = tostring(value.delivery_state or "empty"), last_inbox_sequence = math.floor(tonumber(value.last_inbox_sequence) or 0)}
        else
            local fault = result and bounds.object(result.error)
            local code = fault and tostring(fault.code) or ""
            if code ~= "DENIED" and code ~= "NOT_FOUND" then return reply_result(reply, nil) end
        end
    end
    local views: {unknown} = {}
    for _, item in ipairs(sessions.directory(peers, binding.action_id)) do views[#views + 1] = item end
    local cursor = math.floor(tonumber(request.cursor) or 0)
    local limit = math.floor(tonumber(request.limit) or sessions.PAGE_DEFAULT)
    if cursor < 0 then cursor = 0 end
    if limit < 1 or limit > sessions.MAX_SESSIONS then limit = sessions.PAGE_DEFAULT end
    local page = sessions.page(views, cursor, limit)
    return reply_result({ok = true, value = {peers = page.items, next_cursor = page.next_cursor,
        eof = page.eof, truncated = not page.eof}}, nil)
end
-- The exact local action address an inbox operation targets, or the refusal
-- naming why it is not ours. A local address resolves among the bound
-- workspace's sessions; a remote address is handed to the host-selected remote
-- resolver, which the destination owner re-checks when the send arrives.
local function inbox_target(binding: gateway.Binding, address: unknown): (sessions.Candidate?, Object?)
    local object = bounds.object(address)
    local node_id = object and bounds.id(object.node_id)
    local action_id = object and bounds.id(object.action_id)
    if not node_id or not action_id or node_id ~= local_node() then return nil, refused("NOT_FOUND", "address is not on this node") end
    local candidates, failure = gateway.workspace_sessions(binding)
    if not candidates then return nil, reply_result(failure, nil) end
    for _, item in ipairs(candidates) do if item.action_id == action_id then return item, nil end end
    return nil, refused("NOT_FOUND", "action address is not in this workspace")
end
-- A remote session_send names a node-qualified address: the host-selected
-- resolver answers the thread and workspace it names on its own node, and the
-- gateway sends there with the same body it would send locally. The remote
-- owner authenticates the forwarded principal and re-checks every grant, so
-- resolution is discovery, not authority; an unconfigured or unknown address is
-- reported as not found.
local function remote_send(binding: gateway.Binding, tool: mcp.Tool, request: Object, executor: funcs.Executor): Object
    local object = bounds.object(request.address)
    local node_id = object and bounds.id(object.node_id)
    local action_id = object and bounds.id(object.action_id)
    if not node_id or not action_id then return refused("NOT_FOUND", "address must name a node and action") end
    local resolved, resolve_error = remote.resolve({node_id = node_id, action_id = action_id})
    if not resolved then return refused("NOT_FOUND", resolve_error or "remote address is not resolvable") end
    local digest, digest_error = sends.payload_digest({message_id = request.message_id, content = request.content})
    if not digest then return refused("INVALID_ARGUMENT", tostring(digest_error)) end
    local body: Object = {thread_id = resolved.thread_id, target_action_id = action_id, sender_thread_id = binding.thread_id,
        sender_action_id = binding.action_id, node_id = node_id, workspace_id = resolved.workspace_id,
        grant_epoch = request.grant_epoch, idempotency_key = request.idempotency_key, message_id = request.message_id,
        content = request.content, payload_digest = digest}
    if tool.name == "session_reply" then body.in_reply_to = request.in_reply_to; body.outcome = request.outcome end
    local reply, call_error = executor:call(tool.operation, body)
    return reply_result(reply, call_error)
end
-- The managed-run tools map to the harness launch facade's own run operation,
-- the same one an application reaches as agents.status/wait/cancel. The
-- endpoint's target scope admits that facade plus the membership probe below.
local run_call = "bee.harness.launch:agent_run_call"
local thread_probe = "bee.threads.service:get"
-- A caller reaches only runs it launched. Launching is the membership: a child
-- thread_launch starts on a new thread is created and admitted under the
-- caller, so the caller is an active member of it, and a caller-thread launch
-- runs on the caller's own thread. The thread owner answers membership; an
-- unrelated thread, or an identity the caller fabricated, names no thread it
-- belongs to and is refused. This is durable at thread_launch return and never
-- races the child carrier's own admission.
local function run_visible(executor: funcs.Executor, thread_id: string): boolean
    local reply, call_error = executor:call(thread_probe, {thread_id = thread_id})
    if call_error then return false end
    local answer = bounds.object(reply)
    if not answer or answer.ok ~= true then return false end
    local value = bounds.object(answer.value)
    local membership = value and bounds.object(value.membership)
    return membership ~= nil and membership.active == true
end
local function run_tool(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object): Object
    local executor, failure = subject_executor(binding, tool, values, nil)
    if not executor then return failure :: Object end
    local operation = "status"
    if tool.name == "run_wait" then operation = "wait" end
    if tool.name == "run_cancel" then operation = "cancel" end
    local body: Object = {operation = operation, thread_id = request.thread_id, attempt_id = request.attempt_id}
    if operation == "wait" or operation == "cancel" then body.wait_ms = request.wait_ms or 0 end
    if operation == "cancel" then body.idempotency_key = request.idempotency_key end
    -- The caller reaches only runs it launched: the run is refused by name
    -- before any owner operation runs unless the caller is an active member of
    -- the child thread, which is how a launched child's thread is its own.
    if not run_visible(executor, request.thread_id) then
        return refused("NOT_FOUND", "no run this caller launched names thread " .. request.thread_id)
    end
    local reply, call_error = executor:call(run_call, body)
    if call_error then return reply_result(nil, call_error) end
    local answer = bounds.object(reply)
    if answer and answer.ok ~= true then
        local fault = bounds.object(answer.error)
        if fault and tostring(fault.code) == "DENIED" then
            return refused("NOT_FOUND", "no run this caller launched names thread " .. request.thread_id)
        end
    end
    return reply_result(reply, nil)
end

-- A caller may name a member_thread it is an active member of, such as a child
-- it launched on a new thread. The thread owner checks membership again on the
-- read or watch, but the endpoint refuses early so an unrelated thread is never
-- offered as if it were this binding's own, and strips the field before the
-- owner call so the owner's field allow-list stays exact.
local function member_thread(executor: funcs.Executor, request: Object, bound: string): (string?, Object?)
    local supplied = request.member_thread
    if supplied == nil then return bound, nil end
    request.member_thread = nil
    local thread_id = bounds.id(supplied)
    if not thread_id then return nil, refused("INVALID_ARGUMENT", "member_thread must be a thread identifier") end
    local reply, call_error = executor:call("bee.threads.service:get", {thread_id = thread_id})
    if call_error then return nil, refused("UNAVAILABLE", tostring(call_error)) end
    local answer = bounds.object(reply)
    local value = answer and answer.ok == true and bounds.object(answer.value) or nil
    local membership = value and bounds.object(value.membership)
    if not membership or membership.active ~= true then
        return nil, refused("NOT_FOUND", "member_thread " .. thread_id .. " is not a thread this caller belongs to")
    end
    return thread_id, nil
end

local function run(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object, runtime: RuntimeGrant?): Object
    if tool.name == "run_status" or tool.name == "run_wait" or tool.name == "run_cancel" then
        return run_tool(binding, tool, request, values)
    end
    local executor, failure = subject_executor(binding, tool, values, runtime)
    if not executor then return failure :: Object end
    if tool.name == "thread_sessions" then return list_sessions(binding, executor, request) end
    if tool.name == "session_directory" then return list_directory(binding, executor, request) end
    if tool.name == "capabilities" then return capabilities(binding) end
    if tool.name == "session_send" or tool.name == "session_reply" then
        local address = bounds.object(request.address)
        if address and bounds.id(address.node_id) and bounds.id(address.node_id) ~= local_node() then
            return remote_send(binding, tool, request, executor)
        end
        local target, missing = inbox_target(binding, request.address)
        if not target then return missing :: Object end
        local digest, digest_err = sends.payload_digest({message_id = request.message_id, content = request.content})
        if not digest then return refused("INVALID_ARGUMENT", tostring(digest_err)) end
        local body: Object = {thread_id = target.thread_id, target_action_id = target.action_id, sender_thread_id = binding.thread_id,
            sender_action_id = binding.action_id, node_id = local_node(), grant_epoch = request.grant_epoch,
            idempotency_key = request.idempotency_key, message_id = request.message_id, content = request.content, payload_digest = digest}
        if tool.name == "session_reply" then body.in_reply_to = request.in_reply_to; body.outcome = request.outcome end
        local reply, call_error = executor:call(tool.operation, body)
        return reply_result(reply, call_error)
    end
    if tool.name == "session_inbox" or tool.name == "session_ack" then
        request.thread_id = binding.thread_id
        request.action_id = binding.action_id
    end
    if tool.name == "thread_notify" then
        local target, unreachable = resolve(binding, executor, tostring(request.session))
        if not target then return unreachable :: Object end
        local reply, call_error = executor:call(tool.operation, {thread_id = binding.thread_id, idempotency_key = request.idempotency_key,
            target_thread_id = target.thread_id, target_action_id = target.action_id, watcher_action_id = binding.action_id})
        return reply_result(reply, call_error)
    end
    if tool.name == "thread_read" then
        local selected, missing = member_thread(executor, request, binding.thread_id)
        if not selected then return missing :: Object end
        request.thread_id = selected
    end
    if tool.name == "request_capability" or tool.name == "capability_status" or tool.name == "install_request"
        or tool.name == "uninstall_request" or tool.name == "install_status" then
        request.binding_id = binding.binding_id
    end
    if tool.name == "thread_message" then
        request.kind = "message"
        request.thread_id = binding.thread_id
        request.context = {action_id = binding.action_id, attempt_id = binding.attempt_id}
        local member, missing = member_thread(executor, request, binding.thread_id)
        if not member then return missing :: Object end
        request.thread_id = member
        if member ~= binding.thread_id then request.context = nil end
        local address = request.session
        request.session = nil
        if type(address) == "string" and member == binding.thread_id then
            local target, unreachable = resolve(binding, executor, address)
            if not target then return unreachable :: Object end
            -- The session is the recipient; the caller's own action names the
            -- sending session so the recipient can answer it by address.
            local body = request.body :: Object
            body.recipient_ids = {target.subject}
            body.recipient_action_ids = {target.action_id}
            body.sender_action_id = binding.action_id
            request.thread_id = target.thread_id
            if target.thread_id ~= binding.thread_id then request.context = nil end
        end
    end
    local reply, call_error = executor:call(tool.operation, request)
    return reply_result(reply, call_error)
end
local function wait(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object): Object
    local executor, failure = subject_executor(binding, tool, values, nil)
    if not executor then return failure :: Object end
    local selected, missing = member_thread(executor, request, binding.thread_id)
    if not selected then return missing :: Object end
    request.thread_id = selected
    local remaining = tonumber(request.wait_ms) or 0
    local budget = tonumber(request.transport_budget_ms) or mcp.TRANSPORT_BUDGET_MS
    if remaining > budget then remaining = budget end
    local outcome: Object? = nil
    while not outcome do
        local drain = gateway.draining()
        if drain and drain.draining then
            outcome = mcp.tool_result(json.encode({ok = true, value = {status = "released", reason = "draining", scanned_through = request.after_sequence}}) or "{}", false)
        else
            local slice = math.floor(math.min(remaining, gateway.WAIT_SLICE_MS))
            local sliced: Object = {thread_id = request.thread_id, after_sequence = request.after_sequence, wait_ms = slice, transport_budget_ms = budget}
            local reply, call_error = executor:call(tool.operation, sliced)
            if call_error then
                outcome = refused("UNAVAILABLE", tostring(call_error))
            else
                local value = type(reply) == "table" and (reply :: Object).value or nil
                local status = type(value) == "table" and tostring((value :: Object).status) or ""
                remaining = remaining - slice
                if status ~= "timeout" or remaining <= 0 then outcome = reply_result(reply, nil) end
            end
        end
    end
    return outcome
end
local function handle(): nil
    local request, request_error = http.request({max_body = mcp.MAX_BODY_BYTES})
    local response = http.response()
    if not request or not response then return nil end
    if request_error then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.INVALID_REQUEST, "unreadable request")); return nil end
    local action_id = request:param("action")
    if not action_id or action_id == "" then answer(response, http.STATUS.NOT_FOUND, mcp.failure(nil, mcp.INVALID_REQUEST, "no action")); return nil end
    if request:header("Origin") then answer(response, http.STATUS.FORBIDDEN, mcp.failure(nil, mcp.INVALID_REQUEST, "browser origins are not admitted")); return nil end
    local authorization = request:header("Authorization") or ""
    local token = authorization:match("^Bearer%s+(%S+)$")
    if not token then answer(response, http.STATUS.UNAUTHORIZED, mcp.failure(nil, mcp.INVALID_REQUEST, "bearer token required")); return nil end
    local host = request:host() or ""
    if not gateway.accepts_host(host) then
        answer(response, http.STATUS.FORBIDDEN, mcp.failure(nil, mcp.INVALID_REQUEST, "host is not the selected listener")); return nil
    end
    local binding, refusal = gateway.authenticate(token, action_id, "tool")
    if not binding then
        local fault = refusal and refusal.error or {code = "UNAUTHENTICATED", message = "refused"}
        local status = fault.code == "DENIED" and http.STATUS.FORBIDDEN or (fault.code == "STORAGE" and http.STATUS.INTERNAL_ERROR or http.STATUS.UNAUTHORIZED)
        answer(response, status, mcp.failure(nil, mcp.INVALID_REQUEST, fault.message)); return nil
    end
    local drain = gateway.draining()
    if drain and drain.past_deadline then answer(response, http.STATUS.SERVICE_UNAVAILABLE, mcp.failure(nil, mcp.INVALID_REQUEST, "the gateway is shutting down")); return nil end
    local body, body_error = request:body_json()
    if body_error then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.PARSE_ERROR, "body is not JSON")); return nil end
    local call, decode_error = mcp.decode(body)
    if not call then answer(response, http.STATUS.BAD_REQUEST, mcp.failure(nil, mcp.INVALID_REQUEST, decode_error or "invalid request")); return nil end
    if call.notification then
        response:set_status(http.STATUS.ACCEPTED)
        return nil
    end
    if call.method == "initialize" then answer(response, http.STATUS.OK, mcp.result(call.id, mcp.initialize())); return nil end
    if call.method == "notifications/initialized" or call.method == "ping" then answer(response, http.STATUS.OK, mcp.result(call.id, {})); return nil end
    local bound, surface_error = gateway.surface(binding)
    if not bound then answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(surface_error, nil))); return nil end
    local config = bound.configuration
    local available, available_error = catalog.select(config.catalog, config.ceiling, config.base_tools, config.allowed_traits, bound.selection.active)
    if not available then answer(response, http.STATUS.OK, mcp.result(call.id, refused("DENIED", available_error or "surface is unavailable"))); return nil end
    local values, values_error = context.compose(config.fixed_context, bound.selection.context, config.dynamic_keys)
    if not values then answer(response, http.STATUS.OK, mcp.result(call.id, refused("DENIED", values_error or "context is unavailable"))); return nil end
    local described: {Object} = {}
    for _, item in ipairs(available) do described[#described + 1] = {name = item.name, description = item.description,
        inputSchema = item.schema, outputSchema = mcp.OUTPUT_SCHEMAS[item.name], annotations = item.annotations} end
    if call.method == "tools/list" then
        local listed: {Object} = {}
        for _, item in ipairs(described) do listed[#listed + 1] = item end
        listed[#listed + 1] = {name = "session", description = "Read or select traits/context. Request host-declared access with request_access, then poll access_status with its approval_id; only an approved request enables access for this agent.",
            inputSchema = {type = "object", additionalProperties = false, required = {"operation"}, properties = {
                operation = {type = "string", enum = {"read", "select", "request_access", "access_status"}}, expected_revision = {type = "integer", minimum = 1},
                active_traits = {type = "array", items = {type = "string"}}, context = {type = "object"},
                idempotency_key = {type = "string"}, traits = {type = "array", items = {type = "string"}}, reason = {type = "string", maxLength = 1024}, approval_id = {type = "string"}}},
            outputSchema = mcp.OUTPUT_SCHEMAS.session,
            annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false}}
        listed[#listed + 1] = {name = "call_tool", description = "Call a currently active tool by name. Use session read for current schemas after changing traits; admission is checked on every call.",
            inputSchema = {type = "object", additionalProperties = false, required = {"name", "arguments"}, properties = {name = {type = "string"}, arguments = {type = "object"}}},
            outputSchema = mcp.OUTPUT_SCHEMAS.call_tool,
            annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false}}
        answer(response, http.STATUS.OK, mcp.result(call.id, {tools = listed})); return nil
    end
    if call.method ~= "tools/call" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.METHOD_NOT_FOUND, "method not found")); return nil end
    local name = call.params.name
    if type(name) ~= "string" then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "tool name required")); return nil end
    if name == "session" then
        local request = bounds.object(call.params.arguments)
        if not request then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "session arguments required")); return nil end
        local allowed: {string} = {"operation"}
        if request.operation == "request_access" then allowed = {"operation", "idempotency_key", "traits", "reason"}
        elseif request.operation == "access_status" then allowed = {"operation", "approval_id"}
        elseif request.operation ~= "read" then allowed = {"operation", "expected_revision", "active_traits", "context"} end
        local extra = bounds.fields(request, allowed)
        if extra then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, extra)); return nil end
        if request.operation == "request_access" then
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(gateway.request_access(binding,
                {idempotency_key = request.idempotency_key, traits = request.traits, reason = request.reason}), nil))); return nil
        end
        if request.operation == "access_status" then
            local approval_id = bounds.id(request.approval_id)
            if not approval_id then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "approval_id required")); return nil end
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(gateway.access_status(binding, approval_id), nil))); return nil
        end
        if request.operation == "read" then
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result({ok = true, value = {revision = bound.revision,
                traits = config.catalog.traits, requestable_access = config.access, allowed_traits = config.allowed_traits, active_traits = bound.selection.active, context = bound.selection.context,
                dynamic_keys = config.dynamic_keys, tools = described}}, nil))); return nil
        end
        local revision = bounds.count(request.expected_revision)
        if request.operation ~= "select" or not revision or revision < 1 then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "select needs a positive expected_revision")); return nil end
        local selected = gateway.select_surface(binding, revision, request.active_traits, request.context)
        -- Trait selection changes the admitted tool set: the server advertises
        -- listChanged and names the new revision here, so the client re-lists
        -- tools and reads session for the current schemas before calling one.
        if type(selected) == "table" and selected.ok == true then
            local value = bounds.object(selected.value) or {}
            value.tools_changed = true
            value.remedy = "call tools/list, then session read, before the next tools/call"
            selected = {ok = true, value = value}
        end
        answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(selected, nil))); return nil
    end
    local parameters = call.params
    if name == "call_tool" then
        local forwarded = bounds.object(call.params.arguments)
        if not forwarded or bounds.fields(forwarded, {"name", "arguments"}) or type(forwarded.name) ~= "string" then
            answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "call_tool needs name and arguments")); return nil
        end
        name = forwarded.name
        parameters = {arguments = forwarded.arguments}
    end
    local tool: mcp.Tool? = nil
    for _, item in ipairs(available) do if item.name == name then tool = item end end
    if not tool then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, "tool is not admitted for this binding")); return nil end
    local arguments: Object? = nil
    local argument_error: string? = nil
    if tool.name == "thread_read" then arguments, argument_error = mcp.read_arguments(parameters)
    elseif tool.name == "thread_wait" then arguments, argument_error = mcp.wait_arguments(parameters)
    elseif tool.name == "thread_message" then arguments, argument_error = mcp.message_arguments(parameters)
    elseif tool.name == "thread_sessions" then arguments, argument_error = mcp.sessions_arguments(parameters)
    elseif tool.name == "thread_notify" then arguments, argument_error = mcp.notify_arguments(parameters)
    elseif tool.name == "session_directory" then arguments, argument_error = mcp.sessions_arguments(parameters)
    elseif tool.name == "session_send" then arguments, argument_error = mcp.inbox_message_arguments(parameters, false)
    elseif tool.name == "session_reply" then arguments, argument_error = mcp.inbox_message_arguments(parameters, true)
    elseif tool.name == "session_inbox" then arguments, argument_error = mcp.inbox_page_arguments(parameters)
    elseif tool.name == "session_ack" then arguments, argument_error = mcp.inbox_ack_arguments(parameters)
    elseif tool.name == "thread_launch" then arguments, argument_error = mcp.launch_arguments(parameters)
    elseif tool.name == "run_status" then arguments, argument_error = mcp.run_arguments(parameters, false)
    elseif tool.name == "run_wait" then arguments, argument_error = mcp.run_arguments(parameters, false)
    elseif tool.name == "run_cancel" then arguments, argument_error = mcp.run_arguments(parameters, true)
    elseif tool.name == "launch_definitions" then arguments, argument_error = mcp.launch_definitions_arguments(parameters, binding.workspace_id)
    elseif tool.name == "capabilities" then arguments, argument_error = mcp.capabilities_arguments(parameters)
    elseif tool.name == "request_capability" then arguments, argument_error = mcp.capability_arguments(parameters)
    elseif tool.name == "capability_status" then arguments, argument_error = mcp.capability_status_arguments(parameters)
    elseif tool.name == "overlay" then arguments, argument_error = mcp.overlay_arguments(parameters)
    elseif tool.name == "docs" then arguments, argument_error = mcp.docs_arguments(parameters)
    elseif tool.name == "components" then arguments, argument_error = mcp.components_arguments(parameters)
    elseif tool.name == "install_request" then arguments, argument_error = mcp.install_arguments(parameters, false)
    elseif tool.name == "uninstall_request" then arguments, argument_error = mcp.install_arguments(parameters, true)
    elseif tool.name == "install_status" then arguments, argument_error = mcp.install_status_arguments(parameters)
    elseif tool.name == "delivery" then arguments, argument_error = mcp.delivery_arguments(parameters, binding.workspace_id)
    elseif tool.name == "publish" then arguments, argument_error = mcp.publish_arguments(parameters, binding.workspace_id)
    elseif tool.name == "application_open" then arguments, argument_error = mcp.open_arguments(parameters)
    else arguments = bounds.object(parameters.arguments); if not arguments then argument_error = "tool arguments must be an object" end end
    if arguments and (tool.name == "delivery" or tool.name == "publish" or tool.name == "launch_definitions") then
        argument_error = mcp.bound_workspace(arguments, binding.workspace_id)
        if argument_error then arguments = nil end
    end
    if not arguments then answer(response, http.STATUS.OK, mcp.failure(call.id, mcp.INVALID_PARAMS, argument_error or "invalid arguments")); return nil end
    local runtime: RuntimeGrant? = nil
    if tool.name == "application_open" then
        local granted, grant_failure = gateway.application_runtime(binding, bound)
        if not granted then
            answer(response, http.STATUS.OK, mcp.result(call.id, reply_result(grant_failure, nil)))
            return nil
        end
        runtime = granted
    end
    if tool.name == "thread_wait" then answer(response, http.STATUS.OK, mcp.result(call.id, wait(binding, tool, arguments, values)))
    else answer(response, http.STATUS.OK, mcp.result(call.id, run(binding, tool, arguments, values, runtime))) end
    return nil
end
return {handle = handle}
