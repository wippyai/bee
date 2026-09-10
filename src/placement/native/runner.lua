-- MIT. The attempt runner: one Wippy process per attempt that owns the
-- executor handle, materializes the home, starts the child, records its
-- identity, pumps bounded output to the bound recipient, accepts
-- acknowledged input, signals on request, and records the exit it
-- observed. When the runner is cancelled, the child is stopped; nothing
-- outlives the runner unobserved.
local process = require("process")
local channel = require("channel")
local time = require("time")
local exec = require("exec")
local env = require("env")
local funcs = require("funcs")
local store = require("store")
local resources = require("resources")
local homes = require("homes")
local gateway_configuration = require("gateway_configuration")
local executable = require("executable")
local identity = require("identity")
local protocol = require("protocol")
local quote = require("quote")
local types = require("types")
type Chunk = {stream: string, data: string?, eof: boolean}
type Pending = {sequence: integer, stream: string, data: string?, eof: boolean, bytes: integer, truncated: boolean?}
local function evidence(db, attempt_id: string, kind: string, detail: string, update: {[string]: unknown}?): (boolean, string?)
    local result = store.transition(db, attempt_id, {execution = update and update.execution :: types.ExecutionState? or nil,
        fields = update and update.fields :: {[string]: unknown}? or nil, evidence = {kind = kind, detail = detail}})
    if not result.ok then return false, result.message end
    return true, nil
end
local function resolve_environment(request: types.LaunchRequest, home: string): ({[string]: string}?, string?)
    local values: {[string]: string} = {}
    for name, value in pairs(request.environment) do values[name] = value end
    for name, ref in pairs(request.environment_refs) do
        local value, err = env.get(ref)
        if err or type(value) ~= "string" then return nil, "environment " .. name .. " unavailable from " .. ref end
        values[name] = value
    end
    values.HOME = home
    return values, nil
end
local function resolve_work_dir(request: types.LaunchRequest, home: string): (string?, string?)
    local ref = request.launch.working_directory_ref
    if not ref then return home, nil end
    for _, grant in ipairs(request.resources) do
        if grant.name == ref then
            local directory, err = resources.directory(grant.root_ref)
            if not directory then return nil, err end
            if grant.subpath == "" then return directory, nil end
            return directory .. "/" .. grant.subpath, nil
        end
    end
    return nil, "working directory grant is missing"
