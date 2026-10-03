-- MIT. Runtime ports for one fenced executor turn.
local bounds = require("bounds")
local hash = require("hash")
local channel = require("channel")
local funcs = require("funcs")
local process = require("process")
local stream = require("stream")
local placement_protocol = require("placement_protocol")
local driver_types = require("driver_types")
local budget_values = require("budget")
local turn = require("turn")
local admission = require("admission")
local machine = require("machine")
local canonical = require("canonical")
local clock = require("clock")
local time = require("time")
local exchange = require("exchange")
local checkpoint = require("checkpoint")
local placement_decode = require("placement_decode")
local security = require("security")

type Listener = {outputs: unknown, exits: unknown, states: unknown, events: unknown}
type Object = {[string]: unknown}

local function error_text(value: unknown): string
    if type(value) == "table" then
        local object = bounds.object(value) or {}
        if type(object.message) == "string" then return object.message end
        if type(object.code) == "string" then return object.code end
    end
    return tostring(value)
end

local function service_call(target: string, request: unknown): (unknown, string?)
    local value, call_error = funcs.call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = bounds.object(value)
    if not reply then return nil, target .. " returned a malformed reply" end
    if reply.ok == false then return nil, target .. ": " .. error_text(reply.error) end
    if reply.ok == true then
        if reply.value == nil then return nil, target .. " returned no value" end
        return reply.value, nil
    end
    return nil, target .. " returned no result tag"
end

local function placement_target(request: {[string]: unknown}, method: string): string
    local methods = bounds.object(request.placement_methods) or {}
    return tostring(methods[method])
end

local function unwrap_attempt(value: unknown): (unknown, string?)
    local object = bounds.object(value)
    if not object then return nil, "placement result must be an object" end
    local attempt = bounds.object(object.attempt) or object
    if type(attempt.attempt_id) ~= "string" then return nil, "placement result has no attempt_id" end
    return attempt, nil
end

local function normalizer_call(target: string, state: unknown, index: integer, envelope: {[string]: unknown}?, eof: boolean, resumed: boolean): (unknown, string?)
    local request: {[string]: unknown} = {state = state, index = index, eof = eof, resumed = resumed}
    if envelope then request.envelope = envelope end
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, tostring(call_error) end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then return nil, "driver normalizer refused an output frame" end
    return reply, nil
end

