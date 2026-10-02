-- MIT. The attempt runner: one Wippy process per attempt that owns the
-- executor handle, materializes the home, starts the child, records its
-- identity, pumps bounded output to the bound recipient, accepts
-- acknowledged input, signals on request, and records the exit it
-- observed. Docker start refusal remains uncertain until daemon exit
-- evidence is available; runner cancellation alone does not prove absence.
local process = require("process")
local channel = require("channel")
local time = require("time")
local sql = require("sql")
local exec = require("exec")
local funcs = require("funcs")
local store = require("store")
local resources = require("resources")
local executable = require("executable")
local identity = require("identity")
local protocol = require("protocol")
local quote = require("quote")
local types = require("types")
local materialization = require("materialization")
local output_buffer = require("output_buffer")
local service = require("service")
local process_backend = require("process_backend")
local bounds = require("bounds")
type Stream = "stdout" | "stderr"
type Chunk = {stream: Stream, data: string?, eof: boolean}
type Pending = {sequence: integer, stream: Stream, data: string?, eof: boolean, bytes: integer, truncated: boolean?}
local function evidence(db, attempt_id: string, kind: string, detail: string, update: {execution: types.ExecutionState?, fields: {[string]: unknown}?}?): (boolean, string?)
    local execution: types.ExecutionState? = nil
    local fields: {[string]: unknown}? = nil
    if update then
        execution = update.execution
        fields = update.fields
    end
    local result = store.transition(db, attempt_id, {execution = execution, fields = fields,
        evidence = {kind = kind, detail = detail}})
    if not result.ok then return false, result.message end
    return true, nil