end
local function main(attempt_id: string, starter: string, reply_topic: string, expected_binding: string?, materialization_key: string?)
    local db, open_error = store.open()
    if not db then error("open placement store: " .. tostring(open_error)) end
    -- The gateway binding this runner materialized, retired by this runner
    -- when the child never starts, exits, or outlives its carrier. Only the
    -- binding id is held; the token bytes live in the child's environment.
    local gateway_binding: string? = nil
    local function seal_gateway(why: string)
        if not gateway_binding then return end
        local raw, call_error = funcs.call(resources.GATEWAY_SEAL, {binding_id = gateway_binding})
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string}?} or nil
        if call_error or not reply or not reply.ok then
            evidence(db, attempt_id, "gateway.seal_failed", why .. "; binding " .. tostring(gateway_binding) .. ": " .. tostring(call_error or (reply and reply.error and reply.error.code) or "no answer"))
            return
        end
        evidence(db, attempt_id, "gateway.sealed", why .. "; binding " .. tostring(gateway_binding) .. "; accepted hooks stay for the carrier")
    end
    local function retire_gateway(why: string)
        if not gateway_binding then return end
        local binding_id = gateway_binding :: string
        gateway_binding = nil
        local raw, call_error = funcs.call(resources.GATEWAY_REVOKE, {binding_id = binding_id})
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string}?} or nil
        if call_error or not reply or not reply.ok then
            evidence(db, attempt_id, "gateway.revoke_failed", why .. "; binding " .. binding_id .. ": " .. tostring(call_error or (reply and reply.error and reply.error.code) or "no answer"))
            return
        end
        evidence(db, attempt_id, "gateway.revoked", why .. "; binding " .. binding_id)
    end
    local function refuse(reason: string)
        retire_gateway("start refused: " .. reason)
        process.send(starter, reply_topic, {started = false, reason = reason})
        db:release()
    end
    local row, row_error = store.row(db, attempt_id)
    if not row then return refuse(row_error or "attempt is not recorded") end
    local request, request_error = store.request(row)
    if not request then return refuse(request_error or "request unreadable") end
    local recipient: string? = type(row.recipient) == "string" and row.recipient :: string or nil
    local generation = type(row.attachment_generation) == "number" and math.floor(row.attachment_generation :: number) or 0
    local group = row.capability == "process_group"
    local starting = store.transition(db, attempt_id, {execution = "starting", fields = {runner_pid = process.pid()}, evidence = {kind = "runner.started", detail = "runner " .. process.pid()}})
    if not starting.ok then return refuse(starting.message or "attempt is not intended") end
    local home_key, key_error = homes.attempt_key(request.owner_id, attempt_id)
    if not home_key then
        evidence(db, attempt_id, "home.failed", key_error or "key", {execution = "uncertain"})
        return refuse(key_error or "home key")
    end
    local home_path, home_error = homes.create_attempt(home_key)
    if not home_path then
        evidence(db, attempt_id, "home.failed", home_error or "home", {execution = "exited"})
        return refuse(home_error or "attempt home")
    end
    evidence(db, attempt_id, "home.created", "attempt home under derived key", {fields = {home_key = home_key}})
    -- Parents this runner creates in the home for its configuration files.
    local created_parents: {[string]: boolean} = {}
    if request.configuration then
        local configuration = request.configuration
        local written, write_error = homes.write_protected(home_path, configuration.path, configuration.content, created_parents)
        if not written then
            evidence(db, attempt_id, "configuration.refused", tostring(write_error), {execution = "exited"})
            return refuse(write_error or "configuration")
        end
        evidence(db, attempt_id, "configuration.materialized", configuration.revision .. " " .. configuration.path .. " digest " .. configuration.digest .. " in home " .. home_key)
    end
    local home_os, home_os_error = homes.os_path(home_path .. "/home")
    if not home_os then
        evidence(db, attempt_id, "home.failed", home_os_error or "home path", {execution = "exited"})
        return refuse(home_os_error or "home path")
    end
    if request.session_ref then
        local session_key, session_key_error = homes.session_key(request.owner_id, request.session_ref)
        local session_path = session_key and homes.ensure_session(session_key) or nil
        if not session_path then
            evidence(db, attempt_id, "session.failed", session_key_error or "session directory", {execution = "exited"})
            return refuse("session directory")
        end
        if request.launch.home_ref then
            local session_os = homes.os_path(session_path)
            if session_os then home_os = session_os end
        end
        evidence(db, attempt_id, "session.attached", "retained session directory")
    end
    local environment, environment_error = resolve_environment(request, home_os)
    if not environment then
        evidence(db, attempt_id, "environment.failed", environment_error or "environment", {execution = "exited"})
        return refuse(environment_error or "environment")
    end
    -- Credential projections arrive as bytes in a reply nothing persists;
    -- only the projection id and the outcome reach evidence.
    for index, projection_id in ipairs(request.projections) do
        local raw, call_error = funcs.call(resources.CREDENTIAL_MATERIALIZE, {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id,
            attempt_id = attempt_id, generation_key = attempt_id .. ":" .. tostring(index)})
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string}?, value: {destination: string, value: string}?} or nil
        if call_error or not reply or not reply.ok or not reply.value then
            local code = reply and reply.error and reply.error.code or "UNAVAILABLE"
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
            return refuse("projection " .. projection_id .. ": " .. code)
        end
        local projected = reply.value :: {destination: string, value: string}
        environment[projected.destination] = projected.value
        evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " into " .. projected.destination)
    end
    -- The gateway token is minted at delivery for the binding this attempt
    -- holds under the attached carrier epoch, written nowhere: the
    -- host-approved MCP configuration goes into the private home with
    -- protected creation and names the environment destination the bytes
    -- fill. Evidence carries the generation, never the bytes.
    if request.gateway then
        local gateway = request.gateway
        -- A standalone MCP configuration goes into the home; a launch whose
        -- provider configuration already carries the gateway section has none.
        if gateway.configuration then
            local configured, configure_error = homes.write_protected(home_path, gateway.configuration.path, gateway.configuration.content, created_parents)
            if not configured then
                evidence(db, attempt_id, "gateway.refused", "configuration: " .. tostring(configure_error), {execution = "exited"})
                return refuse(configure_error or "gateway configuration")
            end
        end
        if generation < 1 then
            evidence(db, attempt_id, "gateway.refused", "the attempt is not attached to a carrier", {execution = "exited"})
            return refuse("gateway binding: the attempt is not attached to a carrier")
        end
        -- The hook adapters go into the home before the credentials: the
        -- Claude settings adapter, or the Codex hooks file with its trust
        -- state written under this home's own path into the profile layer.
        if gateway.hook_configuration then
            local configured_hooks, hooks_error = homes.write_protected(home_path, gateway.hook_configuration.path, gateway.hook_configuration.content, created_parents)
            if not configured_hooks then
                evidence(db, attempt_id, "gateway.refused", "hook configuration: " .. tostring(hooks_error), {execution = "exited"})
                return refuse(hooks_error or "gateway hook configuration")
            end
        end
        if gateway.codex_hooks then
            local codex = gateway.codex_hooks
            local hooks_written, hooks_write_error = homes.write_protected(home_path, codex.hooks.path, codex.hooks.content, created_parents)
            if not hooks_written then
                evidence(db, attempt_id, "gateway.refused", "codex hooks: " .. tostring(hooks_write_error), {execution = "exited"})
                return refuse(hooks_write_error or "codex hooks")
            end
            local trust_content = gateway_configuration.codex_trust(home_os .. "/.codex", codex.trust)
            local trust_written, trust_error = homes.write_protected(home_path, ".codex/" .. codex.profile .. ".config.toml", trust_content, created_parents)
            if not trust_written then
                evidence(db, attempt_id, "gateway.refused", "codex hook trust: " .. tostring(trust_error), {execution = "exited"})
                return refuse(trust_error or "codex hook trust")
            end
        end
        local raw, call_error = funcs.call(resources.GATEWAY_MATERIALIZE, {attempt_id = attempt_id, carrier_epoch = generation, binding_id = expected_binding, materialization_key = materialization_key})
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string, message: string}?, value: {token: string, hook_token: string?, generation: number, binding: {binding_id: string}}?} or nil
        if call_error or not reply or not reply.ok or not reply.value then
            local code = reply and reply.error and (reply.error.code .. ": " .. reply.error.message) or tostring(call_error or "UNAVAILABLE")
            evidence(db, attempt_id, "gateway.refused", "materialize under carrier epoch " .. tostring(generation) .. ": " .. code, {execution = "exited"})
            return refuse("gateway binding: " .. code)
        end
        local materialized = reply.value :: {token: string, hook_token: string?, generation: number, binding: {binding_id: string}}
        environment[gateway.destination] = materialized.token
        if gateway.hook_destination and materialized.hook_token then environment[gateway.hook_destination] = materialized.hook_token end
        gateway_binding = materialized.binding.binding_id
        local configured_as = "configuration in the provider file"
        if gateway.configuration then configured_as = "configuration " .. gateway.configuration.revision .. " " .. gateway.configuration.path .. " digest " .. gateway.configuration.digest end
        evidence(db, attempt_id, "gateway.materialized", "binding " .. materialized.binding.binding_id .. " credential generation " .. tostring(materialized.generation) .. " under carrier epoch " .. tostring(generation) .. " into " .. gateway.destination .. "; " .. configured_as)
    end
    local work_dir, work_dir_error = resolve_work_dir(request, home_os)
    if not work_dir then
        evidence(db, attempt_id, "workdir.failed", work_dir_error or "working directory", {execution = "exited"})
        return refuse(work_dir_error or "working directory")
    end
    local executor, executor_error = exec.get(resources.EXECUTOR)
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
    for _, argument in ipairs(request.launch.argv) do argv[#argv + 1] = argument end
    local proc, exec_error = executor:exec(quote.line(argv), {work_dir = work_dir, env = environment, process_group = group})
    if not proc then
        -- The executor's own text is not recorded: it may quote the command
        -- or the environment it refused.
        evidence(db, attempt_id, "child.refused", "executor refused the command", {execution = "exited"})
        executor:release()
        return refuse("executor refused the command")
    end
    local stdout = proc:stdout_stream()
    local stderr = proc:stderr_stream()
    local started, start_error = proc:start()
    if not started then
        evidence(db, attempt_id, "child.start_failed", "the child did not start", {execution = "exited"})
        executor:release()
        return refuse("the child did not start")
    end
    local fields: {[string]: unknown} = {}
    local recorded: identity.Identity? = nil
    local handle = proc :: {[string]: unknown}
    if type(handle.pid) == "function" then
        local pid: unknown = (handle.pid :: (unknown) -> unknown)(proc)
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
        proc:close(true)
        executor:release()
        return refuse(running.message or "record start")
    end
    process.send(starter, reply_topic, {started = true, attempt = running.attempt})
    local stdin_closed = false
    if request.launch.stdin then
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
                local closed, close_error = (handle.close_stdin :: (unknown) -> (unknown, unknown))(proc)
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
    local chunks = channel.new(4)
    local exits = channel.new(1)
    local function pump(name: string, stream)
        coroutine.spawn(function()
            while true do
                local data = stream:read(protocol.MAX_CHUNK_BYTES)
                if not data or #tostring(data) == 0 then break end
                chunks:send({stream = name, data = tostring(data), eof = false})
            end
            chunks:send({stream = name, data = nil, eof = true})
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
            exits:send({code = code, error = wait_error})
        end)
    end
    if has_done then
        local done_value: unknown = (handle.done :: (unknown) -> unknown)(proc)
        local done = done_value :: {receive: (unknown) -> (unknown, boolean)}
        coroutine.spawn(function()
            local outcome = done.receive(done)
            local table_outcome = type(outcome) == "table" and outcome :: {[string]: unknown} or {}
            exits:send({code = table_outcome.code, error = table_outcome.error})
        end)
    end
    -- The recipient is watched: a carrier that dies while the child lives
    -- has its binding retired here, independently of any replacement.
    if recipient then
        process.monitor(recipient :: string)
        process.send(recipient :: string, protocol.TOPIC_ATTACHED, {attempt_id = attempt_id, generation = generation})
    end
    local pending: {Pending} = {}
    local spooled = 0
    local next_sequence = 1
    local sent_through = 0
    local consumed_through = 0
    local remembered: {string} = {}
    local remembered_set: {[string]: boolean} = {}
    local controls = assert(process.listen(protocol.TOPIC_CONTROL, {message = true}))
    local inputs = assert(process.listen(protocol.TOPIC_INPUT, {message = true}))
    local acks = assert(process.listen(protocol.TOPIC_ACK, {message = true}))
    local events = assert(process.events())
    local kill_timer = time.after("1ms")
    local kill_armed = false
    local kill_why = ""
    -- Unacknowledged output outlives the child only for the retention
    -- deadline; past it the loss is recorded, never mistaken for consumption.
    local retain_timer = time.after("1ms")
    local retain_armed = false
    -- An independently observed exit while descendants hold the pipes open
    -- drains for a bounded time, then the streams are closed and the drain
    -- is recorded; retention then applies to what was read.
    local drain_timer = time.after("1ms")
    local drain_armed = false
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
        pending = kept
    end
    local function signal(number: integer, kind: string, why: string)
        local ok, err = proc:signal(number)
        local detail = why .. (ok and "" or ("; signal failed: " .. tostring(err)))
        if group then detail = detail .. "; delivered to the group" else detail = detail .. "; delivered to the direct process only" end
        evidence(db, attempt_id, kind, detail, {execution = "stopping"})
    end
    local function request_stop(mode: string, grace_ms: integer, why: string)
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
        local cases = {controls:case_receive(), inputs:case_receive(), acks:case_receive(), events:case_receive(), exits:case_receive()}
        if spooled < protocol.MAX_SPOOL_BYTES and eof_seen < 2 then cases[#cases + 1] = chunks:case_receive() end
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
            local bytes = 0
            for _, item in ipairs(pending) do bytes = bytes + item.bytes end
            evidence(db, attempt_id, "output.lost", "retention of " .. tostring(request.timeouts.retain_ms) .. " ms elapsed with " .. tostring(#pending) .. " unacknowledged chunks (" .. tostring(bytes) .. " bytes); consumed through " .. tostring(consumed_through) .. ", sent through " .. tostring(sent_through), {})
            pending = {}
            break
        end
        if selected.channel == chunks then
            local chunk = selected.value :: Chunk
            local bytes = chunk.data and #(chunk.data :: string) or 0
            local marked: boolean? = nil
            if chunk.eof and truncated then marked = true end
            pending[#pending + 1] = {sequence = next_sequence, stream = chunk.stream, data = chunk.data, eof = chunk.eof, bytes = bytes, truncated = marked}
            next_sequence = next_sequence + 1
            spooled = spooled + bytes
            if chunk.eof then eof_seen = eof_seen + 1 end
            if eof_seen >= 2 and not has_done and not exited then reap() end
            flush()
        elseif selected.channel == exits then
            local outcome = selected.value :: {code: unknown, error: unknown}
            exited = true
            if type(outcome.code) == "number" then exit_code = math.floor(outcome.code :: number) end
            local detail = exit_code and ("exit code " .. tostring(exit_code)) or ("wait returned no code: " .. tostring(outcome.error))
            store.transition(db, attempt_id, {execution = "exited", fields = {exit_code = exit_code, exit_source = "runner"}, evidence = {kind = "child.exited", detail = detail}})
            -- The child's end seals intake; the carrier drains what was
            -- accepted and revokes when it closes.
            seal_gateway("child exited")
            kill_armed = false
            if eof_seen < 2 and not drain_armed then
                drain_timer = time.after(tostring(request.timeouts.drain_ms) .. "ms")
                drain_armed = true
            end
            if recipient then
                process.send(recipient, protocol.TOPIC_EXIT, {attempt_id = attempt_id, generation = generation, code = exit_code, signal = nil, uncertain = exit_code == nil})
            end
        elseif kill_armed and selected.channel == kill_timer then
            if not exited then signal(9, "signal.kill", "grace elapsed after " .. kill_why) end
            kill_armed = false
        elseif selected.channel == controls then
            local message = selected.value
            local data: unknown = message:payload():data()
            if type(data) == "table" then
                if data.command == "stop" and not exited then
                    local mode = data.mode == "forced" and "forced" or "cooperative"
                    local grace = type(data.grace_ms) == "number" and math.floor(data.grace_ms :: number) or request.timeouts.stop_grace_ms
                    request_stop(mode, grace, mode .. " stop requested")
                elseif data.command == "attach" and type(data.recipient) == "string" and type(data.generation) == "number" then
                    local next_generation = math.floor(data.generation :: number)
                    if next_generation > generation then
                        if recipient then process.unmonitor(recipient :: string) end
                        if takeover_armed then
                            takeover_armed = false
                            evidence(db, attempt_id, "carrier.replaced", "generation " .. tostring(next_generation) .. " took over from lost generation " .. tostring(lost_generation) .. "; gateway binding kept")
                        end
                        generation = next_generation
                        recipient = data.recipient :: string
                        process.monitor(recipient :: string)
                        process.send(recipient :: string, protocol.TOPIC_ATTACHED, {attempt_id = attempt_id, generation = generation})
                        sent_through = consumed_through
                        flush()
                        if exited then process.send(recipient :: string, protocol.TOPIC_EXIT, {attempt_id = attempt_id, generation = generation, code = exit_code, signal = nil, uncertain = exit_code == nil}) end
                    end
                    -- The fence answer goes to the service that asked: from here on
                    -- only the named generation writes or acknowledges.
                    process.send(tostring(message:from()), protocol.TOPIC_FENCED, {attempt_id = attempt_id, generation = generation, fenced = generation == next_generation})
                elseif data.command == "write_status" and type(data.write_id) == "string" then
                    local status = remembered_set[data.write_id :: string] and "accepted" or "unknown"
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
                        local closed, close_error = (handle.close_stdin :: (unknown) -> (unknown, unknown))(proc)
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
                elseif data.command == "detach" and type(data.generation) == "number" and math.floor(data.generation :: number) >= generation then
                    recipient = nil
                    generation = math.floor(data.generation :: number)
                end
            end
        elseif selected.channel == inputs then
            local message = selected.value
            local data: unknown = message:payload():data()
            local sender = tostring(message:from())
            if type(data) == "table" and type(data.write_id) == "string" and type(data.data) == "string" then
                local write_id = data.write_id :: string
                -- The answer names the requester's generation so a fenced sender
                -- can record its refusal; the runner's own generation decides.
                local asked: integer = generation
                if type(data.generation) == "number" then asked = math.floor(data.generation :: number) end
                local reply = {attempt_id = attempt_id, generation = asked, write_id = write_id, accepted = false, reason = nil}
                if sender ~= recipient or data.generation ~= generation then
                    reply.reason = "not the bound recipient"
                elseif #(data.data :: string) > protocol.MAX_WRITE_BYTES then
                    reply.reason = "write exceeds " .. tostring(protocol.MAX_WRITE_BYTES) .. " bytes"
                elseif remembered_set[write_id] then
                    reply.accepted = true
                elseif exited then
                    reply.reason = "the child has exited"
                elseif request.launch.stdin_eof == true or stdin_closed then
                    reply.reason = "stdin is closed after its input"
                else
                    local written, write_error = proc:write_stdin(data.data :: string)
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
                acknowledge(math.floor(data.consumed_through :: number))
                flush()
            end
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then
                if not exited then
                    signal(9, "signal.kill", "runner cancelled")
                    if not has_done then reap() end
                    local outcome = exits:receive()
                    if type(outcome) == "table" and type(outcome.code) == "number" then exit_code = math.floor(outcome.code :: number) end
                    store.transition(db, attempt_id, {execution = "exited", fields = {exit_code = exit_code, exit_source = "runner"}, evidence = {kind = "child.exited", detail = "after runner cancellation, exit code " .. tostring(exit_code)}})
                end
                retire_gateway("runner cancelled")
                break
            elseif event.kind == process.event.EXIT and recipient ~= nil and tostring(event.from) == recipient then
                -- A carrier that leaves after the child ended is closing, not
                -- lost; only a carrier lost while the child lives arms the grace.
                if gateway_binding and not takeover_armed and not exited then
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
        if exited and eof_seen >= 2 and not retain_armed then
            retain_timer = time.after(tostring(request.timeouts.retain_ms) .. "ms")
            retain_armed = true
        end
    end
    close_streams()
    executor:release()
    process.unlisten(controls)
    process.unlisten(inputs)
    process.unlisten(acks)
    evidence(db, attempt_id, "runner.finished", "pending chunks " .. tostring(#pending) .. ", consumed through " .. tostring(consumed_through), {fields = {runner_pid = nil}})
    db:release()
end
return {main = main}
