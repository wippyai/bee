-- MIT. Slice 1 of the gateway against the real listener and thread owner:
-- readiness, admission and revocation, thread_read, bounded read-only
-- authenticated thread_message append, replay and context
-- fencing, cross-attempt and expiry refusal, drain and epoch fencing.
-- It asserts and fails the boot; it prints nothing, so no token bytes can
-- reach captured output.
local bounds = require("bounds")
local funcs = require("funcs")
local access_probe = require("access_probe")
local http_client = require("http_client")
local json = require("json")
local base64 = require("base64")
local time = require("time")
local registry = require("registry")
local security = require("security")
local sql = require("sql")
local ACTOR = "bee.test.gateway"
local THREAD = "gateway-thread"
type Object = {[string]: unknown}
type HookPost = (string, string, unknown, string?) -> (number, string, unknown)
type HeaderOf = (unknown, string) -> string?
local ADDRESS = ""
local function endpoint(): string
    local selected, err = funcs.call("bee.gateway.binding:address", {})
    -- Auto-start services become ready asynchronously. Wait only for the
    -- reported starting state; a failed or missing service is an immediate error.
    for _ = 1, 100 do
        if not err or not tostring(err):find("gateway listener is starting", 1, true) then break end
        time.sleep("20ms")
        selected, err = funcs.call("bee.gateway.binding:address", {})
    end
    assert(not err and type(selected) == "table", "gateway endpoint: " .. tostring(err))
    local address = (assert(bounds.object(selected))).address
    assert(type(address) == "string" and (address):find("^127%.0%.0%.1:%d+$") and address ~= "127.0.0.1:0", "gateway endpoint address")
    return address
end
local function key(): string return "k-" .. tostring(time.now():unix_nano()) end
local function call(target: string, request: Object): Object
    local reply, err = funcs.call(target, request)
    assert(not err, target .. ": " .. tostring(err))
    return assert(bounds.object(reply))
end
local function ok(reply: Object, what: string): Object
    assert(reply.ok == true, what .. " failed: " .. tostring(type(reply.error) == "table" and (assert(bounds.object(reply.error))).message))
    return assert(bounds.object(reply.value))
end
local function code(reply: Object): string
    assert(reply.ok == false, "expected a refusal")
    return tostring((assert(bounds.object(reply.error))).code)
end
local function admit(action: string, ttl: integer?, carrier_epoch: integer?, tools: {string}?, workspace_id: string?): (string, string)
    local request: Object = {subject = ACTOR, action_id = action, attempt_id = action .. "-attempt", thread_id = THREAD, owner_incarnation = 1,
        carrier_epoch = carrier_epoch or 1, tools = tools or {"thread_read", "capabilities"}, ttl_ms = ttl or 60000}
    if workspace_id ~= nil then request.workspace_id = workspace_id end
    local value = ok(call("bee.gateway.binding:admit", request), "admit " .. action)
    local binding_id = tostring((assert(bounds.object(value.binding))).binding_id)
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
    return response.status_code, type(decoded) == "table" and (assert(bounds.object(decoded))) or nil
end
local function tool(action: string, token: string, name: string, arguments: Object): Object
    local status, reply = rpc(action, token, "tools/call", {name = name, arguments = arguments})
    assert(status == 200 and reply and reply.result, name .. " status " .. tostring(status))
    local result = assert(bounds.object(reply.result))
    local content = (assert(bounds.array(result.content)))[1]
    local text: unknown = json.decode(tostring(content.text))
    assert(type(text) == "table", name .. " returned no reply")
    return assert(bounds.object(text))
end
local function validate_output(value: unknown, schema_value: unknown, location: string)
    local schema = assert(bounds.object(schema_value))
    local kind = schema.type
    if kind == "object" then
        assert(type(value) == "table", location .. " must be an object")
        local object = assert(bounds.object(value))
        local properties = assert(bounds.object((schema.properties or {})))
        for _, name in ipairs(assert(bounds.ids(schema.required or {}))) do
            assert(object[name] ~= nil, location .. " is missing " .. name)
        end
        for name, child in pairs(object) do
            local child_schema = properties[name]
            assert(child_schema ~= nil or schema.additionalProperties ~= false, location .. " has unexpected " .. name)
            if child_schema ~= nil then validate_output(child, child_schema, location .. "." .. name) end
        end
    elseif kind == "array" then
        assert(type(value) == "table", location .. " must be an array")
        local item_schema = schema.items
        assert(item_schema ~= nil, location .. " has no item schema")
        for index, item in ipairs(assert(bounds.array(value))) do validate_output(item, item_schema, location .. "[" .. tostring(index) .. "]") end
    elseif kind == "string" then
        assert(type(value) == "string", location .. " must be a string")
    elseif kind == "integer" then
        assert(type(value) == "number" and value == math.floor(value), location .. " must be an integer")
    elseif kind == "boolean" then
        assert(type(value) == "boolean", location .. " must be a boolean")
    else
        error(location .. " has unsupported output schema type " .. tostring(kind))
    end
