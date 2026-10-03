-- MIT. The carrier end to end against the Claude protocol fixture: the
-- agreed lifecycle order in thread records, normalized output with
-- provenance, settlement from the terminal envelope only, placement states
-- as observations, and recovery from real crash points without duplicate
-- records or duplicate settlement.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local exec = require("exec")
local quote = require("quote")
local placement_fixture = require("placement_fixture")
local exits = require("exits")
local ACTOR = "bee.test.carrier"
local POLICY = "bee.harness.catalog:fixture_policy"
local ROOT = "bee.harness.catalog:project_fixture"
local BINDING = "bee.driver.claude.binding:binding"
local counter = 0

type RegistryInput = {id: string, kind: string, meta: {[string]: unknown}, data: unknown, dependency_root: boolean}
local function registry_input(value: {[string]: unknown}): RegistryInput
    local id, kind, meta, dependency_root = value.id, value.kind, value.meta, value.dependency_root
    assert(type(id) == "string" and type(kind) == "string", "fixture registry entry identity")
    local metadata: {[string]: unknown} = {}
    if meta ~= nil then
        assert(type(meta) == "table", "fixture registry metadata")
        for key, item in pairs(meta) do metadata[key] = item end
    end
    assert(dependency_root == nil or type(dependency_root) == "boolean", "fixture registry dependency root")
    return {id = id, kind = kind, meta = metadata, data = value.data, dependency_root = dependency_root == true}
end

