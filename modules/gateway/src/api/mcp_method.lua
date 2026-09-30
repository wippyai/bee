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
local gateway = require("gateway")
local mcp = require("mcp")
local catalog = require("catalog")
local context = require("context")
local sessions = require("sessions")
local session_tools = require("session_tools")
local bounds = require("bounds")
local transport_admission = require("admission")
local subject_call = require("subject_call")
type Object = {[string]: unknown}
type RuntimeGrant = {access_approval_id: string, access_proposal_digest: string,
    surface_revision: integer, surface_digest: string}
type OwnerFault = {code: string, message: string, field: string?, retryable: boolean?, remedy: string?}
type OwnerSuccess = {ok: true, value: unknown, replayed: boolean?}
type OwnerFailure = {ok: false, value: unknown?, error: OwnerFault, replayed: boolean?}
type OwnerReply = OwnerSuccess | OwnerFailure
local function selected_policy(reference: string): (string?, string?)
    if not mcp.is_tool_policy_reference(reference) then return reference, nil end
    local entry, entry_error = registry.get(reference)
    if entry_error or not entry then return nil, "built-in tool policy reference is unavailable" end
    local data = bounds.object(entry.data)
    local selected = data and bounds.id(data.resource_ref)
    if not selected then return nil, "built-in tool policy is not linked by the host" end
    return selected, nil
