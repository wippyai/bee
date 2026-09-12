-- MIT. Slice 1 of the gateway against the real listener and thread owner:
-- readiness, admission and revocation, thread_read, bounded read-only
-- thread_wait, cross-attempt and expiry refusal, drain and epoch fencing.
-- It asserts and fails the boot; it prints nothing, so no token bytes can
-- reach captured output.
local funcs = require("funcs")
local http_client = require("http_client")
local json = require("json")
local time = require("time")
local process = require("process")
local registry = require("registry")
local security = require("security")
local ACTOR = "bee.test.gateway"
local THREAD = "gateway-thread"
type Object = {[string]: unknown}
local ADDRESS = ""
local function endpoint(): string
    local entry, err = registry.get("bee:gateway_endpoint")
    assert(not err and entry and type(entry.data) == "table", "gateway endpoint")
    local address = (entry.data :: Object).address
    assert(type(address) == "string" and (address :: string):find("^127%.0%.0%.1:%d+$"), "gateway endpoint address")
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
local function admit(action: string, ttl: integer?, carrier_epoch: integer?): (string, string)
    local value = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = action, attempt_id = action .. "-attempt", thread_id = THREAD, owner_incarnation = 1,
        carrier_epoch = carrier_epoch or 1, tools = {"thread_read", "thread_wait"}, ttl_ms = ttl or 60000}), "admit " .. action)
    local binding_id = tostring((value.binding :: Object).binding_id)
    assert(value.token == nil, "admit must not return token bytes")
    local authorized = ok(call("bee.gateway:authorize_materialization", {attempt_id = action .. "-attempt", carrier_epoch = carrier_epoch or 1, binding_id = binding_id}), "authorize " .. action)
    local materialized = ok(call("bee.gateway:materialize", {attempt_id = action .. "-attempt", carrier_epoch = carrier_epoch or 1, materialization_key = authorized.materialization_key}), "materialize " .. action)
    return tostring(materialized.token), binding_id
end
local function materialize(attempt: string, carrier_epoch: integer, binding_id: string): Object
    local authorized = ok(call("bee.gateway:authorize_materialization", {attempt_id = attempt, carrier_epoch = carrier_epoch, binding_id = binding_id}), "authorize " .. attempt)
    return call("bee.gateway:materialize", {attempt_id = attempt, carrier_epoch = carrier_epoch, materialization_key = authorized.materialization_key})
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
    assert(projection.path == ".claude.json", "unexpected rendered configuration path")
    assert(type(projection.content) == "string" and (projection.content :: string):find("scope%-render", 1, false) ~= nil, "configuration did not render input")
    assert((projection.content :: string):find("BEE_GATEWAY_TOKEN", 1, true) ~= nil, "rendered configuration omitted host destination")
