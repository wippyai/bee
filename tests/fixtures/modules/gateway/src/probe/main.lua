-- MIT. Slice 1 of the gateway against the real listener and thread owner:
-- readiness, admission and revocation, thread_read, bounded read-only
-- thread_wait, authenticated thread_message append, replay and context
-- fencing, cross-attempt and expiry refusal, drain and epoch fencing.
-- It asserts and fails the boot; it prints nothing, so no token bytes can
-- reach captured output.
local funcs = require("funcs")
local access_probe = require("access_probe")
local http_client = require("http_client")
local json = require("json")
local base64 = require("base64")
local time = require("time")
local process = require("process")
local registry = require("registry")
local security = require("security")
local ACTOR = "bee.test.gateway"
local THREAD = "gateway-thread"
type Object = {[string]: unknown}
local ADDRESS = ""
local function endpoint(): string
    local selected, err = funcs.call("bee.gateway.registry:address", {})
    -- Auto-start services become ready asynchronously. Wait only for the
    -- reported starting state; a failed or missing service is an immediate error.
    for _ = 1, 100 do
        if not err or not tostring(err):find("gateway listener is starting", 1, true) then break end
        time.sleep("20ms")
        selected, err = funcs.call("bee.gateway.registry:address", {})
    end
    assert(not err and type(selected) == "table", "gateway endpoint: " .. tostring(err))
    local address = (selected :: Object).address
    assert(type(address) == "string" and (address :: string):find("^127%.0%.0%.1:%d+$") and address ~= "127.0.0.1:0", "gateway endpoint address")
    return address :: string
end
local function key(): string return "k-" .. tostring(time.now():unix_nano()) end
local function call(target: string, request: Object): Object
    local reply, err = funcs.call(target, request)
    assert(not err, target .. ": " .. tostring(err))
    return reply :: Object
end
local function ok(reply: Object, what: string): Object
    assert(reply.ok == true, what .. " failed: " .. tostring(type(reply.error) == "table" and (reply.error :: Object).message))
    return reply.value :: Object
end
local function code(reply: Object): string
    assert(reply.ok == false, "expected a refusal")
    return tostring((reply.error :: Object).code)
end
local function admit(action: string, ttl: integer?, carrier_epoch: integer?, tools: {string}?): (string, string)
    local value = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = action, attempt_id = action .. "-attempt", thread_id = THREAD, owner_incarnation = 1,
        carrier_epoch = carrier_epoch or 1, tools = tools or {"thread_read", "thread_wait"}, ttl_ms = ttl or 60000}), "admit " .. action)
    local binding_id = tostring((value.binding :: Object).binding_id)
    assert(value.token == nil, "admit must not return token bytes")
    local authorized = ok(call("bee.gateway.binding:authorize_materialization", {attempt_id = action .. "-attempt", carrier_epoch = carrier_epoch or 1, binding_id = binding_id}), "authorize " .. action)
    local materialized = ok(call("bee.gateway.binding:materialize", {attempt_id = action .. "-attempt", carrier_epoch = carrier_epoch or 1, materialization_key = authorized.materialization_key}), "materialize " .. action)
    return tostring(materialized.token), binding_id
end
local function materialize(attempt: string, carrier_epoch: integer, binding_id: string): Object
    local authorized = ok(call("bee.gateway.binding:authorize_materialization", {attempt_id = attempt, carrier_epoch = carrier_epoch, binding_id = binding_id}), "authorize " .. attempt)
    return call("bee.gateway.binding:materialize", {attempt_id = attempt, carrier_epoch = carrier_epoch, materialization_key = authorized.materialization_key})
end
local function rpc(action: string, token: string, method: string, params: Object?): (number, Object?)
    local body = json.encode({jsonrpc = "2.0", id = 1, method = method, params = params or {}})
    local response, err = http_client.post("http://" .. ADDRESS .. "/mcp/" .. action, {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = body, timeout = "8s"})
    assert(response, "rpc " .. method .. ": " .. tostring(err))
    local decoded: unknown = json.decode(tostring(response.body))
    return response.status_code, type(decoded) == "table" and (decoded :: Object) or nil
end
local function tool(action: string, token: string, name: string, arguments: Object): Object
    local status, reply = rpc(action, token, "tools/call", {name = name, arguments = arguments})
    assert(status == 200 and reply and reply.result, name .. " status " .. tostring(status))
    local result = reply.result :: Object
    local content = (result.content :: {Object})[1]
    local text: unknown = json.decode(tostring(content.text))
    assert(type(text) == "table", name .. " returned no reply")
    return text :: Object
end
local function record(text: string)
    ok(call("bee.threads.service:record", {thread_id = THREAD, idempotency_key = key(), kind = "message",
        body = {message_id = "m-" .. key(), message_kind = "request", recipient_ids = {}, content = {text = text}}}), "record")
end
local function prove_configuration_scope(address: string)
    local selected, scope_error = security.new_scope({})
    assert(selected and not scope_error, "configuration scope: " .. tostring(scope_error))
    local executor, executor_error = funcs.new():with_scope(selected)
    assert(executor and not executor_error, "configuration caller scope: " .. tostring(executor_error))
    local privileged_result, privileged_call_error = funcs.call("bee.gateway_probe:render_configuration", {address = address, action_id = "scope-render", privileged = true})
    assert(not privileged_call_error and type(privileged_result) == "table", "privileged configuration control call failed")
    local privileged = privileged_result :: Object
    assert(privileged.placement_db_acquired == true, "privileged callee could not acquire placement database")
    assert(privileged.placement_executor_acquired == true, "privileged callee could not acquire placement executor")
    local result, call_error = executor:call("bee.gateway_probe:render_configuration", {address = address, action_id = "scope-render"})
    assert(result and not call_error, "configuration scope call: " .. tostring(call_error))
    assert(type(result) == "table", "configuration scope call returned a non-table")
    local value = result :: Object
    assert(value.placement_db_denied == true, "callee acquired placement database")
    assert(value.placement_executor_denied == true, "callee acquired placement executor")
    assert(value.placement_policy_denied == true, "callee recovered placement policy")
    assert(value.funcs_security_denied == true, "callee rebuilt a security scope")
    assert(value.scope_create_denied == true, "callee created a custom scope")
    assert(type(value.projection) == "table", "configuration projection must be a table")
    local projection = value.projection :: Object
    assert(projection.path == ".codex/config.toml", "unexpected rendered configuration path")
    assert(type(projection.content) == "string" and (projection.content :: string):find("scope%-render", 1, false) ~= nil, "configuration did not render input")
    assert((projection.content :: string):find("BEE_GATEWAY_TOKEN", 1, true) ~= nil, "rendered configuration omitted host destination")