end
-- The real-harness MCP contract: tools/list validity, per-operation effects in
-- annotations, schema-valid calls, cursor paging, structured results with the
-- normalized error shape, and the authoring path of guide index, section,
-- example and bounded docs windows.
local function prove_mcp_contract(token: string)
    local init_status, init = rpc("act-a", token, "initialize")
    assert(init_status == 200 and init, "contract initialize")
    local capabilities = assert(bounds.object((assert(bounds.object(init.result))).capabilities))
    assert((assert(bounds.object(capabilities.tools))).listChanged == true, "tool list changes with trait selection")
    local _, catalog = rpc("act-a", token, "tools/list")
    assert(catalog, "contract tools/list")
    local entries = assert(bounds.array((assert(bounds.object(catalog.result))).tools))
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(entries) do
        local name = tostring(entry.name)
        seen[name] = true
        local schema = assert(bounds.object(entry.inputSchema))
        assert(type(schema) == "table" and type(schema.properties) == "table", name .. " inputSchema properties object")
        assert(type(entry.outputSchema) == "table", name .. " outputSchema")
        local annotations = assert(bounds.object(entry.annotations))
        assert(type(annotations.readOnlyHint) == "boolean", name .. " annotations")
    end
    assert(seen.thread_read and seen.capabilities, "admitted tools listed")
    local contract_token, _ = admit("contract-action", nil, 1, {"capabilities", "overlay", "docs", "delivery", "components"},
        string.rep("c", 32))
    local _, contract_list = rpc("contract-action", contract_token, "tools/list")
    local contracts = assert(bounds.array((assert(bounds.object(contract_list.result))).tools))
    local by_name: {[string]: Object} = {}
    for _, entry in ipairs(contracts) do by_name[tostring(entry.name)] = entry end
    local delivery = by_name.delivery
    assert(delivery and (assert(bounds.object(delivery.annotations))).readOnlyHint == false, "delivery stages versions, never read-only")
    local operations = assert(bounds.ids((assert(bounds.object((assert(bounds.object((assert(bounds.object(delivery.inputSchema))).properties))).operation))).enum))
    local preflighted = false
    for _, operation in ipairs(operations) do if operation == "preflight" then preflighted = true end end
    assert(preflighted, "delivery preflight without staging")
    local overlay = by_name.overlay
    assert(overlay and (assert(bounds.object(overlay.annotations))).readOnlyHint == false, "overlay mixes reads and writes")
    assert((assert(bounds.object((assert(bounds.object((assert(bounds.object(overlay.inputSchema))).properties))).section))).pattern ~= nil, "guide sections in schema")
    local components = by_name.components
    local request_schema = (assert(bounds.object((assert(bounds.object((assert(bounds.object(components.inputSchema))).properties))).request)))
    assert(type((assert(bounds.object(request_schema.properties))).component) == "table", "components per-operation fields")
    assert(type((assert(bounds.array((assert(bounds.object(components.inputSchema))).examples)))[1]) == "table", "components examples")
    -- The authoring path: a bare guide read is the short index with sections
    -- and no example; one section reads alone; the example is explicit.
    local index = tool("contract-action", contract_token, "overlay", {operation = "guide"})
    assert(index.ok == true, "guide index: " .. tostring(json.encode(index)))
    local index_value = assert(bounds.object(index.value))
    assert(type(index_value.document) == "string", "guide index document")
    assert(#(assert(bounds.array(index_value.sections))) >= 8, "guide section list")
    assert(index_value.example == nil, "guide index carries no example")
    local section = tool("contract-action", contract_token, "overlay", {operation = "guide", section = "delivery"})
    assert((assert(bounds.object(section.value))).section == "delivery" and type((assert(bounds.object(section.value))).text) == "string", "guide section")
    local example = tool("contract-action", contract_token, "overlay", {operation = "guide", include_example = true})
    assert(type((assert(bounds.object((assert(bounds.object(example.value))).example))).entries_json) == "string", "guide example on request")
    -- Docs windows honor the offset after section selection.
    local first = tool("contract-action", contract_token, "docs", {operation = "read", id = "toolkit", section = "lifecycle", limit = 400})
    local continued = tool("contract-action", contract_token, "docs", {operation = "read", id = "toolkit", section = "lifecycle", offset = 100, limit = 400})
    local first_offset = assert(bounds.object(first.value)).offset
    local continued_offset = assert(bounds.object(continued.value)).offset
    assert(type(first_offset) == "number" and type(continued_offset) == "number")
    assert(continued_offset == first_offset + 100, "docs section paging")
    -- The capability report names the admitted surface before authoring.
    local report = tool("contract-action", contract_token, "capabilities", {})
    local report_value = assert(bounds.object(report.value))
    assert(type(report_value.thread_id) == "string", "capability thread")
    assert(type(report_value.tools) == "table" and report_value.launch == nil, "capability tools")
    validate_output(report, by_name.capabilities.outputSchema, "capabilities result")
    local capability_schema = (assert(bounds.object((assert(bounds.object((assert(bounds.object(by_name.capabilities.outputSchema))).properties))).value)))
    local traits_schema = assert(bounds.object((assert(bounds.object(capability_schema.properties))).traits))
    assert(traits_schema.type == "array" and type(traits_schema.items) == "table", "capability traits are advertised as typed array items")
    assert(type((assert(bounds.object(report_value.authoring))).preflight_operation) == "string", "capability authoring path")
    -- A delivery without its frozen digest is refused before anything stages;
    -- a delivery for an unknown overlay fails in the normalized tool shape.
    local _, missing_digest = rpc("contract-action", contract_token, "tools/call", {name = "delivery", arguments = {operation = "request",
        source_overlay_id = "missing", version = "0.0.0"}})
    assert(missing_digest and (assert(bounds.object(missing_digest.error))).code == -32602, "delivery digest required")
    local _, refused = rpc("contract-action", contract_token, "tools/call", {name = "delivery", arguments = {operation = "request",
        source_overlay_id = "missing", version = "0.0.0", snapshot_digest = string.rep("0", 64)}})
    assert(refused and refused.result, "delivery refusal")
    local content = (assert(bounds.array((assert(bounds.object(refused.result))).content)))[1]
    local fault: unknown = json.decode(tostring(content.text))
    assert(type(fault) == "table" and (assert(bounds.object(fault))).ok == false, "delivery refusal shape")
    local structured = assert(bounds.object((assert(bounds.object(refused.result))).structuredContent))
    assert(type(structured) == "table" and (assert(bounds.object(structured.error))).code ~= nil, "delivery refusal structured error")
end
local function record(text: string)
    ok(call("bee.threads.binding:record", {thread_id = THREAD, idempotency_key = key(), kind = "message",
        body = {message_id = "m-" .. key(), message_kind = "request", recipient_ids = {}, content = {text = text}}}), "record")
end
local function prove_configuration_scope(address: string)
    local selected, scope_error = security.new_scope({})
    assert(selected and not scope_error, "configuration scope: " .. tostring(scope_error))
    local executor, executor_error = funcs.new():with_scope(selected)
    assert(executor and not executor_error, "configuration caller scope: " .. tostring(executor_error))
    local privileged_result, privileged_call_error = funcs.call("bee.gateway.probe:render_configuration", {address = address, action_id = "scope-render", privileged = true})
    assert(not privileged_call_error and type(privileged_result) == "table",
        "privileged configuration control call failed: " .. tostring(privileged_call_error))
    local privileged = assert(bounds.object(privileged_result))
    assert(privileged.placement_db_acquired == true, "privileged callee could not acquire placement database")
    assert(privileged.placement_executor_acquired == true, "privileged callee could not acquire placement executor")
    local result, call_error = executor:call("bee.gateway.probe:render_configuration", {address = address, action_id = "scope-render"})
    assert(result and not call_error, "configuration scope call: " .. tostring(call_error))
    assert(type(result) == "table", "configuration scope call returned a non-table")
    local value = assert(bounds.object(result))
    assert(value.placement_db_denied == true, "callee acquired placement database")
    assert(value.placement_executor_denied == true, "callee acquired placement executor")
    assert(value.placement_policy_denied == true, "callee recovered placement policy")
    assert(value.funcs_security_denied == true, "callee rebuilt a security scope")
    assert(value.scope_create_denied == true, "callee created a custom scope")
    assert(type(value.projection) == "table", "configuration projection must be a table")
    local projection = assert(bounds.object(value.projection))
    assert(projection.path == ".codex/config.toml", "unexpected rendered configuration path")
    assert(type(projection.content) == "string" and (projection.content):find("scope%-render", 1, false) ~= nil, "configuration did not render input")
    assert((projection.content):find("BEE_GATEWAY_TOKEN", 1, true) ~= nil, "rendered configuration omitted host destination")
end
local function prove_endpoint_call_scope()
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.gateway.security:address_call_policy", "bee.gateway.security:store_policy", "bee.gateway.security:execute_policy", "bee.security.gateway:gateway_tool_read_policy", "bee.security.gateway:gateway_tool_message_policy", "bee.security.gateway:gateway_tool_overlay_policy", "bee.security.gateway:gateway_tool_docs_policy"}) do
        local selected, err = security.policy(name)
        assert(selected ~= nil and err == nil, "endpoint policy unavailable")
        policies[#policies + 1] = selected
    end
    local scope = security.new_scope(policies)
    local actor = security.actor()
    assert(actor ~= nil, "probe actor missing")
    for _, target in ipairs({"bee.gateway.binding:address", "bee.threads.binding:read_after", "bee.threads.binding:record", "bee.gov.binding:overlay_call", "bee.docs.binding:call"}) do
        assert(scope:evaluate(actor, "funcs.call", target) == "allow", "endpoint cannot invoke its selected operation")
    end
    -- The docs tool reads the one embedded corpus and reaches no other volume.
    assert(scope:evaluate(actor, "fs.get", "bee:docs_corpus") == "allow", "docs corpus read is absent")
    assert(scope:evaluate(actor, "fs.get", "bee.env:workspace_root") ~= "allow", "docs policy reaches an unrelated filesystem")
    assert(scope:evaluate(actor, "registry.get", "bee.docs:corpus_ref") == "allow", "docs corpus reference is absent")
    assert(scope:evaluate(actor, "registry.get", "bee.env:workspace_root") ~= "allow", "docs policy reaches an unrelated registry entry")
    assert(scope:evaluate(actor, "bee.gov.overlay.read", "any-overlay") == "allow", "overlay read is absent")
    assert(scope:evaluate(actor, "bee.gov.overlay.write", "any-overlay") == "allow", "overlay write is absent")
    for _, target in ipairs({"bee.threads.binding:create", "bee.gateway.binding:materialize", "bee.hub.binding:call", "arbitrary:operation"}) do
        assert(scope:evaluate(actor, "funcs.call", target) ~= "allow", "endpoint can invoke an unrelated operation")
    end
end
local function configurable_surface(token_a: string)
    local configurable = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "configurable", attempt_id = "configurable-attempt",
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "measure_context"}, ttl_ms = 60000,
        surface = {tools = {{name = "measure_context", operation = "bee.gateway.probe:context_tool", description = "Read scoped context",
            policies = {"bee.gateway.probe:context_tool_policy", "bee.gateway.probe:replacement_policy"}, schema = {type = "object", additionalProperties = false}, annotations = {readOnlyHint = true}}},
            traits = {{id = "research:measure", title = "Measure", prompt = "Collect a baseline", tools = {"measure_context"}},
                {id = "research:compare", title = "Compare", prompt = "Compare measurements", tools = {"measure_context"}}},
            base_tools = {"thread_read"}, active_traits = {}, fixed_context = {project = "project-a"}, dynamic_keys = {"experiment"}}}), "configurable admission")
    local configurable_binding = tostring((assert(bounds.object(configurable.binding))).binding_id)
    local configurable_token = tostring(ok(materialize("configurable-attempt", 1, configurable_binding), "configurable credential").token)
    local _, disabled = rpc("configurable", configurable_token, "tools/call", {name = "measure_context", arguments = {}})
    assert(disabled and disabled.error ~= nil, "inactive trait exposed its tool")
    local selected = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 1,
        active_traits = {"research:measure", "research:compare"}, context = {experiment = "baseline"}})
    assert(selected.ok == true, "two-trait selection failed")
    local measured = tool("configurable", configurable_token, "call_tool", {name = "measure_context", arguments = {}})
    local measured_value = assert(bounds.object(measured.value))
    assert(measured.ok == true and measured_value.project == "project-a" and measured_value.experiment == "baseline", "native context was not delivered: " .. tostring(json.encode(measured)))
    assert(measured_value.can_read_gateway == false and measured_value.can_create_scope == false, "tool gained gateway authority")
    local attribution = assert(bounds.object(measured_value.binding))
    assert(attribution.binding_id == configurable_binding and attribution.thread_id == THREAD
        and attribution.action_id == "configurable" and attribution.attempt_id == "configurable-attempt", "tool received foreign binding attribution")
    local spoofed = tool("configurable", configurable_token, "session", {operation = "select", expected_revision = 2,
        active_traits = {"research:measure"}, context = {["bee.gateway.binding"] = {thread_id = "foreign"}}})
    assert(spoofed.ok == false, "caller replaced reserved binding attribution")
    local peer = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "context-peer", attempt_id = "context-peer-attempt",
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"measure_context"}, ttl_ms = 60000,
        surface = {tools = {{name = "measure_context", operation = "bee.gateway.probe:context_tool", description = "Read attribution",
            policies = {"bee.gateway.probe:context_tool_policy"}, schema = {type = "object", additionalProperties = false}, annotations = {readOnlyHint = true}}},
            traits = {}, base_tools = {"measure_context"}, active_traits = {}, fixed_context = {}, dynamic_keys = {}}}), "peer context admission")
    local peer_binding = tostring((assert(bounds.object(peer.binding))).binding_id)
    local peer_token = tostring(ok(materialize("context-peer-attempt", 1, peer_binding), "peer credential").token)
    local peer_result = tool("context-peer", peer_token, "measure_context", {})
    local peer_identity = assert(bounds.object((assert(bounds.object(peer_result.value))).binding))
    assert(peer_result.ok == true and peer_identity.binding_id == peer_binding and peer_binding ~= configurable_binding
        and peer_identity.action_id == "context-peer" and peer_identity.attempt_id == "context-peer-attempt", "same-subject bindings shared attribution")
    local original_again = tool("configurable", configurable_token, "measure_context", {})
    assert((assert(bounds.object((assert(bounds.object(original_again.value))).binding))).binding_id == configurable_binding, "peer call contaminated original attribution")
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
    assert(next(assert(bounds.object((assert(bounds.object(independent.value))).context))) == nil, "binding context leaked")
    local left = funcs.async("bee.gateway.probe:concurrent_call", endpoint(), configurable_token, "left")
    local right = funcs.async("bee.gateway.probe:concurrent_call", endpoint(), configurable_token, "right")
    assert(left and right, "concurrent calls did not start")
    local left_reply = left:response():receive()
    local right_reply = right:response():receive()
    local left_value = left_reply:data()
    local right_value = right_reply:data()
    assert(left_value.ok ~= right_value.ok, "concurrent selection had zero or two winners")
    local loser = left_value.ok and right_value or left_value
    assert(loser.error.code == "CONFLICT", "concurrent loser was not a revision conflict")
    local winner = tool("configurable", configurable_token, "session", {operation = "read"})
    assert((assert(bounds.object(winner.value))).revision == 3, "concurrent update advanced twice")
    ok(call("bee.gateway.binding:reissue", {binding_id = configurable_binding, expected_generation = 1}), "rotate configurable credential")
    local old_status = rpc("configurable", configurable_token, "tools/call", {name = "session", arguments = {operation = "read"}})
    assert(old_status == 401, "rotated token retained selection access")
    configurable_token = tostring(ok(materialize("configurable-attempt", 1, configurable_binding), "renew configurable credential").token)
    local retained = tool("configurable", configurable_token, "session", {operation = "read"})
    local retained_value, winner_value = assert(bounds.object(retained.value)), assert(bounds.object(winner.value))
    assert(retained_value.revision == winner_value.revision, "credential rotation changed selection revision")
    assert((assert(bounds.object(retained_value.context))).experiment == (assert(bounds.object(winner_value.context))).experiment, "credential rotation lost dynamic context")
    assert(json.encode(retained_value.active_traits) == json.encode(winner_value.active_traits), "credential rotation lost active traits")
    local after_rotation = tool("configurable", configurable_token, "measure_context", {})
    assert(after_rotation.ok == true and (assert(bounds.object(after_rotation.value))).project == "project-a", "credential rotation lost fixed context or dispatch")
    assert((assert(bounds.object(after_rotation.value))).replacement_granted == false, "ungranted replacement action was allowed")
    local policy_entry = registry.get("bee.gateway.probe:replacement_policy")
    if not policy_entry then error("replacement fixture policy missing") end
    policy_entry.data = {policy = {actions = {"bee.probe.replacement"}, resources = {"sentinel"}, effect = "allow"}}
    local changes = registry.snapshot():changes()
    changes:update(policy_entry)
    local applied, apply_error = changes:apply()
    assert(applied, "fixture policy replacement failed: " .. tostring(apply_error))
    local observed = false
    for _ = 1, 100 do
        local current = tool("configurable", configurable_token, "measure_context", {})
        if current.ok == true and (assert(bounds.object(current.value))).replacement_granted == true then observed = true; break end
        time.sleep("10ms")
    end
    assert(observed, "same binding did not observe native policy replacement")
    ok(call("bee.gateway.binding:revoke", {binding_id = configurable_binding}), "revoke configurable binding")
    local revoked_status = rpc("configurable", configurable_token, "tools/call", {name = "measure_context", arguments = {}})
    assert(revoked_status == 401, "revoked configurable binding executed")
