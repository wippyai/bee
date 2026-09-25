-- SPDX-License-Identifier: MIT
-- Explicit fixture operator. Credentials stay inside this process.
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local http_client = require("http_client")
local json = require("json")
local time = require("time")
local bounds = require("bounds")
type Object = {[string]: unknown}
local THREAD = "research-performance"
local ACTION = "research-measure"
local ATTEMPT = "research-measure-attempt"
local function object(raw: unknown): Object
    local value = bounds.object(raw)
    if not value then error("expected object") end
    return value
end
local function call(target: string, request: Object): Object
    local result, problem = funcs.call(target, request)
    if problem then error(target .. ": " .. tostring(problem)) end
    local reply = object(result)
    if reply.ok ~= true then error(target .. ": " .. tostring(json.encode(reply.error))) end
    return object(reply.value)
end
local function run(): Object
    local actor = security.actor()
    if not actor then error("fixture actor missing") end
    local subject = actor:id()
    assert(subject ~= "bee.research.measurement", "operator must differ from measured producer")
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "create", title = "Canonical JSON research"})
    call("bee.threads.service:join", {thread_id = THREAD, idempotency_key = "join-producer", member_id = "bee.research.measurement",
        role = "participant", expected_revision = 1})
    call("bee.threads.service:join", {thread_id = THREAD, idempotency_key = "join-dashboard", member_id = "bee.local",
        role = "observer", expected_revision = 2})
    call("bee.threads.service:admit_action", {thread_id = THREAD, idempotency_key = "admit", action_id = ACTION,
        admitted = {request_id = "measure-request", principal_id = subject, binding_ref = "measure-binding",
            binding_digest = "measure-digest", grant_refs = {}, budget_ref = "fixed-budget", input = {text = "Measure reviewed sources"}}})
    call("bee.threads.service:prepare_attempt", {thread_id = THREAD, idempotency_key = "prepare", action_id = ACTION, attempt_id = ATTEMPT,
        prepared = {binding_ref = "measure-binding", binding_digest = "measure-digest", profile_id = "measure-profile",
            profile_digest = "measure-profile-digest", placement_binding = "measure-placement", placement_attempt_id = "measure-placement-attempt", plan_digest = "measure-plan"}})
    local address: string? = nil
    for _ = 1, 100 do
        local raw = funcs.call("bee.gateway:address", {})
        local value = bounds.object(raw)
        if value and type(value.address) == "string" then address = value.address; break end
        time.sleep("20ms")
    end
    if not address or not address:match("^127%.0%.0%.1:%d+$") then error("automatic loopback endpoint unavailable") end
    local admitted = call("bee.gateway.binding:admit", {subject = subject, action_id = ACTION, attempt_id = ATTEMPT,
        thread_id = THREAD, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "thread_message", "research_measure"}, ttl_ms = 60000,
        surface = object(assert(registry.get("bee.research.measurement:surface")).data)})
    local binding_id = object(admitted.binding).binding_id
    local authorized = call("bee.gateway.binding:authorize_materialization", {attempt_id = ATTEMPT, carrier_epoch = 1, binding_id = binding_id})
    local materialized = call("bee.gateway.binding:materialize", {attempt_id = ATTEMPT, carrier_epoch = 1, materialization_key = authorized.materialization_key})
    local token = materialized.token
    if type(token) ~= "string" then error("missing credential") end
    local function rpc(name: string, arguments: Object): (number, Object)
        local bytes = json.encode({jsonrpc = "2.0", id = 1, method = "tools/call", params = {name = name, arguments = arguments}})
        local response, problem = http_client.post("http://" .. address .. "/mcp/" .. ACTION,
            {headers = {Authorization = "Bearer " .. token, ["Content-Type"] = "application/json"}, body = bytes, timeout = "15s"})
        if not response then error("HTTP measurement failed: " .. tostring(problem)) end
        return response.status_code, object(json.decode(tostring(response.body)))
    end
    local function tool(name: string, arguments: Object): Object
        local status, reply = rpc(name, arguments)
        assert(status == 200, "tool HTTP status")
        local result = object(reply.result)
        local content = result.content
        if type(content) ~= "table" then error("missing tool content") end
        local value = object(json.decode(tostring(object(content[1]).text)))
        return value
    end
    local _, inactive = rpc("research_measure", {label = "candidate"})
    assert(inactive.error ~= nil, "inactive tool was exposed")
    assert(tool("session", {operation = "select", expected_revision = 1, active_traits = {"research:measure"}, context = {}}).ok == true)
    local results: Object = {}
    local input = registry.get("bee.research.measurement:inputs")
    if not input then error("inputs missing") end
    local config = object(input.data)
    for _, label in ipairs({"baseline", "candidate"}) do
        local reply = tool("call_tool", {name = "research_measure", arguments = {label = label}})
        assert(reply.ok == true, "measurement failed: " .. tostring(json.encode(reply.error)))
        local value = object(reply.value)
        local measured = object(value.measurement)
        assert(measured.schema == "bee.research.measurement@1" and measured.benchmark == "canonical-json@1" and measured.units == "ns/op")
        assert(measured.source_sha256 == config[label .. "_sha256"] and measured.label == label)
        assert(measured.correct == (label == "candidate"))
        assert(measured.outcome == (label == "candidate" and "passed" or "invalid"))
        local samples = measured.samples
        assert(type(samples) == "table" and #samples == 7)
        for _, sample in ipairs(samples) do assert(type(sample) == "number" and sample > 0 and sample < math.huge) end
        local again = tool("call_tool", {name = "research_measure", arguments = {label = label}})
        assert(again.ok == true and again.replayed == true and object(again.value).sequence == value.sequence, "measurement replay differs")
        results[label] = value
    end
    local injected = tool("call_tool", {name = "research_measure", arguments = {label = "candidate", thread_id = "elsewhere"}})
    assert(injected.ok == false, "tool accepted a foreign thread")
    local fake = object(json.decode(tostring(json.encode(object(results.candidate).measurement))))
    fake.samples = {1, 1, 1, 1, 1, 1, 1}
    local message = tool("thread_message", {idempotency_key = "fabricated", message_id = "fabricated", message_kind = "progress",
        recipient_ids = {}, content = {text = json.encode(fake)}})
    assert(message.ok == true, "ordinary message should remain permitted")
    local page = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64})
    local observations, fabricated = 0, false
    if type(page.records) ~= "table" then error("records missing") end
    for _, raw in ipairs(page.records) do
        local record = object(raw)
        local body = object(record.body)
        if record.kind == "observation" then
            assert(record.producer_id == "bee.research.measurement" and record.source == "mcp")
            assert(record.action_id == ACTION and record.attempt_id == ATTEMPT)
            observations = observations + 1
        elseif body.message_id == "fabricated" then
            assert(record.kind == "message" and record.producer_id == subject and body.sender_id == subject)
            fabricated = true
        end
    end
    assert(observations == 2 and fabricated, "measurement count/provenance differs")
    call("bee.gateway.binding:revoke", {binding_id = binding_id})
    local revoked = rpc("call_tool", {name = "research_measure", arguments = {label = "candidate"}})
    assert(revoked == 401, "revoked credential accepted")
    return {ok = true, thread_id = THREAD, measurements = results, observations = observations, forged_message_excluded = fabricated}
end
return {run = run}