end
local function main()
    ADDRESS = endpoint()
    prove_configuration_scope(ADDRESS)
    local opened = ok(call("bee.gateway:open", {address = ADDRESS}), "open")
    assert(opened.epoch == 1, "first epoch")
    ok(call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = key(), title = "Gateway"}), "create")
    for index = 1, 3 do record("line " .. tostring(index)) end
    local token_a, binding_a = admit("act-a")
    local ready = ok(call("bee.gateway:ready", {binding_id = binding_a}), "ready")
    assert(ready.listening == true and (ready.generation :: Object).epoch == 1, "readiness under epoch 1")
    assert(ready.binding_valid == true, "binding A valid")
    local status, init = rpc("act-a", token_a, "initialize")
    assert(status == 200 and init and (init.result :: Object).protocolVersion ~= nil, "initialize")
    local _, listed = rpc("act-a", token_a, "tools/list")
    assert(listed and #((listed.result :: Object).tools :: {unknown}) == 2, "two tools advertised")
    local page = tool("act-a", token_a, "thread_read", {cursor = 0})
    assert(page.ok == true, "thread_read refused: " .. tostring(json.encode(page)))
    assert(#((page.value :: Object).records :: {unknown}) == 3, "thread_read returned the three records: " .. tostring(json.encode(page)))
    -- The credential lifecycle: the same generation cannot be materialized
    -- twice, reissue is a compare-and-set that revokes the old token and
    -- opens the next generation, a stale reissue changes nothing, and the
    -- replaced token is refused while the new one works.
    assert(code(materialize("act-a-attempt", 1, binding_a)) == "CONFLICT", "second materialization refused")
    -- Materialization needs placement's one-time key: none, a wrong one, or
    -- a used one is refused even by a caller holding the materializer grant.
    assert(code(call("bee.gateway:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1})) == "INVALID", "materialization without a key refused")
    assert(code(call("bee.gateway:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1, materialization_key = "not-the-key"})) == "DENIED", "materialization with a wrong key refused")
    assert(code(call("bee.gateway:reissue", {binding_id = binding_a, expected_generation = 7})) == "CONFLICT", "stale reissue refused")
    local reissued = ok(call("bee.gateway:reissue", {binding_id = binding_a, expected_generation = 1}), "reissue")
    assert(reissued.generation == 2, "generation advanced")
    assert(code(call("bee.gateway:reissue", {binding_id = binding_a, expected_generation = 1})) == "CONFLICT", "concurrent reissue with the same expectation loses")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "replaced token refused")
    local authorized_again = ok(call("bee.gateway:authorize_materialization", {attempt_id = "act-a-attempt", carrier_epoch = 1, binding_id = binding_a}), "authorize generation 2")
    local renewed = ok(call("bee.gateway:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1, materialization_key = authorized_again.materialization_key}), "materialize generation 2")
    token_a = tostring(renewed.token)
    assert(code(call("bee.gateway:materialize", {attempt_id = "act-a-attempt", carrier_epoch = 1, materialization_key = authorized_again.materialization_key})) == "DENIED", "a used key authorizes nothing more")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "new generation token works")
    assert(code(materialize("act-a-attempt", 2, binding_a)) == "CONFLICT", "a later carrier epoch inherits the binding and its materialized generation")
    assert(code(call("bee.gateway:authorize_materialization", {attempt_id = "act-a-attempt", carrier_epoch = 1, binding_id = "another-binding"})) == "CONFLICT", "a binding that is not the carrier's recorded one is refused")
    assert(code(call("bee.gateway:authorize_materialization", {attempt_id = "act-zz-attempt", carrier_epoch = 1, binding_id = binding_a})) == "NOT_FOUND", "no binding for an unknown attempt")
    -- A presented token is counted; the count is the evidence a client authenticated.
    local presented = ok(call("bee.gateway:check", {binding_id = binding_a}), "check presentations")
    assert((tonumber(presented.presented_count) or 0) >= 1 and presented.last_presented_at ~= nil, "presentations counted")
    -- One live binding per attempt and carrier epoch: the same admission
    -- replays it, a different one at the same epoch conflicts.
    local replayed = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "thread_wait"}, ttl_ms = 60000}), "replay admission")
    assert(replayed.replayed == true and (replayed.binding :: Object).binding_id == binding_a, "same admission replays the live binding")
    assert(code(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "a different admission at the same epoch conflicts")
    -- A later carrier epoch's admission supersedes the earlier binding of the same attempt.
    local superseding = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 2, tools = {"thread_read"}, ttl_ms = 60000}), "admit under epoch 2")
    assert((superseding.binding :: Object).binding_id ~= binding_a, "a new binding")
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 401, "the superseded binding's token is refused")
    local superseded = ok(call("bee.gateway:check", {binding_id = binding_a}), "check superseded")
    assert(superseded.valid == false and tostring(superseded.reason) == "binding is revoked", "superseded binding is revoked")
    binding_a = tostring((superseding.binding :: Object).binding_id)
    token_a = tostring(ok(materialize("act-a-attempt", 2, binding_a), "materialize under epoch 2").token)
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "the superseding binding's token works")
    -- A delayed admission under an epoch below the highest ever admitted for
    -- the attempt is refused, so no second live binding can appear.
    assert(code(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "stale admission refused")
    ok(call("bee.gateway:revoke", {binding_id = binding_a}), "revoke the epoch 2 binding")
    assert(code(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000})) == "CONFLICT", "stale admission refused even with the newer binding revoked")
    local reopened_a = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-a", attempt_id = "act-a-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 3, tools = {"thread_read", "thread_wait"}, ttl_ms = 60000}), "admit under epoch 3")
    binding_a = tostring((reopened_a.binding :: Object).binding_id)
    token_a = tostring(ok(materialize("act-a-attempt", 3, binding_a), "materialize under epoch 3").token)
    assert(select(1, rpc("act-a", token_a, "tools/list")) == 200, "the epoch 3 binding's token works")
    -- Independent revocation is fenced by carrier epoch: a report from an
    -- older carrier cannot revoke a binding admitted under a higher epoch.
    local token_f, binding_f = admit("act-f", nil, 5)
    local older = ok(call("bee.gateway:revoke_attempt", {attempt_id = "act-f-attempt", carrier_epoch = 4}), "revoke_attempt older")
    assert(older.revoked == 0 and select(1, rpc("act-f", token_f, "tools/list")) == 200, "older carrier report left the newer binding alive")
    local current = ok(call("bee.gateway:revoke_attempt", {attempt_id = "act-f-attempt", carrier_epoch = 5}), "revoke_attempt current")
    assert(current.revoked == 1 and select(1, rpc("act-f", token_f, "tools/list")) == 401, "current carrier report revoked the binding")
    local checked = ok(call("bee.gateway:check", {binding_id = binding_f}), "check")
    assert(checked.valid == false and tostring(checked.reason) == "binding is revoked", "check reports revocation")
    -- A tool outside the binding's admitted set is refused at the call, whatever a client allows for itself.
    local token_h = admit("act-h", nil, 1)
    local narrow_status, narrow_reply = rpc("act-h", token_h, "tools/list")
    assert(narrow_status == 200 and #(((narrow_reply :: Object).result :: Object).tools :: {Object}) == 2, "the probe admits both tools")
    local admitted_only = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-i", attempt_id = "act-i-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, ttl_ms = 60000}), "admit read only")
    local token_i = tostring(ok(materialize("act-i-attempt", 1, tostring((admitted_only.binding :: Object).binding_id)), "materialize read only").token)
    local listed_status, listed = rpc("act-i", token_i, "tools/list")
    assert(listed_status == 200 and #(((listed :: Object).result :: Object).tools :: {Object}) == 1, "only the admitted tool is advertised")
    local refused_status, refused = rpc("act-i", token_i, "tools/call", {name = "thread_wait", arguments = {after_sequence = 0, wait_ms = 10}})
    assert(refused_status == 200 and refused and refused.error ~= nil and tostring(((refused :: Object).error :: Object).message):find("not admitted", 1, true), "a tool outside the binding is refused")
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
    ok(call("bee.gateway:revoke", {binding_id = binding_a}), "revoke")
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
    local hook_admit = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-k", attempt_id = "act-k-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"},
        hooks = {"PreToolUse", "PostToolUse", "Stop", "SessionStart"}, ttl_ms = 60000}), "admit with hooks")
    local binding_k = tostring((hook_admit.binding :: Object).binding_id)
    assert(code(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-k2", attempt_id = "act-k2-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"Notification"}})) == "INVALID", "an event outside the catalog is not admitted")
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
    local queue = ok(call("bee.gateway:hook_queue", {binding_id = binding_k}), "hook queue")
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
    local engine_text = tostring((((engine_reply :: Object).result :: Object).content :: {Object})[1].text)
    assert(engine_text:find("^queued ") ~= nil and not engine_text:find("{", 1, true), "the MCP answer names the queued status as bare text: " .. engine_text)
    local _, model_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_2"}, _meta = {callId = "call_2", ["x-codex-turn-metadata"] = {turn_id = "t1"}}})
    assert(model_reply and model_reply.error ~= nil and tostring(((model_reply :: Object).error :: Object).message):find("(model)", 1, true), "a model shaped call is refused")
    local _, mixed_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_3"}, _meta = {threadId = "s2", callId = "call_3"}})
    assert(mixed_reply and mixed_reply.error ~= nil and tostring(((mixed_reply :: Object).error :: Object).message):find("(mixed)", 1, true), "a mixed metadata call is refused")
    local _, bare_reply = hook_rpc(hook_k, "tools/call", {name = "hook", arguments = {event = "PostToolUse", session_id = "s2", turn_id = "t1", tool_use_id = "call_4"}})
    assert(bare_reply and bare_reply.error ~= nil and tostring(((bare_reply :: Object).error :: Object).message):find("(unclassified)", 1, true), "a call without metadata is refused")
    local _, other_tool = hook_rpc(hook_k, "tools/call", {name = "thread_read", arguments = {cursor = 0}, _meta = {threadId = "s2"}})
    assert(other_tool and other_tool.error ~= nil, "no thread tool is served on the hook endpoint")
    local engine_queue = ok(call("bee.gateway:hook_queue", {binding_id = binding_k}), "hook queue after mcp")
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
    local claimed = ok(call("bee.gateway:hook_claim", {binding_id = binding_k, carrier_epoch = 1, limit = 3}), "claim")
    local claimed_list = claimed.hooks :: {Object}
    assert(#claimed_list == 3 and claimed_list[1].event_id == event_1, "the first three queued submissions are claimed in order")
    local again_claimed = ok(call("bee.gateway:hook_claim", {binding_id = binding_k, carrier_epoch = 1, limit = 3}), "claim again")
    assert(#(again_claimed.hooks :: {Object}) == 3 and (again_claimed.hooks :: {Object})[1].event_id ~= event_1, "a second claim under the same epoch takes the next rows, never the claimed ones")
    local acked = ok(call("bee.gateway:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = {event_1}}), "ack")
    assert(acked.acknowledged == 1, "one acknowledged")
    local committed_status, committed_body = hook_get("act-k", hook_k, event_1)
    assert(committed_status == 200 and committed_body and committed_body.status == "committed", "status answers committed")
    local replay_status, replay_body = hook_post("act-k", hook_k, first_payload)
    assert(replay_status == 200 and replay_body == "", "a replay of a committed submission answers 200 with an empty body")
    assert(ok(call("bee.gateway:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = {event_1}}), "ack twice").acknowledged == 0, "an acknowledgment is idempotent")
    -- Sealing ends intake at once and keeps the accepted rows for the carrier.
    local pre_seal = ok(call("bee.gateway:hook_queue", {binding_id = binding_k}), "queue before seal")
    ok(call("bee.gateway:seal", {binding_id = binding_k}), "seal")
    local sealed_status, sealed_body = hook_post("act-k", hook_k, {hook_event_name = "PreToolUse", session_id = "s9", tool_use_id = "toolu_after_seal", tool_name = "Bash"})
    assert(sealed_status == 403 and sealed_body:find("sealed", 1, true), "a submission after the seal is refused: " .. tostring(sealed_status) .. " " .. sealed_body)
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 200, "a replay of a committed submission still answers after the seal")
    assert(select(1, rpc("act-k", token_k, "tools/list")) == 200, "the seal leaves the tool credential valid")
    local post_seal = ok(call("bee.gateway:hook_queue", {binding_id = binding_k}), "queue after seal")
    assert(#(post_seal.hooks :: {Object}) == #(pre_seal.hooks :: {Object}), "the seal discards nothing accepted")
    local taken_over = ok(call("bee.gateway:hook_claim", {binding_id = binding_k, carrier_epoch = 3, limit = 2}), "claim under a higher epoch")
    assert(#(taken_over.hooks :: {Object}) == 2, "a higher epoch takes over rows a lower epoch claimed, sealed or not")
    local stale_ack = ok(call("bee.gateway:hook_ack", {binding_id = binding_k, carrier_epoch = 1, event_ids = {(taken_over.hooks :: {Object})[1].event_id}}), "stale ack")
    assert(stale_ack.acknowledged == 0, "a lower epoch cannot acknowledge what a higher one claimed")
    local unclaimed_ack = ok(call("bee.gateway:hook_ack", {binding_id = binding_k, carrier_epoch = 3, event_ids = {(again_claimed.hooks :: {Object})[2].event_id}}), "ack without claim")
    assert(unclaimed_ack.acknowledged == 0, "an epoch that did not claim a row cannot acknowledge it")
    local admitted_higher = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-k", attempt_id = "act-k-attempt", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 4, tools = {"thread_read"}, hooks = {"Stop", "PreToolUse"}, ttl_ms = 60000}), "admit act-k under epoch 4")
    assert(code(call("bee.gateway:hook_claim", {binding_id = binding_k, carrier_epoch = 3})) == "CONFLICT", "a claim below the highest admitted epoch is refused")
    assert(code(call("bee.gateway:hook_ack", {binding_id = binding_k, carrier_epoch = 3, event_ids = {(taken_over.hooks :: {Object})[1].event_id}})) == "CONFLICT",
        "an old claim cannot acknowledge after the replacement admission")
    local superseded_queue = ok(call("bee.gateway:hook_queue", {binding_id = binding_k}), "superseded queue")
    local rejected_count, committed_count, retained_claimed = 0, 0, 0
    for _, item in ipairs(superseded_queue.hooks :: {Object}) do
        if item.status == "rejected" then rejected_count = rejected_count + 1; assert(item.rejected_reason == "binding superseded", "rejection names its reason") end
        if item.status == "committed" then committed_count = committed_count + 1 end
        if item.status == "queued" and (tonumber(item.claimed_epoch) or 0) > 0 then retained_claimed = retained_claimed + 1 end
    end
    assert(committed_count == 1 and rejected_count > 0 and retained_claimed > 0,
        "supersession rejects unclaimed rows, keeps committed rows and retains claimed uncertainty: " .. tostring(committed_count) .. " " .. tostring(rejected_count) .. " " .. tostring(retained_claimed))
    local recovered_after_supersession = ok(call("bee.gateway:hook_claim", {binding_id = binding_k, carrier_epoch = 4, limit = 3}), "reclaim superseded claims")
    assert(#(recovered_after_supersession.hooks :: {Object}) > 0, "the current carrier reclaims a superseded claimed row")
    local recovered_id = tostring((recovered_after_supersession.hooks :: {Object})[1].event_id)
    assert(ok(call("bee.gateway:hook_ack", {binding_id = binding_k, carrier_epoch = 4, event_ids = {recovered_id}}), "ack reclaimed superseded row").acknowledged == 1,
        "a replacement can acknowledge a retained claim")
    assert(select(1, hook_post("act-k", hook_k, first_payload)) == 401, "the superseded binding's hook credential is refused")
    local binding_k4 = tostring((admitted_higher.binding :: Object).binding_id)
    local minted_k4 = ok(materialize("act-k-attempt", 4, binding_k4), "materialize under epoch 4")
    local hook_k4 = tostring(minted_k4.hook_token)
    local stop_status, _, stop_headers = hook_post("act-k", hook_k4, {hook_event_name = "Stop", session_id = "s4", prompt_id = "p4", stop_hook_active = false})
    assert(stop_status == 202, "a hook under the new binding queues")
    local ended = ok(call("bee.gateway:hook_reject", {binding_id = binding_k4, carrier_epoch = 4, reason = "attempt settled"}), "reject at settlement")
    assert(ended.rejected == 1, "the queued row is rejected at settlement")
    local rejected_status, rejected_body = hook_get("act-k", hook_k4, tostring(header_of(stop_headers, "X-Bee-Event")))
    assert(rejected_status == 200 and rejected_body and rejected_body.status == "rejected" and rejected_body.rejected_reason == "attempt settled", "status answers rejected with its reason")
    local gone_status, gone_body = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_gone", tool_name = "Bash"})
    assert(gone_status == 202, "a fresh occurrence still queues until the binding ends: " .. tostring(gone_status) .. " " .. tostring(gone_body))
    ok(call("bee.gateway:hook_reject", {binding_id = binding_k4, carrier_epoch = 4, reason = "attempt settled"}), "reject again")
    local replay_gone_status, replay_gone_body = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_gone", tool_name = "Bash"})
    assert(replay_gone_status == 410 and replay_gone_body:find("rejected: attempt settled", 1, true), "a replay of a rejected occurrence answers 410 with plain text: " .. tostring(replay_gone_status) .. " " .. replay_gone_body)
    local claimed_before_revoke, _, claimed_headers = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_claimed_revoke", tool_name = "Bash"})
    local queued_before_revoke, _, revoke_headers = hook_post("act-k", hook_k4, {hook_event_name = "PreToolUse", session_id = "s4", tool_use_id = "toolu_revoked", tool_name = "Bash"})
    assert(claimed_before_revoke == 202 and queued_before_revoke == 202, "claimed and unclaimed rows queue before the revocation")
    local claimed_for_commit = ok(call("bee.gateway:hook_claim", {binding_id = binding_k4, carrier_epoch = 4, limit = 1}), "claim before lost acknowledgment")
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
    ok(call("bee.gateway:revoke", {binding_id = binding_k4}), "revoke the hook binding")
    assert(select(1, hook_post("act-k", hook_k4, first_payload)) == 401, "a revoked binding's hook credential is refused")
    local after_revoke = ok(call("bee.gateway:hook_queue", {binding_id = binding_k4}), "queue after revoke")
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
    assert(ok(call("bee.gateway:hook_ack", {binding_id = binding_k4, carrier_epoch = 4, event_ids = {claimed_for_commit_id}}), "ack after revoke").acknowledged == 1,
        "the internally authorized carrier acknowledges the committed row after revocation")
    -- Expiry has the same distinction: the token is refused, unclaimed rows
    -- are rejected, and the internally authorized carrier path reclaims work
    -- that was already claimed before expiry.
    local expiring = ok(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-expiring-hooks", attempt_id = "act-expiring-hooks-attempt", thread_id = THREAD,
        owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"PreToolUse"}, ttl_ms = 250}), "admit expiring hooks")
    local expiring_binding = tostring((expiring.binding :: Object).binding_id)
    local expiring_tokens = ok(materialize("act-expiring-hooks-attempt", 1, expiring_binding), "materialize expiring hooks")
    local expiring_hook = tostring(expiring_tokens.hook_token)
    local expiring_status, _, expiring_headers = hook_post("act-expiring-hooks", expiring_hook, {hook_event_name = "PreToolUse", session_id = "expiry", tool_use_id = "toolu_expiry", tool_name = "Bash"})
    assert(expiring_status == 202, "hook queues before expiry")
    local expiring_claim = ok(call("bee.gateway:hook_claim", {binding_id = expiring_binding, carrier_epoch = 1, limit = 1}), "claim before expiry")
    local expiring_id = tostring((expiring_claim.hooks :: {Object})[1].event_id)
    assert(expiring_id == tostring(header_of(expiring_headers, "X-Bee-Event")), "the expiring row was claimed")
    time.sleep("300ms")
    local expired_recovery = ok(call("bee.gateway:hook_claim", {binding_id = expiring_binding, carrier_epoch = 2, limit = 1}), "reclaim after expiry")
    assert(#(expired_recovery.hooks :: {Object}) == 1 and tostring((expired_recovery.hooks :: {Object})[1].event_id) == expiring_id,
        "expiry retains and reclaims a claimed row")
    assert(ok(call("bee.gateway:hook_ack", {binding_id = expiring_binding, carrier_epoch = 2, event_ids = {expiring_id}}), "ack after expiry").acknowledged == 1,
        "the reclaimed expired row acknowledges normally")
    -- Drain during a wait: a helper drains while this wait is in flight; the
    -- wait returns a released outcome well before its own deadline, new
    -- admissions are refused, and a bounded read still finishes before the
    -- host's deadline.
    assert(process.spawn("bee.gateway_probe:drainer", "bee:workers", "400ms"), "spawn drainer")
    local drain_started = time.now()
    local released = tool("act-d", token_d, "thread_wait", {after_sequence = 4, wait_ms = 4000})
    assert(released.ok == true and (released.value :: Object).status == "released" and (released.value :: Object).reason == "draining", "wait released by drain: " .. tostring(json.encode(released)))
    assert(time.now():sub(drain_started):milliseconds() < 3500, "release came before the wait's own deadline")
    assert(code(call("bee.gateway:admit", {subject = ACTOR, action_id = "act-e", attempt_id = "att-e", thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}})) == "UNAVAILABLE", "admission refused after drain")
    local late = tool("act-d", token_d, "thread_read", {cursor = 0})
    assert(late.ok == true, "bounded read finishes during drain")
    -- A new epoch fences every earlier binding and readiness.
    local reopened = ok(call("bee.gateway:open", {address = ADDRESS}), "reopen")
    assert(reopened.epoch == 2, "second epoch")
    local stale = ok(call("bee.gateway:ready", {binding_id = binding_d}), "ready after reopen")
    assert((stale.generation :: Object).epoch == 2 and stale.binding_valid == false, "earlier binding fenced by the new epoch")
    assert(select(1, rpc("act-d", token_d, "tools/list")) == 401, "earlier epoch token refused")
end
return {main = main}