end
local function prove_corrupt_hooks(hook_post: HookPost, header_of: HeaderOf)
    local corrupt = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-corrupt-hooks", attempt_id = "act-corrupt-hooks-attempt",
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"Stop"}, ttl_ms = 60000}), "admit corrupt hook probe")
    local binding_id = tostring((assert(bounds.object(corrupt.binding))).binding_id)
    local tokens = ok(materialize("act-corrupt-hooks-attempt", 1, binding_id), "materialize corrupt hook probe")
    local status, _, headers = hook_post("act-corrupt-hooks", tostring(tokens.hook_token),
        {hook_event_name = "Stop", session_id = "corrupt", prompt_id = "corrupt-prompt", stop_hook_active = false})
    assert(status == 202, "valid hook queues before storage corruption")
    local event_id = tostring(header_of(headers, "X-Bee-Event"))
    local database, database_error = sql.get("bee.gateway:db")
    assert(database and not database_error, "open gateway store for corruption probe: " .. tostring(database_error))
    local _, write_error = database:execute("UPDATE bee_gateway_hooks SET fields_json = ? WHERE event_id = ?", {"not-json", event_id})
    database:release()
    assert(not write_error, "corrupt stored hook fields")
    assert(code(call("bee.gateway.binding:hook_queue", {binding_id = binding_id})) == "STORAGE", "hook_queue rejects malformed stored fields_json")
    assert(code(call("bee.gateway.binding:hook_claim", {binding_id = binding_id, carrier_epoch = 1, limit = 1})) == "STORAGE",
        "hook_claim rejects malformed stored fields_json")