end
local function policies_for(names: {string}): ({security.Policy}?, string?)
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local selected, selected_error = selected_policy(name)
        if not selected then return nil, selected_error or "tool policy is unavailable" end
        local policy, err = security.policy(selected)
        if err or not policy then return nil, "policy " .. selected .. " unavailable" end
        policies[index] = policy
    end
    return policies, nil
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
local function owner_fault(raw: unknown): (OwnerFault?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "owner failure has no error object" end
    local extra = bounds.fields(value, {"code", "message", "field", "retryable", "remedy"})
    if extra then return nil, extra end
    local code, message = bounds.id(value.code), bounds.text(value.message, 4096)
    if not code or not message then return nil, "owner failure is malformed" end
    local field: string? = nil
    if value.field ~= nil then
        field = bounds.id(value.field)
        if not field then return nil, "owner failure field is malformed" end
    end
    local retryable: boolean? = nil
    if value.retryable ~= nil then
        if type(value.retryable) ~= "boolean" then return nil, "owner failure retryable is malformed" end
        retryable = value.retryable
    end
    local remedy: string? = nil
    if value.remedy ~= nil then
        remedy = bounds.text(value.remedy, 4096)
        if not remedy then return nil, "owner failure remedy is malformed" end
    end
    return {code = code, message = message, field = field, retryable = retryable, remedy = remedy}, nil
end
local function decode_owner_reply(raw: unknown): (OwnerReply?, string?)
    local reply = bounds.object(raw)
    if not reply then return nil, "owner reply must be an object" end
    if type(reply.ok) ~= "boolean" then return nil, "owner reply must declare ok" end
    local replayed: boolean? = nil
    if reply.replayed ~= nil then
        if type(reply.replayed) ~= "boolean" then return nil, "owner reply replayed flag is malformed" end
        replayed = reply.replayed
    end
    if reply.error ~= nil then
        local extra = bounds.fields(reply, {"ok", "value", "error", "replayed"})
        if extra then return nil, extra end
        if reply.ok then return nil, "successful owner reply includes an error" end
        local fault, fault_error = owner_fault(reply.error)
        if not fault then return nil, fault_error end
        return {ok = false, value = reply.value, error = fault, replayed = replayed}, nil
    end
    if reply.code ~= nil or reply.message ~= nil or reply.commit ~= nil then
        local extra = bounds.fields(reply, {"ok", "value", "code", "message", "replayed", "commit"})
        if extra then return nil, extra end
        if replayed == nil then return nil, "transaction reply has no replayed flag" end
        if reply.commit ~= nil and type(reply.commit) ~= "boolean" then return nil, "transaction reply commit flag is malformed" end
        if reply.ok then
            if reply.code ~= nil or reply.message ~= nil then return nil, "successful transaction reply includes an error" end
            return {ok = true, value = reply.value, replayed = replayed}, nil
        end
        local fault, fault_error = owner_fault({code = reply.code, message = reply.message})
        if not fault then return nil, fault_error end
        return {ok = false, value = reply.value, error = fault, replayed = replayed}, nil
    end
    local extra = bounds.fields(reply, {"ok", "value", "replayed"})
    if extra then return nil, extra end
    if reply.ok then return {ok = true, value = reply.value, replayed = replayed}, nil end
    return nil, "owner failure has no error details"
end
-- The executor that runs a tool as the bound subject under the tool's
-- host-named scope. The endpoint's own right to invoke these operations
-- is a separate grant; membership is the thread owner's decision.
local function subject_executor(binding: gateway.Binding, tool: mcp.Tool, values: Object?, runtime: RuntimeGrant?): (funcs.Executor?, Object?)
    local policies, policy_error = policies_for(tool.policies)
    if not policies then return nil, refused("UNAVAILABLE", policy_error or "tool policy is unavailable") end
    local executor, setup_error = subject_call.executor(binding, policies, values or {}, runtime)
    if not executor then
        local fault = setup_error and setup_error.error
        return nil, refused(fault and fault.code or "DENIED", fault and fault.message or "bound subject executor is unavailable")
    end
    return executor, nil
end
local function reply_result(reply: unknown, call_error: unknown): Object
    if call_error then return refused("UNAVAILABLE", tostring(call_error), nil, true, "retry the same call") end
    local decoded, decode_error = decode_owner_reply(reply)
    if not decoded then return refused("UNAVAILABLE", decode_error or "owner returned an invalid reply") end
    local encoded, encode_error = json.encode(reply)
    if encode_error or not encoded then return refused("UNAVAILABLE", "owner reply could not be encoded") end
    if decoded.ok then return mcp.tool_result(encoded, false, reply) end
    local value = bounds.object(decoded.value)
    local remedy = value and bounds.text(value.remedy, 4096) or nil
    return mcp.tool_result(encoded, true, mcp.tool_error(decoded.error.code,
        decoded.error.message, decoded.error.field, decoded.error.retryable == true, remedy or decoded.error.remedy))
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
    local traits: {Object} = {}
    for _, trait in ipairs(config.catalog.traits) do
        traits[#traits + 1] = {id = trait.id, title = trait.title, tools = trait.tools}
    end
    return reply_result({ok = true, value = {workspace_id = binding.workspace_id, thread_id = binding.thread_id,
        action_id = binding.action_id, revision = bound.revision, digest = bound.digest,
        tools = tools, traits = traits, allowed_traits = config.allowed_traits, active_traits = bound.selection.active,
        requestable_access = config.access,
        session_tools = session_tools.NAMES,
        thread_access = {thread_id = binding.thread_id,
            note = "thread_read, thread_wait and thread_message reach the bound thread; session_list lists durable sessions"},
        authoring = {guide_tool = "overlay", guide_operation = "guide",
            preflight_tool = "delivery", preflight_operation = "preflight",
            note = "read the capabilities report, then the overlay guide index, then preflight a frozen digest before delivery request"}}}, nil)
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

-- The default session tools are projections of the bee.sessions owner
-- contracts. The owner binding opens as the bound subject; the request is the
-- validated payload and identity travels only in the authenticated context. A
-- reply that violates the published schema is an owner fault, not a result.
local function session_projection(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object): Object
    local policies, policy_error = policies_for(tool.policies)
    if not policies then return refused("UNAVAILABLE", policy_error or "tool policy is unavailable") end
    local contract_id = session_tools.target(tool.name)
    if not contract_id then return refused("INTERNAL", "session tool has no owner contract") end
    local instance, failure = subject_call.contract(binding, policies, values, contract_id)
    if not instance then
        local fault = failure and failure.error
        return refused(fault and fault.code or "DENIED", fault and fault.message or "owner binding is unavailable", nil, true)
    end
    local remedy = request.operation_key ~= nil and "retry with the same operation_key" or nil
    local reply, call_error = session_tools.call(instance, tool.name, request)
    if call_error then return refused("UNAVAILABLE", tostring(call_error), nil, true, remedy) end
    local checked, check_error = session_tools.result(tool.name, reply)
    if not checked then return refused("UNAVAILABLE", check_error or "owner returned an invalid reply", nil, true, remedy) end
    local encoded, encode_error = json.encode(checked)
    if encode_error or not encoded then return refused("UNAVAILABLE", "owner reply could not be encoded", nil, true, remedy) end
    return mcp.tool_result(encoded, checked.ok ~= true, checked)
end
local function run(binding: gateway.Binding, tool: mcp.Tool, request: Object, values: Object, runtime: RuntimeGrant?): Object
    if session_tools.is_session_tool(tool.name) then return session_projection(binding, tool, request, values) end
    local executor, failure = subject_executor(binding, tool, values, runtime)
    if not executor then return failure :: Object end
    if tool.name == "capabilities" then return capabilities(binding) end
    if tool.name == "thread_notify" then
        local target_thread_id: string
        local target_action_id: string? = nil
        local target_attempt_id: string? = nil
        if request.thread_id ~= nil then
            local selected, missing = member_thread(executor, {member_thread = request.thread_id}, binding.thread_id)
            if not selected then return missing :: Object end
            target_thread_id = selected
            target_attempt_id = tostring(request.attempt_id)
        else
            local target, unreachable = resolve(binding, executor, tostring(request.session))
            if not target then return unreachable :: Object end
            target_thread_id = target.thread_id
            target_action_id = target.action_id
        end
        local body: Object = {thread_id = binding.thread_id, idempotency_key = request.idempotency_key,
            target_thread_id = target_thread_id, watcher_action_id = binding.action_id}
        if target_action_id then body.target_action_id = target_action_id end
        if target_attempt_id then body.target_attempt_id = target_attempt_id end
        local reply, call_error = executor:call(tool.operation, body)
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
        local drain, drain_error = gateway.draining()
        if not drain then
            local message = drain_error and drain_error.error and drain_error.error.message or "gateway drain state is unavailable"
            outcome = refused("UNAVAILABLE", message, nil, true)
        elseif drain.draining then
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
    local admitted = transport_admission.check(request, "tool")
    if not admitted.ok then
        answer(response, admitted.status, mcp.failure(nil, mcp.INVALID_REQUEST, admitted.message))
        return nil
    end
    local binding = admitted.binding
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
    elseif tool.name == "thread_notify" then arguments, argument_error = mcp.notify_arguments(parameters)
    elseif session_tools.is_session_tool(tool.name) then arguments, argument_error = session_tools.decode(tool.name, parameters)
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
    if arguments and (tool.name == "delivery" or tool.name == "publish") then
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