end
local function prove_endpoint_call_scope()
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.gateway.security:address_call_policy", "bee.gateway.security:store_policy", "bee.gateway.security:execute_policy", "bee:gateway_tool_read_policy", "bee:gateway_tool_message_policy", "bee:gateway_tool_overlay_policy", "bee:gateway_tool_docs_policy"}) do
        local selected, err = security.policy(name)
        assert(selected ~= nil and err == nil, "endpoint policy unavailable")
        policies[#policies + 1] = selected
    end
    local scope = security.new_scope(policies)
    local actor = security.actor()
    assert(actor ~= nil, "probe actor missing")
    for _, target in ipairs({"bee.gateway.registry:address", "bee.threads.service:read_after", "bee.threads.delivery:watch", "bee.threads.service:record", "bee.governance.binding:overlay_call", "bee.docs.binding:call"}) do
        assert(scope:evaluate(actor, "funcs.call", target) == "allow", "endpoint cannot invoke its selected operation")
    end
    -- The docs tool reads the one embedded corpus and reaches no other volume.
    assert(scope:evaluate(actor, "fs.get", "bee:docs_corpus") == "allow", "docs corpus read is absent")
    assert(scope:evaluate(actor, "fs.get", "bee:workspace_root") ~= "allow", "docs policy reaches an unrelated filesystem")
    assert(scope:evaluate(actor, "registry.get", "bee.docs:corpus_ref") == "allow", "docs corpus reference is absent")
    assert(scope:evaluate(actor, "registry.get", "bee:workspace_root") ~= "allow", "docs policy reaches an unrelated registry entry")
    assert(scope:evaluate(actor, "bee.governance.overlay.read", "any-overlay") == "allow", "overlay read is absent")
    assert(scope:evaluate(actor, "bee.governance.overlay.write", "any-overlay") == "allow", "overlay write is absent")
    for _, target in ipairs({"bee.threads.service:create", "bee.gateway.binding:materialize", "bee.hub.binding:call", "arbitrary:operation"}) do
        assert(scope:evaluate(actor, "funcs.call", target) ~= "allow", "endpoint can invoke an unrelated operation")
    end
end
local function configurable_surface(token_a: string)
    local configurable = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "configurable", attempt_id = "configurable-attempt",
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "measure_context"}, ttl_ms = 60000,
        surface = {tools = {{name = "measure_context", operation = "bee.gateway_probe:context_tool", description = "Read scoped context",
            policies = {"bee.gateway_probe:context_tool_policy", "bee.gateway_probe:replacement_policy"}, schema = {type = "object", additionalProperties = false}, annotations = {readOnlyHint = true}}},
            traits = {{id = "research:measure", title = "Measure", prompt = "Collect a baseline", tools = {"measure_context"}},
                {id = "research:compare", title = "Compare", prompt = "Compare measurements", tools = {"measure_context"}}},
            base_tools = {"thread_read"}, active_traits = {}, fixed_context = {project = "project-a"}, dynamic_keys = {"experiment"}}}), "configurable admission")
    local configurable_binding = tostring((configurable.binding :: Object).binding_id)
    local configurable_token = tostring(ok(materialize("configurable-attempt", 1, configurable_binding), "configurable credential").token)
    local _, disabled = rpc("configurable", configurable_token, "tools/call", {name = "measure_context", arguments = {}})
    assert(disabled and disabled.error ~= nil, "inactive trait exposed its tool")
    local selected = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 1,
        active_traits = {"research:measure", "research:compare"}, context = {experiment = "baseline"}})
    assert(selected.ok == true, "two-trait selection failed")
    local measured = tool("configurable", configurable_token, "call_tool", {name = "measure_context", arguments = {}})
    local measured_value = measured.value :: Object
    assert(measured.ok == true and measured_value.project == "project-a" and measured_value.experiment == "baseline", "native context was not delivered: " .. tostring(json.encode(measured)))
    assert(measured_value.can_read_gateway == false and measured_value.can_create_scope == false, "tool gained gateway authority")
    local attribution = measured_value.binding :: Object
    assert(attribution.binding_id == configurable_binding and attribution.thread_id == THREAD
        and attribution.action_id == "configurable" and attribution.attempt_id == "configurable-attempt", "tool received foreign binding attribution")
    local spoofed = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 2,
        active_traits = {"research:measure"}, context = {["bee.gateway.binding"] = {thread_id = "foreign"}}})
    assert(spoofed.ok == false, "caller replaced reserved binding attribution")
    local peer = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "context-peer", attempt_id = "context-peer-attempt",
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"measure_context"}, ttl_ms = 60000,
        surface = {tools = {{name = "measure_context", operation = "bee.gateway_probe:context_tool", description = "Read attribution",
            policies = {"bee.gateway_probe:context_tool_policy"}, schema = {type = "object", additionalProperties = false}, annotations = {readOnlyHint = true}}},
            traits = {}, base_tools = {"measure_context"}, active_traits = {}, fixed_context = {}, dynamic_keys = {}}}), "peer context admission")
    local peer_binding = tostring((peer.binding :: Object).binding_id)
    local peer_token = tostring(ok(materialize("context-peer-attempt", 1, peer_binding), "peer credential").token)
    local peer_result = tool("context-peer", peer_token, "measure_context", {})
    local peer_identity = (peer_result.value :: Object).binding :: Object
    assert(peer_result.ok == true and peer_identity.binding_id == peer_binding and peer_binding ~= configurable_binding
        and peer_identity.action_id == "context-peer" and peer_identity.attempt_id == "context-peer-attempt", "same-subject bindings shared attribution")
    local original_again = tool("configurable", configurable_token, "measure_context", {})
    assert(((original_again.value :: Object).binding :: Object).binding_id == configurable_binding, "peer call contaminated original attribution")
    local rejected_context = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 2,
        active_traits = {"research:measure"}, context = {project = "foreign"}})
    assert(rejected_context.ok == false, "caller replaced host context")
    local rejected_trait = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 2,
        active_traits = {"foreign:trait"}, context = {}})
    assert(rejected_trait.ok == false, "caller activated foreign trait")
    local stale_selection = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 1,
        active_traits = {}, context = {}})
    assert(stale_selection.ok == false, "stale selection overwrote current state")
    local independent = tool("act-a", token_a, "session", {operation = "read"})
    assert(next((independent.value :: Object).context :: Object) == nil, "binding context leaked")
    local left = funcs.async("bee.gateway_probe:concurrent_call", endpoint(), configurable_token, "left")
    local right = funcs.async("bee.gateway_probe:concurrent_call", endpoint(), configurable_token, "right")
    assert(left and right, "concurrent calls did not start")
    local left_reply = left:response():receive()
    local right_reply = right:response():receive()
    local left_value = left_reply:data()
    local right_value = right_reply:data()
    assert(left_value.ok ~= right_value.ok, "concurrent selection had zero or two winners")
    local loser = left_value.ok and right_value or left_value
    assert(loser.error.code == "CONFLICT", "concurrent loser was not a revision conflict")
    local winner = tool("configurable", configurable_token, "session", {operation = "read"})
    assert((winner.value :: Object).revision == 3, "concurrent update advanced twice")
    ok(call("bee.gateway.binding:reissue", {binding_id = configurable_binding, expected_generation = 1}), "rotate configurable credential")
    local old_status = rpc("configurable", configurable_token, "tools/call", {name = "session", arguments = {operation = "read"}})
    assert(old_status == 401, "rotated token retained selection access")
    configurable_token = tostring(ok(materialize("configurable-attempt", 1, configurable_binding), "renew configurable credential").token)
    local retained = tool("configurable", configurable_token, "session", {operation = "read"})
    local retained_value, winner_value = retained.value :: Object, winner.value :: Object
    assert(retained_value.revision == winner_value.revision, "credential rotation changed selection revision")
    assert((retained_value.context :: Object).experiment == (winner_value.context :: Object).experiment, "credential rotation lost dynamic context")
    assert(json.encode(retained_value.active_traits) == json.encode(winner_value.active_traits), "credential rotation lost active traits")
    local after_rotation = tool("configurable", configurable_token, "measure_context", {})
    assert(after_rotation.ok == true and (after_rotation.value :: Object).project == "project-a", "credential rotation lost fixed context or dispatch")
    assert((after_rotation.value :: Object).replacement_granted == false, "ungranted replacement action was allowed")
    local policy_entry = registry.get("bee.gateway_probe:replacement_policy")
    if not policy_entry then error("replacement fixture policy missing") end
    policy_entry.data = {policy = {actions = {"bee.probe.replacement"}, resources = {"sentinel"}, effect = "allow"}}
    local changes = registry.snapshot():changes()
    changes:update(policy_entry)
    local applied, apply_error = changes:apply()
    assert(applied, "fixture policy replacement failed: " .. tostring(apply_error))
    local observed = false
    for _ = 1, 100 do
        local current = tool("configurable", configurable_token, "measure_context", {})
        if current.ok == true and (current.value :: Object).replacement_granted == true then observed = true; break end
        time.sleep("10ms")
    end
    assert(observed, "same binding did not observe native policy replacement")
    ok(call("bee.gateway.binding:revoke", {binding_id = configurable_binding}), "revoke configurable binding")
    local revoked_status = rpc("configurable", configurable_token, "tools/call", {name = "measure_context", arguments = {}})
    assert(revoked_status == 401, "revoked configurable binding executed")
end
-- Cross-session coordination over the real endpoint: thread_sessions lists
-- only the running sessions of the caller's workspace whose threads the
-- subject reads; thread_message with session records on that session's
-- thread addressed to its action and naming the sender's; thread_notify
-- tells the caller once, on its own thread, when that session's turn ends.
local SESSION_TOOLS = {"thread_sessions", "thread_read", "thread_wait", "thread_message", "thread_notify"}
local function session(action: string, thread_id: string, workspace_id: string?, subject: string?): string
    local request: Object = {subject = subject or ACTOR, action_id = action, attempt_id = action .. "-attempt", thread_id = thread_id,
        owner_incarnation = 1, carrier_epoch = 1, tools = SESSION_TOOLS, ttl_ms = 60000}
    if workspace_id then request.workspace_id = workspace_id end
    local value = ok(call("bee.gateway.binding:admit", request), "admit session " .. action)
    return tostring(ok(materialize(action .. "-attempt", 1, tostring((value.binding :: Object).binding_id)), "materialize session " .. action).token)
end
local function running(thread_id: string, action: string)
    ok(call("bee.threads.service:admit_action", {thread_id = thread_id, idempotency_key = key(), action_id = action,
        admitted = {request_id = action .. "-request", principal_id = ACTOR, binding_ref = "session-binding", binding_digest = "session-digest", grant_refs = {}, budget_ref = "session-budget", input = {text = action}}}), "admit " .. action)
    ok(call("bee.threads.service:prepare_attempt", {thread_id = thread_id, idempotency_key = key(), action_id = action, attempt_id = action .. "-attempt",
        prepared = {binding_ref = "session-binding", binding_digest = "session-digest", profile_id = "session-profile", profile_digest = "session-profile-digest", placement_binding = "session-placement", placement_attempt_id = action .. "-placement", plan_digest = "session-plan"}}), "prepare " .. action)
    ok(call("bee.threads.service:start_attempt", {thread_id = thread_id, idempotency_key = key(), action_id = action, attempt_id = action .. "-attempt",
        started = {execution_kind = "process", execution_ref = action .. "-pid", owner_epoch = 1}}), "start " .. action)
