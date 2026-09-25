-- SPDX-License-Identifier: MIT
-- Fixed, host-admitted experiment. Context attributes the call; the thread
-- owner still authorizes its actor. No path, source or function comes from MCP.
local ctx = require("ctx")
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local security = require("security")
local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
type Object = {[string]: unknown}
type Binding = {binding_id: string, thread_id: string, action_id: string, attempt_id: string}
local MEASUREMENT_ACTOR = "bee.research.measurement"
local function fail(code: string, message: string): Object
    return {ok = false, error = {code = code, message = message}}
end
local function call(target: string, request: Object, executor: funcs.Executor?): (Object?, Object?)
    local raw, call_error
    if executor then raw, call_error = executor:call(target, request)
    else raw, call_error = funcs.call(target, request) end
    if call_error then return nil, fail("UNKNOWN", tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply then return nil, fail("INVALID", "malformed owner reply") end
    if reply.ok ~= true then return nil, reply end
    local value = bounds.object(reply.value)
    if not value then return nil, fail("INVALID", "missing owner result") end
    return value, nil
end
local function binding(): Binding?
    local raw = bounds.object(ctx.get("bee.gateway.binding"))
    if not raw then return nil end
    local id, thread = bounds.id(raw.binding_id), bounds.id(raw.thread_id)
    local action, attempt = bounds.id(raw.action_id), bounds.id(raw.attempt_id)
    if not id or not thread or not action or not attempt then return nil end
    return {binding_id = id, thread_id = thread, action_id = action, attempt_id = attempt}
end
local function previous(bound: Binding, actor: string, message_id: string): (Object?, Object?)
    local cursor = 0
    for _ = 1, 16 do
        local page, failure = call("bee.threads.service:read_after", {thread_id = bound.thread_id,
            cursor = cursor, limit = 64, filter = {kinds = {"observation"}, action_id = bound.action_id}})
        if not page then return nil, failure end
        if type(page.records) ~= "table" then return nil, fail("INVALID", "missing thread records") end
        for _, value in ipairs(page.records) do
            local record = bounds.object(value)
            local body = record and bounds.object(record.body) or nil
            if record and body and body.event_key == message_id then
                if record.producer_id ~= actor or record.source ~= "mcp" or record.action_id ~= bound.action_id
                    or record.attempt_id ~= bound.attempt_id then
                    return nil, fail("CONFLICT", "measurement identity belongs to a different producer")
                end
                local content = bounds.object(body.data)
                if not content or content.type ~= "extension" or content.event_name ~= "bee.research.measurement"
                    or content.event_revision ~= "1" then return nil, fail("INVALID", "stored measurement type differs") end
                local text = content.payload_json
                if type(text) ~= "string" then return nil, fail("INVALID", "stored measurement has no body") end
                local decoded, decode_error = json.decode(text)
                local measurement = bounds.object(decoded)
                if not measurement or decode_error then return nil, fail("INVALID", "stored measurement is malformed") end
                return {ok = true, replayed = true, value = {measurement = measurement,
                    record_id = record.record_id, sequence = record.sequence}}, nil
            end
        end
        if page.has_more == false then return nil, nil end
        local next_cursor = bounds.count(page.scanned_through)
        if not next_cursor or next_cursor <= cursor then return nil, fail("INVALID", "thread scan did not advance") end
        cursor = next_cursor
    end
    return nil, fail("LIMIT", "measurement lookup exceeds the bounded thread scan")
end
local function run(raw: unknown): Object
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"label"}) or (request.label ~= "baseline" and request.label ~= "candidate") then
        return fail("INVALID", "expected only baseline or candidate label")
    end
    local label = request.label
    local bound = binding()
    local actor = security.actor()
    if not bound or not actor then return fail("DENIED", "authenticated MCP binding required") end
    local input = registry.get("bee.research.measurement:inputs")
    local config = input and bounds.object(input.data) or nil
    if not config then return fail("UNAVAILABLE", "host experiment inputs missing") end
    local source_digest = label == "baseline" and config.baseline_sha256 or config.candidate_sha256
    if type(source_digest) ~= "string" or #source_digest ~= 64 or not source_digest:match("^[0-9a-f]+$") then
        return fail("INVALID", "host source digest is invalid")
    end
    local entry_id = label == "baseline" and "bee.research.benchmark.probe:canonical" or "bee.research.demo:canonical"
    local entry = registry.get(entry_id)
    local entry_data = entry and bounds.object(entry.data) or nil
    local source = entry_data and entry_data.source or nil
    if type(source) ~= "string" or hash.sha256(source) ~= source_digest then
        return fail("CONFLICT", "effective encoder differs from the reviewed source")
    end
    local message_id, hash_error = hash.sha256(bound.binding_id .. "\n" .. label .. "\n" .. source_digest)
    if not message_id then return fail("INVALID", tostring(hash_error)) end
    local cached, lookup_error = previous(bound, MEASUREMENT_ACTOR, message_id)
    if cached or lookup_error then return cached or lookup_error or fail("INVALID", "lookup failed") end
    local target = label == "baseline" and "bee.research.measurement:measure" or "bee.research.demo:measure"
    local pending, start_error = funcs.async(target, label)
    if not pending then return fail("UNAVAILABLE", tostring(start_error)) end
    local response = pending:response()
    local deadline = time.after("5s")
    local selected = channel.select({response:case_receive(), deadline:case_receive()})
    if not selected.ok or selected.channel == deadline then
        pending:cancel()
        return fail("TIMEOUT", "benchmark result deadline exceeded; no measurement committed")
    end
    local result, result_error = pending:result()
    if not result then return fail("UNAVAILABLE", tostring(result_error)) end
    local measurement = bounds.object(result:data())
    if not measurement then return fail("INVALID", "benchmark returned no measurement") end
    measurement.label, measurement.source_sha256 = label, source_digest
    local encoded, encode_error = json.encode(measurement)
    if not encoded then return fail("INVALID", tostring(encode_error)) end
    local producer, producer_error = security.new_actor(MEASUREMENT_ACTOR)
    if not producer then return fail("DENIED", tostring(producer_error)) end
    local writer, writer_error = funcs.new():with_actor(producer)
    if not writer then return fail("DENIED", tostring(writer_error)) end
    local recorded, record_error = call("bee.threads.service:record", {thread_id = bound.thread_id,
        idempotency_key = message_id, kind = "observation", source = "mcp",
        body = {type = "extension", event_key = message_id, data = {type = "extension",
            event_name = "bee.research.measurement", event_revision = "1", payload_json = encoded}},
        context = {action_id = bound.action_id, attempt_id = bound.attempt_id}}, writer)
    if not recorded then
        -- Another identical request may have won, or the commit reply was lost.
        -- Only a real owner read can establish the result after uncertainty.
        local winner, read_error = previous(bound, MEASUREMENT_ACTOR, message_id)
        return winner or read_error or record_error or fail("UNKNOWN", "measurement commit outcome unknown")
    end
    return {ok = true, replayed = false, value = {measurement = measurement,
        record_id = recorded.record_id, sequence = recorded.sequence}}
end
return {run = run}