local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy", "bee.harness.security:carrier_policy", "bee.harness.catalog:carrier_spawn_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(ACTOR)
local function call(target: string, request: unknown): {[string]: unknown}
    local result, err = funcs.new():with_actor(actor):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = result
    if not reply.ok then error(target .. ": " .. tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function fixture_bin(): string
    local bin, err = env.get("bee.harness.catalog:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
local function command(argv: {string})
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local child = assert(executor:exec(quote.line(argv)))
    assert(child:start())
    local code, err = child:wait()
    executor:release()
    assert(code == 0, "fixture command: " .. tostring(err))
end
local function stream(name: string): string
    local base, err = env.get("bee.harness.catalog:fixture_streams")
    if err or type(base) ~= "string" or base == "" then error("BEE_FIXTURE_STREAMS is not set for the test runtime") end
    return base .. "/claude/stream-json-2/" .. name
end
local function install_policy()
    local entry = registry.get(POLICY)
    if not entry then error("fixture policy entry") end
    local data = assert(bounds.object(entry.data))
    data.executables = {claude = fixture_bin() .. "/claude"}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    local applied, err = changes:apply()
    if not applied then error("install fixture policy: " .. tostring(err)) end
end
local function admit_root()
    -- These runner fixtures exercise host-configured roots with literal grant labels.
    local mode = assert(registry.get("bee.placement.native.env:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    local selected = registry.snapshot():changes()
    selected:update(mode)
    local configured, mode_error = selected:apply()
    if not configured then error("fixture resource mode: " .. tostring(mode_error)) end
    local entry = registry.get("bee.placement.native.env:placement_admitted_roots")
    if not entry then error("admitted roots entry") end
    local data = assert(bounds.object(entry.data))
    local roots = principals.objects(data.roots)
    data.roots = roots
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    local changes = registry.snapshot():changes()
    changes:update(registry_input(entry))
    local applied, err = changes:apply()
    if not applied then error("admit root: " .. tostring(err)) end
end
local function thread(): string
    local created = call("bee.threads.binding:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Carrier"})
    if type(created.thread_id) ~= "string" then error("invalid fixture created.thread_id") end
    return created.thread_id
end
local function request(thread_id: string, attempt_id: string, environment: {[string]: string}): {[string]: unknown}
    local placement = placement_fixture.resolve()
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = ACTOR, owner_incarnation = 1, binding_ref = BINDING,
        profile_id = "batch", brief = "ping", policy_ref = POLICY, resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = environment, working_directory = "project", placement_binding_ref = placement.binding_id,
        placement_binding_digest = placement.binding_digest}
end
type Outcome = {value: {[string]: unknown}?, error: string?}
local function spawn_carrier(entry: string, request_value: {[string]: unknown}, mode: string, crash_after: string?, batch: number?, pause_after: string?, slow_commit_ms: number?): string
    local spawner = process.with_context({}):with_actor(actor):with_scope(scope())
    local pid, err = spawner:spawn_monitored(entry, "bee:workers", request_value, mode, process.pid(), crash_after, batch, pause_after, slow_commit_ms)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
-- Exits arrive on one events channel, so several carriers are awaited
-- together and every exit is kept.
local exited: {[string]: Outcome} = {}
local function await_carriers(pids: {string}, label: string?): {[string]: Outcome}
    local events = assert(process.events())
    return exits.collect(pids, exited, function(poll: boolean): unknown
        if poll then
            local selected = channel.select({events:case_receive(), default = true})
            if selected.default or not selected.ok then return nil end
            return selected.value
        end
        local selected = channel.select({events:case_receive()})
        if selected.ok and selected.channel == events then return selected.value end
        return nil
    end, label or "carrier")
end
local function await_carrier(pid: string, label: string?): Outcome
    return assert(await_carriers({pid}, label)[pid])
end
local function run_carrier(entry: string, request_value: {[string]: unknown}, mode: string, crash_after: string?, batch: number?, pause_after: string?, slow_commit_ms: number?): Outcome
    return await_carrier(spawn_carrier(entry, request_value, mode, crash_after, batch, pause_after, slow_commit_ms), crash_after or mode)
end
local function kinds(thread_id: string): ({string}, {{[string]: unknown}})
    local list: {string} = {}
    local records: {{[string]: unknown}} = {}
    local cursor = 0
    while true do
        local page = call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        local current = principals.objects(page.records)
        for _, item in ipairs(current) do
            list[#list + 1] = tostring(item.kind)
            records[#records + 1] = item
        end
        if page.has_more ~= true then break end
        local scanned = page.scanned_through
        if type(scanned) ~= "number" or scanned <= cursor then error("thread record page did not advance") end
        cursor = scanned
    end
    return list, records
end
local function count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do
        if item == wanted then total = total + 1 end
    end
    return total
end
local function observations(records: {{[string]: unknown}}, event_name: string?): {{[string]: unknown}}
    local out: {{[string]: unknown}} = {}
    for _, item in ipairs(records) do
        if item.kind == "observation" then
            local body = assert(bounds.object(item.body))
            if event_name == nil and item.source == "stream" then out[#out + 1] = item end
            if event_name ~= nil and item.source == "bee" then
                local data = assert(bounds.object(body.data))
                if data.event_name == event_name then out[#out + 1] = item end
            end
        end
    end
    return out
end
local function define_tests()
    test.describe("Harness carrier", function()
        install_policy()
        admit_root()
        test.it("runs a fixture turn in the agreed order and settles from the terminal envelope", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local outcome = run_carrier("bee.harness.service:carrier", request(thread_id, attempt_id, {BEE_FIXTURE_STREAM = stream("plain.jsonl")}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local settlement = assert(bounds.object(outcome.value.settlement))
            test.eq(settlement.outcome, "succeeded")
            test.eq(settlement.answer, "pong")
            test.is_true((outcome.value.revision) > 1)
            local list, records = kinds(thread_id)
            test.eq(list[1], "action.admitted")
            test.eq(list[2], "attempt.prepared")
            test.eq(list[3], "turn.request")
            test.eq(count(list, "attempt.started"), 1)
            test.eq(count(list, "turn.end"), 1)
            test.eq(count(list, "receipt"), 1)
            local started_at, first_stream, turn_end_at, receipt_at = 0, 0, 0, 0
            for index, item in ipairs(list) do
                if item == "attempt.started" then started_at = index end
                if item == "observation" and records[index].source == "stream" and first_stream == 0 then first_stream = index end
                if item == "turn.end" then turn_end_at = index end
                if item == "receipt" then receipt_at = index end
            end
            test.is_true(started_at > 3)
            test.is_true(first_stream > started_at)
            test.is_true(turn_end_at > first_stream)
            test.is_true(receipt_at > turn_end_at)
            local streamed = observations(records, nil)
            test.is_true(#streamed >= 3)
            local texts: {string} = {}
            for _, item in ipairs(streamed) do
                local body = assert(bounds.object(item.body))
                test.is_nil(body.raw_ref)
                test.eq(item.attempt_id, attempt_id)
                test.eq(item.turn_id, "turn:" .. attempt_id .. ":1")
                texts[#texts + 1] = tostring(body.type)
            end
            test.is_true(count(texts, "text") >= 1)
            test.is_true(count(texts, "turn.signal") >= 1)
            local placements = observations(records, "bee.placement.attempt")
            test.is_true(#placements >= 1)
            local stored = call("bee.threads.binding:checkpoint", {thread_id = thread_id, attempt_id = attempt_id})
            test.eq(stored.attempt_state, "ended")
            test.eq(stored.checkpoint_revision, outcome.value.revision)
            local point = assert(bounds.object(stored.checkpoint))
            test.eq((assert(bounds.object(point.terminal))).answer, "pong")
            local placement = assert(bounds.object(outcome.value.placement))
            test.eq(placement.execution_state, "exited")
            test.eq(placement.cleanup_state, "complete")
        end)
        test.it("reports api errors as failed turns and cut streams as uncertain", function()
            local failed = run_carrier("bee.harness.service:carrier", request(thread(), fresh("attempt"), {BEE_FIXTURE_STREAM = stream("api_error.jsonl")}), "open", nil)
            if not failed.value then error("carrier failed: " .. tostring(failed.error)) end
            local failure = assert(bounds.object(failed.value.settlement))
            test.eq(failure.outcome, "failed")
            local thread_id = thread()
            local cut = run_carrier("bee.harness.service:carrier", request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_TRUNCATE = "1"}), "open", nil)
            if not cut.value then error("carrier failed: " .. tostring(cut.error)) end
            local uncertain = assert(bounds.object(cut.value.settlement))
            test.eq(uncertain.outcome, "uncertain")
            local list = kinds(thread_id)
            test.eq(count(list, "receipt"), 1)
            test.eq(count(list, "turn.end"), 1)
        end)
        test.it("records stderr written after the terminal frame and both pipe ends before settlement", function()
            local policy = assert(registry.get(POLICY))
            local data = assert(bounds.object(policy.data))
            local saved = data.gateway_hooks
            data.gateway_hooks = {}
            local selected = registry.snapshot():changes()
            selected:update(policy)
            assert(selected:apply())
            local thread_id = thread()
            local launch = request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("success.jsonl"), BEE_FIXTURE_AFTER_CLOSE = "1"})
            local outcome = run_carrier("bee.harness.service:carrier", launch, "open")
            data.gateway_hooks = saved
            local restored = registry.snapshot():changes()
            restored:update(policy)
            assert(restored:apply())
            assert(outcome.value, tostring(outcome.error))
            local _, records = kinds(thread_id)
            local late = 0
            for _, item in ipairs(observations(records)) do
                local data = assert(bounds.object((assert(bounds.object(item.body))).data))
                if data.type == "notice" and data.code == "stderr" and tostring((assert(bounds.object(data.content))).text):find("after:terminal", 1, true) then late = late + 1 end
            end
            test.eq(late, 1)
            local output = observations(records, "bee.carrier.output")
            test.eq(#output, 1)
            local data = assert(bounds.object((assert(bounds.object(output[1].body))).data))
            local payload = assert(bounds.object(require("json").decode(tostring(data.payload_json))))
            test.eq(payload.state, "complete")
        end)
        test.it("settles a stream that ends without a result only after the child's exit and remaining output", function()
            local thread_id = thread()
            local cut = run_carrier("bee.harness.service:carrier", request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_TRUNCATE = "1", BEE_FIXTURE_LATE_STDERR = "1"}), "open", nil)
            if not cut.value then error("carrier failed: " .. tostring(cut.error)) end
            local settlement = assert(bounds.object(cut.value.settlement))
            test.eq(settlement.outcome, "uncertain")
            test.is_true(settlement.exit_reconciled == true)
            local placement = assert(bounds.object(cut.value.placement))
            test.eq((assert(bounds.object(placement.exit))).code, 0)
            local _, records = kinds(thread_id)
            local late = 0
            for _, item in ipairs(observations(records, nil)) do
                local data = assert(bounds.object((assert(bounds.object(item.body))).data))
                if data.type == "notice" and data.code == "stderr" and tostring((assert(bounds.object(data.content))).text):find("late:stderr", 1, true) then late = late + 1 end
            end
            test.eq(late, 1, "stderr written after stdout ended")
        end)
        local function stream_counts(records: {{[string]: unknown}}): (integer, integer, integer)
            local texts, ended, reads = 0, 0, 0
            for _, item in ipairs(observations(records, nil)) do
                local body = assert(bounds.object(item.body))
                local data = assert(bounds.object(body.data))
                if data.type == "text" then texts = texts + 1 end
                if data.type == "turn.signal" and data.phase == "ended" then ended = ended + 1 end
                -- The fixture reports the line it read as a stdout frame
                -- ahead of its stream, so the evidence precedes the result.
                if data.type == "notice" and data.code == "informational" then
                    local content = assert(bounds.object(data.content))
                    if content.text == "read:ping" then reads = reads + 1 end
                end
            end
            return texts, ended, reads
        end
        local function writes(records: {{[string]: unknown}}): {string}
            local phases: {string} = {}
            for _, item in ipairs(observations(records, "bee.carrier.write")) do
                local body = assert(bounds.object(item.body))
                local data = assert(bounds.object(body.data))
                local payload = assert(bounds.object(require("json").decode(tostring(data.payload_json))))
                phases[#phases + 1] = tostring(payload.write_id) .. ":" .. tostring(payload.phase)
            end
            return phases
        end
        test.it("recovers from a checkpointed partial frame and from a crash between events of one chunk", function()
            local baseline_thread = thread()
            local baseline = run_carrier("bee.harness.service:carrier", request(baseline_thread, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl")}), "open", nil)
            if not baseline.value then error("baseline failed: " .. tostring(baseline.error)) end
            local _, baseline_records = kinds(baseline_thread)
            local base_texts, base_ended = stream_counts(baseline_records)
            local split_thread = thread()
            local split = request(split_thread, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_SPLIT = "1", BEE_FIXTURE_LINGER = "1"})
            local crashed = run_carrier("bee.harness.catalog:carrier_faulted", split, "open", "committed")
            test.is_nil(crashed.value)
            local resumed = run_carrier("bee.harness.catalog:carrier_faulted", split, "resume", nil)
            if not resumed.value then error("split resume failed: " .. tostring(resumed.error)) end
            test.eq((assert(bounds.object(resumed.value.settlement))).answer, "pong")
            local _, split_records = kinds(split_thread)
            local split_texts, split_ended = stream_counts(split_records)
            test.eq(split_texts, base_texts)
            test.eq(split_ended, base_ended)
            local batch_thread = thread()
            local batched = request(batch_thread, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_LINGER = "1"})
            local partial = run_carrier("bee.harness.catalog:carrier_faulted", batched, "open", "partial_commit", 2)
            test.is_nil(partial.value)
            test.is_true(tostring(partial.error):find("crash after partial_commit", 1, true) ~= nil)
            local continued = run_carrier("bee.harness.catalog:carrier_faulted", batched, "resume", nil, 2)
            if not continued.value then error("partial resume failed: " .. tostring(continued.error)) end
            test.eq((assert(bounds.object(continued.value.settlement))).answer, "pong")
            local batch_list, batch_records = kinds(batch_thread)
            local batch_texts, batch_ended = stream_counts(batch_records)
            test.eq(batch_texts, base_texts)
            test.eq(batch_ended, base_ended)
            test.eq(count(batch_list, "receipt"), 1)
        end)
        test.it("carries a frame larger than the checkpointable carry and resumes across it", function()
            -- A provider echoes a whole tool result as one frame, which may be
            -- larger than a checkpoint can carry. The carrier holds the
            -- runner's acknowledgment until the frame completes.
            local thread_id = thread()
            local outcome = run_carrier("bee.harness.service:carrier", request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_HUGE = "1"}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            test.eq((assert(bounds.object(outcome.value.settlement))).answer, "pong")
            local function framing_notices(records: {{[string]: unknown}}): integer
                local framing = 0
                for _, item in ipairs(observations(records, nil)) do
                    local data = assert(bounds.object((assert(bounds.object(item.body))).data))
                    if data.type == "notice" and data.code == "framing" then framing = framing + 1 end
                end
                return framing
            end
            local _, records = kinds(thread_id)
            test.eq(framing_notices(records), 0)
            local resumed_thread = thread()
            local held = request(resumed_thread, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_HUGE = "1", BEE_FIXTURE_LINGER = "1"})
            local crashed = run_carrier("bee.harness.catalog:carrier_faulted", held, "open", "committed")
            test.is_nil(crashed.value)
            local resumed = run_carrier("bee.harness.catalog:carrier_faulted", held, "resume", nil)
            if not resumed.value then error("resume across a held frame failed: " .. tostring(resumed.error)) end
            test.eq((assert(bounds.object(resumed.value.settlement))).answer, "pong")
            local _, resumed_records = kinds(resumed_thread)
            test.eq(framing_notices(resumed_records), 0)
            local reported = assert(bounds.object(funcs.call("bee.harness.binding:capabilities", {})))
            test.is_true((reported.max_frame_bytes) > 16384)
            test.eq(reported.takeover, "claim")
        end)
        test.it("omits an oversized status frame and continues to the terminal result", function()
            local thread_id = thread()
            local outcome = run_carrier("bee.harness.service:carrier", request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_HUGE = "10400"}), "open", nil)
            if not outcome.value then error("carrier failed: " .. tostring(outcome.error)) end
            local settled = assert(bounds.object(outcome.value.settlement))
            local _, records = kinds(thread_id)
            local framing = 0
            local codes: {string} = {}
            for _, item in ipairs(observations(records, nil)) do
                local data = assert(bounds.object((assert(bounds.object(item.body))).data))
                if data.type == "notice" and data.code == "oversized_frame" then framing = framing + 1 end
                if data.type == "notice" then codes[#codes + 1] = tostring(data.code) end
            end
            if settled.answer ~= "pong" then error("oversized result: " .. tostring(settled.outcome) .. ": " .. tostring(settled.reason) .. ": " .. table.concat(codes, ",")) end
            test.eq(framing, 1)
        end)
        test.it("writes input under control records and reconciles both write boundaries after a crash", function()
            local clean_thread = thread()
            local clean_pid = spawn_carrier("bee.harness.service:carrier", request(clean_thread, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_READ = "1"}), "open", nil)
            process.send(clean_pid, "bee.carrier.input", {write_id = "w1", data = "ping\n"})
            local clean = await_carrier(clean_pid)
            if not clean.value then error("write run failed: " .. tostring(clean.error)) end
            test.eq((assert(bounds.object(clean.value.settlement))).answer, "pong")
            local _, clean_records = kinds(clean_thread)
            local _, _, clean_reads = stream_counts(clean_records)
            test.eq(clean_reads, 1, "clean child read evidence")
            test.eq(table.concat(writes(clean_records), ","), "w1:intended,w1:accepted")
            for _, crash in ipairs({"write_intended", "write_dispatched"}) do
                local thread_id = thread()
                local launch = request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_READ = "1", BEE_FIXTURE_LINGER = "2"})
                local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", crash)
                process.send(pid, "bee.carrier.input", {write_id = "w2", data = "ping\n"})
                local crashed = await_carrier(pid)
                test.is_true(tostring(crashed.error):find("crash after " .. crash, 1, true) ~= nil)
                local resumed = run_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil)
                if not resumed.value then error(crash .. ": resume failed: " .. tostring(resumed.error)) end
                test.eq((assert(bounds.object(resumed.value.settlement))).answer, "pong")
                local _, records = kinds(thread_id)
                local _, _, reads = stream_counts(records)
                test.eq(reads, 1, crash .. " child read evidence")
                test.eq(table.concat(writes(records), ","), "w2:intended,w2:accepted")
            end
        end)
        -- A faulted carrier tells the controller when it holds at a step.
        local function await_paused(paused: Channel<process.Message>, pid: string, wanted: string)
            local deadline = time.after("30s")
            while true do
                local selected = channel.select({paused:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error(pid .. " never held at " .. wanted) end
                local message = selected.value
                if tostring(message:from()) == pid and message:payload():data() == wanted then return end
            end
        end
        -- Placement's record that the runner installed a generation: the old
        -- generation's input and acknowledgements are refused from then on.
        local function await_fenced(attempt_id: string, generation: integer)
            local wanted = "runner installed generation " .. tostring(generation)
            for _ = 1, 600 do
                local page = call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 128})
                for _, item in ipairs(principals.objects(page.evidence)) do
                    if item.kind == "attach.fenced" and item.detail == wanted then return end
                end
                time.sleep("50ms")
            end
            error("generation " .. tostring(generation) .. " was never fenced on " .. attempt_id)
        end
        test.it("continues from what a live carrier committed between the replacement's checkpoint read and its claim", function()
            local thread_id = thread()
            local launch = request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_READ = "1", BEE_FIXTURE_PACE = "0.3"})
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local old = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, nil, "write_intended,write_settled")
            process.send(old, "bee.carrier.input", {write_id = "w5", data = "ping\n"})
            await_paused(paused, old, "write_intended")
            local replacement_pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil, nil, "checkpoint_read")
            await_paused(paused, replacement_pid, "checkpoint_read")
            -- The old carrier is not fenced yet: its write is accepted and
            -- committed after the replacement read the checkpoint. It then
            -- holds, so it commits nothing more until the replacement settles.
            process.send(old, "bee.carrier.continue", {go = true})
            await_paused(paused, old, "write_settled")
            process.send(replacement_pid, "bee.carrier.continue", {go = true})
            local replacement = await_carrier(replacement_pid, "replacement")
            process.unlisten(paused)
            if not replacement.value then error("replacement failed: " .. tostring(replacement.error)) end
            -- Once the replacement has settled, the old carrier's next
            -- commit is refused because the attempt has ended.
            process.send(old, "bee.carrier.input", {write_id = "late", data = "late\n"})
            process.send(old, "bee.carrier.continue", {go = true})
            local stale = await_carrier(old, "old carrier")
            test.is_nil(stale.value)
            if not tostring(stale.error):find("INVALID_STATE: attempt has ended", 1, true) then error("old carrier ended with: " .. tostring(stale.error)) end
            test.eq((assert(bounds.object((assert(bounds.object(replacement.value))).settlement))).answer, "pong")
            local list, records = kinds(thread_id)
            local _, _, reads = stream_counts(records)
            test.eq(reads, 1, "child read evidence")
            test.eq(table.concat(writes(records), ","), "w5:intended,w5:accepted")
            test.eq(count(list, "receipt"), 1)
        end)
        test.it("fences a live carrier once a replacement claims the attempt", function()
            local thread_id = thread()
            local launch = request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_PACE = "0.4"})
            -- The old carrier holds mid-stream, after committing its first
            -- output, until the replacement is fenced in.
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local old = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, nil, "committed")
            await_paused(paused, old, "committed")
            process.unlisten(paused)
            local replacement_pid = spawn_carrier("bee.harness.service:carrier", launch, "resume", nil)
            await_fenced(assert(bounds.id(launch.attempt_id)), 2)
            process.send(old, "bee.carrier.continue", {go = true})
            process.send(old, "bee.carrier.input", {write_id = "late", data = "late\n"})
            local stale = await_carrier(old)
            test.is_nil(stale.value)
            if not tostring(stale.error):find("CONFLICT", 1, true) then error("old carrier ended with: " .. tostring(stale.error)) end
            local replacement = await_carrier(replacement_pid)
            if not replacement.value then error("replacement failed: " .. tostring(replacement.error)) end
            test.eq((assert(bounds.object(replacement.value.settlement))).answer, "pong")
            local list, records = kinds(thread_id)
            test.eq(count(list, "receipt"), 1)
            test.eq(count(list, "turn.end"), 1)
            test.eq(#writes(records), 0)
        end)
        test.it("refuses an old carrier's admitted write dispatched after the replacement is fenced", function()
            local thread_id = thread()
            local launch = request(thread_id, fresh("attempt"), {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_READ = "1", BEE_FIXTURE_PACE = "0.3"})
            local old = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", nil, nil, "write_intended")
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            process.send(old, "bee.carrier.input", {write_id = "w9", data = "ping\n"})
            await_paused(paused, old, "write_intended")
            process.unlisten(paused)
            local replacement_pid = spawn_carrier("bee.harness.service:carrier", launch, "resume", nil)
            await_fenced(assert(bounds.id(launch.attempt_id)), 2)
            process.send(old, "bee.carrier.continue", {go = true})
            local both = await_carriers({old, replacement_pid}, "old carrier and replacement")
            local stale = both[old]
            test.is_nil(stale.value)
            if not tostring(stale.error):find("CONFLICT", 1, true) then error("old carrier ended with: " .. tostring(stale.error)) end
            local waited, replacement_or_error = true, both[replacement_pid]
            if not replacement_or_error.value then
                local list, records = kinds(thread_id)
                local stored = call("bee.threads.binding:checkpoint", {thread_id = thread_id, attempt_id = launch.attempt_id})
                local point = assert(bounds.object(stored.checkpoint))
                error("replacement failed: " .. tostring(replacement_or_error.error) .. "; records " .. table.concat(list, ",") .. "; writes " .. table.concat(writes(records), ",") .. "; pending " .. tostring(#(principals.items(point.pending_writes))) .. "; epoch " .. tostring(stored.carrier_epoch) .. "; placement " .. require("json").encode(call("bee.placement.native.binding:evidence", {attempt_id = launch.attempt_id})))
            end
            local replacement = replacement_or_error
            test.eq((assert(bounds.object(replacement.value))).settlement and (assert(bounds.object((assert(bounds.object(replacement.value))).settlement))).answer, "pong")
            local _, records = kinds(thread_id)
            local _, _, reads = stream_counts(records)
            test.eq(reads, 1, "replacement child read evidence")
            test.eq(table.concat(writes(records), ","), "w9:intended,w9:accepted")
        end)
        test.it("recovers from crash points without duplicate records or settlement", function()
            for _, crash in ipairs({"placement_started", "committed", "stdout_ended", "stderr_ended", "turn_ended"}) do
                local thread_id = thread()
                local attempt_id = fresh("attempt")
                local launch = request(thread_id, attempt_id, {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_LINGER = "1"})
                local crashed = run_carrier("bee.harness.catalog:carrier_faulted", launch, "open", crash)
                test.is_nil(crashed.value)
                test.is_true(tostring(crashed.error):find("crash after " .. crash, 1, true) ~= nil)
                local resumed = run_carrier("bee.harness.catalog:carrier_faulted", launch, "resume", nil)
                if not resumed.value then error(crash .. ": resume failed: " .. tostring(resumed.error)) end
                local settlement = assert(bounds.object(resumed.value.settlement))
                test.eq(settlement.outcome, "succeeded", crash .. ": " .. require("json").encode(settlement))
                test.eq(settlement.answer, "pong")
                local list, records = kinds(thread_id)
                test.eq(count(list, "attempt.started"), 1)
                test.eq(count(list, "turn.end"), 1)
                test.eq(count(list, "receipt"), 1)
                local answers = 0
                for _, item in ipairs(observations(records, nil)) do
                    local body = assert(bounds.object(item.body))
                    local data = assert(bounds.object(body.data))
                    if data.type == "turn.signal" and data.phase == "ended" then answers = answers + 1 end
                end
                test.eq(answers, 1)
                local stored = call("bee.threads.binding:checkpoint", {thread_id = thread_id, attempt_id = attempt_id})
                test.eq(stored.carrier_epoch, 2)
                local stale = funcs.new():with_actor(actor):with_scope(scope()):call("bee.threads.binding:commit", {thread_id = thread_id, idempotency_key = fresh("key"), attempt_id = attempt_id,
                    carrier_epoch = 1, expected_revision = stored.checkpoint_revision, checkpoint = stored.checkpoint, records = {}})
                test.eq((assert(bounds.object(stale))).ok, false)
            end
        end)
    end)
end
local function define_stream_tests()
    test.describe("Harness carrier stream burst", function()
        install_policy()
        admit_root()
        test.it("preserves a burst larger than the output spool while the consumer is slow", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local expected_deltas = 2000
            local fixture_delta = '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'
                .. string.rep("x", 80) .. '"}}}\n'
            test.is_true(expected_deltas * #fixture_delta > 256 * 1024,
                "the emitted frames exceed the placement output spool")
            local environment = {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_FLOOD = tostring(expected_deltas),
                BEE_FIXTURE_FLOOD_PACE = "0", BEE_FIXTURE_FLOOD_EXIT = "1", BEE_FIXTURE_STDERR_EOF = "1"}
            local outcome = run_carrier("bee.harness.catalog:carrier_faulted", request(thread_id, attempt_id, environment),
                "open", nil, nil, nil, 40)
            if not outcome.value then error("short-frame stream failed: " .. tostring(outcome.error)) end
            local settlement = assert(bounds.object(outcome.value.settlement))
            test.eq(settlement.outcome, "succeeded", require("json").encode(settlement))
            test.eq(settlement.answer, "flood-complete")
            local _, records = kinds(thread_id)
            local deltas = 0
            for _, item in ipairs(observations(records, nil)) do
                local data = assert(bounds.object((assert(bounds.object(item.body))).data))
                if data.type == "text" then
                    test.eq(data.text, string.rep("x", 80), "every burst delta retains its full content")
                    deltas = deltas + 1
                end
            end
            test.eq(deltas, expected_deltas)
            local state, truncated = "", 0
            for _, item in ipairs(observations(records, "bee.carrier.output")) do
                local data = assert(bounds.object((assert(bounds.object(item.body))).data))
                local payload = assert(bounds.object(require("json").decode(tostring(data.payload_json))))
                if payload.state == "truncated" then truncated = truncated + 1 end
                if payload.stream == nil then state = tostring(payload.state) end
            end
            test.is_true(state == "incomplete" or state == "complete",
                "terminal output is complete or explicitly incomplete while EOF is in flight")
            test.eq(truncated, 0)
        end)
    end)
end
local function define_drain_tests()
    test.describe("Harness carrier post-exit drain", function()
        install_policy()
        admit_root()
        test.it("keeps the post-exit drain budget while a slow carrier holds the spool full", function()
            local policy = registry.get(POLICY)
            if not policy then error("fixture policy entry") end
            local data = assert(bounds.object(policy.data))
            local saved_drain = data.runner_drain_ms
            local saved_carrier_drain = data.drain_ms
            data.runner_drain_ms = 2000
            -- The carrier settles past runner_drain_ms + drain_ms without
            -- the terminal envelope; a wide carrier drain isolates the
            -- runner's post-exit deadline under test.
            data.drain_ms = 300000
            local narrowed = registry.snapshot():changes()
            narrowed:update(policy)
            local shrunk, shrink_error = narrowed:apply()
            if not shrunk then error("shrink runner drain: " .. tostring(shrink_error)) end
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local expected = 280
            -- 280 deltas of 2000 bytes are some 590 KB, far past the 256 KB
            -- spool: the spool pins full while the child writes, so the pipe
            -- tail holding the result is still unread at the exit and the
            -- drain arms. Each commit waits 800 ms, so the carrier drains at
            -- most 20 KB/s: a 2 s wall-clock window past the exit would let
            -- at most 40 KB of the full pipes leave, while the full drain
            -- takes some seventeen times it. Reads paused at the spool limit
            -- do not consume the drain budget, so the terminal envelope
            -- arrives.
            local environment = {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_FLOOD = tostring(expected),
                BEE_FIXTURE_FLOOD_TEXT = "2000", BEE_FIXTURE_FLOOD_PACE = "0"}
            local outcome = run_carrier("bee.harness.catalog:carrier_faulted", request(thread_id, attempt_id, environment),
                "open", nil, nil, nil, 800)
            data.runner_drain_ms = saved_drain
            data.drain_ms = saved_carrier_drain
            local widened = registry.snapshot():changes()
            widened:update(policy)
            local restored, restore_error = widened:apply()
            if not restored then error("restore runner drain: " .. tostring(restore_error)) end
            if not outcome.value then error("slow drain run failed: " .. tostring(outcome.error)) end
            local settlement = assert(bounds.object(outcome.value.settlement))
            test.eq(settlement.outcome, "succeeded")
            test.eq(settlement.answer, "flood-complete")
            local _, records = kinds(thread_id)
            local deltas = 0
            for _, item in ipairs(observations(records, nil)) do
                local body = assert(bounds.object(item.body))
                local data = assert(bounds.object(body.data))
                if data.type == "text" then
                    test.eq(data.text, string.rep("x", 2000), "every burst delta retains its full content")
                    deltas = deltas + 1
                end
            end
            test.eq(deltas, expected)
            local truncated = 0
            for _, item in ipairs(observations(records, "bee.carrier.output")) do
                local body = assert(bounds.object(item.body))
                local payload = assert(bounds.object(require("json").decode(tostring((assert(bounds.object(body.data))).payload_json))))
                if payload.stream ~= nil and payload.state == "truncated" then truncated = truncated + 1 end
            end
            test.eq(truncated, 0)
        end)
        test.it("still truncates a silent consumer at the drain deadline", function()
            local policy = registry.get(POLICY)
            if not policy then error("fixture policy entry") end
            local data = assert(bounds.object(policy.data))
            local saved_drain = data.runner_drain_ms
            local saved_retain = data.retain_ms
            data.runner_drain_ms = 1000
            data.retain_ms = 2000
            local narrowed = registry.snapshot():changes()
            narrowed:update(policy)
            local shrunk, shrink_error = narrowed:apply()
            if not shrunk then error("shrink runner drain: " .. tostring(shrink_error)) end
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local gate = require("orphan_gate")
            local release = fixture_bin() .. "/" .. fresh("silent-orphan")
            gate.create(release)
            local ok, problem = pcall(function()
                local launch = request(thread_id, attempt_id, {BEE_FIXTURE_STREAM = stream("plain.jsonl"),
                    BEE_FIXTURE_ORPHAN_FIFO = release})
                local paused = assert(process.listen("bee.carrier.paused", {message = true}))
                local pid = spawn_carrier("bee.harness.catalog:carrier_faulted", launch, "open", "committed", nil, "placement_started")
                local events = assert(process.events())
                exits.paused(pid, "placement_started", exited, function(poll: boolean): unknown
                    local selected
                    if poll then
                        selected = channel.select({paused:case_receive(), default = true})
                        if selected.default then return nil end
                    else selected = channel.select({paused:case_receive(), events:case_receive()}) end
                    assert(selected.ok, "silent-consumer barrier observation closed")
                    if selected.channel == events then return selected.value end
                    local message = selected.value
                    return {kind = "pause", from = tostring(message:from()), step = message:payload():data()}
                end)
                local status = call("bee.placement.native.binding:status", {attempt_id = attempt_id})
                local runner = assert(bounds.text(assert(bounds.object(status.attempt)).runner, 256))
                assert(process.monitor(runner))
                assert(process.send(pid, "bee.carrier.continue", {}))
                local outcomes = await_carriers({pid, runner}, "silent-consumer supervision")
                test.is_nil(outcomes[pid].value)
                test.is_true(tostring(outcomes[pid].error):find("crash after committed", 1, true) ~= nil)
                test.is_nil(outcomes[runner].error)
                process.unmonitor(runner)
                process.unlisten(paused)
                local drained, finished, child_exited, lost = false, false, false, false
                local page = call("bee.placement.native.binding:evidence", {attempt_id = attempt_id, limit = 128})
                for _, item in ipairs(principals.objects(page.evidence)) do
                    if item.kind == "output.drain_elapsed" then drained = true end
                    if item.kind == "runner.finished" then finished = true end
                    if item.kind == "child.exited" then child_exited = true end
                    if item.kind == "output.lost" then lost = true end
                end
                test.is_true(child_exited, "the producer exits independently of its pipe-holding descendant")
                test.is_true(drained, "open descendant pipes exhaust the declared post-exit drain")
                test.is_true(lost, "the silent carrier leaves unacknowledged output for retention expiry")
                test.is_true(finished)
            end)
            gate.release(release)
            data.runner_drain_ms = saved_drain
            data.retain_ms = saved_retain
            local widened = registry.snapshot():changes()
            widened:update(policy)
            local restored, restore_error = widened:apply()
            if not restored then error("restore runner drain: " .. tostring(restore_error)) end
            if not ok then error(tostring(problem)) end
        end)
        test.it("marks output truncated when descendants hold the pipes past the runner's drain and never settles it as complete", function()
            local thread_id = thread()
            local attempt_id = fresh("attempt")
            local release = fixture_bin() .. "/" .. fresh("truncated-orphan")
            local gate = require("orphan_gate")
            gate.create(release)
            local outcome = run_carrier("bee.harness.service:carrier", request(thread_id, attempt_id, {BEE_FIXTURE_STREAM = stream("plain.jsonl"), BEE_FIXTURE_TRUNCATE = "1", BEE_FIXTURE_ORPHAN_FIFO = release}), "open", nil)
            gate.release(release)
            if not outcome.value then error("orphan run failed: " .. tostring(outcome.error)) end
            local settlement = assert(bounds.object(outcome.value.settlement))
            test.eq(settlement.outcome, "uncertain")
            local status = call("bee.placement.native.binding:status", {attempt_id = attempt_id})
            local attempt = assert(bounds.object(status.attempt))
            local _, records = kinds(thread_id)
            local output = ""
            local truncated = 0
            for _, item in ipairs(observations(records, "bee.carrier.output")) do
                local body = assert(bounds.object(item.body))
                local data = assert(bounds.object(body.data))
                local payload = assert(bounds.object(require("json").decode(tostring(data.payload_json))))
                if payload.stream ~= nil then
                    if payload.state == "truncated" then truncated = truncated + 1 end
                else
                    output = tostring(payload.state)
                end
            end
            if attempt.exit_observation == "independent" then
                test.eq(output, "truncated")
                if truncated < 1 or not tostring(settlement.reason):find("output truncated", 1, true) then
                    error("truncated streams " .. tostring(truncated) .. "; reason " .. tostring(settlement.reason) .. "; kinds " .. table.concat(kinds(thread_id), ","))
                end
            else
                -- EOF-gated exit: the runner never closes a stream on a
                -- deadline, so no stream is truncated. The terminal envelope
                -- settles the run when it arrives, and the other stream's
                -- end mark may still be in flight then, which settles the
                -- output as incomplete rather than complete.
                if output ~= "incomplete" and output ~= "complete" then
                    error("output " .. output .. " with " .. tostring(truncated) .. " truncated streams; reason " .. tostring(settlement.reason) .. "; kinds " .. table.concat(kinds(thread_id), ","))
                end
                test.eq(truncated, 0)
            end
        end)
    end)
end
local function owned_cases(cases, options)
    local originals: {{[string]: unknown}} = {}
    for _, ref in ipairs({"bee.placement.native.env:placement_resource_mode", "bee.placement.native.env:placement_admitted_roots"}) do originals[#originals + 1] = assert(registry.get(ref)) end
    local ok, result = pcall(cases, options)
    local changes = assert(registry.snapshot()):changes()
    for _, original in ipairs(originals) do changes:update(registry_input(original)) end
    assert(changes:apply())
    if not ok then error(tostring(result)) end
    return result
end
return {
    run = function(options) return owned_cases(test.run_cases(define_tests), options) end,
    run_stream = function(options) return owned_cases(test.run_cases(define_stream_tests), options) end,
    run_drain = function(options) return owned_cases(test.run_cases(define_drain_tests), options) end,
}
