-- MIT. Runtime ports for one fenced executor turn.
local bounds = require("bounds")
local hash = require("hash")
local channel = require("channel")
local funcs = require("funcs")
local process = require("process")
local stream = require("stream")
local placement_protocol = require("placement_protocol")
local driver_types = require("driver_types")
local turn = require("turn")
local admission = require("admission")
local machine = require("machine")
local canonical = require("canonical")
local clock = require("clock")
local time = require("time")
local exchange = require("exchange")
local checkpoint = require("checkpoint")
local placement_decode = require("placement_decode")

type Listener = {outputs: unknown, exits: unknown, events: unknown}
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
    local permission_context: exchange.Context? = nil
    local permission_point: checkpoint.Checkpoint? = nil
    local poller = nil
    if plan and plan.exchange then
        if plan.exchange_refusal then return nil, plan.exchange_refusal end
        if not plan.request.workspace_id or not plan.request.session_ref then return nil, "permission exchange omitted workspace or session" end
        permission_point = checkpoint.new({binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry,
            profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest}, generation)
        poller = time.ticker(tostring(plan.exchange.poll_ms) .. "ms")
    end
    local monitored = process.monitor(runner)
    local decoder = stream.new()
    local state: unknown = nil
    local terminal: driver_types.Terminal? = nil
    local observations: {{[string]: unknown}} = {}
    local stdout_eof, stderr_eof, exited = false, false, false
    local stopped = false
    local output_error: string? = nil
    local exit_uncertain = false
    local stderr_bytes: integer = 0
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
            exchange = planned.exchange, permissions = point.permissions, epoch = generation}
        permission_context = {state = permission_state, now_ms = clock.milliseconds, approvals = "bee.approvals.binding", max_consume_attempts = exchange.MAX_CONSUME_ATTEMPTS,
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
        local ctx = permission_context
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
    while not (stdout_eof and stderr_eof and exited) do
        local cases = {listener.outputs:case_receive(), listener.exits:case_receive(), listener.events:case_receive(),
            acks:case_receive()}
        if poller then cases[#cases + 1] = poller:channel():case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then output_error = output_error or "placement output observation was interrupted"; break end
        if selected.channel == listener.outputs then
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
            if event.kind == process.event.EXIT and tostring(event.from) == runner then
                output_error = output_error or "placement runner exited before output completed"
                break
            end
        end
    end
    if monitored then process.unmonitor(runner) end
    process.unlisten(acks)
    if poller then poller:stop() end
    if permission_context then
        local _, close_error = exchange.close(permission_context)
        output_error = output_error or close_error
    end
    if output_error then return {terminal = terminal, observations = observations, stopped = stopped}, output_error end
    if exit_uncertain then return {terminal = terminal, observations = observations, stopped = stopped}, "placement runner did not prove process exit" end
    return {terminal = terminal, observations = observations, stopped = stopped}, nil
end

local function handle(value: unknown): ({[string]: unknown}?, string?)
    local request = bounds.object(value)
    if not request then return nil, "turn request must be an object" end
    local function progress(stage: string, label: string): string?
        local _, append_error = service_call("bee.threads.service:turn_observation", {turn = request.attempt_id,
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
            local progress_error = progress("prepare", "Preparing agent")
            if progress_error then return nil, progress_error end
            return service_call(placement_target(request, "prepare"), placement_request)
        end,
        listen = function()
            return {outputs = assert(process.listen(placement_protocol.TOPIC_OUTPUT, {message = true})),
                exits = assert(process.listen(placement_protocol.TOPIC_EXIT, {message = true})), events = assert(process.events())}, nil
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