end
local function main(attempt_id: string, starter: string, reply_topic: string, expected_binding: string?, materialization_key: string?, control_token: string, backend: process_backend.Backend?)
    local function cleanup(attempt: types.Attempt): (boolean, string?)
        if backend then return backend.cleanup(attempt, true) end
        local reply = service.cleanup_attempt(attempt, true)
        return reply.ok, reply.error and reply.error.message or nil
    end
    local events = assert(process.events())
    local controls = assert(process.listen(protocol.TOPIC_CONTROL, {message = true}))
    local db, open_error = store.open()
    if not db then error("open placement store: " .. tostring(open_error)) end
    -- The gateway binding this runner materialized, retired by this runner
    -- when the child never starts, exits, or outlives its carrier. Only the
    -- binding id is held; the token bytes live in the child's environment.
    local gateway_binding: string? = nil
    local function seal_gateway(why: string)
        if not gateway_binding then return end
        local raw, call_error = funcs.call(resources.GATEWAY_SEAL, {binding_id = gateway_binding})
        local reply = type(raw) == "table" and raw or nil
        if call_error or not reply or not reply.ok then
            evidence(db, attempt_id, "gateway.seal_failed", why .. "; binding " .. tostring(gateway_binding) .. ": " .. tostring(call_error or (reply and reply.error and reply.error.code) or "no answer"))
            return
        end
        evidence(db, attempt_id, "gateway.sealed", why .. "; binding " .. tostring(gateway_binding) .. "; accepted hooks stay for the carrier")
    end
    local function retire_gateway(why: string)
        if not gateway_binding then return end
        local binding_id = gateway_binding
        gateway_binding = nil
        local raw, call_error = funcs.call(resources.GATEWAY_REVOKE, {binding_id = binding_id})
        local reply = type(raw) == "table" and raw or nil
        if call_error or not reply or not reply.ok then
            evidence(db, attempt_id, "gateway.revoke_failed", why .. "; binding " .. binding_id .. ": " .. tostring(call_error or (reply and reply.error and reply.error.code) or "no answer"))
            return
        end
        evidence(db, attempt_id, "gateway.revoked", why .. "; binding " .. binding_id)
    end
    local claimed = false
    local child_created = false
    local function refuse(reason: string)
        if claimed and not child_created then
            local recorded = materialization.fail_start(db, attempt_id, reason, backend ~= nil)
            if not recorded.ok then reason = reason .. "; record failed start: " .. tostring(recorded.message) end
            local attempt = store.attempt(db, attempt_id)
            if attempt then
                local cleaned: boolean
                local cleanup_error: string?
                if backend then cleaned, cleanup_error = backend.cleanup(attempt)
                else cleaned, cleanup_error = cleanup(attempt) end
                if not cleaned then reason = reason .. "; cleanup: " .. tostring(cleanup_error) end
            end
        end
        retire_gateway("start refused: " .. reason)
        process.send(starter, reply_topic, {started = false, reason = reason})
        db:release()
    end
    local row, row_error = store.row(db, attempt_id)
    if not row then return refuse(row_error or "attempt is not recorded") end
    local request, request_error = store.request(row)
    if not request then return refuse(request_error or "request unreadable") end
    local recipient: string? = type(row.recipient) == "string" and row.recipient or nil
    local generation = type(row.attachment_generation) == "number" and math.floor(row.attachment_generation) or 0
    local group = row.capability == "process_group"
    local starting = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting", fields = {runner_pid = process.pid()}, evidence = {kind = "runner.started", detail = "runner " .. process.pid()}})
    if not starting.ok then return refuse(starting.message or "attempt is not intended") end
    claimed = true
    if recipient then
        local monitored, monitor_error = process.monitor(recipient)
        if not monitored then return refuse("monitor carrier: " .. tostring(monitor_error)) end
    end
    local materialized, materialization_error, bound_gateway = materialization.prepare(db, request, attempt_id, generation, expected_binding, materialization_key, backend and backend.guest_home or nil)
    gateway_binding = bound_gateway
    if not materialized then return refuse(materialization_error or "attempt materialization") end
    local executor: exec.Executor? = nil
    local proc: exec.Process? = nil
    local stdin_materialized = false
    if backend then
        local selected, argv, options, prepare_error = backend.prepare(db, request, materialized)
        if not selected or not argv or not options then return refuse(prepare_error or "placement executor unavailable") end
        executor = selected
        stdin_materialized = options.stdin_materialized == true
        proc = selected:exec(quote.line(argv), {work_dir = options.work_dir, env = options.env, mounts = options.mounts, process_group = options.process_group})
    else
        local environment, work_dir = materialized.environment, materialized.working_directory
        local executor_ref, reference_error = resources.executor()
        local executor_error
        if executor_ref then executor, executor_error = exec.get(executor_ref) else executor_error = reference_error end
        if not executor then
            evidence(db, attempt_id, "executor.failed", tostring(executor_error), {execution = "exited"})
            return refuse("executor unavailable")
        end
        -- The plan's measurement is checked against what the path opens now,
        -- immediately before exec; a change refuses the start on record.
        if request.executable then
            local verified, verify_error = executable.verify(request.launch.executable, request.executable)
            if not verified then
                evidence(db, attempt_id, "executable.changed", tostring(verify_error), {execution = "exited"})
                executor:release()
                return refuse(verify_error or "executable changed")
            end
            evidence(db, attempt_id, "executable.measured", verified.revision .. " " .. verified.kind .. " digest " .. verified.digest .. " size " .. tostring(verified.size))
        end
        local argv: {string} = {request.launch.executable}
        for _, argument in ipairs(materialized.arguments) do argv[#argv + 1] = argument end
        proc = executor:exec(quote.line(argv), {work_dir = work_dir, env = environment, process_group = group})
    end
    if not executor then return refuse("placement executor unavailable") end
    if not proc then
        if backend then executor:release(); return refuse("executor refused the command") end
        -- The executor's own text is not recorded: it may quote the command
        -- or the environment it refused.
        evidence(db, attempt_id, "child.refused", "executor refused the command", {execution = "exited"})
        executor:release()
        return refuse("executor refused the command")
    end
    local stdout = not backend and proc:stdout_stream() or nil
    local stderr = not backend and proc:stderr_stream() or nil
    local creating = store.transition(db, attempt_id, {expected_execution = "starting", evidence = {kind = "child.creating", detail = "native process start"}})
    if not creating.ok then executor:release(); return refuse(creating.message or "attempt stopped before start") end
    local started, start_error = proc:start()
    if not started then
        if backend then
            proc:close(true)
            executor:release()
            return refuse(tostring(start_error))
        end
        evidence(db, attempt_id, "child.start_failed", "the child did not start", {execution = "exited"})
        executor:release()
        return refuse("the child did not start")
    end
    child_created = true
    if backend then
        stdout = proc:stdout_stream()
        stderr = proc:stderr_stream()
    end
    local fields: {[string]: unknown} = {}
    if backend then
        local identified, identify_error = backend.identity(request)
        if not identified then proc:signal(9); executor:release(); return refuse(identify_error or "Docker identity unavailable") end
        fields = identified
    end
    local recorded: identity.Identity? = nil
    local handle = proc
    if type(handle.pid) == "function" then
        local pid: unknown = proc:pid()
        if type(pid) == "number" then
            local found = identity.read(executor, math.floor(pid))
            if found then
                recorded = found
                fields.pid = found.pid
                fields.pgid = found.pgid
                fields.start_ticks = found.start_ticks
                fields.boot_id = found.boot_id
            end
        end
    end
    local detail = recorded and ("pid " .. tostring(recorded.pid) .. " group " .. tostring(recorded.pgid)) or "no pid available from this runtime"
    local running = store.transition(db, attempt_id, {execution = "running", fields = fields, evidence = {kind = "child.started", detail = detail}})
    if not running.ok then
        local current = store.row(db, attempt_id)
        if current and current.execution_state == "stopping" and current.runner_pid == process.pid() then
            local recorded_start = store.transition(db, attempt_id, {expected_execution = "stopping", fields = fields,
                evidence = {kind = "child.started", detail = detail .. "; stop requested during startup"}})
            if not recorded_start.ok then
                proc:close(true)
                executor:release()
                return refuse(recorded_start.message or "record child identity after startup stop")
            end
            process.send(starter, reply_topic, {started = false, reason = "stop requested during startup"})
        else
            proc:close(true)
            executor:release()
            return refuse(running.message or "record start")
        end
    else
        process.send(starter, reply_topic, {started = true, attempt = running.attempt})
    end
    local stdin_closed = false
    if stdin_materialized then
        stdin_closed = true
        evidence(db, attempt_id, "stdin.materialized", "initial input supplied through an admitted source with EOF")
    elseif request.launch.stdin then
        -- The complete initial input goes first, then stdin is closed once
        -- for a launch that reads until end of file; each step leaves
        -- evidence so accepted input, closure and uncertainty stay distinct.
        local accepted, write_error = proc:write_stdin(request.launch.stdin)
        if accepted then
            evidence(db, attempt_id, "stdin.accepted", tostring(#request.launch.stdin) .. " bytes of initial input")
        else
            evidence(db, attempt_id, "stdin.uncertain", "initial input write failed")
        end
        if request.launch.stdin_eof == true then
            if accepted and type(handle.close_stdin) == "function" then
                local closed, close_error = proc:close_stdin()
                if closed then
                    stdin_closed = true
                    evidence(db, attempt_id, "stdin.closed", "stdin closed after the initial input")
                else
                    evidence(db, attempt_id, "stdin.uncertain", "stdin close failed")
                end
            elseif accepted then
                evidence(db, attempt_id, "stdin.uncertain", "executor cannot close stdin")
            end
        end
    end
    -- Pumps hand chunks to the loop through a small channel; a full channel
    -- blocks the pump, and a blocked pump blocks the child. The exit is
    -- learned from the runtime's done channel where it exists; otherwise
    -- wait() runs only after both streams end, because wait() consumes the
    -- handle and would end signalling and input.
    local function chunk_value(value: Chunk): Chunk return {stream = value.stream, data = value.data, eof = value.eof} end
    local chunks = channel.new(4)
    local exits = channel.new(1)
    local function pump(name: Stream, stream)
        coroutine.spawn(function()
            while true do
                local data = stream:read(protocol.MAX_CHUNK_BYTES)
                if not data or #tostring(data) == 0 then break end
                local chunk: Chunk = {stream = name, data = tostring(data), eof = false}
                chunks:send(chunk_value(chunk))
            end
            local chunk: Chunk = {stream = name, data = nil, eof = true}
            chunks:send(chunk_value(chunk))
        end)
    end
    pump("stdout", stdout)
    pump("stderr", stderr)
    local has_done = type(handle.done) == "function"
    local waited = false
    local function reap()
        if waited then return end
        waited = true
        coroutine.spawn(function()
            local code, wait_error = proc:wait()
            local exit_code = bounds.integer(code)
            if not exit_code then error("executor returned an invalid exit code") end
            exits:send({code = exit_code, error = wait_error})
        end)
    end
    if has_done then
        local done = proc:done()
        coroutine.spawn(function()
            local outcome = done:receive()
            local code = bounds.integer(outcome.code)
            if not code then error("executor returned an invalid exit code") end
            exits:send({code = code, error = outcome.error})
        end)
    end
    -- The recipient is watched: a carrier that dies while the child lives
    -- has its binding retired here, independently of any replacement.
    if recipient then
        process.send(recipient, protocol.TOPIC_ATTACHED, {attempt_id = attempt_id, generation = generation})
    end
    local pending: {Pending} = {}
    local spooled = 0
    local next_sequence = 1
    local sent_through = 0
    local consumed_through = 0
    -- Pipe reads can be much smaller than the requested read size. A short
    -- coalescing window keeps line-oriented providers from turning each
    -- flushed JSON line into a separate durable carrier commit.
    local coalesce_timer = time.after("1ms")
    local coalesce_armed = false
    local buffered = output_buffer.new()
    local function enqueue(stream: Stream, data: string?, eof: boolean, marked: boolean?)
        local bytes = data and #data or 0
        pending[#pending + 1] = {sequence = next_sequence, stream = stream, data = data, eof = eof, bytes = bytes, truncated = marked}
        next_sequence = next_sequence + 1
    end
    local function flush_buffer(stream: Stream)
        local item = output_buffer.flush(buffered, stream)
        if item then enqueue(item.stream, item.data, false, nil) end
    end
    local function flush_buffers()
        flush_buffer("stdout")
        flush_buffer("stderr")
    end
    local function buffer_data(stream: Stream, data: string)
        if data == "" then return end
        spooled = spooled + #data
        for _, item in ipairs(output_buffer.append(buffered, stream, data)) do
            enqueue(item.stream, item.data, false, nil)
        end
        if not coalesce_armed then
            coalesce_timer = time.after(tostring(output_buffer.COALESCE_WINDOW_MS) .. "ms")
            coalesce_armed = true
        end
    end
    local remembered: {string} = {}
    local remembered_set: {[string]: boolean} = {}
    local inputs = assert(process.listen(protocol.TOPIC_INPUT, {message = true}))
    local acks = assert(process.listen(protocol.TOPIC_ACK, {message = true}))
    local kill_timer = time.after("1ms")
    local kill_armed = false
    local kill_why = ""
    -- Unacknowledged output outlives the child only for the retention
    -- deadline; past it the loss is recorded, never mistaken for consumption.
    local retain_timer = time.after("1ms")
    local retain_armed = false
    -- An independently observed exit while descendants hold the pipes open
    -- drains for a bounded time, then the streams are closed and the drain
    -- is recorded. Time spent with pipe reads paused by spool backpressure
    -- does not consume this drain budget; retention still bounds that wait.
    local drain_timer = time.after("1ms")
    local drain_armed = false
    local drain_remaining = request.timeouts.drain_ms
    local drain_started = time.now()
    -- A lost carrier's binding outlives it only for the takeover grace: a
    -- replacement that attaches under a newer generation inherits it, and
    -- nothing else keeps it alive.
    local takeover_timer = time.after("1ms")
    local takeover_armed = false
    local lost_generation = 0
    local streams_closed = false
    local truncated = false
    local function close_streams()
        if streams_closed then return end
        streams_closed = true
        stdout:close()
        stderr:close()
    end
    local eof_seen = 0
    local exited = false
    local exit_code: integer? = nil
    local function flush()
        if not recipient then return end
        local outstanding = sent_through - consumed_through
        for _, item in ipairs(pending) do
            if item.sequence > sent_through then
                if outstanding >= protocol.MAX_OUTSTANDING_CHUNKS then return end
                process.send(recipient, protocol.TOPIC_OUTPUT, {attempt_id = attempt_id, generation = generation, stream = item.stream, sequence = item.sequence, data = item.data, eof = item.eof, truncated = item.truncated})
                sent_through = item.sequence
                outstanding = outstanding + 1
            end
        end
    end
    local function acknowledge(through: integer)
        if through <= consumed_through or through > sent_through then return end
        consumed_through = through
        local kept: {Pending} = {}
        spooled = 0
        for _, item in ipairs(pending) do
            if item.sequence > through then
                kept[#kept + 1] = item
                spooled = spooled + item.bytes
            end
        end
        spooled = spooled + output_buffer.size(buffered)
        pending = kept
    end
    local function signal(number: integer, kind: string, why: string)
        local ok, err = proc:signal(number)
        local detail = why .. (ok and "" or ("; signal failed: " .. tostring(err)))
        if group then detail = detail .. "; delivered to the group" else detail = detail .. "; delivered to the direct process only" end
        evidence(db, attempt_id, kind, detail, {execution = "stopping"})
    end
    local stop_requested = false
    local function request_stop(mode: string, grace_ms: integer, why: string)
        stop_requested = true
        if mode == "forced" then
            signal(9, "signal.kill", why)
        else
            signal(15, "signal.term", why)
            kill_timer = time.after(tostring(grace_ms) .. "ms")
            kill_armed = true
            kill_why = why
        end
    end
    while true do
        local reads_paused = spooled >= protocol.MAX_SPOOL_BYTES
        if retain_armed and eof_seen < 2 and not reads_paused then retain_armed = false end
        if drain_armed and reads_paused then
            drain_remaining = math.floor(math.max(0, drain_remaining - time.now():sub(drain_started):milliseconds()))
            drain_armed = false
        elseif exited and eof_seen < 2 and not reads_paused and not drain_armed and not streams_closed then
            drain_started = time.now()
            drain_timer = time.after(tostring(math.max(1, drain_remaining)) .. "ms")
            drain_armed = true
        end
        local cases = {controls:case_receive(), inputs:case_receive(), acks:case_receive(), events:case_receive(), exits:case_receive()}
        if spooled < protocol.MAX_SPOOL_BYTES and eof_seen < 2 then cases[#cases + 1] = chunks:case_receive() end
        if coalesce_armed then cases[#cases + 1] = coalesce_timer:case_receive() end
        if kill_armed then cases[#cases + 1] = kill_timer:case_receive() end
        if retain_armed then cases[#cases + 1] = retain_timer:case_receive() end
        if drain_armed then cases[#cases + 1] = drain_timer:case_receive() end
        if takeover_armed then cases[#cases + 1] = takeover_timer:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then break end
        if drain_armed and selected.channel == drain_timer then
            drain_armed = false
            if eof_seen < 2 then
                truncated = true
                evidence(db, attempt_id, "output.drain_elapsed", "drain of " .. tostring(request.timeouts.drain_ms) .. " ms elapsed after exit with " .. tostring(2 - eof_seen) .. " stream(s) still open; the streams are closed, which is forced truncation, not observed end of output", {})
                close_streams()
            end
        elseif retain_armed and selected.channel == retain_timer then
            flush_buffers()
            local bytes = spooled
            evidence(db, attempt_id, "output.lost", "retention of " .. tostring(request.timeouts.retain_ms) .. " ms elapsed with " .. tostring(#pending) .. " unacknowledged chunks (" .. tostring(bytes) .. " bytes); consumed through " .. tostring(consumed_through) .. ", sent through " .. tostring(sent_through) .. (eof_seen < 2 and "; unread pipe output is also lost" or ""), {})
            pending = {}
            break
        end
        if coalesce_armed and selected.channel == coalesce_timer then
            coalesce_armed = false
            flush_buffers()
            flush()
        elseif selected.channel == chunks then
            local raw_chunk = bounds.object(selected.value)
            if not raw_chunk then error("invalid pipe chunk") end
            local stream, data, eof = raw_chunk.stream, raw_chunk.data, raw_chunk.eof
            if (stream ~= "stdout" and stream ~= "stderr") or (data ~= nil and type(data) ~= "string")
                or type(eof) ~= "boolean" then error("invalid pipe chunk") end
            local chunk: Chunk = {stream = stream, data = data, eof = eof}
            local marked: boolean? = nil
            if chunk.eof and truncated then marked = true end
            if chunk.data then buffer_data(chunk.stream, chunk.data) end
            if chunk.eof then
                flush_buffer(chunk.stream)
                enqueue(chunk.stream, nil, true, marked)
                eof_seen = eof_seen + 1
            end
            if eof_seen >= 2 and not has_done and not exited then reap() end
            flush()
        elseif selected.channel == exits then
            local outcome = selected.value
            exited = true
            if type(outcome.code) == "number" then exit_code = math.floor(outcome.code) end
            local detail = exit_code and ("exit code " .. tostring(exit_code)) or ("wait returned no code: " .. tostring(outcome.error))
            store.transition(db, attempt_id, {execution = "exited", fields = {exit_code = exit_code, exit_source = "runner"}, evidence = {kind = "child.exited", detail = detail}})
            -- The child's end seals intake; the carrier drains what was
            -- accepted and revokes when it closes.
            seal_gateway("child exited")
            kill_armed = false
            if recipient then
                process.send(recipient, protocol.TOPIC_EXIT, {attempt_id = attempt_id, generation = generation, code = exit_code, signal = nil, uncertain = exit_code == nil, stopped = stop_requested})
            end
        elseif kill_armed and selected.channel == kill_timer then
            if not exited then signal(9, "signal.kill", "grace elapsed after " .. kill_why) end
            kill_armed = false
        elseif selected.channel == controls then
            local message = selected.value
            local data: unknown = message:payload():data()
            local sender = tostring(message:from())
            -- The per-attempt token authenticates placement-service controls.
            -- The bound carrier may ask only whether its pending write was seen.
            if type(data) == "table" and (data.control_token == control_token
                or recipient ~= nil and sender == recipient and data.command == "write_status") then
                if data.command == "stop" and not exited then
                    local mode = data.mode == "forced" and "forced" or "cooperative"
                    local grace = type(data.grace_ms) == "number" and math.floor(data.grace_ms) or request.timeouts.stop_grace_ms
                    request_stop(mode, grace, mode .. " stop requested")
                elseif data.command == "attach" and type(data.recipient) == "string" and type(data.generation) == "number" then
                    local next_generation = math.floor(data.generation)
                    local installed = false
                    local refusal_reason: string? = nil
                    if next_generation > generation then
                        local same_recipient = recipient == data.recipient
                        local monitored, monitor_error = true, nil
                        if not same_recipient then monitored, monitor_error = process.monitor(data.recipient) end
                        if monitored then
                            if recipient and not same_recipient then process.unmonitor(recipient) end
                            if takeover_armed then
                                takeover_armed = false
                                evidence(db, attempt_id, "carrier.replaced", "generation " .. tostring(next_generation) .. " took over from lost generation " .. tostring(lost_generation) .. "; gateway binding kept")
                            end
                            generation = next_generation
                            recipient = data.recipient
                            installed = true
                            process.send(recipient, protocol.TOPIC_ATTACHED, {attempt_id = attempt_id, generation = generation})
                            sent_through = consumed_through
                            flush()
                            if exited then process.send(recipient, protocol.TOPIC_EXIT, {attempt_id = attempt_id, generation = generation, code = exit_code, signal = nil, uncertain = exit_code == nil, stopped = stop_requested}) end
                        else
                            refusal_reason = "recipient is not monitorable: " .. tostring(monitor_error)
                            evidence(db, attempt_id, "attach.refused", "generation " .. tostring(next_generation) .. " recipient is not monitorable: " .. tostring(monitor_error))
                        end
                    else
                        refusal_reason = "generation is not newer than the attached generation"
                    end
                    -- The fence answer goes to the service that asked: from here on
                    -- only the named generation writes or acknowledges.
                    process.send(tostring(message:from()), protocol.TOPIC_FENCED, {attempt_id = attempt_id, generation = next_generation,
                        fenced = installed, refused = not installed, reason = refusal_reason})
                elseif data.command == "write_status" and type(data.write_id) == "string" then
                    local status = remembered_set[data.write_id] and "accepted" or "unknown"
                    process.send(tostring(message:from()), protocol.TOPIC_WRITE_STATUS, {attempt_id = attempt_id, generation = generation, write_id = data.write_id, status = status})
                elseif data.command == "status" and data.attempt_id == attempt_id and type(data.probe) == "string" then
                    local execution = "running"
                    if exited then execution = "exited" elseif kill_armed then execution = "stopping" end
                    process.send(tostring(message:from()), protocol.TOPIC_STATUS, {attempt_id = attempt_id, generation = generation, probe = data.probe, execution = execution, exit_code = exit_code,
                        eof_seen = eof_seen, pending_outputs = #pending, remembered_writes = #remembered, truncated = truncated})
                elseif data.command == "close_stdin" and data.attempt_id == attempt_id and type(data.probe) == "string" then
                    -- The owner ends a settled session by closing stdin; the
                    -- fact is recorded apart from input acceptance and exit.
                    local closed_now = false
                    local reason: string? = nil
                    if stdin_closed then
                        closed_now = true
                    elseif exited then
                        reason = "the child has exited"
                    elseif type(handle.close_stdin) ~= "function" then
                        reason = "executor cannot close stdin"
                        evidence(db, attempt_id, "stdin.uncertain", "executor cannot close stdin at the owner's request")
                    else
                        local closed, close_error = proc:close_stdin()
                        if closed then
                            stdin_closed = true
                            closed_now = true
                            evidence(db, attempt_id, "stdin.closed", "stdin closed at the owner's request after settlement")
                        else
                            reason = "stdin close failed: " .. tostring(close_error)
                            evidence(db, attempt_id, "stdin.uncertain", reason)
                        end
                    end
                    process.send(tostring(message:from()), protocol.TOPIC_STDIN, {attempt_id = attempt_id, generation = generation, probe = data.probe, closed = closed_now, reason = reason})
                elseif data.command == "detach" and type(data.generation) == "number" and math.floor(data.generation) >= generation then
                    recipient = nil
                    generation = math.floor(data.generation)
                end
            end
        elseif selected.channel == inputs then
            local message = selected.value
            local data: unknown = message:payload():data()
            local sender = tostring(message:from())
            if type(data) == "table" and type(data.write_id) == "string" and type(data.data) == "string" then
                local write_id = data.write_id
                -- The answer names the requester's generation so a fenced sender
                -- can record its refusal; the runner's own generation decides.
                local asked: integer = generation
                if type(data.generation) == "number" then asked = math.floor(data.generation) end
                local reply = {attempt_id = attempt_id, generation = asked, write_id = write_id, accepted = false, reason = nil}
                if sender ~= recipient or data.generation ~= generation then
                    reply.reason = "not the bound recipient"
                elseif #(data.data) > protocol.MAX_WRITE_BYTES then
                    reply.reason = "write exceeds " .. tostring(protocol.MAX_WRITE_BYTES) .. " bytes"
                elseif remembered_set[write_id] then
                    reply.accepted = true
                elseif exited then
                    reply.reason = "the child has exited"
                elseif request.launch.stdin_eof == true or stdin_closed then
                    reply.reason = "stdin is closed after its input"
                else
                    local written, write_error = proc:write_stdin(data.data)
                    if written then
                        reply.accepted = true
                        remembered[#remembered + 1] = write_id
                        remembered_set[write_id] = true
                        if #remembered > protocol.MAX_REMEMBERED_WRITES then
                            local oldest = table.remove(remembered, 1)
                            remembered_set[oldest] = nil
                        end
                    else
                        reply.reason = "write failed: " .. tostring(write_error)
                    end
                end
                process.send(sender, protocol.TOPIC_ACK, reply)
            end
        elseif selected.channel == acks then
            local message = selected.value
            local data: unknown = message:payload():data()
            if type(data) == "table" and tostring(message:from()) == recipient and data.generation == generation and type(data.consumed_through) == "number" then
                acknowledge(math.floor(data.consumed_through))
                flush()
            end
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then
                if not exited then
                    signal(9, "signal.kill", "runner cancelled")
                    if not has_done then reap() end
                    local outcome = exits:receive()
                    if type(outcome) == "table" and type(outcome.code) == "number" then exit_code = math.floor(outcome.code) end
                    store.transition(db, attempt_id, {execution = "exited", fields = {exit_code = exit_code, exit_source = "runner"}, evidence = {kind = "child.exited", detail = "after runner cancellation, exit code " .. tostring(exit_code)}})
                    exited = true
                end
                retire_gateway("runner cancelled")
                break
            elseif event.kind == process.event.EXIT and recipient ~= nil and tostring(event.from) == recipient then
                -- A carrier that returns has closed the attempt; one that ends
                -- in an error, a crash or a termination, is lost, whether or
                -- not the child has exited, so the order in which the runner
                -- observes the two exits decides nothing.
                local result: unknown = event.result
                local closed = type(result) == "table" and (result).error == nil
                if gateway_binding and not takeover_armed and not closed then
                    lost_generation = generation
                    takeover_timer = time.after(tostring(protocol.TAKEOVER_GRACE_MS) .. "ms")
                    takeover_armed = true
                    evidence(db, attempt_id, "carrier.lost", "carrier " .. tostring(recipient) .. " exited under generation " .. tostring(generation) .. "; gateway binding retired unless a newer generation attaches within " .. tostring(protocol.TAKEOVER_GRACE_MS) .. " ms")
                end
            elseif event.kind == process.event.EXIT then
                evidence(db, attempt_id, "carrier.stale_exit", "exit of " .. tostring(event.from) .. " is not the attached generation " .. tostring(generation) .. "; ignored")
            end
        elseif takeover_armed and selected.channel == takeover_timer then
            takeover_armed = false
            retire_gateway("carrier lost under generation " .. tostring(lost_generation) .. "; no takeover within " .. tostring(protocol.TAKEOVER_GRACE_MS) .. " ms")
        end
        if exited and eof_seen >= 2 and #pending == 0 then break end
        if exited and (eof_seen >= 2 or spooled >= protocol.MAX_SPOOL_BYTES) and not retain_armed then
            retain_timer = time.after(tostring(request.timeouts.retain_ms) .. "ms")
            retain_armed = true
        end
    end
    close_streams()
    if exited and #materialized.writebacks > 0 then
        local scope_absent = false
        local scope_error = "write-back requires a proven-empty process group"
        if backend then scope_absent, scope_error = backend.absent(request)
        elseif request.required_cleanup == "process_group" and recorded and recorded.pgid then
            local absent, absent_error = identity.group_absent(recorded.pgid)
            scope_absent = absent == true
            if absent ~= true then scope_error = absent_error or "provider worker processes remain" end
        end
        if scope_absent then
            for _, result in ipairs(materialization.write_back(materialized.home_path, materialized.writebacks, request.owner_id, attempt_id)) do
                if result.ok then
                    evidence(db, attempt_id, "credential.write_back", "projection " .. result.projection_id .. (result.written and " refreshed token persisted" or " token unchanged"))
                else
                    evidence(db, attempt_id, "credential.write_back_failed", "projection " .. result.projection_id .. ": " .. tostring(result.message or result.code or "UNAVAILABLE"))
                end
            end
        else
            for _, candidate in ipairs(materialized.writebacks) do
                evidence(db, attempt_id, "credential.write_back_failed", "projection " .. candidate.projection_id .. ": " .. scope_error)
            end
        end
    end
    executor:release()
    process.unlisten(controls)
    process.unlisten(inputs)
    process.unlisten(acks)
    evidence(db, attempt_id, "runner.finished", "pending chunks " .. tostring(#pending) .. ", consumed through " .. tostring(consumed_through), {fields = {runner_pid = sql.NULL}})
    local ended = store.attempt(db, attempt_id)
    if ended and ended.execution_state == "exited" then cleanup(ended) end
    db:release()
end
return {main = main}