local function observe(listener_value: unknown, attempt_value: unknown, normalizer_target: string, resumed: boolean,
    request: turn.Request, plan: machine.Plan?): (unknown, string?)
    local listener = bounds.object(listener_value)
    local attempt, attempt_error = unwrap_attempt(attempt_value)
    if not listener or not attempt then return nil, attempt_error or "output listener or attempt is malformed" end
    local attempt_object = bounds.object(attempt)
    if not attempt_object then return nil, "placement attempt is malformed" end
    local attempt_id = tostring(attempt_object.attempt_id)
    local runner = bounds.id(attempt_object.runner)
    local generation = bounds.integer(attempt_object.attachment_generation)
    if not runner or not generation then return nil, "placement start omitted runner attachment identity" end
    local observation_target = tostring(request.observation_target)
    local claim = tostring(request.claim)
    local acks = assert(process.listen(placement_protocol.TOPIC_ACK, {message = true}))
    local permission_contexts: {exchange.Context} = {}
    local permission_point: checkpoint.Checkpoint? = nil
    local poller = nil
    if plan and plan.exchange then
        if plan.exchange_refusal then return nil, plan.exchange_refusal end
        if not plan.request.workspace_id or not plan.request.session_ref then return nil, "permission exchange omitted workspace or session" end
        permission_point = checkpoint.new({binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry,
            profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest}, generation)
        poller = time.ticker(tostring(plan.exchange.poll_ms) .. "ms")
    end
    local starting = attempt_object.execution_state == "starting"
    local monitored = process.monitor(runner)
    local decoder = stream.new()
    local state: unknown = nil
    local terminal: driver_types.Terminal? = nil
    local observations: {{[string]: unknown}} = {}
    local stdout_eof, stderr_eof, exited = false, false, false
    local stopped = false
    local output_error: string? = nil
    local exit_uncertain = false
    local input_close_attempted = false
    local stderr_bytes: integer = 0
    local live_budget = bounds.object(request.budget)
    local wall_limit = live_budget and bounds.count(live_budget.wall_time_ms) or nil
    local session_budget = request.session_budget
    if session_budget and session_budget.wall_time_ms then
        local remaining = math.max(1, session_budget.wall_time_ms - (request.session_wall_ms or 0))
        wall_limit = wall_limit and math.min(wall_limit, remaining) or remaining
    end
    local session_counters = request.session_consumption or budget_values.new()
    local quiet_period = request.supervision and request.supervision.quiet_period_ms or 60000
    local stall_timer = request.supervision and request.supervision.on_stall == "cancel_work" and time.ticker(tostring(math.min(1000, quiet_period)) .. "ms") or nil
    local last_progress_ms = math.floor(time.now():unix_nano() / 1000000)
    local stalled = false
    local budget_started_ms = math.floor(time.now():unix_nano() / 1000000)
    local wall_timer = wall_limit and time.after(tostring(wall_limit) .. "ms") or nil
    local budget: budget_values.Budget? = nil
    local counters = budget_values.new()
    local budget_exceeded: string? = nil
    local budget_stop_error: string? = nil
    if request.budget ~= nil then
        budget, budget_stop_error = budget_values.decode(request.budget)
        if budget_stop_error then return nil, budget_stop_error end
    end
    local function now_ms(): integer
        return math.floor(time.now():unix_nano() / 1000000)
    end
    local function stop_for_budget(): string?
        local admission_request = bounds.object(request.admission)
        local owner = admission_request and bounds.id(admission_request.owner_id)
        local workspace = admission_request and bounds.id(admission_request.workspace_id)
        local methods = bounds.object(request.placement_methods)
        local target = methods and bounds.id(methods.stop)
        if not owner or not workspace or not target then return "admitted owner or placement stop method is missing" end
        local actor, actor_error = security.new_actor(owner, {workspace_id = workspace})
        if actor_error or not actor then return "restore admitted placement owner: " .. tostring(actor_error) end
        local raw, call_error = funcs.new():with_actor(actor):call(target, {attempt_id = attempt_id, mode = "cooperative"})
        if call_error then return "request placement stop: " .. tostring(call_error) end
        local reply = bounds.object(raw)
        if not reply or reply.ok ~= true or not bounds.object(reply.value) then
            return "placement did not acknowledge the budget stop"
        end
        return nil
    end
    local function check_budget(): string?
        local elapsed = now_ms() - budget_started_ms
        return budget_values.exceeded(budget, counters, elapsed) or budget_values.exceeded(session_budget, session_counters, (request.session_wall_ms or 0) + elapsed)
    end
    local function request_budget_stop(kind: string)
        if budget_exceeded then return end
        budget_exceeded = kind
        budget_stop_error = stop_for_budget()
    end
    local function publish_startup(state: string, cause: string?): string?
        local payload, encode_error = canonical.encode({execution_state = state, start_failure = cause})
        if not payload then return "encode placement observation: " .. tostring(encode_error) end
        local _, append_error = service_call(observation_target, {turn = attempt_id, claim = claim,
            operation_key = "executor-placement:" .. attempt_id:sub(-72) .. ":" .. state,
            observation = {type = "extension", event_key = "placement:" .. attempt_id .. ":" .. state,
                data = {type = "extension", event_name = "bee.placement.attempt", event_revision = "1", payload_json = payload}}})
        return append_error
    end
    local initial_state_error = publish_startup(tostring(attempt_object.execution_state), nil)
    if initial_state_error then return nil, initial_state_error end
    local function observe_startup(): string?
        local raw, read_error = service_call(placement_target(request, "reconcile"), {attempt_id = attempt_id})
        if read_error then return read_error end
        local current, decode_error = placement_decode.attempt(raw)
        if not current then return "startup state: " .. tostring(decode_error) end
        if current.attempt_id ~= attempt_id or current.attachment_generation ~= generation then return "startup state identity differs from this turn" end
        if current.start_cancelled then
            stopped = true
            stdout_eof, stderr_eof, exited = true, true, true
            starting = false
            return nil
        end
        if current.start_failure then
            local append_error = publish_startup("start_failed", current.start_failure)
            return append_error and (current.start_failure .. "; publish startup failure: " .. append_error) or current.start_failure
        end
        if current.execution_state == "starting" then return nil end
        if starting and (current.execution_state == "running" or current.execution_state == "exited") then
            starting = false
            last_progress_ms = now_ms()
            return publish_startup("running", nil)
        end
        return nil
    end
    local function completion_event(stage: string): string?
        local _, err = service_call(tostring(request.observation_target), {turn = request.attempt_id, claim = request.claim,
            operation_key = "executor-complete:" .. tostring(request.attempt_id):sub(-72) .. ":" .. stage,
            observation = {type = "extension", event_key = "executor:" .. stage,
                data = {type = "extension", event_name = "bee.executor." .. stage, event_revision = "1", payload_json = "{}"}}})
        return err
    end
    local function apply(reply_value: unknown): string?
        local reply = bounds.object(reply_value)
        if not reply then return "driver normalizer response must be an object" end
        state = reply.state
        local raw_events, events_error = bounds.array(reply.observations or {}, 4096)
        if not raw_events then return "driver normalizer observations are malformed: " .. tostring(events_error) end
        for _, raw in ipairs(raw_events) do
            local event = bounds.object(raw)
            if not event then return "driver normalizer emitted a non-object observation" end
            local event_key = bounds.id(event.event_key)
            if not event_key then return "driver normalizer emitted an observation without a valid event key" end
            local event_identity, hash_error = hash.sha256(tostring(request.attempt_id) .. "\n" .. event_key)
            if hash_error or not event_identity then return "measure normalized event identity: " .. tostring(hash_error or "no digest") end
            local _, append_error = service_call(tostring(request.observation_target), {
                turn = request.attempt_id, claim = request.claim, operation_key = "turnobs:" .. event_identity, observation = event,
            })
            if append_error then return "append live turn observation: " .. append_error end
            observations[#observations + 1] = event
            last_progress_ms = now_ms()
            budget_values.observe(counters, event)
            budget_values.observe(session_counters, event)
            local exceeded = check_budget()
            if exceeded then request_budget_stop(exceeded); break end
        end
        if reply.terminal ~= nil then
            local decoded, decode_error = driver_types.decode_terminal(reply.terminal)
            if not decoded then return "driver normalizer terminal is malformed: " .. tostring(decode_error) end
            terminal = decoded
        end
        return nil
    end
    local function commit_permissions(records: {Object}): (boolean, string?)
        for _, record in ipairs(records) do
            local body = bounds.object(record.body)
            if not body then return false, "permission record omitted its observation" end
            local event_key = bounds.id(body.event_key)
            if not event_key then return false, "permission record omitted its identity" end
            local identity, identity_error = hash.sha256(attempt_id .. "\n" .. event_key)
            if not identity then return false, tostring(identity_error) end
            local saved: Object = {}
            for name, field in pairs(request.checkpoint or {}) do saved[name] = field end
            saved.permission_checkpoint = permission_point
            local _, append_error = service_call(observation_target, {turn = attempt_id, claim = claim,
                operation_key = "turnobs:" .. identity, observation = body, checkpoint = saved})
            if append_error then return false, append_error end
        end
        return true, nil
    end
    if plan and plan.exchange and permission_point then
        local point = permission_point
        local planned = plan
        local permission_state: exchange.State = {request = planned.request, plan_digest = planned.plan_digest,
            exchange = planned.exchange, permissions = point.permissions, epoch = generation, proposal_kind = "operation"}
        permission_contexts[1] = {state = permission_state, now_ms = clock.milliseconds, approvals = "bee.approvals.binding", max_consume_attempts = exchange.MAX_CONSUME_ATTEMPTS,
            commit = commit_permissions,
            call = function(target: string, fields: unknown): (unknown, string?)
                local value, err = funcs.call(target, fields)
                if err then return nil, tostring(err) end
                return value, nil
            end,
            digest_of = function(value: unknown): (string?, string?)
                local text, err = canonical.encode(value)
                if not text then return nil, err end
                return hash.sha256(text)
            end,
            step = function(_: string) end,
            waiting = function(): boolean return not exited and not stopped and not stdout_eof and terminal == nil end,
            settled = function(): boolean return exited or terminal ~= nil end,
            revalidate = function(): string?
                local host_io: machine.IO = {call = function(target: string, fields: unknown): (unknown, string?)
                        local value, err = funcs.call(target, fields)
                        if err then return nil, tostring(err) end
                        return value, nil
                    end, send = function(_: string, _: string, _: unknown) end,
                    self_pid = function(): string return process.pid() end, now_ms = clock.milliseconds,
                    key = function(): string return attempt_id end}
                local fresh, plan_error = machine.session_plan(host_io, planned.request, planned.resume_ref)
                if not fresh then return "permission plan unavailable: " .. tostring(plan_error) end
                if fresh.exchange_refusal then return fresh.exchange_refusal end
                if fresh.plan_digest ~= point.plan_digest then return "permission plan changed" end
                local raw, err = service_call(placement_target(request, "reconcile"), {attempt_id = attempt_id})
                if err then return err end
                local current, decode_error = placement_decode.attempt(raw)
                if not current then return decode_error end
                if current.execution_state ~= "running" then return "placement no longer running" end
                return nil
            end,
            write = function(write_id: string, line: string): (boolean, string?)
                local digest, err = canonical.encode(line)
                if not digest then return false, err end
                local sum, hash_error = hash.sha256(digest)
                if not sum then return false, tostring(hash_error) end
                point.pending_writes[#point.pending_writes + 1] = {write_id = write_id, input_digest = sum, data = line, dispatched = false}
                local record: Object = {body = {type = "extension", event_key = "write:" .. write_id .. ":intended",
                    data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1",
                        payload_json = canonical.encode({write_id = write_id, phase = "intended", input_digest = sum})}}}
                local committed, commit_error = commit_permissions({record})
                if not committed then return false, commit_error end
                local sent, send_error = process.send(runner, placement_protocol.TOPIC_INPUT,
                    {write_id = write_id, generation = generation, data = line})
                if not sent then return false, tostring(send_error) end
                point.pending_writes[#point.pending_writes].dispatched = true
                return true, nil
            end}
    end
    local function accept_observations(fresh: {Object})
        local ctx = permission_contexts[1]
        if not ctx then return end
        local records: {Object} = {}
        for _, body in ipairs(fresh) do records[#records + 1] = {body = body} end
        local _, detect_error = exchange.detect(ctx, records)
        if detect_error then output_error = output_error or detect_error; return end
        exchange.acknowledge(ctx, records)
        if #records > #fresh then
            local added: {Object} = {}
            for index = #fresh + 1, #records do added[#added + 1] = records[index] end
            local _, commit_error = ctx.commit(added)
            output_error = output_error or commit_error
        end
        local _, advance_error = exchange.advance(ctx, false)
        output_error = output_error or advance_error
    end
    local function answer_acks(sender: string, raw: unknown)
        local point = permission_point
        if not point or sender ~= runner then return end
        local data = bounds.object(raw)
        if not data or data.attempt_id ~= attempt_id or data.generation ~= generation then return end
        local write_id = bounds.id(data.write_id)
        if not write_id then return end
        for index, pending in ipairs(point.pending_writes) do
            if pending.write_id == write_id then
                table.remove(point.pending_writes, index)
                local phase = data.accepted == true and "accepted" or "uncertain"
                local _, err = commit_permissions({{body = {type = "extension", event_key = "write:" .. write_id .. ":" .. phase,
                    data = {type = "extension", event_name = "bee.carrier.write", event_revision = "1",
                        payload_json = canonical.encode({write_id = write_id, phase = phase})}}}})
                output_error = output_error or err
                if data.accepted ~= true then output_error = output_error or "stdin refused the permission response" end
                return
            end
        end
    end
    local function finish_stdout()
        local problem = stream.finish(decoder)
        if problem then output_error = output_error or problem end
        local base = #observations
        local reply, normalize_error = normalizer_call(normalizer_target, state, stream.next_index(decoder), nil, true, resumed)
        if normalize_error then output_error = output_error or normalize_error; return end
        local apply_error = apply(reply)
        if apply_error then output_error = output_error or apply_error end
        if #observations > base then
            local fresh: {Object} = {}
            for index = base + 1, #observations do fresh[#fresh + 1] = observations[index] end
            accept_observations(fresh)
        end
    end
    local function accept_output(sender: string, raw: unknown)
        local output = bounds.object(raw)
        if not output or output.attempt_id ~= attempt_id or output.generation ~= generation then return end
        if sender ~= runner then output_error = output_error or "placement output came from an unrecorded runner"; return end
        local sequence = bounds.integer(output.sequence)
        local output_stream = bounds.member(output.stream, {"stdout", "stderr"})
        if not sequence or sequence < 1 or not output_stream or type(output.eof) ~= "boolean" then
            output_error = output_error or "placement output envelope is malformed"
            return
        end
        if output.eof then
            if output_stream == "stdout" and not stdout_eof then stdout_eof = true; finish_stdout(); output_error = output_error or completion_event("stdout_complete") end
            if output_stream == "stderr" then stderr_eof = true; output_error = output_error or completion_event("stderr_complete") end
        elseif output_stream == "stdout" then
            if type(output.data) ~= "string" then output_error = output_error or "stdout chunk has no bytes"; return end
            local base = #observations
            local envelopes, feed_error = stream.feed(decoder, output.data)
            if feed_error then output_error = output_error or feed_error end
            for _, envelope in ipairs(envelopes) do
                local reply, normalize_error = normalizer_call(normalizer_target, state, envelope.index, envelope.value, false, resumed)
                if normalize_error then output_error = output_error or normalize_error; break end
                local apply_error = apply(reply)
                if apply_error then output_error = output_error or apply_error; break end
            end
            if #observations > base then
                local fresh: {Object} = {}
                for index = base + 1, #observations do fresh[#fresh + 1] = observations[index] end
                accept_observations(fresh)
            end
        end
        if not output.eof and output_stream == "stderr" and type(output.data) == "string" and #output.data > 0 then last_progress_ms = now_ms() end
        if not output.eof and output_stream == "stderr" and type(output.data) == "string" and stderr_bytes < 4096 then
            local text = output.data:sub(1, 4096 - stderr_bytes)
            stderr_bytes = stderr_bytes + #text
            local _, stderr_error = service_call(tostring(request.observation_target), {turn = request.attempt_id, claim = request.claim,
                operation_key = "executor-stderr:" .. tostring(request.attempt_id):sub(-72) .. ":" .. tostring(sequence),
                observation = {type = "text", event_key = "executor:stderr:" .. tostring(sequence),
                    data = {type = "text", channel = "progress", segment_id = "executor-stderr", operation = "append", text = text}}})
            output_error = output_error or stderr_error
        end
        process.send(sender, placement_protocol.TOPIC_ACK, {generation = generation, consumed_through = sequence})
    end
    local function finish_input(): string?
        if input_close_attempted or exited or terminal == nil or not plan or plan.launch.session_end ~= "stdin_close" then return nil end
        if permission_point and #permission_point.pending_writes > 0 then return nil end
        input_close_attempted = true
        local target = plan.placement_binding.methods.close_stdin
        if not target then return "selected placement cannot close stdin" end
        if permission_point then
            permission_point.input_closed = true
            local committed, err = commit_permissions({{body = {type = "extension", event_key = "executor:input_close_intended",
                data = {type = "extension", event_name = "bee.carrier.input", event_revision = "1",
                    payload_json = canonical.encode({phase = "close_intended"})}}}})
            if not committed then return err end
        else
            local err = completion_event("input_close_intended")
            if err then return err end
        end
        local raw, call_error = service_call(target, {attempt_id = attempt_id})
        local answer, decode_error = placement_decode.stdin_closure(raw, attempt_id)
        if not answer then
            completion_event("input_close_uncertain")
            return call_error or decode_error
        end
        local err = completion_event(answer.closed and "input_closed" or "input_close_uncertain")
        return err or (not answer.closed and answer.reason or nil)
    end
    while not (stdout_eof and stderr_eof and exited) do
        local close_error = finish_input()
        if close_error then output_error = output_error or close_error; break end
        local cases = {listener.outputs:case_receive(), listener.exits:case_receive(), listener.states:case_receive(), listener.events:case_receive(),
            acks:case_receive()}
        if poller then cases[#cases + 1] = poller:channel():case_receive() end
        if wall_timer then cases[#cases + 1] = wall_timer:case_receive() end
        if stall_timer then cases[#cases + 1] = stall_timer:channel():case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then output_error = output_error or "placement output observation was interrupted"; break end
        if wall_timer and selected.channel == wall_timer then
            local exceeded = check_budget()
            if exceeded then request_budget_stop(exceeded)
            else
                wall_timer = time.after(tostring(math.max(1, (wall_limit or 1) - (now_ms() - budget_started_ms))) .. "ms")
            end
        elseif stall_timer and selected.channel == stall_timer:channel() then
            local waiting = false
            if permission_point then
                for _, item in ipairs(permission_point.permissions) do
                    if item.phase ~= "closed" and item.phase ~= "acknowledged" then waiting = true end
                end
            end
            if starting or waiting then last_progress_ms = now_ms()
            elseif not stalled and now_ms() - last_progress_ms >= quiet_period then
                stalled = true
                budget_stop_error = stop_for_budget()
                if budget_stop_error then output_error = output_error or budget_stop_error end
            end
        elseif selected.channel == listener.states then
            local message = selected.value
            local hint = placement_protocol.decode_state_hint(message:payload():data())
            if hint and hint.attempt_id == attempt_id and hint.generation == generation then
                local cause = observe_startup()
                if cause then output_error = cause; break end
            end
        elseif selected.channel == listener.outputs then
            if starting then
                local cause = observe_startup()
                if cause then output_error = cause; break end
            end
            local message = selected.value
            accept_output(tostring(message:from()), message:payload():data())
        elseif selected.channel == listener.exits then
            local message = selected.value
            local exit = bounds.object(message:payload():data())
            if tostring(message:from()) == runner and exit and exit.attempt_id == attempt_id and exit.generation == generation then
                exited = true
                stopped = exit.stopped == true
                exit_uncertain = exit.uncertain == true
                output_error = output_error or completion_event("process_exited")
            end
        elseif poller and selected.channel == poller:channel() then
            local permission_context = permission_contexts[1]
            if permission_context then
                local _, err = exchange.advance(permission_context, true)
                output_error = output_error or err
            end
        elseif selected.channel == acks then
            local message = selected.value
            answer_acks(tostring(message:from()), message:payload():data())
        else
            local event = selected.value
            if event.kind == process.event.CANCEL then output_error = output_error or "executor worker was interrupted"; break end
            if event.kind == process.event.EXIT and tostring(event.from) == runner and not starting then
                output_error = output_error or "placement runner exited before output completed"
                break
            end
        end
    end
    if monitored then process.unmonitor(runner) end
    process.unlisten(acks)
    if poller then poller:stop() end
    if stall_timer then stall_timer:stop() end
    local permission_context = permission_contexts[1]
    if permission_context then
        local _, close_error = exchange.close(permission_context)
        output_error = output_error or close_error
    end
    if budget_exceeded then
        return {terminal = terminal, observations = observations, stopped = stopped,
            budget_exceeded = budget_exceeded, budget_stop_error = budget_stop_error}, nil
    end
    if output_error then return {terminal = terminal, observations = observations, stopped = stopped}, output_error end
    if exit_uncertain then return {terminal = terminal, observations = observations, stopped = stopped}, "placement runner did not prove process exit" end
    return {terminal = terminal, observations = observations, stopped = stopped, stalled = stalled}, nil
end

local function handle(value: unknown): ({[string]: unknown}?, string?)
    local request = bounds.object(value)
    if not request then return nil, "turn request must be an object" end
    local function progress(stage: string, label: string): string?
        local _, append_error = service_call("bee.threads.binding:turn_observation", {turn = request.attempt_id,
            claim = request.claim, operation_key = "executor-progress:" .. tostring(request.attempt_id):sub(-72) .. ":" .. stage,
            observation = {type = "text", event_key = "executor:" .. stage,
                data = {type = "text", segment_id = "executor-progress", operation = "replace", channel = "progress", text = label}}})
        return append_error
    end
    local current_plan: machine.Plan? = nil
    local function host_call(target: string, arguments: unknown): (unknown, string?)
        local result, call_error = funcs.call(target, arguments)
        if call_error then return nil, tostring(call_error) end
        return result, nil
    end
    local host_io: machine.IO = {
        call = host_call,
        send = function(_: string, _: string, _: unknown) end,
        self_pid = function(): string return process.pid() end,
        now_ms = function(): integer return 0 end,
        key = function(): string return tostring(request.attempt_id) end,
    }
    local io: turn.IO = {
        reconcile = function(attempt_id: string)
            return service_call(placement_target(request, "reconcile"), {attempt_id = attempt_id})
        end,
        cleanup = function(attempt_id: string)
            return service_call(placement_target(request, "cleanup"), {attempt_id = attempt_id})
        end,
        plan = function(raw_request: unknown)
            local turn_request = bounds.object(raw_request)
            local source = turn_request and bounds.object(turn_request.admission)
            if not turn_request or not source then return nil, "turn omitted its retained admission route" end
            local session_request: {[string]: unknown} = {}
            for name, field in pairs(source) do session_request[name] = field end
            session_request.brief = turn_request.prompt
            if request.placement_methods.prepare == "bee.placement.docker.binding:prepare" then
                local issue = progress("environment", "Preparing Docker network and gateway; review any pending approval in the inbox")
                if issue then return nil, issue end
            end
            local admitted, refused = admission.admit_session_turn(session_request)
            if not admitted then
                local fault = refused and bounds.object(refused.error)
                return nil, tostring(fault and fault.message or fault and fault.code or "host admission refused the turn")
            end
            local checkpoint = bounds.object(turn_request.checkpoint)
            local resume_ref = checkpoint and bounds.id(checkpoint.resume_ref) or nil
            local planned, plan_error = machine.session_plan(host_io, admitted.request, resume_ref)
            if plan_error or not planned then return nil, "host launch plan: " .. tostring(plan_error or "no plan") end
            current_plan = planned
            return {placement_request = planned.placement_request, normalize_target = planned.normalize_target}, nil
        end,
        prepare = function(placement_request: unknown)
            local target = placement_target(request, "prepare")
            local docker = target == "bee.placement.docker.binding:prepare"
            local progress_error = progress("prepare", docker and "Preparing Docker runtime image" or "Preparing agent")
            if progress_error then return nil, progress_error end
            if not docker then return service_call(target, placement_request) end
            local launch = bounds.object(placement_request)
            local profile = launch and bounds.id(launch.placement_profile_ref)
            if not launch or not profile then return nil, "Docker preparation has no selected profile" end
            local input: {[string]: unknown} = {}
            for name, field in pairs(launch) do input[name] = field end
            input.progress_recipient = tostring(process.pid())
            local owner = process.registry.lookup("bee.placement.docker/image")
            local events = process.listen("bee.placement.image_progress", {message = true})
            if not events then return nil, "Docker preparation progress listener is unavailable" end
            local completed = channel.new(1)
            local result: unknown = nil
            local failure: string? = nil
            local finished = false
            coroutine.spawn(function()
                result, failure = service_call(target, input)
                finished = true
                completed:send(true)
            end)
            local serial: integer = 0
            while not finished do
                local selected = channel.select({events:case_receive(), completed:case_receive()})
                if not selected.ok then
                    process.unlisten(events)
                    return nil, "Docker preparation reply channel closed before completion; preparation outcome is unknown"
                end
                if selected.channel == events and not progress_error then
                    local message = selected.value
                    if owner and tostring(message:from()) == tostring(owner) then
                        local detail, decode_error = placement_decode.preparation_progress(message:payload():data())
                        if not detail then progress_error = decode_error
                        elseif detail.profile_ref == profile then
                            serial = serial + 1
                            progress_error = progress("image-" .. tostring(serial), "Preparing Docker runtime image\n" .. detail.detail:sub(-4000))
                        end
                    end
                end
            end
            process.unlisten(events)
            if failure then return nil, failure .. (progress_error and "; progress publication: " .. progress_error or "") end
            if progress_error then return nil, "Docker preparation completed; progress publication failed: " .. progress_error end
            local ready_error = progress("image-ready", "Docker runtime image ready")
            if ready_error then return nil, ready_error end
            return result, nil
        end,
        listen = function()
            return {outputs = assert(process.listen(placement_protocol.TOPIC_OUTPUT, {message = true})),
                exits = assert(process.listen(placement_protocol.TOPIC_EXIT, {message = true})),
                states = assert(process.listen(placement_protocol.TOPIC_STARTED, {message = true})), events = assert(process.events())}, nil
        end,
        attach = function(attempt_id: string, generation: integer)
            return service_call(placement_target(request, "attach"), {attempt_id = attempt_id, recipient = process.pid(), generation = generation})
        end,
        admit_gateway = function(generation: integer): (string?, string?)
            local progress_error = progress("gateway", "Connecting Bee tools")
            if progress_error then return nil, progress_error end
            if not current_plan then return nil, "host launch plan is unavailable" end
            return machine.admit_gateway(host_io, current_plan, generation)
        end,
        gateway_ready = function(binding_id: string): string?
            local progress_error = progress("ready", "Checking Bee tool connection")
            if progress_error then return progress_error end
            if not current_plan then return "host launch plan is unavailable" end
            return machine.gateway_ready(host_io, binding_id)
        end,
        revoke_gateway = function(binding_id: string)
            machine.revoke_gateway(host_io, binding_id)
        end,
        start = function(attempt_id: string, gateway_binding: string?)
            local progress_error = progress("start", "Starting agent")
            if progress_error then return nil, progress_error end
            local request_value: {[string]: unknown} = {attempt_id = attempt_id}
            if gateway_binding then request_value.gateway_binding = gateway_binding end
            return service_call(placement_target(request, "start"), request_value)
        end,
        observe = function(listener: unknown, attempt: unknown, normalizer_target: string, resumed: boolean,
            _checkpoint: unknown?, turn_request: turn.Request)
            return observe(listener, attempt, normalizer_target, resumed, turn_request, current_plan)
        end,
        close = function(value: unknown)
            local listener = bounds.object(value)
            if not listener then return end
            process.unlisten(listener.outputs)
            process.unlisten(listener.exits)
            process.unlisten(listener.states)
        end,
    }
    local result, execution_error = turn.execute(io, value)
    if execution_error then
        return {ok = false, error = {code = "EXECUTOR_FAILED", message = execution_error}}
    end
    if not result then return {ok = false, error = {code = "EXECUTOR_FAILED", message = "external turn returned no result"}} end
    return {ok = true, value = result}
end

return {handle = handle}