end
-- A launcher reaches a child it started on a new thread. The orchestrator's
-- binding is on THREAD; a separate child thread it owns (created and admitted
-- under its own actor, as thread_launch does for a caller-thread definition on
-- a new thread) is reachable by naming it as member_thread on thread_read and
-- thread_read. An unrelated thread the caller is not a member of is refused,
-- and the bound thread still works with no member_thread.
local function prove_child_thread()
    local child = "child-thread"
    ok(call("bee.threads.binding:create", {thread_id = child, idempotency_key = key(), title = "Child work"}), "create child thread")
    ok(call("bee.threads.binding:record", {thread_id = child, idempotency_key = key(), kind = "message",
        body = {message_id = "child-note", message_kind = "progress", recipient_ids = {}, content = {text = "child progress"}}}), "record on child thread")
    local token, _ = admit("child-launcher", nil, 1, {"thread_read"})
    local member = tool("child-launcher", token, "thread_read", {cursor = 0, member_thread = child})
    assert(member.ok == true, "a launched child thread was not readable as member_thread: " .. tostring(json.encode(member)))
    local child_records = assert(bounds.array((assert(bounds.object(member.value))).records))
    assert(#child_records == 1 and ((assert(bounds.object((assert(bounds.object(child_records[1].body))).content))).text) == "child progress", "member_thread read the wrong thread")
    local bound = tool("child-launcher", token, "thread_read", {cursor = 0})
    assert(bound.ok == true, "the bound thread was not readable without member_thread")
    assert((assert(bounds.object(bound.value))).records ~= nil and (assert(bounds.object((assert(bounds.array((assert(bounds.object(bound.value))).records)))[1]))).thread_id ~= child, "no member_thread read the bound thread, not the child")
    -- A thread this caller does not belong to is refused, never silently
    -- redirected to the bound thread. The foreign thread is owned by a
    -- different actor, so membership really does deny it.
    local foreign = "foreign-thread"
    local other = security.new_actor("bee.test.gateway.other", {})
    assert(other, "construct the foreign actor")
    local created, create_error = funcs.new():with_actor(other):call("bee.threads.binding:create",
        {thread_id = foreign, idempotency_key = key(), title = "Someone else"})
    assert(not create_error and type(created) == "table" and (assert(bounds.object(created))).ok == true,
        "create foreign thread: " .. tostring(create_error or json.encode(created)))
    local refused_read = tool("child-launcher", token, "thread_read", {cursor = 0, member_thread = foreign})
    assert(refused_read.ok == false and (assert(bounds.object(refused_read.error))).code == "NOT_FOUND", "an unrelated member_thread was not refused")
end

local function main()
    prove_endpoint_call_scope()
    ADDRESS = endpoint()
    prove_configuration_scope(ADDRESS)
    local opened = ok(call("bee.gateway.binding:open", {address = ADDRESS}), "open")
    assert(opened.epoch == 1, "first epoch")
    ok(call("bee.threads.binding:create", {thread_id = THREAD, idempotency_key = key(), title = "Gateway"}), "create")
    for index = 1, 3 do record("line " .. tostring(index)) end
    local token_a, binding_a = admit("act-a")
    local readiness_response, readiness_error = http_client.get("http://" .. ADDRESS .. "/ready", {timeout = "2s", query = {nonce = "fixture-readiness"}})
    assert(readiness_response, "readiness request: " .. tostring(readiness_error))
    if readiness_response.status_code ~= 200 then error("readiness refused: " .. tostring(readiness_response.body)) end
    local ready = ok(call("bee.gateway.binding:ready", {binding_id = binding_a}), "ready")
    assert(ready.listening == true and (assert(bounds.object(ready.generation))).epoch == 1, "readiness under epoch 1")
    assert(ready.binding_valid == true, "binding A valid")
    local status, init = rpc("act-a", token_a, "initialize")
    assert(status == 200 and init and (assert(bounds.object(init.result))).protocolVersion ~= nil, "initialize")
    local _, listed = rpc("act-a", token_a, "tools/list")
    assert(listed and #(assert(bounds.array((assert(bounds.object(listed.result))).tools))) == 4, "two admitted tools and MCP controls advertised")
    prove_mcp_contract(token_a)
    access_probe.run(ADDRESS)
    configurable_surface(token_a)
    local page = tool("act-a", token_a, "thread_read", {cursor = 0})
    assert(page.ok == true, "thread_read refused: " .. tostring(json.encode(page)))
    assert(#(assert(bounds.array((assert(bounds.object(page.value))).records))) == 3, "thread_read returned the three records: " .. tostring(json.encode(page)))
    -- A managed subject authors through the same authenticated endpoint. The
    -- workspace owner remains the subject; neither thread binding fields nor
    -- publication/activation authority enter the request.
    do
    local workspace_token, workspace_binding = admit("workspace-action", nil, 1, {"overlay"})
    local created = tool("workspace-action", workspace_token, "overlay", {operation = "create", overlay_id = "gateway-research",
        expected_revision = 0, idempotency_key = "create"})
    assert(created.ok == true and (assert(bounds.object(created.value))).revision == 1, "MCP overlay create failed")
    local put_arguments: Object = {operation = "put", overlay_id = "gateway-research", expected_revision = 1,
        idempotency_key = "finding", path = "findings/one.md", content = "measured evidence"}
    local put = tool("workspace-action", workspace_token, "overlay", put_arguments)
    assert(put.ok == true and (assert(bounds.object(put.value))).revision == 2, "MCP overlay put failed")
    local put_replay = tool("workspace-action", workspace_token, "overlay", put_arguments)
    assert(put_replay.ok == true and put_replay.replayed == true and (assert(bounds.object(put_replay.value))).revision == 2,
        "MCP overlay retry was not idempotent")
    local frozen = tool("workspace-action", workspace_token, "overlay", {operation = "freeze", overlay_id = "gateway-research",
        expected_revision = 2, idempotency_key = "freeze"})
    assert(frozen.ok == true and type((assert(bounds.object(frozen.value))).digest) == "string", "MCP overlay freeze failed")
    local source = string.rep("local measurement = 1\n", 1024)
    local large_created = tool("workspace-action", workspace_token, "overlay", {operation = "create", overlay_id = "gateway-large-source",
        expected_revision = 0, idempotency_key = "create-large"})
    assert(large_created.ok == true, "large source workspace create failed")
    local large_put = tool("workspace-action", workspace_token, "overlay", {operation = "put", overlay_id = "gateway-large-source",
        expected_revision = 1, idempotency_key = "put-large", path = "app.lua", content = source})
    assert(large_put.ok == true, "app-size source refused over HTTP")
    local tail = string.rep("local measurement = 2\n", 2200)
    local large_append = tool("workspace-action", workspace_token, "overlay", {operation = "append", overlay_id = "gateway-large-source",
        expected_revision = 2, idempotency_key = "append-large", path = "app.lua", offset = #source, content = tail})
    assert(large_append.ok == true and (assert(bounds.object(large_append.value))).revision == 3, "app-size append refused over HTTP")
    local complete = source .. tail
    local parts: {string} = {}
    local offset = 0
    local ended = false
    repeat
        local page = tool("workspace-action", workspace_token, "overlay", {operation = "read", overlay_id = "gateway-large-source",
            path = "app.lua", offset = offset})
        assert(page.ok == true and (assert(bounds.object(page.value))).bytes == #complete, "app-size source was truncated")
        local value = assert(bounds.object(page.value))
        local decoded = assert(base64.decode(tostring(value.content_base64)))
        parts[#parts + 1] = decoded
        offset = offset + #decoded
        if value.eof then ended = true; break end
    until offset >= #complete
    assert(ended, "app-size source read did not reach EOF")
    assert(table.concat(parts) == complete, "app-size source changed during HTTP authoring")
    local _, oversized = rpc("workspace-action", workspace_token, "tools/call", {name = "overlay", arguments = {
        operation = "put", overlay_id = "gateway-large-source", expected_revision = 2,
        idempotency_key = "too-large", path = "app.lua", content = string.rep("x", 65537)}})
    assert(oversized and oversized.error, "oversized workspace source was admitted")
    local body_status = rpc("workspace-action", workspace_token, "ping", {padding = string.rep("x", 524288)})
    assert(body_status == 400, "whole MCP body limit was not enforced")
    local unchanged = tool("workspace-action", workspace_token, "overlay", {operation = "list", overlay_id = "gateway-large-source"})
    assert(unchanged.ok == true and (assert(bounds.object(unchanged.value))).revision == 3, "refused oversized request changed the workspace")
    local foreign_admission = ok(call("bee.gateway.binding:admit", {subject = "foreign-workspace-subject", action_id = "foreign-workspace-action",
        attempt_id = "foreign-workspace-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1,
        tools = {"overlay"}, ttl_ms = 60000}), "admit foreign workspace actor")
    local foreign_workspace_binding = tostring((assert(bounds.object(foreign_admission.binding))).binding_id)
    local foreign_workspace_token = tostring(ok(materialize("foreign-workspace-attempt", 1, foreign_workspace_binding), "materialize foreign workspace actor").token)
    local foreign_workspace = tool("foreign-workspace-action", foreign_workspace_token, "overlay", {operation = "list", overlay_id = "gateway-research"})
    local foreign_fault = type(foreign_workspace.error) == "table" and (assert(bounds.object(foreign_workspace.error))).code or foreign_workspace.code
    assert(foreign_workspace.ok == false and foreign_fault == "DENIED",
        "foreign MCP actor read another workspace: " .. tostring(json.encode(foreign_workspace)))
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
    local replayed = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "capabilities"}, ttl_ms = 60000}), "replay admission")
    assert(replayed.replayed == true and (assert(bounds.object(replayed.binding))).binding_id == binding_a, "same admission replays the live binding")
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "a different admission at the same epoch conflicts")
    -- A later carrier epoch's admission supersedes the earlier binding of the same attempt.
    local superseding = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 2, tools = {"thread_read"}, ttl_ms = 60000}), "admit under epoch 2")
    assert((assert(bounds.object(superseding.binding))).binding_id ~= binding_a, "a new binding")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "the superseded binding's token is refused")
    local superseded = ok(call("bee.gateway.binding:check", {binding_id = binding_a}), "check superseded")
    assert(superseded.valid == false and tostring(superseded.reason) == "binding is revoked", "superseded binding is revoked")
    binding_a = tostring((assert(bounds.object(superseding.binding))).binding_id)
    token_a = tostring(ok(materialize("act-a-attempt", 2, binding_a), "materialize under epoch 2").token)
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "the superseding binding's token works")
    -- A delayed admission under an epoch below the highest ever admitted for
    -- the attempt is refused, so no second live binding can appear.
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "stale admission refused")
    ok(call("bee.gateway.binding:revoke", {binding_id = binding_a}), "revoke the epoch 2 binding")
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "stale admission refused even with the newer binding revoked")
    local reopened_a = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 3, tools = {"thread_read", "capabilities"}, ttl_ms = 60000}), "admit under epoch 3")
    binding_a = tostring((assert(bounds.object(reopened_a.binding))).binding_id)
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
    assert(narrow_status == 200 and #(assert(bounds.array((assert(bounds.object((assert(bounds.object(narrow_reply))).result))).tools))) == 4, "the probe admits both tools and MCP controls")
    local admitted_only = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-i", attempt_id = "act-i-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000}), "admit read only")
    local token_i = tostring(ok(materialize("act-i-attempt", 1, tostring((assert(bounds.object(admitted_only.binding))).binding_id)), "materialize read only").token)
    local listed_status, listed = rpc("act-i", token_i, "tools/list")
    assert(listed_status == 200 and #(assert(bounds.array((assert(bounds.object((assert(bounds.object(listed))).result))).tools))) == 3, "only the admitted tool and MCP controls are advertised")
    local refused_status, refused = rpc("act-i", token_i, "tools/call", {name = "docs", arguments = {operation = "list"}})
    assert(refused_status == 200 and refused and refused.error ~= nil and tostring((assert(bounds.object((assert(bounds.object(refused))).error))).message):find("not admitted", 1, true), "a tool outside the binding is refused")
    local refused_message_status, refused_message = rpc("act-i", token_i, "tools/call", {name = "thread_message", arguments = {idempotency_key = "read-only-message", message_id = "read-only-message", message_kind = "notification", content = {text = "no"}}})
    assert(refused_message_status == 200 and refused_message and refused_message.error ~= nil and tostring((assert(bounds.object((assert(bounds.object(refused_message))).error))).message):find("not admitted", 1, true), "a read-only binding admitted a write")
    local foreign_admission = ok(call("bee.gateway.binding:admit", {subject = "foreign-subject", action_id = "foreign-action", attempt_id = "foreign-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_message"}, ttl_ms = 60000}), "admit non-member message")
    local foreign_binding = tostring((assert(bounds.object(foreign_admission.binding))).binding_id)
    local foreign_token = tostring(ok(materialize("foreign-attempt", 1, foreign_binding), "materialize non-member message").token)
    local foreign_message = tool("foreign-action", foreign_token, "thread_message", {idempotency_key = "foreign-message", message_id = "foreign-message", message_kind = "notification", content = {text = "no"}})
    assert(foreign_message.ok == false and type(foreign_message.error) == "table" and (assert(bounds.object(foreign_message.error))).code == "DENIED", "a non-member message sender was accepted")
    -- A token bound to another action is refused on this action, and vice versa.
    local token_b = admit("act-b")
    assert(select(1, rpc("act-a", token_b, "tools/list")) == 403, "cross-attempt token refused")
    assert(select(1, rpc("act-b", token_a, "tools/list")) == 403, "cross-attempt token refused the other way")
    -- An expired token is refused.
    local token_c = admit("act-c", 2000)
    local before_expiry_status, before_expiry = rpc("act-c", token_c, "tools/list")
    assert(before_expiry_status == 200, "token works before expiry: " .. tostring(before_expiry_status) .. " " .. tostring(json.encode(before_expiry)))
    time.sleep("2050ms")
    assert(select(1, rpc("act-c", token_c, "tools/list")) == 401, "expired token refused")
    -- A revoked token is refused.
    ok(call("bee.gateway.binding:revoke", {binding_id = binding_a}), "revoke")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "revoked token refused")
    -- Viewing is read-only: reading the bound thread touches no delivery mark.
    local token_d, binding_d = admit("act-d")
    record("line 4")
    assert(tool("act-d", token_d, "thread_read", {cursor = 0}).ok == true, "read the bound thread")
    local marks = ok(call("bee.threads.binding:read_after", {thread_id = THREAD, cursor = 0, filter = {kinds = {"delivery.mark"}}}), "read marks")
    assert(#(assert(bounds.array(marks.records))) == 0, "viewing wrote a delivery mark")
    do
    -- thread_message is an explicitly admitted write. Its arguments contain
    -- only the message and a stable key; the endpoint supplies the thread,
    -- authenticated sender, fixed kind and action/attempt context.
    ok(call("bee.threads.binding:admit_action", {thread_id = THREAD, idempotency_key = key(), action_id = "mcp-action",
        admitted = {request_id = "mcp-request", principal_id = ACTOR, binding_ref = "mcp-binding", binding_digest = "mcp-digest", grant_refs = {}, budget_ref = "mcp-budget", input = {text = "mcp"}}}), "admit MCP action")
    ok(call("bee.threads.binding:prepare_attempt", {thread_id = THREAD, idempotency_key = key(), action_id = "mcp-action", attempt_id = "mcp-attempt",
        prepared = {binding_ref = "mcp-binding", binding_digest = "mcp-digest", profile_id = "mcp-profile", profile_digest = "mcp-profile-digest", placement_binding = "mcp-placement", placement_attempt_id = "mcp-placement-attempt", plan_digest = "mcp-plan"}}), "prepare MCP attempt")
    local mcp_admit = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "mcp-action", attempt_id = "mcp-attempt", thread_id = THREAD,
        owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_message"}, ttl_ms = 60000}), "admit MCP message")
    local mcp_binding = tostring((assert(bounds.object(mcp_admit.binding))).binding_id)
    local mcp_token = tostring(ok(materialize("mcp-attempt", 1, mcp_binding), "materialize MCP message").token)
    local message_arguments: Object = {idempotency_key = "mcp-message-key", message_id = "mcp-message", message_kind = "notification", content = {text = "from authenticated MCP"}}
    local appended = tool("mcp-action", mcp_token, "thread_message", message_arguments)
    assert(appended.ok == true and type(appended.value) == "table", "thread_message append refused: " .. tostring(json.encode(appended)))
    local appended_value = assert(bounds.object(appended.value))
    local replay = tool("mcp-action", mcp_token, "thread_message", message_arguments)
    assert(replay.ok == true and replay.replayed == true and (assert(bounds.object(replay.value))).record_id == appended_value.record_id and (assert(bounds.object(replay.value))).sequence == appended_value.sequence,
        "identical thread_message replay duplicated or changed the result")
    local changed_arguments: Object = {idempotency_key = "mcp-message-key", message_id = "mcp-message", message_kind = "notification", content = {text = "changed"}}
    local changed = tool("mcp-action", mcp_token, "thread_message", changed_arguments)
    assert(changed.ok == false and (assert(bounds.object(changed.error))).code == "CONFLICT", "changed thread_message replay was accepted")
    local contextual = ok(call("bee.threads.binding:read_after", {thread_id = THREAD, cursor = 0, filter = {action_id = "mcp-action"}}), "read MCP append")
    local message_records = 0
    for _, item in ipairs(assert(bounds.array(contextual.records))) do
        local item = assert(bounds.object(item))
        if item.kind == "message" then
            message_records = message_records + 1
            assert(item.thread_id == THREAD and item.producer_id == ACTOR and item.action_id == "mcp-action" and item.attempt_id == "mcp-attempt", "MCP append context was not bound")
            assert((assert(bounds.object(item.body))).sender_id == ACTOR, "MCP sender was not authenticated")
        end
    end
    assert(message_records == 1, "replayed thread_message created a duplicate record")
    local _, foreign_thread = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "foreign-thread", message_id = "foreign-thread", message_kind = "notification", content = {text = "no"}, thread_id = "other-thread"}})
    assert(foreign_thread and foreign_thread.error and tostring((assert(bounds.object(foreign_thread.error))).message):find("unknown field thread_id", 1, true), "foreign thread override was accepted")
    local _, foreign_sender = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "foreign-sender", message_id = "foreign-sender", message_kind = "notification", content = {text = "no"}, sender_id = "foreign"}})
    assert(foreign_sender and foreign_sender.error and tostring((assert(bounds.object(foreign_sender.error))).message):find("unknown field sender_id", 1, true), "foreign producer override was accepted")
    local _, foreign_context = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "foreign-context", message_id = "foreign-context", message_kind = "notification", content = {text = "no"}, context = {action_id = "other-action"}}})
    assert(foreign_context and foreign_context.error and tostring((assert(bounds.object(foreign_context.error))).message):find("unknown field context", 1, true), "foreign context override was accepted")
    local _, arbitrary_record = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = {idempotency_key = "arbitrary-record", kind = "receipt", message_id = "arbitrary-record", message_kind = "notification", content = {text = "no"}}})
    assert(arbitrary_record and arbitrary_record.error and tostring((assert(bounds.object(arbitrary_record.error))).message):find("unknown field kind", 1, true), "arbitrary record kind was accepted")
    for _, field in ipairs({"session", "recipient_ids", "member_thread", "in_reply_to"}) do
        local addressed: Object = {idempotency_key = "note-" .. field, message_id = "note-" .. field, message_kind = "progress", content = {text = "no"}}
        addressed[field] = "x"
        local _, refused_field = rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = addressed})
        assert(refused_field and refused_field.error and tostring((assert(bounds.object(refused_field.error))).message):find("unknown field " .. field, 1, true), "a note accepted " .. field)
    end
    local settled = ok(call("bee.threads.binding:read_after", {thread_id = THREAD, cursor = 0, filter = {kinds = {"receipt"}, action_id = "mcp-action"}}), "read MCP receipts")
    assert(#(assert(bounds.array(settled.records))) == 0, "thread_message settled an attempt")
    ok(call("bee.gateway.binding:revoke", {binding_id = mcp_binding}), "revoke MCP message binding")
    assert(select(1, rpc("mcp-action", mcp_token, "tools/call", {name = "thread_message", arguments = message_arguments})) == 401, "revoked thread_message token was accepted")
    end
    prove_child_thread()
    -- Hooks: a binding that admits hook events gets a second credential of
    -- its own kind; neither credential opens the other endpoint.
    local function header_of(headers: unknown, name: string): string?
        if type(headers) ~= "table" then return nil end
        for key, value in pairs(assert(bounds.object(headers))) do
            if tostring(key):lower() == name:lower() then
                if type(value) == "table" then return tostring((assert(bounds.array(value)))[1]) end
                return tostring(value)
            end
        end
        return nil
    end
    local function hook_post(action: string, token: string, body: unknown, path: string?): (number, string, unknown)
        local encoded = type(body) == "string" and body or (json.encode(body) or "{}")
        local response, err = http_client.post("http://" .. ADDRESS .. "/hook/" .. action .. (path or ""), {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = encoded, timeout = "8s"})
        assert(response, "hook post: " .. tostring(err))
        return response.status_code, tostring(response.body or ""), response.headers
    end
    local function hook_get(action: string, token: string, event_id: string): (number, Object?)
        local response, err = http_client.get("http://" .. ADDRESS .. "/hook/" .. action .. "/" .. event_id, {headers = {Authorization = "Bearer " .. token}, timeout = "8s"})
        assert(response, "hook get: " .. tostring(err))
        local decoded: unknown = json.decode(tostring(response.body))
        return response.status_code, type(decoded) == "table" and (assert(bounds.object(decoded))) or nil
    end
    local hook_admit = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-k", attempt_id = "act-k-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"},
        hooks = {"PreToolUse", "PostToolUse", "Stop", "SessionStart"}, ttl_ms = 60000}), "admit with hooks")
    local binding_k = tostring((assert(bounds.object(hook_admit.binding))).binding_id)
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
    local queued_list = assert(bounds.array(queue.hooks))
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
        return response.status_code, type(decoded) == "table" and (assert(bounds.object(decoded))) or nil
    end
    assert(select(1, hook_rpc(token_k, "tools/list")) == 401, "the tool credential is refused on the MCP hook endpoint")
    local listed_status, listed_hook = hook_rpc(hook_k, "tools/list")
    assert(listed_status == 200 and #(assert(bounds.array((assert(bounds.object((assert(bounds.object(listed_hook))).result))).tools))) == 1, "the MCP hook endpoint serves one tool")
    local engine_status, engine_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_1", tool_name = "mcp__bee__thread_read", tool_response = {content = {}}}, _meta = {threadId = "s2", progressToken = 1}})
    assert(engine_status == 200 and engine_reply and engine_reply.result ~= nil, "a hook-engine shaped call is accepted")
    -- Codex joins the tool's text content into hook stdout and reads it with
    -- command-hook semantics: plain text is invalid Stop output and becomes
    -- model context for other events. An observer answers no text at all and
    -- carries its receipt as structured content.
    local engine_result = assert(bounds.object((assert(bounds.object(engine_reply))).result))
    assert(#(assert(bounds.array(engine_result.content))) == 0, "the MCP answer carries no hook stdout: " .. tostring(json.encode(engine_result)))
    local engine_receipt = assert(bounds.object(engine_result.structuredContent))
    assert(engine_receipt and engine_receipt.status == "queued" and type(engine_receipt.event_id) == "string", "the receipt is structured: " .. tostring(json.encode(engine_result)))
    local stop_status, stop_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "Stop", session_id = "s2", turn_id = "t1", last_assistant_message = "done"}, _meta = {threadId = "s2", progressToken = 2}})
    local stop_result = stop_reply and assert(bounds.object((assert(bounds.object(stop_reply))).result)) or nil
    assert(stop_status == 200 and stop_result and #(assert(bounds.array(stop_result.content))) == 0 and stop_result.isError == false, "a Stop hook answers no stdout: " .. tostring(json.encode(stop_reply)))
    local _, model_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_2"}, _meta = {callId = "call_2", ["x-codex-turn-metadata"] = {turn_id = "t1"}}})
    assert(model_reply and model_reply.error ~= nil and tostring((assert(bounds.object((assert(bounds.object(model_reply))).error))).message):find("(model)", 1, true), "a model shaped call is refused")
    local _, mixed_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_3"}, _meta = {threadId = "s2", callId = "call_3"}})
    assert(mixed_reply and mixed_reply.error ~= nil and tostring((assert(bounds.object((assert(bounds.object(mixed_reply))).error))).message):find("(mixed)", 1, true), "a mixed metadata call is refused")
    local _, bare_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_4"}})
    assert(bare_reply and bare_reply.error ~= nil and tostring((assert(bounds.object((assert(bounds.object(bare_reply))).error))).message):find("(unclassified)", 1, true), "a call without metadata is refused")
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
    local lost_list = assert(bounds.array(lost_claim.hooks))
    assert(#lost_list == 3 and lost_list[1].event_id == event_1, "the first three queued submissions are claimed in order")
    local claimed = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 1, limit = 3}), "recover lost claim reply")
    local claimed_list = assert(bounds.array(claimed.hooks))
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
    assert(#(assert(bounds.object((assert(bounds.array(progressed_claim.hooks))) == 3 and (assert(bounds.array(progressed_claim.hooks)))[1]))).event_id ~= event_1,
        "acknowledgment advances the next bounded claim")
    -- Sealing ends intake at once and keeps the accepted rows for the carrier.
    local pre_seal = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "queue before seal")
    ok(call("bee.gateway.binding:seal", {binding_id = binding_k}), "seal")
    local sealed_status, sealed_body = hook_post("act-k", hook_k, {hook_event_name = "PreToolUse", session_id = "s9", tool_use_id = "toolu_after_seal", tool_name = "Bash"})
    assert(sealed_status == 403 and sealed_body:find("sealed", 1, true), "a submission after the seal is refused: " .. tostring(sealed_status) .. " " .. sealed_body)
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 200, "a replay of a committed submission still answers after the seal")
    assert(select(1, rpc("act-k", token_k, "tools/list")) == 200, "the seal leaves the tool credential valid")
    local post_seal = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "queue after seal")
    assert(#(assert(bounds.array(post_seal.hooks))) == #(assert(bounds.array(pre_seal.hooks))), "the seal discards nothing accepted")
    local taken_over = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 3, limit = 2}), "claim under a higher epoch")
    assert(#(assert(bounds.array(taken_over.hooks))) == 2, "a higher epoch takes over rows a lower epoch claimed, sealed or not")
    local stale_ack = ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = {(assert(bounds.object((assert(bounds.array(taken_over.hooks)))[1]))).event_id}}), "stale ack")
    assert(stale_ack.acknowledged == 0, "a lower epoch cannot acknowledge what a higher one claimed")
    local unclaimed_ack = ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 3, event_ids = {(assert(bounds.object((assert(bounds.array(progressed_claim.hooks)))[3]))).event_id}}), "ack without claim")
    assert(unclaimed_ack.acknowledged == 0, "an epoch that did not take over a row cannot acknowledge it")
    local admitted_higher = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-k", attempt_id = "act-k-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 4, tools = {"thread_read"}, hooks = {"Stop", "PreToolUse"}, ttl_ms = 60000}), "admit act-k under epoch 4")
    assert(code(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 3})) == "CONFLICT", "a claim below the highest admitted epoch is refused")
    assert(code(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 3, event_ids = {(assert(bounds.object((assert(bounds.array(taken_over.hooks)))[1]))).event_id}})) == "CONFLICT",
        "an old claim cannot acknowledge after the replacement admission")
    local superseded_queue = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k}), "superseded queue")
    local rejected_count, committed_count, retained_claimed = 0, 0, 0
    for _, item in ipairs(assert(bounds.array(superseded_queue.hooks))) do
        local item = assert(bounds.object(item))
        if item.status == "rejected" then rejected_count = rejected_count + 1; assert(item.rejected_reason == "binding superseded", "rejection names its reason") end
        if item.status == "committed" then committed_count = committed_count + 1 end
        if item.status == "queued" and (tonumber(item.claimed_epoch) or 0) > 0 then retained_claimed = retained_claimed + 1 end
    end
    assert(committed_count == 3 and rejected_count > 0 and retained_claimed > 0,
        "supersession rejects unclaimed rows, keeps committed rows and retains claimed uncertainty: " .. tostring(committed_count) .. " " .. tostring(rejected_count) .. " " .. tostring(retained_claimed))
    local recovered_after_supersession = ok(call("bee.gateway.binding:hook_claim", {binding_id = binding_k, carrier_epoch = 4, limit = 3}), "reclaim superseded claims")
    assert(#(assert(bounds.array(recovered_after_supersession.hooks))) > 0, "the current carrier reclaims a superseded claimed row")
    local recovered_id = tostring((assert(bounds.object((assert(bounds.array(recovered_after_supersession.hooks)))[1]))).event_id)
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k, carrier_epoch = 4, event_ids = {recovered_id}}), "ack reclaimed superseded row").acknowledged == 1,
        "a replacement can acknowledge a retained claim")
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 401, "the superseded binding's hook credential is refused")
    local binding_k4 = tostring((assert(bounds.object(admitted_higher.binding))).binding_id)
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
    local claimed_item = (assert(bounds.array(claimed_for_commit.hooks)))[1]
    local claimed_for_commit_id = tostring(claimed_item.event_id)
    assert(claimed_for_commit_id == tostring(header_of(claimed_headers, "X-Bee-Event")), "the row held across revoke was claimed first")
    -- Commit the claimed hook through the actual fenced carrier API, then
    -- deliberately omit its gateway acknowledgment. This is the durable
    -- uncertainty retention must preserve across revocation.
    ok(call("bee.threads.binding:admit_action", {thread_id = THREAD, idempotency_key = key(), action_id = "act-k",
        admitted = {request_id = "act-k-request", principal_id = ACTOR, binding_ref = "act-k-binding", binding_digest = "act-k-digest", grant_refs = {}, budget_ref = "act-k-budget", input = {text = "hook recovery"}}}), "admit hook action")
    ok(call("bee.threads.binding:prepare_attempt", {thread_id = THREAD, idempotency_key = key(), action_id = "act-k", attempt_id = "act-k-attempt",
        prepared = {binding_ref = "act-k-binding", binding_digest = "act-k-digest", profile_id = "act-k-profile", profile_digest = "act-k-profile-digest", placement_binding = "act-k-placement", placement_attempt_id = "act-k-placement-attempt", plan_digest = "act-k-plan"}}), "prepare hook attempt")
    ok(call("bee.threads.binding:start_attempt", {thread_id = THREAD, idempotency_key = key(), action_id = "act-k", attempt_id = "act-k-attempt",
        started = {execution_kind = "process", execution_ref = "act-k-execution", owner_epoch = 1}}), "start hook attempt")
    -- The binding is at gateway epoch 4, so bring the thread carrier to the
    -- same fenced epoch before recording its hook.
    for epoch = 1, 4 do
        local carrier = ok(call("bee.threads.binding:claim", {thread_id = THREAD, idempotency_key = key(), attempt_id = "act-k-attempt"}), "claim hook carrier")
        assert(carrier.carrier_epoch == epoch, "hook carrier epoch " .. tostring(epoch))
    end
    local event_key = "hook:" .. binding_k4 .. ":" .. tostring(claimed_item.event) .. ":" .. tostring(claimed_item.occurrence)
    local payload = json.encode({event_id = claimed_item.event_id, event = claimed_item.event, occurrence = claimed_item.occurrence, ambiguous = claimed_item.ambiguous == true,
        provenance = claimed_item.provenance, sequence = claimed_item.sequence, fields = claimed_item.fields, binding_id = binding_k4}) or "{}"
    local hook_record = {source = "bee", body = {type = "extension", event_key = event_key,
        data = {type = "extension", event_name = "bee.harness.hook", event_revision = "1", payload_json = payload}}}
    local first_commit = ok(call("bee.threads.binding:commit", {thread_id = THREAD, idempotency_key = key(), attempt_id = "act-k-attempt", carrier_epoch = 4, expected_revision = 0,
        checkpoint = {schema_revision = "bee.carrier.checkpoint@1", phase = "hook-committed-before-ack"}, records = {hook_record}}), "commit claimed hook")
    assert(#(assert(bounds.object((assert(bounds.array(first_commit.records))) == 1 and (assert(bounds.array(first_commit.records)))[1]))).replayed == false, "the claimed hook committed once")
    ok(call("bee.gateway.binding:revoke", {binding_id = binding_k4}), "revoke the hook binding")
    assert(select(1, hook_post("act-k", hook_k4, first_payload)) == 401, "a revoked binding's hook credential is refused")
    local after_revoke = ok(call("bee.gateway.binding:hook_queue", {binding_id = binding_k4}), "queue after revoke")
    for _, item in ipairs(assert(bounds.array(after_revoke.hooks))) do
        local item = assert(bounds.object(item))
        if item.event_id == header_of(revoke_headers, "X-Bee-Event") then assert(item.status == "rejected" and item.rejected_reason == "binding revoked", "revocation rejects an unclaimed row terminally") end
        if item.event_id == claimed_for_commit_id then assert(item.status == "queued" and item.claimed_epoch == 4, "revocation retains the claimed row after its thread commit") end
    end
    local retry_commit = ok(call("bee.threads.binding:commit", {thread_id = THREAD, idempotency_key = key(), attempt_id = "act-k-attempt", carrier_epoch = 4, expected_revision = 1,
        checkpoint = {schema_revision = "bee.carrier.checkpoint@1", phase = "hook-recovered-before-ack"}, records = {hook_record}}), "retry committed hook")
    assert(#(assert(bounds.object((assert(bounds.array(retry_commit.records))) == 1 and (assert(bounds.array(retry_commit.records)))[1]))).replayed == true, "retry replays the retained hook record")
    local committed_records = ok(call("bee.threads.binding:read_after", {thread_id = THREAD, cursor = 0, limit = 64}), "read retained hook record")
    local retained_records = 0
    for _, item in ipairs(assert(bounds.array(committed_records.records))) do
        local item = assert(bounds.object(item))
        if item.kind == "observation" and type(item.body) == "table" and (assert(bounds.object(item.body))).event_key == event_key then retained_records = retained_records + 1 end
    end
    assert(retained_records == 1, "the replay did not duplicate the committed hook record")
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = binding_k4, carrier_epoch = 4, event_ids = {claimed_for_commit_id}}), "ack after revoke").acknowledged == 1,
        "the internally authorized carrier acknowledges the committed row after revocation")
    -- Expiry has the same distinction: the token is refused, unclaimed rows
    -- are rejected, and the internally authorized carrier path reclaims work
    -- that was already claimed before expiry.
    local expiring = ok(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-expiring-hooks", attempt_id = "act-expiring-hooks-attempt", thread_id = THREAD,
        owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"PreToolUse"}, ttl_ms = 250}), "admit expiring hooks")
    local expiring_binding = tostring((assert(bounds.object(expiring.binding))).binding_id)
    local expiring_tokens = ok(materialize("act-expiring-hooks-attempt", 1, expiring_binding), "materialize expiring hooks")
    local expiring_hook = tostring(expiring_tokens.hook_token)
    local expiring_status, _, expiring_headers = hook_post("act-expiring-hooks", expiring_hook, {hook_event_name = "PreToolUse", session_id = "expiry", tool_use_id = "toolu_expiry", tool_name = "Bash"})
    assert(expiring_status == 202, "hook queues before expiry")
    local expiring_claim = ok(call("bee.gateway.binding:hook_claim", {binding_id = expiring_binding, carrier_epoch = 1, limit = 1}), "claim before expiry")
    local expiring_id = tostring((assert(bounds.object((assert(bounds.array(expiring_claim.hooks)))[1]))).event_id)
    assert(expiring_id == tostring(header_of(expiring_headers, "X-Bee-Event")), "the expiring row was claimed")
    time.sleep("300ms")
    local expired_recovery = ok(call("bee.gateway.binding:hook_claim", {binding_id = expiring_binding, carrier_epoch = 2, limit = 1}), "reclaim after expiry")
    assert(#(assert(bounds.object((assert(bounds.array(expired_recovery.hooks))) == 1 and tostring((assert(bounds.array(expired_recovery.hooks)))[1]))).event_id) == expiring_id,
        "expiry retains and reclaims a claimed row")
    assert(ok(call("bee.gateway.binding:hook_ack", {binding_id = expiring_binding, carrier_epoch = 2, event_ids = {expiring_id}}), "ack after expiry").acknowledged == 1,
        "the reclaimed expired row acknowledges normally")
    prove_corrupt_hooks(hook_post, header_of)
    -- Drain refuses new admissions and a bounded read still finishes before
    -- the host's deadline.
    ok(call("bee.gateway.binding:drain", {deadline_ms = 5000}), "drain")
    assert(code(call("bee.gateway.binding:admit", {subject = ACTOR, action_id = "act-e", attempt_id = "att-e", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}})) == "UNAVAILABLE", "admission refused after drain")
    local late = tool("act-d", token_d, "thread_read", {cursor = 0})
    assert(late.ok == true, "bounded read finishes during drain")
    -- A new epoch fences every earlier binding and readiness.
    local reopened = ok(call("bee.gateway.binding:open", {address = ADDRESS}), "reopen")
    assert(reopened.epoch == 2, "second epoch")
    local stale = ok(call("bee.gateway.binding:ready", {binding_id = binding_d}), "ready after reopen")
    assert((assert(bounds.object(stale.generation))).epoch == 2 and stale.binding_valid == false, "earlier binding fenced by the new epoch")
    assert(select(1, rpc("act-d", token_d, "tools/list")) == 401, "earlier epoch token refused")
end
return {main = main}
