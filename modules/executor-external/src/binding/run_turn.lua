-- MIT. Runtime ports for one fenced executor turn.
local bounds = require("bounds")
local channel = require("channel")
local funcs = require("funcs")
local process = require("process")
local stream = require("stream")
local placement_protocol = require("placement_protocol")
local driver_types = require("driver_types")
local turn = require("turn")
local admission = require("admission")
local machine = require("machine")

type Listener = {outputs: unknown, exits: unknown, events: unknown}

local function error_text(value: unknown): string
    if type(value) == "table" then
        local object = value :: {[string]: unknown}
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

local function observe(listener_value: unknown, attempt_value: unknown, normalizer_target: string, resumed: boolean): (unknown, string?)
    local listener = bounds.object(listener_value) :: Listener?
    local attempt, attempt_error = unwrap_attempt(attempt_value)
    if not listener or not attempt then return nil, attempt_error or "output listener or attempt is malformed" end
    local attempt_object = attempt :: {[string]: unknown}
    local attempt_id = tostring(attempt_object.attempt_id)
    local runner = bounds.id(attempt_object.runner)
    local generation = bounds.integer(attempt_object.attachment_generation)
    if not runner or not generation then return nil, "placement start omitted runner attachment identity" end
    local monitored = process.monitor(runner)
    local decoder = stream.new()
    local state: unknown = nil
    local terminal: driver_types.Terminal? = nil
    local observations: {{[string]: unknown}} = {}
    local stdout_eof, stderr_eof, exited = false, false, false
    local output_error: string? = nil
    local exit_uncertain = false
    local function apply(reply_value: unknown): string?
        local reply = bounds.object(reply_value)
        if not reply then return "driver normalizer response must be an object" end
        state = reply.state
        local raw_events, events_error = bounds.array(reply.observations or {}, 4096)
        if not raw_events then return "driver normalizer observations are malformed: " .. tostring(events_error) end
        for _, raw in ipairs(raw_events) do
            local event = bounds.object(raw)
            if not event then return "driver normalizer emitted a non-object observation" end
            observations[#observations + 1] = event
        end
        if reply.terminal ~= nil then
            local decoded, decode_error = driver_types.decode_terminal(reply.terminal)
            if not decoded then return "driver normalizer terminal is malformed: " .. tostring(decode_error) end
            terminal = decoded
        end
        return nil
    end
    local function finish_stdout()
        local problem = stream.finish(decoder)
        if problem then output_error = output_error or problem end
        local reply, normalize_error = normalizer_call(normalizer_target, state, stream.next_index(decoder), nil, true, resumed)
        if normalize_error then output_error = output_error or normalize_error; return end
        local apply_error = apply(reply)
        if apply_error then output_error = output_error or apply_error end
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
            if output_stream == "stdout" and not stdout_eof then stdout_eof = true; finish_stdout() end
            if output_stream == "stderr" then stderr_eof = true end
        elseif output_stream == "stdout" then
            if type(output.data) ~= "string" then output_error = output_error or "stdout chunk has no bytes"; return end
            local envelopes, feed_error = stream.feed(decoder, output.data)
            if feed_error then output_error = output_error or feed_error end
            for _, envelope in ipairs(envelopes) do
                local reply, normalize_error = normalizer_call(normalizer_target, state, envelope.index, envelope.value, false, resumed)
                if normalize_error then output_error = output_error or normalize_error; break end
                local apply_error = apply(reply)
                if apply_error then output_error = output_error or apply_error; break end
            end
        end
        process.send(sender, placement_protocol.TOPIC_ACK, {generation = generation, consumed_through = sequence})
    end
    while not (stdout_eof and stderr_eof and exited) do
        local selected = channel.select({listener.outputs:case_receive(), listener.exits:case_receive(), listener.events:case_receive()})
        if not selected.ok then output_error = output_error or "placement output observation was interrupted"; break end
        if selected.channel == listener.outputs then
            local message = selected.value
            accept_output(tostring(message:from()), message:payload():data())
        elseif selected.channel == listener.exits then
            local message = selected.value
            local exit = bounds.object(message:payload():data())
            if tostring(message:from()) == runner and exit and exit.attempt_id == attempt_id and exit.generation == generation then
                exited = true
                exit_uncertain = exit.uncertain == true
            end
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
    if output_error then return {terminal = terminal, observations = observations}, output_error end
    if exit_uncertain then return {terminal = terminal, observations = observations}, "placement runner did not prove process exit" end
    return {terminal = terminal, observations = observations}, nil
end

local function handle(value: unknown): ({[string]: unknown}?, string?)
    local request = bounds.object(value)
    if not request then return nil, "turn request must be an object" end
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
            if not current_plan then return nil, "host launch plan is unavailable" end
            return machine.admit_gateway(host_io, current_plan, generation)
        end,
        gateway_ready = function(binding_id: string): string?
            if not current_plan then return "host launch plan is unavailable" end
            return machine.gateway_ready(host_io, binding_id)
        end,
        revoke_gateway = function(binding_id: string)
            machine.revoke_gateway(host_io, binding_id)
        end,
        start = function(attempt_id: string, gateway_binding: string?)
            local request_value: {[string]: unknown} = {attempt_id = attempt_id}
            if gateway_binding then request_value.gateway_binding = gateway_binding end
            return service_call(placement_target(request, "start"), request_value)
        end,
        observe = function(listener: unknown, attempt: unknown, normalizer_target: string, resumed: boolean, _checkpoint: unknown?)
            return observe(listener, attempt, normalizer_target, resumed)
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