end
local function prove_sessions()
    local thread_a, thread_b = "session-a-thread", "session-b-thread"
    ok(call("bee.threads.service:create", {thread_id = thread_a, idempotency_key = key(), title = "Parser fix"}), "create session a thread")
    ok(call("bee.threads.service:create", {thread_id = thread_b, idempotency_key = key(), title = "Release notes"}), "create session b thread")
    running(thread_a, "session-a")
    running(thread_b, "session-b")
    local token_a = session("session-a", thread_a, "cross-ws")
    local token_b = session("session-b", thread_b, "cross-ws")
    session("session-hidden", "session-hidden-thread", "cross-ws")
    session("session-elsewhere", thread_b, "other-ws")
    local token_none = session("session-none", thread_a, nil)
    local listed = tool("session-a", token_a, "thread_sessions", {})
    assert(listed.ok == true, "thread_sessions refused: " .. tostring(json.encode(listed)))
    local views = (listed.value :: Object).sessions :: {Object}
    assert(#views == 2, "thread_sessions listed other than the two reachable sessions: " .. tostring(json.encode(views)))
    assert(views[1].session == "session-a" and views[1].self == true and views[1].title == "Parser fix" and views[1].thread_id == thread_a, "the caller's own session")
    assert(views[2].session == "session-b" and views[2].self == false and views[2].title == "Release notes" and views[2].attempt_id == "session-b-attempt", "the peer session")
    local unscoped = tool("session-none", token_none, "thread_sessions", {})
    assert(unscoped.ok == false and (unscoped.error :: Object).code == "UNAVAILABLE", "a binding without a workspace listed sessions")
    local b_head = tonumber((ok(call("bee.threads.service:get", {thread_id = thread_b}), "b head").summary :: Object).head_sequence)
    local sent = tool("session-a", token_a, "thread_message", {idempotency_key = "go-ahead", message_id = "go-ahead", message_kind = "notification", session = "session-b", content = {text = "go ahead"}})
    assert(sent.ok == true, "message to a session refused: " .. tostring(json.encode(sent)))
    local woke = tool("session-b", token_b, "thread_wait", {after_sequence = b_head, wait_ms = 2000})
    assert(woke.ok == true and (woke.value :: Object).status == "ready", "the addressed session's wait did not see the message")
    local on_b = ok(call("bee.threads.service:read_after", {thread_id = thread_b, cursor = b_head, filter = {kinds = {"message"}}}), "read b")
    local delivered = (on_b.records :: {Object})[1]
    local body = delivered.body :: Object
    assert((body.recipient_action_ids :: {string})[1] == "session-b" and body.sender_action_id == "session-a" and (body.recipient_ids :: {string})[1] == ACTOR
        and delivered.action_id == nil and (body.content :: Object).text == "go ahead", "the message was not addressed to session b from session a: " .. tostring(json.encode(delivered)))
    for _, address in ipairs({"session-b-attempt", thread_b}) do
        local by_address = tool("session-a", token_a, "thread_message", {idempotency_key = "by-" .. address, message_id = "by-" .. address, message_kind = "progress", session = address, content = {text = "again"}})
        assert(by_address.ok == true, "session addressed by " .. address .. " refused")
    end
    for _, unreachable in ipairs({"session-hidden", "session-elsewhere", "session-hidden-thread", "no-such-session"}) do
        local refused_message = tool("session-a", token_a, "thread_message", {idempotency_key = "to-" .. unreachable, message_id = "to-" .. unreachable, message_kind = "notification", session = unreachable, content = {text = "no"}})
        assert(refused_message.ok == false and (refused_message.error :: Object).code == "NOT_FOUND", "an unreachable session was addressed: " .. unreachable)
    end
    local registered = tool("session-a", token_a, "thread_notify", {session = "session-b", idempotency_key = "tell-me-when-b-ends"})
    assert(registered.ok == true and (registered.value :: Object).state == "pending", "thread_notify refused: " .. tostring(json.encode(registered)))
    local replayed = tool("session-a", token_a, "thread_notify", {session = "session-b", idempotency_key = "tell-me-when-b-ends"})
    assert(replayed.ok == true and replayed.replayed == true and (replayed.value :: Object).notice_id == (registered.value :: Object).notice_id, "thread_notify replay changed the notice")
    local refused_notice = tool("session-a", token_a, "thread_notify", {session = "session-hidden", idempotency_key = "hidden"})
    assert(refused_notice.ok == false and (refused_notice.error :: Object).code == "NOT_FOUND", "a notice on an unreachable session was registered")
    local a_head = tonumber((ok(call("bee.threads.service:get", {thread_id = thread_a}), "a head").summary :: Object).head_sequence)
    local ended = ok(call("bee.threads.service:record", {thread_id = thread_b, idempotency_key = key(), kind = "observation", source = "stream",
        body = {type = "turn.signal", event_key = "session-b-turn-end", data = {type = "turn.signal", phase = "ended", reported_outcome = "succeeded"}},
        context = {action_id = "session-b", attempt_id = "session-b-attempt"}}), "end session b's turn")
    local told = tool("session-a", token_a, "thread_wait", {after_sequence = a_head, wait_ms = 2000})
    assert(told.ok == true and (told.value :: Object).status == "ready", "the notice did not reach session a's thread")
    local notices = ok(call("bee.threads.service:read_after", {thread_id = thread_a, cursor = a_head, filter = {kinds = {"message"}}}), "read a")
    local notice = (notices.records :: {Object})[1]
    local notice_body = notice.body :: Object
    assert((notice_body.recipient_action_ids :: {string})[1] == "session-a" and notice_body.outcome == "succeeded" and (notice.causation :: Object).record_id == ended.record_id,
        "the notice was not addressed to session a with the ending record: " .. tostring(json.encode(notice)))
end
local function main()
    prove_endpoint_call_scope()
    ADDRESS = endpoint()
    prove_configuration_scope(ADDRESS)
    local opened = ok(call("bee.gateway.binding:open", {address = ADDRESS}), "open")
    assert(opened.epoch == 1, "first epoch")
    ok(call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = key(), title = "Gateway"}), "create")
    for index = 1, 3 do record("line " .. tostring(index)) end
    local token_a, binding_a = admit("act-a")
    local readiness_response, readiness_error = http_client.get("http://" .. ADDRESS .. "/ready", {timeout = "2s", query = {nonce = "fixture-readiness"}})
    assert(readiness_response, "readiness request: " .. tostring(readiness_error))
    if readiness_response.status_code ~= 200 then error("readiness refused: " .. tostring(readiness_response.body)) end
    local ready = ok(call("bee.gateway.binding:ready", {binding_id = binding_a}), "ready")
    assert(ready.listening == true and (ready.generation :: Object).epoch == 1, "readiness under epoch 1")
    assert(ready.binding_valid == true, "binding A valid")
    local status, init = rpc("act-a", token_a, "initialize")
    assert(status == 200 and init and (init.result :: Object).protocolVersion ~= nil, "initialize")
    local _, listed = rpc("act-a", token_a, "tools/list")
    assert(listed and #((listed.result :: Object).tools :: {unknown}) == 4, "two admitted tools and MCP controls advertised")
    access_probe.run(ADDRESS)
    configurable_surface(token_a)
    local page = tool("act-a", token_a, "thread_read", {cursor = 0})
    assert(page.ok == true, "thread_read refused: " .. tostring(json.encode(page)))
    assert(#((page.value :: Object).records :: {unknown}) == 3, "thread_read returned the three records: " .. tostring(json.encode(page)))
    -- A managed subject authors through the same authenticated endpoint. The
    -- workspace owner remains the subject; neither thread binding fields nor
    -- publication/activation authority enter the request.
    do
    local workspace_token, workspace_binding = admit("workspace-action", nil, 1, {"overlay"})
    local created = tool("workspace-action", workspace_token, "overlay", {operation = "create", overlay_id = "gateway-research",
        expected_revision = 0, idempotency_key = "create"})
    assert(created.ok == true and (created.value :: Object).revision == 1, "MCP overlay create failed")
    local put_arguments: Object = {operation = "put", overlay_id = "gateway-research", expected_revision = 1,
        idempotency_key = "finding", path = "findings/one.md", content = "measured evidence"}
    local put = tool("workspace-action", workspace_token, "overlay", put_arguments)
    assert(put.ok == true and (put.value :: Object).revision == 2, "MCP overlay put failed")
    local put_replay = tool("workspace-action", workspace_token, "overlay", put_arguments)
    assert(put_replay.ok == true and put_replay.replayed == true and (put_replay.value :: Object).revision == 2,
        "MCP overlay retry was not idempotent")
    local frozen = tool("workspace-action", workspace_token, "overlay", {operation = "freeze", overlay_id = "gateway-research",
        expected_revision = 2, idempotency_key = "freeze"})
    assert(frozen.ok == true and type((frozen.value :: Object).digest) == "string", "MCP overlay freeze failed")
    local source = string.rep("local measurement = 1\n", 1024)
    local large_created = tool("workspace-action", workspace_token, "overlay", {operation = "create", overlay_id = "gateway-large-source",
        expected_revision = 0, idempotency_key = "create-large"})
    assert(large_created.ok == true, "large source workspace create failed")
    local large_put = tool("workspace-action", workspace_token, "overlay", {operation = "put", overlay_id = "gateway-large-source",
        expected_revision = 1, idempotency_key = "put-large", path = "app.lua", content = source})
    assert(large_put.ok == true, "app-size source refused over HTTP")
    local large_read = tool("workspace-action", workspace_token, "overlay", {operation = "read", overlay_id = "gateway-large-source", path = "app.lua"})
    assert(large_read.ok == true and (large_read.value :: Object).bytes == #source, "app-size source was truncated")
    local recovered = base64.decode(tostring((large_read.value :: Object).content_base64))
    assert(recovered == source, "app-size source changed during HTTP authoring")
    local _, oversized = rpc("workspace-action", workspace_token, "tools/call", {name = "overlay", arguments = {
        operation = "put", overlay_id = "gateway-large-source", expected_revision = 2,
        idempotency_key = "too-large", path = "app.lua", content = string.rep("x", 65537)}})
    assert(oversized and oversized.error, "oversized workspace source was admitted")
    local body_status = rpc("workspace-action", workspace_token, "ping", {padding = string.rep("x", 524288)})
    assert(body_status == 400, "whole MCP body limit was not enforced")
    local unchanged = tool("workspace-action", workspace_token, "overlay", {operation = "list", overlay_id = "gateway-large-source"})
    assert(unchanged.ok == true and (unchanged.value :: Object).revision == 2, "refused oversized request changed the workspace")
    local foreign_admission = ok(call("bee.gateway.binding:admit", {subject = "foreign-workspace-subject", action_id = "foreign-workspace-action",
        attempt_id = "foreign-workspace-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1,
        tools = {"overlay"}, ttl_ms = 60000}), "admit foreign workspace actor")
    local foreign_workspace_binding = tostring((foreign_admission.binding :: Object).binding_id)
    local foreign_workspace_token = tostring(ok(materialize("foreign-workspace-attempt", 1, foreign_workspace_binding), "materialize foreign workspace actor").token)
    local foreign_workspace = tool("foreign-workspace-action", foreign_workspace_token, "overlay", {operation = "list", overlay_id = "gateway-research"})
    assert(foreign_workspace.ok == false and foreign_workspace.code == "DENIED", "foreign MCP actor read another workspace")
    ok(call("bee.gateway.binding:revoke", {binding_id = workspace_binding}), "revoke workspace binding")
    end
    -- The credential lifecycle: the same generation cannot be materialized
    -- twice, reissue is a compare-and-set that revokes the old token and
    -- opens the next generation, a stale reissue changes nothing, and the
    -- replaced token is refused while the new one works.
    assert(code(materialize("act-a-attempt", 1, binding_a)) == "CONFLICT", "second materialization refused")
    -- Materialization needs placement's one-time key: none, a wrong one, or
    -- a used one is refused even by a caller holding the materializer grant.
    assert(code(call("bee.gateway.binding:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1})) == "INVALID", "materialization without a key refused")
    assert(code(call("bee.gateway.binding:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1, materialization_key = "not-the-key"})) == "DENIED", "materialization with a wrong key refused")
    assert(code(call("bee.gateway.binding:reissue", {binding_id = binding_a, expected_generation = 7})) == "CONFLICT", "stale reissue refused")
    local reissued = ok(call("bee.gateway.binding:reissue", {binding_id = binding_a, expected_generation = 1}), "reissue")
    assert(reissued.generation == 2, "generation advanced")
    assert(code(call("bee.gateway.binding:reissue", {binding_id = binding_a, expected_generation = 1})) == "CONFLICT", "concurrent reissue with the same expectation loses")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "replaced token refused")
    local authorized_again = ok(call("bee.gateway.binding:authorize_materialization", {attempt_id = "act-a-attempt", carrier_epoch = 1, binding_id = binding_a}), "authorize generation 2")
    local renewed = ok(call("bee.gateway.binding:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1, materialization_key = authorized_again.materialization_key}), "materialize generation 2")
    token_a = tostring(renewed.token)
    assert(code(call("bee.gateway.binding:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1, materialization_key = authorized_again.materialization_key})) == "DENIED", "a used key authorizes nothing more")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "new generation token works")
    assert(code(materialize("act-a-attempt", 2, binding_a)) == "CONFLICT", "a later carrier epoch inherits the binding and its materialized generation")
    assert(code(call("bee.gateway.binding:authorize_materialization", {attempt_id = "act-a-attempt", carrier_epoch = 1, binding_id = "another-binding"})) == "CONFLICT", "a binding that is not the carrier's recorded one is refused")
    assert(code(call("bee.gateway.binding:authorize_materialization", {attempt_id = "act-zz-attempt", carrier_epoch = 1, binding_id = binding_a})) == "NOT_FOUND", "no binding for an unknown attempt")
    -- A presented token is counted; the count is the evidence a client authenticated.
    local presented = ok(call("bee.gateway.binding:check", {binding_id = binding_a}), "check presentations")
    assert((tonumber(presented.presented_count) or 0) >= 1 and presented.last_presented_at ~= nil, "presentations counted")
    -- One live binding per attempt and carrier epoch: the same admission
    -- replays it, a different one at the same epoch conflicts.
    local replayed = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "thread_wait"}, ttl_ms = 60000}), "replay admission")
    assert(replayed.replayed == true and (replayed.binding :: Object).binding_id == binding_a, "same admission replays the live binding")
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "a different admission at the same epoch conflicts")
    -- A later carrier epoch's admission supersedes the earlier binding of the same attempt.
    local superseding = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 2, tools = {"thread_read"}, ttl_ms = 60000}), "admit under epoch 2")
    assert((superseding.binding :: Object).binding_id ~= binding_a, "a new binding")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "the superseded binding's token is refused")
    local superseded = ok(call("bee.gateway.binding:check", {binding_id = binding_a}), "check superseded")
    assert(superseded.valid == false and tostring(superseded.reason) == "binding is revoked", "superseded binding is revoked")
    binding_a = tostring((superseding.binding :: Object).binding_id)
    token_a = tostring(ok(materialize("act-a-attempt", 2, binding_a), "materialize under epoch 2").token)
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "the superseding binding's token works")
    -- A delayed admission under an epoch below the highest ever admitted for
    -- the attempt is refused, so no second live binding can appear.
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "stale admission refused")
    ok(call("bee.gateway.binding:revoke", {binding_id = binding_a}), "revoke the epoch 2 binding")
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "stale admission refused even with the newer binding revoked")
    local reopened_a = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 3, tools = {"thread_read", "thread_wait"}, ttl_ms = 60000}), "admit under epoch 3")
    binding_a = tostring((reopened_a.binding :: Object).binding_id)
    token_a = tostring(ok(materialize("act-a-attempt", 3, binding_a), "materialize under epoch 3").token)
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "the epoch 3 binding's token works")
    -- Independent revocation is fenced by carrier epoch: a report from an
    -- older carrier cannot revoke a binding admitted under a higher epoch.
    local token_f, binding_f = admit("act-f", nil, 5)
    local older = ok(call("bee.gateway.binding:revoke_attempt", {attempt_id = "act-f-attempt", carrier_epoch = 4}), "revoke_attempt older")
    assert(older.revoked == 0 and select(1, rpc("act-f", token_f, "tools/list")) == 200, "older carrier report left the newer binding alive")
    local current = ok(call("bee.gateway.binding:revoke_attempt", {attempt_id = "act-f-attempt", carrier_epoch = 5}), "revoke_attempt current")
    assert(current.revoked == 1 and select(1, rpc("act-f", token_f, "tools/list")) == 401, "current carrier report revoked the binding")
    local checked = ok(call("bee.gateway.binding:check", {binding_id = binding_f}), "check")
    assert(checked.valid == false and tostring(checked.reason) == "binding is revoked", "check reports revocation")
    -- A tool outside the binding's admitted set is refused at the call, whatever a client allows for itself.
    local token_h = admit("act-h", nil, 1)
    local narrow_status, narrow_reply = rpc("act-h", token_h, "tools/list")
    assert(narrow_status == 200 and #(((narrow_reply :: Object).result :: Object).tools :: {Object}) == 4, "the probe admits both tools and MCP controls")
    local admitted_only = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-i", attempt_id = "act-i-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000}), "admit read only")
    local token_i = tostring(ok(materialize("act-i-attempt", 1, tostring((admitted_only.binding :: Object).binding_id)), "materialize read only").token)
    local listed_status, listed = rpc("act-i", token_i, "tools/list")
    assert(listed_status == 200 and #(((listed :: Object).result :: Object).tools :: {Object}) == 3, "only the admitted tool and MCP controls are advertised")
    local refused_status, refused = rpc("act-i", token_i, "tools/call", {name = "thread_wait", arguments = {after_sequence = 0, wait_ms = 10}})
    assert(refused_status == 200 and refused and refused.error ~= nil and tostring(((refused :: Object).error :: Object).message):find("not admitted", 1, true), "a tool outside the binding is refused")
    local refused_message_status, refused_message = rpc("act-i", token_i, "tools/call", {name = "thread_message", arguments = {idempotency_key = "read-only-message", message_id = "read-only-message", message_kind = "notification", recipient_ids = {}, content = {text = "no"}}})
    assert(refused_message_status == 200 and refused_message and refused_message.error ~= nil and tostring(((refused_message :: Object).error :: Object).message):find("not admitted", 1, true), "a read-only binding admitted a write")
    local foreign_admission = ok(call("bee.gateway.binding:admit", {subject = "foreign-subject", action_id = "foreign-action", attempt_id = "foreign-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_message"}, ttl_ms = 60000}), "admit non-member message")
    local foreign_binding = tostring((foreign_admission.binding :: Object).binding_id)
    local foreign_token = tostring(ok(materialize("foreign-attempt", 1, foreign_binding), "materialize non-member message").token)
    local foreign_message = tool("foreign-action", foreign_token, "thread_message", {idempotency_key = "foreign-message", message_id = "foreign-message", message_kind = "notification", recipient_ids = {}, content = {text = "no"}})
    assert(foreign_message.ok == false and type(foreign_message.error) == "table" and (foreign_message.error :: Object).code == "DENIED", "a non-member message sender was accepted")
    -- A token bound to another action is refused on this action, and vice versa.
    local token_b = admit("act-b")
    assert(select(1, rpc("act-a", token_b, "tools/list")) == 403, "cross-attempt token refused")
    assert(select(1, rpc("act-b", token_a, "tools/list")) == 403, "cross-attempt token refused the other way")
    -- An expired token is refused.
    local token_c = admit("act-c", 200)
    assert(select(1, rpc("act-c", token_c, "tools/list")) == 200, "token works before expiry")
    time.sleep("250ms")
    assert(select(1, rpc("act-c", token_c, "tools/list")) == 401, "expired token refused")
    -- A revoked token is refused.
    ok(call("bee.gateway.binding:revoke", {binding_id = binding_a}), "revoke")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "revoked token refused")
    -- thread_wait is bounded and read-only: a timeout returns within the budget, a
    -- new record wakes it, and no obligation or delivery mark is touched.
    local token_d, binding_d = admit("act-d")
    local started = time.now()
    local waited = tool("act-d", token_d, "thread_wait", {after_sequence = 3, wait_ms = 100})
    assert(waited.ok == true and (waited.value :: Object).status == "timeout", "wait timed out")
    assert(time.now():sub(started):milliseconds() < 5000, "wait respected the transport budget")
    record("line 4")
    local woke = tool("act-d", token_d, "thread_wait", {after_sequence = 3, wait_ms = 100})
    assert(woke.ok == true and (woke.value :: Object).status == "ready", "wait woke on the new record")
    local marks = ok(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, filter = {kinds = {"delivery.mark"}}}), "read marks")
    assert(#(marks.records :: {unknown}) == 0, "viewing wrote a delivery mark")
    do
    -- thread_message is an explicitly admitted write. Its arguments contain
    -- only the message and a stable key; the endpoint supplies the thread,
    -- authenticated sender, fixed kind and action/attempt context.
    ok(call("bee.threads.service:admit_action", {thread_id = THREAD, idempotency_key = key(), action_id = "mcp-action",
        admitted = {request_id = "mcp-request", principal_id = ACTOR, binding_ref = "mcp-binding", binding_digest = "mcp-digest", grant_refs = {}, budget_ref = "mcp-budget", input = {text = "mcp"}}}), "admit MCP action")
    ok(call("bee.threads.service:prepare_attempt", {thread_id = THREAD, idempotency_key = key(), action_id = "mcp-action", attempt_id = "mcp-attempt",
        prepared = {binding_ref = "mcp-binding", binding_digest = "mcp-digest", profile_id = "mcp-profile", profile_digest = "mcp-profile-digest", placement_binding = "mcp-placement", placement_attempt_id = "mcp-placement-attempt", plan_digest = "mcp-plan"}}), "prepare MCP attempt")
    local mcp_admit = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "mcp-action", attempt_id = "mcp-attempt", thread_id = THREAD,
        owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_message"}, ttl_ms = 60000}), "admit MCP message")
    local mcp_binding = tostring((mcp_admit.binding :: Object).binding_id)
    local mcp_token = tostring(ok(materialize("mcp-attempt", 1, mcp_binding), "materialize MCP message").token)
    local message_arguments: Object = {idempotency_key = "mcp-message-key", message_id = "mcp-message", message_kind = "notification", recipient_ids = {}, content = {text = "from authenticated MCP"}}
    local appended = tool("mcp-action", mcp_token, "thread_message", message_arguments)
    assert(appended.ok == true and type(appended.value) == "table", "thread_message append refused: " .. tostring(json.encode(appended)))
    local appended_value = appended.value :: Object
    local replay = tool("mcp-action", mcp_token, "thread_message", message_arguments)
    assert(replay.ok == true and replay.replayed == true and (replay.value :: Object).record_id == appended_value.record_id and (replay.value :: Object).sequence == appended_value.sequence,
        "identical thread_message replay duplicated or changed the result")
    local changed_arguments: Object = {idempotency_key = "mcp-message-key", message_id = "mcp-message", message_kind = "notification", recipient_ids = {}, content = {text = "changed"}}
    local changed = tool("mcp-action", mcp_token, "thread_message", changed_arguments)
    assert(changed.ok == false and (changed.error :: Object).code == "CONFLICT", "changed thread_message replay was accepted")
    local contextual = ok(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, filter = {action_id = "mcp-action"}}), "read MCP append")
    local message_records = 0
    for _, item in ipairs(contextual.records :: {Object}) do
        if item.kind == "message" then
            message_records = message_records + 1
            assert(item.thread_id == THREAD and item.producer_id == ACTOR and item.action_id == "mcp-action" and item.attempt_id == "mcp-attempt", "MCP append context was not bound")
            assert((item.body :: Object).sender_id == ACTOR, "MCP sender was not authenticated")
        end
    end
    assert(message_records == 1, "replayed thread_message created a duplicate record")
    local _, foreign_thread = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "foreign-thread", message_id = "foreign-thread", message_kind = "notification", recipient_ids = {}, content = {text = "no"}, thread_id = "other-thread"}})
    assert(foreign_thread and foreign_thread.error and tostring((foreign_thread.error :: Object).message):find("unknown field thread_id", 1, true), "foreign thread override was accepted")
    local _, foreign_sender = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "foreign-sender", message_id = "foreign-sender", message_kind = "notification", recipient_ids = {}, content = {text = "no"}, sender_id = "foreign"}})
    assert(foreign_sender and foreign_sender.error and tostring((foreign_sender.error :: Object).message):find("unknown field sender_id", 1, true), "foreign producer override was accepted")
    local _, foreign_context = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "foreign-context", message_id = "foreign-context", message_kind = "notification", recipient_ids = {}, content = {text = "no"}, context = {action_id = "other-action"}}})
    assert(foreign_context and foreign_context.error and tostring((foreign_context.error :: Object).message):find("unknown field context", 1, true), "foreign context override was accepted")
    local _, arbitrary_record = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "arbitrary-record", kind = "receipt", message_id = "arbitrary-record", message_kind = "notification", recipient_ids = {}, content = {text = "no"}}})
    assert(arbitrary_record and arbitrary_record.error and tostring((arbitrary_record.error :: Object).message):find("unknown field kind", 1, true), "arbitrary record kind was accepted")
    local settled = ok(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, filter = {kinds = {"receipt"}, action_id = "mcp-action"}}), "read MCP receipts")
    assert(#(settled.records :: {unknown}) == 0, "thread_message settled an attempt")
    ok(call("bee.gateway.binding:revoke", {binding_id = mcp_binding}), "revoke MCP message binding")
    assert(select(1, rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = message_arguments})) == 401, "revoked thread_message token was accepted")
    end
    prove_sessions()
    -- Hooks: a binding that admits hook events gets a second credential of
    -- its own kind; neither credential opens the other endpoint.
    local function header_of(headers: unknown, name: string): string?
        if type(headers) ~= "table" then return nil end
        for key, value in pairs(headers :: {[string]: unknown}) do
            if tostring(key):lower() == name:lower() then
                if type(value) == "table" then return tostring((value :: {unknown})[1]) end
                return tostring(value)
            end
        end
        return nil
    end
    local function hook_post(action: string, token: string, body: unknown, path: string?): (number, string, unknown)
        local encoded = type(body) == "string" and body :: string or (json.encode(body) or "{}")
        local response, err = http_client.post("http://" .. ADDRESS .. "/hook/" .. action .. (path or ""), {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = encoded, timeout = "8s"})
        assert(response, "hook post: " .. tostring(err))
        return response.status_code, tostring(response.body or ""), response.headers
    end
    local function hook_get(action: string, token: string, event_id: string): (number, Object?)
        local response, err = http_client.get("http://" .. ADDRESS .. "/hook/" .. action .. "/" .. event_id, {headers = {Authorization = "Bearer " .. token}, timeout = "8s"})
        assert(response, "hook get: " .. tostring(err))
        local decoded: unknown = json.decode(tostring(response.body))
        return response.status_code, type(decoded) == "table" and (decoded :: Object) or nil
    end
    local hook_admit = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-k", attempt_id = "act-k-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"},
        hooks = {"PreToolUse", "PostToolUse", "Stop", "SessionStart"}, ttl_ms = 60000}), "admit with hooks")
    local binding_k = tostring((hook_admit.binding :: Object).binding_id)
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-k2", attempt_id = "act-k2-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"Notification"}})) == "INVALID", "an event outside the catalog is not admitted")
    local minted_k = ok(materialize("act-k-attempt", 1, binding_k), "materialize with hooks")
    local token_k, hook_k = tostring(minted_k.token), tostring(minted_k.hook_token)
    assert(hook_k ~= token_k and #hook_k > 20, "a hook credential of its own")
    assert(select(1, rpc("act-k", hook_k, "tools/list")) == 401, "the hook credential is refused on the tool endpoint")
    assert(select(1, rpc("act-k", token_k, "tools/list")) == 200, "the tool credential works on the tool endpoint")
    local refused_status, refused_body, refused_headers = hook_post("act-k", token_k, {hook_event_name = "PreToolUse", session_id = "s1", tool_use_id = "toolu_0"})
    assert(refused_status == 401 and tostring(header_of(refused_headers, "Content-Type")):find("text/plain", 1, true) and not refused_body:find("{", 1, true), "the tool credential is refused on the hook endpoint with a plain text body: " .. refused_body)
    -- A submission is answered with a status and an empty body, whatever the
    -- payload carried; control fields never reach the queue.
    local first_payload = {hook_event_name = "PreToolUse", session_id = "s1", prompt_id = "p1", tool_use_id = "toolu_1", tool_name = "Bash", tool_input = {command = "ls", secret = "sk-live-000"},
        decision = "block", ["continue"] = false, hookSpecificOutput = {hookEventName = "PreToolUse", permissionDecision = "deny"}}
    local s1, b1, h1 = hook_post("act-k", hook_k, first_payload)
    assert(s1 == 202 and b1 == "", "queued with an empty body: " .. tostring(s1) .. " " .. b1)
    local event_1 = tostring(header_of(h1, "X-Bee-Event"))
    assert(#event_1 > 10, "the event id rides in a header")
    local s1_again, b1_again, h1_again = hook_post("act-k", hook_k, first_payload)
    assert(s1_again == 202 and b1_again == "" and header_of(h1_again, "X-Bee-Event") == event_1, "an identical replay answers the same event")
    local changed = {hook_event_name = "PreToolUse", session_id = "s1", prompt_id = "p1", tool_use_id = "toolu_1", tool_name = "Bash", tool_input = {command = "rm"}}
    local s_changed, b_changed, h_changed = hook_post("act-k", hook_k, changed)
    assert(s_changed == 409 and tostring(header_of(h_changed, "Content-Type")):find("text/plain", 1, true) and not b_changed:find("{", 1, true), "a changed submission under the same occurrence conflicts: " .. tostring(s_changed))
    local status_code, status_body = hook_get("act-k", hook_k, event_1)
    assert(status_code == 200 and status_body and status_body.status == "queued" and status_body.ambiguous == false, "status answers queued")
    local unknown_code, unknown_body = hook_get("act-k", hook_k, "no-such-event")
    assert(unknown_code == 200 and unknown_body and unknown_body.status == "unknown", "an unknown id answers unknown")
    assert(select(1, hook_post("act-k", hook_k, {hook_event_name = "SessionEnd", session_id = "s1", reason = "other"})) == 403, "an event the binding does not admit is refused")
    assert(select(1, hook_post("act-k", hook_k, {hook_event_name = "Notification", session_id = "s1"})) == 400, "an event outside the catalog is refused")
    assert(select(1, hook_post("act-k", hook_k, "not json")) == 400, "a body that is not an object is refused")
    -- Occurrence identity: a Stop names no occurrence of its own, so a
    -- repeated Stop under one prompt is kept per delivery and reported
    -- ambiguous, as is a SessionStart without its source.
    local stop_1_status, _, stop_1_headers = hook_post("act-k", hook_k, {hook_event_name = "Stop", session_id = "s1", prompt_id = "p1", stop_hook_active = false, last_assistant_message = "done"})
    local stop_2_status, _, stop_2_headers = hook_post("act-k", hook_k, {hook_event_name = "Stop", session_id = "s1", prompt_id = "p1", stop_hook_active = false, last_assistant_message = "done"})
    assert(stop_1_status == 202 and stop_2_status == 202 and header_of(stop_1_headers, "X-Bee-Event") ~= header_of(stop_2_headers, "X-Bee-Event"), "a repeated Stop is kept per delivery")
    local _, stop_status = hook_get("act-k", hook_k, tostring(header_of(stop_2_headers, "X-Bee-Event")))
    assert(stop_status and stop_status.ambiguous == true, "and reported ambiguous")
    local _, _, start_1 = hook_post("act-k", hook_k, {hook_event_name = "SessionStart", session_id = "s1"})
    local _, _, start_2 = hook_post("act-k", hook_k, {hook_event_name = "SessionStart", session_id = "s1"})
    assert(header_of(start_1, "X-Bee-Event") ~= header_of(start_2, "X-Bee-Event"), "a SessionStart without its source is recorded per delivery")
    local _, start_status = hook_get("act-k", hook_k, tostring(header_of(start_2, "X-Bee-Event")))
    assert(start_status and start_status.ambiguous == true, "and reported ambiguous")
    local big: {string} = {}
    for index = 1, 3400 do big[index] = "0123456789" end
    assert(select(1, hook_post("act-k", hook_k, {hook_event_name = "PostToolUse", session_id = "s1", tool_use_id = "toolu_big", tool_response = table.concat(big)})) == 413, "a payload past the bound is refused")
    -- What the queue holds: kinds, claims, sizes and digests; no content and
    -- no control field.
    local queue = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "hook queue")
    local queued_list = queue.hooks :: {Object}
    assert(#queued_list == 5, "five submissions queued: " .. tostring(#queued_list))
    local queued_text = json.encode(queued_list) or ""
    assert(not queued_text:find("sk-live", 1, true) and not queued_text:find("\"ls\"", 1, true) and not queued_text:find("decision", 1, true) and not queued_text:find("permissionDecision", 1, true), "no content or control field in the queue")
    assert(queued_text:find("content_sizes", 1, true) and queued_text:find("content_digests", 1, true) and queued_text:find("\"provenance\":\"http\"", 1, true), "sizes, digests and provenance in the queue")
    -- The MCP form of the same endpoint serves one tool to Codex's hook
    -- engine; the request metadata is classified, never trusted.
    local function hook_rpc(token: string, method: string, params: Object?): (number, Object?)
        local body = json.encode({jsonrpc = "2.0", id = 1, method = method, params = params or {}})
        local response, err = http_client.post("http://" .. ADDRESS .. "/hook/act-k/mcp", {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = body, timeout = "8s"})
        assert(response, "hook rpc: " .. tostring(err))
        local decoded: unknown = json.decode(tostring(response.body))
        return response.status_code, type(decoded) == "table" and (decoded :: Object) or nil
    end
    assert(select(1, hook_rpc(token_k, "tools/list")) == 401, "the tool credential is refused on the MCP hook endpoint")
    local listed_status, listed_hook = hook_rpc(hook_k, "tools/list")
    assert(listed_status == 200 and #(((listed_hook :: Object).result :: Object).tools :: {Object}) == 1, "the MCP hook endpoint serves one tool")
    local engine_status, engine_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_1", tool_name = "mcp__bee__thread_read", tool_response = {content = {}}}, _meta = {threadId = "s2", progressToken = 1}})
    assert(engine_status == 200 and engine_reply and engine_reply.result ~= nil, "a hook-engine shaped call is accepted")
    -- Codex joins the tool's text content into hook stdout and reads it with
    -- command-hook semantics: plain text is invalid Stop output and becomes
    -- model context for other events. An observer answers no text at all and
    -- carries its receipt as structured content.
    local engine_result = (engine_reply :: Object).result :: Object
    assert(#(engine_result.content :: {Object}) == 0, "the MCP answer carries no hook stdout: " .. tostring(json.encode(engine_result)))
    local engine_receipt = engine_result.structuredContent :: Object
    assert(engine_receipt and engine_receipt.status == "queued" and type(engine_receipt.event_id) == "string", "the receipt is structured: " .. tostring(json.encode(engine_result)))
    local stop_status, stop_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "Stop", session_id = "s2", turn_id = "t1", last_assistant_message = "done"}, _meta = {threadId = "s2", progressToken = 2}})
    local stop_result = stop_reply and (stop_reply :: Object).result :: Object or nil
    assert(stop_status == 200 and stop_result and #(stop_result.content :: {Object}) == 0 and stop_result.isError == false, "a Stop hook answers no stdout: " .. tostring(json.encode(stop_reply)))
    local _, model_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_2"}, _meta = {callId = "call_2", ["x-codex-turn-metadata"] = {turn_id = "t1"}}})
    assert(model_reply and model_reply.error ~= nil and tostring(((model_reply :: Object).error :: Object).message):find("(model)", 1, true), "a model shaped call is refused")
    local _, mixed_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_3"}, _meta = {threadId = "s2", callId = "call_3"}})
    assert(mixed_reply and mixed_reply.error ~= nil and tostring(((mixed_reply :: Object).error :: Object).message):find("(mixed)", 1, true), "a mixed metadata call is refused")
    local _, bare_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_4"}})
    assert(bare_reply and bare_reply.error ~= nil and tostring(((bare_reply :: Object).error :: Object).message):find("(unclassified)", 1, true), "a call without metadata is refused")
    local _, other_tool = hook_rpc(hook_k, "tools/call", {name = "thread_read", arguments = {cursor = 0}, _meta = {threadId = "s2"}})
    assert(other_tool and other_tool.error ~= nil, "no thread tool is served on the hook endpoint")
    local engine_queue = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "hook queue after mcp")
    assert((json.encode(engine_queue.hooks) or ""):find("codex:hook_engine", 1, true) ~= nil, "provenance records the classification")
    -- Overload is explicit: past the queue bound the endpoint answers 429
    -- with a retry interval, and a replay of a queued event still answers.
    local overflowed = 0
    for index = 1, 70 do
        local status_n, _, headers_n = hook_post("act-k", hook_k, {hook_event_name = "PostToolUse", session_id = "s3", tool_use_id = "fill_" .. tostring(index), tool_name = "Bash"})
        if status_n == 429 then
            overflowed = overflowed + 1
            assert(header_of(headers_n, "Retry-After") ~= nil, "429 names a retry interval")
        else
            assert(status_n == 202, "fill " .. tostring(index) .. " status " .. tostring(status_n))
        end
    end
    assert(overflowed > 0, "the queue bound is enforced")
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 202, "a replay of a queued event still answers past the bound")
    -- Intake: a carrier claims queued submissions under its epoch and
    -- acknowledges only a claimed row. The carrier record path is exercised
    -- with the retained claim below. A claim or acknowledgment from an epoch
    -- below the highest admitted for the attempt changes nothing.
    local lost_claim = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 1, limit = 3}), "claim whose reply is lost")
    local lost_list = lost_claim.hooks :: {Object}
    assert(#lost_list == 3 and lost_list[1].event_id == event_1, "the first three queued submissions are claimed in order")
    local claimed = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 1, limit = 3}), "recover lost claim reply")
    local claimed_list = claimed.hooks :: {Object}
    assert(#claimed_list == #lost_list, "the lost claim is redelivered at the same bound")
    for index, item in ipairs(claimed_list) do
        assert(item.event_id == lost_list[index].event_id, "the same epoch redelivers outstanding rows in order")
    end
    local claimed_ids: {string} = {}
    for index, item in ipairs(claimed_list) do claimed_ids[index] = tostring(item.event_id) end
    local acked = ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = claimed_ids}), "ack claimed batch")
    assert(acked.acknowledged == 3, "the recovered batch is acknowledged once")
    local committed_status, committed_body = hook_get("act-k", hook_k, event_1)
    assert(committed_status == 200 and committed_body and committed_body.status == "committed", "status answers committed")
    local replay_status, replay_body = hook_post("act-k", hook_k, first_payload)
    assert(replay_status == 200 and replay_body == "", "a replay of a committed submission answers 200 with an empty body")
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = claimed_ids}), "ack twice").acknowledged == 0, "an acknowledgment is idempotent")
    local progressed_claim = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 1, limit = 3}), "claim after acknowledgment")
    assert(#(progressed_claim.hooks :: {Object}) == 3 and (progressed_claim.hooks :: {Object})[1].event_id ~= event_1,
        "acknowledgment advances the next bounded claim")
    -- Sealing ends intake at once and keeps the accepted rows for the carrier.
    local pre_seal = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "queue before seal")
    ok(call("bee.gateway.binding:seal", {binding_id = binding_k}), "seal")
    local sealed_status, sealed_body = hook_post("act-k", hook_k, {hook_event_name = "PreToolUse", session_id = "s9", tool_use_id = "toolu_after_seal", tool_name = "Bash"})
    assert(sealed_status == 403 and sealed_body:find("sealed", 1, true), "a submission after the seal is refused: " .. tostring(sealed_status) .. " " .. sealed_body)
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 200, "a replay of a committed submission still answers after the seal")
    assert(select(1, rpc("act-k", token_k, "tools/list")) == 200, "the seal leaves the tool credential valid")
    local post_seal = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "queue after seal")
    assert(#(post_seal.hooks :: {Object}) == #(pre_seal.hooks :: {Object}), "the seal discards nothing accepted")
    local taken_over = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 3, limit = 2}), "claim under a higher epoch")
    assert(#(taken_over.hooks :: {Object}) == 2, "a higher epoch takes over rows a lower epoch claimed, sealed or not")
    local stale_ack = ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = {(taken_over.hooks :: {Object})[1].event_id}}), "stale ack")
    assert(stale_ack.acknowledged == 0, "a lower epoch cannot acknowledge what a higher one claimed")
    local unclaimed_ack = ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 3, event_ids = {(progressed_claim.hooks :: {Object})[3].event_id}}), "ack without claim")
    assert(unclaimed_ack.acknowledged == 0, "an epoch that did not take over a row cannot acknowledge it")
    local admitted_higher = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-k", attempt_id = "act-k-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 4, tools = {"thread_read"}, hooks = {"Stop", "PreToolUse"}, ttl_ms = 60000}), "admit act-k under epoch 4")
    assert(code(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 3})) == "CONFLICT", "a claim below the highest admitted epoch is refused")
    assert(code(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 3, event_ids = {(taken_over.hooks :: {Object})[1].event_id}})) == "CONFLICT",
        "an old claim cannot acknowledge after the replacement admission")
    local superseded_queue = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "superseded queue")
    local rejected_count, committed_count, retained_claimed = 0, 0, 0
    for _, item in ipairs(superseded_queue.hooks :: {Object}) do
        if item.status == "rejected" then rejected_count = rejected_count + 1; assert(item.rejected_reason == "binding superseded", "rejection names its reason") end
        if item.status == "committed" then committed_count = committed_count + 1 end
        if item.status == "queued" and (tonumber(item.claimed_epoch) or 0) > 0 then retained_claimed = retained_claimed + 1 end
    end
    assert(committed_count == 3 and rejected_count > 0 and retained_claimed > 0,
        "supersession rejects unclaimed rows, keeps committed rows and retains claimed uncertainty: " .. tostring(committed_count) .. " " .. tostring(rejected_count) .. " " .. tostring(retained_claimed))
    local recovered_after_supersession = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 4, limit = 3}), "reclaim superseded claims")
    assert(#(recovered_after_supersession.hooks :: {Object}) > 0, "the current carrier reclaims a superseded claimed row")
    local recovered_id = tostring((recovered_after_supersession.hooks :: {Object})[1].event_id)
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 4, event_ids = {recovered_id}}), "ack reclaimed superseded row").acknowledged == 1,
        "a replacement can acknowledge a retained claim")
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 401, "the superseded binding's hook credential is refused")
    local binding_k4 = tostring((admitted_higher.binding :: Object).binding_id)
    local minted_k4 = ok(materialize("act-k-attempt", 4, binding_k4), "materialize under epoch 4")
    local hook_k4 = tostring(minted_k4.hook_token)
    local stop_status, _, stop_headers = hook_post("act-k", hook_k4, {hook_event_name = "Stop", session_id = "s4", prompt_id = "p4", stop_hook_active = false})
    assert(stop_status == 202, "a hook under the new binding queues")
    local ended = ok(call("bee.gateway.binding:hook_reject", {binding_id = binding_k4, carrier_epoch = 4, reason = "attempt settled"}), "reject at settlement")
    assert(ended.rejected == 1, "the queued row is rejected at settlement")
    local rejected_status, rejected_body = hook_get("act-k", hook_k4, tostring(header_of(stop_headers, "X-Bee-Event")))
    assert(rejected_status == 200 and rejected_body and rejected_body.status == "rejected" and rejected_body.rejected_reason == "attempt settled", "status answers rejected with its reason")
    local gone_status, gone_body = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_gone", tool_name = "Bash"})
    assert(gone_status == 202, "a fresh occurrence still queues until the binding ends: " .. tostring(gone_status) .. " " .. tostring(gone_body))
    ok(call("bee.gateway.binding:hook_reject", {binding_id = binding_k4, carrier_epoch = 4, reason = "attempt settled"}), "reject again")
    local replay_gone_status, replay_gone_body = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_gone", tool_name = "Bash"})
    assert(replay_gone_status == 410 and replay_gone_body:find("rejected: attempt settled", 1, true), "a replay of a rejected occurrence answers 410 with plain text: " .. tostring(replay_gone_status) .. " " .. replay_gone_body)
    local claimed_before_revoke, _, claimed_headers = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_claimed_revoke", tool_name = "Bash"})
    local queued_before_revoke, _, revoke_headers = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_revoked", tool_name = "Bash"})
    assert(claimed_before_revoke == 202 and queued_before_revoke == 202, "claimed and unclaimed rows queue before the revocation")
    local claimed_for_commit = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k4, carrier_epoch = 4, limit = 1}), "claim before lost acknowledgment")
    local claimed_item = (claimed_for_commit.hooks :: {Object})[1]
    local claimed_for_commit_id = tostring(claimed_item.event_id)
    assert(claimed_for_commit_id == tostring(header_of(claimed_headers, "X-Bee-Event")), "the row held across revoke was claimed first")
    -- Commit the claimed hook through the actual fenced carrier API, then
    -- deliberately omit its gateway acknowledgment. This is the durable
    -- uncertainty retention must preserve across revocation.
    ok(call("bee.threads.service:admit_action", {thread_id = THREAD, idempotency_key = key(), action_id = "act-k",
        admitted = {request_id = "act-k-request", principal_id = ACTOR, binding_ref = "act-k-binding", binding_digest = "act-k-digest", grant_refs = {}, budget_ref = "act-k-budget", input = {text = "hook recovery"}}}), "admit hook action")
    ok(call("bee.threads.service:prepare_attempt", {thread_id = THREAD, idempotency_key = key(), action_id = "act-k", attempt_id = "act-k-attempt",
        prepared = {binding_ref = "act-k-binding", binding_digest = "act-k-digest", profile_id = "act-k-profile", profile_digest = "act-k-profile-digest", placement_binding = "act-k-placement", placement_attempt_id = "act-k-placement-attempt", plan_digest = "act-k-plan"}}), "prepare hook attempt")
    ok(call("bee.threads.service:start_attempt", {thread_id = THREAD, idempotency_key = key(), action_id = "act-k", attempt_id = "act-k-attempt",
        started = {execution_kind = "process", execution_ref = "act-k-execution", owner_epoch = 1}}), "start hook attempt")
    -- The binding is at gateway epoch 4, so bring the thread carrier to the
    -- same fenced epoch before recording its hook.
    for epoch = 1, 4 do
        local carrier = ok(call("bee.threads.carrier:claim", {thread_id = THREAD, idempotency_key = key(), attempt_id = "act-k-attempt"}), "claim hook carrier")
        assert(carrier.carrier_epoch == epoch, "hook carrier epoch " .. tostring(epoch))
    end
    local event_key = "hook:" .. binding_k4 .. ":" .. tostring(claimed_item.event) .. ":" .. tostring(claimed_item.occurrence)
    local payload = json.encode({event_id = claimed_item.event_id, event = claimed_item.event, occurrence = claimed_item.occurrence, ambiguous = claimed_item.ambiguous == true,
        provenance = claimed_item.provenance, sequence = claimed_item.sequence, fields = claimed_item.fields, binding_id = binding_k4}) or "{}"
    local hook_record = {source = "bee", body = {type = "extension", event_key = event_key,
        data = {type = "extension", event_name = "bee.harness.hook", event_revision = "1", payload_json = payload}}}
    local first_commit = ok(call("bee.threads.carrier:commit", {thread_id = THREAD, idempotency_key = key(), attempt_id = "act-k-attempt", carrier_epoch = 4, expected_revision = 0,
        checkpoint = {schema_revision = "bee.carrier.checkpoint@1", phase = "hook-committed-before-ack"}, records = {hook_record}}), "commit claimed hook")
    assert(#(first_commit.records :: {Object}) == 1 and (first_commit.records :: {Object})[1].replayed == false, "the claimed hook committed once")
    ok(call("bee.gateway.binding:revoke", {binding_id = binding_k4}), "revoke the hook binding")
    assert(select(1, hook_post("act-k", hook_k4, first_payload)) == 401, "a revoked binding's hook credential is refused")
    local after_revoke = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k4}), "queue after revoke")
    for _, item in ipairs(after_revoke.hooks :: {Object}) do
        if item.event_id == header_of(revoke_headers, "X-Bee-Event") then assert(item.status == "rejected" and item.rejected_reason == "binding revoked", "revocation rejects an unclaimed row terminally") end
        if item.event_id == claimed_for_commit_id then assert(item.status == "queued" and item.claimed_epoch == 4, "revocation retains the claimed row after its thread commit") end
    end
    local retry_commit = ok(call("bee.threads.carrier:commit", {thread_id = THREAD, idempotency_key = key(), attempt_id = "act-k-attempt", carrier_epoch = 4, expected_revision = 1,
        checkpoint = {schema_revision = "bee.carrier.checkpoint@1", phase = "hook-recovered-before-ack"}, records = {hook_record}}), "retry committed hook")
    assert(#(retry_commit.records :: {Object}) == 1 and (retry_commit.records :: {Object})[1].replayed == true, "retry replays the retained hook record")
    local committed_records = ok(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64}), "read retained hook record")
    local retained_records = 0
    for _, item in ipairs(committed_records.records :: {Object}) do
        if item.kind == "observation" and type(item.body) == "table" and (item.body :: Object).event_key == event_key then retained_records = retained_records + 1 end
    end
    assert(retained_records == 1, "the replay did not duplicate the committed hook record")
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k4, carrier_epoch = 4, event_ids = {claimed_for_commit_id}}), "ack after revoke").acknowledged == 1,
        "the internally authorized carrier acknowledges the committed row after revocation")
    -- Expiry has the same distinction: the token is refused, unclaimed rows
    -- are rejected, and the internally authorized carrier path reclaims work
    -- that was already claimed before expiry.
    local expiring = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-expiring-hooks", attempt_id = "act-expiring-hooks-attempt", thread_id = THREAD,
        owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"PreToolUse"}, ttl_ms = 250}), "admit expiring hooks")
    local expiring_binding = tostring((expiring.binding :: Object).binding_id)
    local expiring_tokens = ok(materialize("act-expiring-hooks-attempt", 1, expiring_binding), "materialize expiring hooks")
    local expiring_hook = tostring(expiring_tokens.hook_token)
    local expiring_status, _, expiring_headers = hook_post("act-expiring-hooks", expiring_hook, {hook_event_name = "PreToolUse", session_id = "expiry", tool_use_id = "toolu_expiry", tool_name = "Bash"})
    assert(expiring_status == 202, "hook queues before expiry")
    local expiring_claim = ok(call("bee.gateway.binding:hook_claim", {binding_id = expiring_binding, carrier_epoch = 1, limit = 1}), "claim before expiry")
    local expiring_id = tostring((expiring_claim.hooks :: {Object})[1].event_id)
    assert(expiring_id == tostring(header_of(expiring_headers, "X-Bee-Event")), "the expiring row was claimed")
    time.sleep("300ms")
    local expired_recovery = ok(call("bee.gateway.binding:hook_claim", {binding_id = expiring_binding, carrier_epoch = 2, limit = 1}), "reclaim after expiry")
    assert(#(expired_recovery.hooks :: {Object}) == 1 and tostring((expired_recovery.hooks :: {Object})[1].event_id) == expiring_id,
        "expiry retains and reclaims a claimed row")
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = expiring_binding, carrier_epoch = 2, event_ids = {expiring_id}}), "ack after expiry").acknowledged == 1,
        "the reclaimed expired row acknowledges normally")
    -- Drain during a wait: a helper drains while this wait is in flight; the
    -- wait returns a released outcome well before its own deadline, new
    -- admissions are refused, and a bounded read still finishes before the
    -- host's deadline.
    local before_drain = ok(call("bee.threads.service:get", {thread_id = THREAD}), "read head before drain")
    local drain_summary = before_drain.summary
    assert(type(drain_summary) == "table", "read the thread summary before the drain wait")
    local drain_cursor = tonumber((drain_summary :: Object).head_sequence)
    assert(drain_cursor and drain_cursor >= 4, "read the current head before the drain wait")
    assert(process.spawn("bee.gateway_probe:drainer", "bee:workers", "400ms"), "spawn drainer")
    local drain_started = time.now()
    local released = tool("act-d", token_d, "thread_wait", {after_sequence = drain_cursor, wait_ms = 4000})
    assert(released.ok == true and (released.value :: Object).status == "released" and (released.value :: Object).reason == "draining", "wait released by drain: " .. tostring(json.encode(released)))
    assert(time.now():sub(drain_started):milliseconds() < 3500, "release came before the wait's own deadline")
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-e", attempt_id = "att-e", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}})) == "UNAVAILABLE", "admission refused after drain")
    local late = tool("act-d", token_d, "thread_read", {cursor = 0})
    assert(late.ok == true, "bounded read finishes during drain")
    -- A new epoch fences every earlier binding and readiness.
    local reopened = ok(call("bee.gateway.binding:open", {address = ADDRESS}), "reopen")
    assert(reopened.epoch == 2, "second epoch")
    local stale = ok(call("bee.gateway.binding:ready", {binding_id = binding_d}), "ready after reopen")
    assert((stale.generation :: Object).epoch == 2 and stale.binding_valid == false, "earlier binding fenced by the new epoch")
    assert(select(1, rpc("act-d", token_d, "tools/list")) == 401, "earlier epoch token refused")
end
return {main = main}
