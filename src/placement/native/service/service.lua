-- MIT. The native placement operations. Every operation authenticates the
-- owner, reads the recorded attempt, and changes it only through a
-- transition with evidence. The runner does the external work.
local process = require("process")
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local sql = require("sql")
local cdc = require("cdc")
local uuid = require("uuid")
local env = require("env")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local request_codec = require("request")
local transitions = require("transitions")
local store = require("store")
local executable = require("executable")
local resources = require("resources")
local capability = require("capability")
local homes = require("homes")
local protocol = require("protocol")
local materialization = require("materialization")
local service_reply = require("service_reply")
local workdir_preparers = require("workdir_preparers")
local supervision = require("supervision")
local demand = require("demand")
local M = {}
local part_preparation = require("part_preparation")
type LocalPreparation = part_preparation.LocalPreparation
type Fault = part_preparation.Fault
type Reply = part_preparation.Reply
type DecodedReply = part_preparation.DecodedReply
type Access = part_preparation.Access
local fail = part_preparation.fail
local succeed = part_preparation.succeed
local decode_reply = part_preparation.decode_reply
local actor = part_preparation.actor
local transition = part_preparation.transition
type Resolved = part_preparation.Resolved
M.check_grants = part_preparation.check_grants
M.authorize_materialization = part_preparation.authorize_materialization
M.prepare_local = part_preparation.prepare_local
M.prepare = part_preparation.prepare
M.SWEEP_INTERVAL_MS = 30000
M.RECONCILE_TIMEOUT_MS = 5000
M.SWEEP_BOUND = 64
M.SWEEPER_NAME = "bee.placement.sweeper"
type Purpose = "project" | "output" | "cache" | "session"
local function owned(attempt: types.Attempt): Reply?
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if caller ~= attempt.owner_id then return fail("FORBIDDEN", "the attempt belongs to another owner") end
    return nil
end
local function load(attempt_id: unknown): (types.Attempt?, Reply?, store.Row?)
    local id = bounds.id(attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    local db, open_error = store.open()
    if not db then return nil, fail("STORAGE", open_error or "open placement store") end
    local attempt, read_error = store.attempt(db, id)
    local row = store.row(db, id)
    db:release()
    if read_error then return nil, fail("STORAGE", read_error) end
    if not attempt then return nil, fail("NOT_FOUND", "attempt is not recorded") end
    local denied = owned(attempt)
    if denied then return nil, denied end
    return attempt, nil, row
end
-- Requests that name only an attempt: {attempt_id}.
local function named(value: unknown): (string?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id"})
    if unknown_field then return nil, fail("INVALID", unknown_field) end
    local id = bounds.id(object.attempt_id)
    if not id then return nil, fail("INVALID", "attempt_id is not an identifier") end
    return id, nil
end
local function recorded_row(attempt_id: string): (store.Row?, string?)
    local db, open_error = store.open()
    if not db then return nil, open_error end
    local row, row_error = store.row(db, attempt_id)
    db:release()
    return row, row_error
end
local runner_status: (store.Row?, types.Attempt) -> (string?, string?)
-- The machine's current boot, as the host names it; absent where the
-- platform names none.
M.HOST_BOOT = "bee.placement.native.env:host_boot_id"
function M.host_boot(): string?
    local value = env.get(M.HOST_BOOT)
    if type(value) ~= "string" or value == "" then return nil end
    return value
end
-- No process outlives its boot: a child recorded under an earlier boot ended
-- when the machine restarted, whether or not its runtime owner saw the exit.
function M.host_restart(row: store.Row?): string?
    local recorded = row and bounds.id(row.boot_id) or nil
    local current = M.host_boot()
    if not recorded or not current or recorded == current then return nil end
    return "the machine restarted after the child started; boot " .. recorded .. " is now " .. current
end
local function restarted_exit(attempt: types.Attempt, detail: string): Reply
    M.retire_gateway(attempt, "machine restarted")
    return transition(attempt.attempt_id, {execution = "exited", fields = {exit_source = "reconcile"},
        evidence = {kind = "host.restarted", detail = detail}})
end
local function runner_authority(attempt_id: string): (string?, string?)
    local db, open_error = store.open()
    if not db then return nil, open_error or "open placement store" end
    local token, token_error = store.runner_authority(db, attempt_id, nil)
    db:release()
    return token, token_error
end
-- Retires the gateway bindings an attempt holds at or below its attached
-- carrier epoch; the placement supervision owns this independently of any
-- carrier, and the epoch fence keeps a later carrier's binding alive.
function M.retire_gateway(attempt: types.Attempt, why: string)
    local db = store.open()
    if not db then return end
    local row = store.row(db, attempt.attempt_id)
    local request = row and store.request(row) or nil
    db:release()
    if not request or not request.gateway or attempt.attachment_generation < 1 then return end
    local raw, call_error = funcs.call(resources.GATEWAY_REVOKE_ATTEMPT, {attempt_id = attempt.attempt_id, carrier_epoch = attempt.attachment_generation})
    local detail = why .. "; bindings through carrier epoch " .. tostring(attempt.attachment_generation)
    local reply = not call_error and decode_reply(raw) or nil
    if call_error or not reply or not reply.ok then
        local refused = reply and not reply.ok and reply.error.code or nil
        detail = detail .. " not revoked: " .. tostring(call_error or refused or "invalid reply")
        transition(attempt.attempt_id, {evidence = {kind = "gateway.revoke_failed", detail = detail}})
        return
    end
    transition(attempt.attempt_id, {evidence = {kind = "gateway.revoked", detail = detail}})
end
-- renew_leases extends the leases a live attempt holds: its resource grants,
-- credential projections and gateway binding, each renewed by its authority
-- for the term it was issued with. The first refusal is returned.
function M.renew_leases(row: store.Row, request: types.LaunchRequest): Reply?
    local renewals: {{target: string, input: {[string]: unknown}}} = {}
    if #request.resources > 0 then
        renewals[#renewals + 1] = {target = resources.RENEW, input = {attempt_id = request.attempt_id, subject = request.owner_id, audience = request.owner_id}}
    end
    if #request.projections > 0 then
        renewals[#renewals + 1] = {target = resources.CREDENTIAL_RENEW, input = {attempt_id = request.attempt_id, subject = request.owner_id, audience = request.owner_id}}
    end
    local carrier_epoch = bounds.count(row.attachment_generation)
    if request.gateway and carrier_epoch and carrier_epoch > 0 then
        renewals[#renewals + 1] = {target = resources.GATEWAY_RENEW, input = {attempt_id = request.attempt_id, carrier_epoch = carrier_epoch}}
    end
    for _, renewal in ipairs(renewals) do
        local raw, call_error = funcs.call(renewal.target, renewal.input)
        if call_error then return fail("UNAVAILABLE", renewal.target .. " did not answer: " .. tostring(call_error)) end
        local reply, reply_error = decode_reply(raw)
        if not reply then return fail("UNAVAILABLE", renewal.target .. " returned an invalid reply: " .. tostring(reply_error)) end
        if reply.ok == false then return fail(reply.error.code, renewal.target .. ": " .. reply.error.message) end
    end
    return nil
end
-- Start admission ends when a durable attempt is monitored, before execution.
function M.start_local(value: unknown, runner_ref: string?): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "start request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "gateway_binding"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local gateway_binding: string? = nil
    if object.gateway_binding ~= nil then
        gateway_binding = bounds.id(object.gateway_binding)
        if not gateway_binding then return fail("INVALID", "gateway_binding is not an identifier") end
    end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return assert(denied) end
    if attempt.execution_state ~= "intended" then return succeed(attempt) end
    local host, host_error = resources.runner_host()
    if not host then return fail("STORAGE", host_error or "runner host") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local row = store.row(db, attempt.attempt_id)
    local request = row and store.request(row) or nil
    local issued_authority, authority_error = uuid.v4()
    if authority_error or not issued_authority then db:release(); return fail("INTERNAL", "runner authority") end
    local control_token, control_error = store.runner_authority(db, attempt.attempt_id, issued_authority)
    db:release()
    if not row or not request then return fail("STORAGE", "attempt request unreadable") end
    if not control_token then return fail("STORAGE", control_error or "runner authority unavailable") end
    local materialization_key, authorization_denied = M.authorize_materialization(attempt, row, request, gateway_binding)
    if authorization_denied then return authorization_denied end
    local reply_topic = "bee.placement.start." .. (uuid.v7() or attempt.attempt_id)
    local replies = assert(process.listen(reply_topic, {message = true}))
    local events = assert(process.events())
    local supervisor, spawn_error = process.spawn_monitored("bee.placement.native.service:startup", host,
        attempt.attempt_id, process.pid(), reply_topic, runner_ref or resources.RUNNER, host,
        gateway_binding, materialization_key, control_token, attempt.attachment_generation)
    if not supervisor then
        process.unlisten(replies)
        return fail("UNAVAILABLE", "spawn startup supervisor: " .. tostring(spawn_error))
    end
    local outcome: Reply? = nil
    while not outcome do
        local selected = channel.select({replies:case_receive(), events:case_receive()})
        if not selected.ok then
            outcome = fail("UNAVAILABLE", "start interrupted")
        elseif selected.channel == replies then
            local message = selected.value
            if tostring(message:from()) == tostring(supervisor) then
                local decoded, decode_error = service_reply.decode(message:payload():data())
                if not decoded then outcome = fail("UNAVAILABLE", "startup admission reply: " .. tostring(decode_error))
                elseif not decoded.ok then outcome = fail(assert(decoded.error.code, "startup rejection omitted code"), assert(decoded.error.message, "startup rejection omitted cause"))
                else outcome = succeed(decoded.value) end
            end
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == tostring(supervisor) then
                local result = bounds.object(event.result)
                outcome = fail("UNAVAILABLE", "startup supervisor exited: " .. tostring(result and result.error or event.kind))
            elseif event.kind == process.event.CANCEL then
                local current, load_error = load(attempt.attempt_id)
                if not current then outcome = assert(load_error)
                else
                    local stopped = M.stop_attempt(current, "cooperative")
                    outcome = stopped.ok and fail("UNAVAILABLE", "start cancelled") or stopped
                end
            end
        end
    end
    process.unlisten(replies)
    process.unmonitor(supervisor)
    return outcome
end
function M.start(value: unknown): Reply
    return M.start_local(value, nil)
end
function M.status(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid end
    local attempt, denied, row = load(id)
    if not attempt then return assert(denied) end
    local liveness: types.Liveness = {observed = false, at = store.now(), detail = "runtime owner unavailable"}
    if attempt.execution_state == "exited" then
        liveness = {observed = true, alive = false, at = store.now(), detail = "recorded runtime exit"}
    elseif (attempt.execution_state == "running" or attempt.execution_state == "stopping") and row and row.runner_pid then
        liveness = {observed = true, alive = true, at = tostring(row.updated_at), detail = "last published runtime child state"}
    end
    local private_home: boolean? = nil
    if attempt.session_ref then
        if not row then return fail("STORAGE", "retained placement row is unavailable") end
        local selected, selection_error = store.private_home(row)
        if selected == nil then return fail("STORAGE", selection_error or "read retained placement HOME selection") end
        private_home = selected
    end
    return succeed({attempt = attempt, liveness = liveness, private_home = private_home})
end
function M.activity(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid end
    local attempt, denied = load(id)
    if not attempt then return assert(denied) end
    return fail("UNSUPPORTED_CAPABILITY", "runtime exposes no native descendant activity measurement")
end
function M.stop(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "stop request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "mode"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local mode = bounds.member(object.mode == nil and "cooperative" or object.mode, types.STOP_MODES)
    if not mode then return fail("INVALID", "mode must be cooperative or forced") end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return assert(denied) end
    return M.stop_attempt(attempt, mode)
end
-- stop_attempt is the owner-independent core shared with supervision.
function M.stop_attempt(attempt: types.Attempt, mode: string): Reply
    if attempt.execution_state == "intended" then
        -- Both runners must claim starting before materializing files or
        -- creating a child. Winning that same claim proves there is nothing
        -- to signal or remove and releases the retained session atomically.
        local stopped = transition(attempt.attempt_id, {expected_execution = "intended",
            execution = "exited", cleanup = "complete", evidence = {
                kind = "stop.before_start", detail = "stopped before runner claim; no child or attempt home was created"}})
        if stopped.ok or not stopped.error or stopped.error.code ~= "CONFLICT" then return stopped end
        -- Startup may have won. Use its recorded identity and normal stop
        -- path; never infer that the starting child is absent.
        local current, denied = load(attempt.attempt_id)
        if not current then return assert(denied) end
        attempt = current
    end
    if not transitions.live(attempt.execution_state) then return succeed(attempt) end
    local row = recorded_row(attempt.attempt_id)
    local runner = row and row.runner_pid or nil
    local db = store.open()
    local request = row and store.request(row) or nil
    local control_token: string? = nil
    if db then control_token = store.runner_authority(db, attempt.attempt_id, nil) end
    if db then db:release() end
    local grace = request and request.timeouts.stop_grace_ms or request_codec.DEFAULT_STOP_GRACE_MS
    if attempt.execution_state == "starting" and (not row or row.pid == nil) and (runner == nil or runner == "") then
        -- The supervisor may still be installing its child monitor. Record
        -- stop intent; the runner checks it before materialization is released.
        return transition(attempt.attempt_id, {expected_execution = "starting", execution = "stopping",
            evidence = {kind = "stop.requested", detail = mode .. " before runner monitor installation"}})
    end
    if type(runner) == "string" and runner ~= "" and control_token then
        -- The intent is recorded before the runner acts on it: a runner that
        -- observes the exit at once records exited next, and stopping is the
        -- only state that exit follows from here.
        local requested = transition(attempt.attempt_id, {execution = "stopping", evidence = {kind = "stop.requested", detail = mode .. " through the runner, grace " .. tostring(grace) .. " ms"}})
        if not requested.ok then
            local current = load(attempt.attempt_id)
            if current and not transitions.live(current.execution_state) then return succeed(current) end
            return requested
        end
        local sent, send_error = process.send(runner, protocol.TOPIC_CONTROL, {command = "stop", control_token = control_token, mode = mode, grace_ms = grace})
        if sent then return requested end
        if attempt.execution_state == "starting" and (not row or row.pid == nil) then
            -- The durable stop is also checked by the runner before launch.
            return transition(attempt.attempt_id, {evidence = {kind = "stop.delivery_failed", detail = tostring(send_error) .. "; durable stop remains requested during startup"}})
        end
    end
    local restarted = M.host_restart(row)
    if restarted then return restarted_exit(attempt, restarted) end
    return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "stop.unproven",
        detail = "runtime process owner unavailable; no recoverable native handle"}})

end
-- measure_executable: a read-only measurement of one host path, for the
-- plan and the acceptance record; the runner repeats it before exec.
function M.measure_executable(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "measure_executable request must be an object") end
    local unknown_field = bounds.fields(object, {"path"})
    if unknown_field then return fail("INVALID", unknown_field) end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local measured, err = executable.measure(object.path)
    if not measured then return fail("UNAVAILABLE", err or "measurement failed") end
    return succeed(measured)
end
-- close_stdin: the owner ends a settled session whose harness reads stdin
-- until end of file; the runner closes it and answers, and its evidence
-- records closure apart from input acceptance and exit. Signalling and
-- cleanup stay with stop and cleanup.
function M.close_stdin(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "close_stdin request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return assert(denied) end
    if attempt.execution_state == "exited" then
        return succeed({attempt = attempt, closed = false, reason = "the child has exited"})
    end
    if not transitions.live(attempt.execution_state) then return fail("CONFLICT", "the attempt is not live") end
    local row = recorded_row(attempt.attempt_id)
    local runner = row and row.runner_pid or nil
    if type(runner) ~= "string" or runner == "" then return fail("CONFLICT", "no runner supervises the attempt") end
    local control_token, authority_error = runner_authority(attempt.attempt_id)
    if not control_token then return fail("CONFLICT", authority_error or "runner authority is unavailable") end
    local probe, probe_error = uuid.v4()
    if probe_error or not probe then return fail("INTERNAL", "probe") end
    local expected: protocol.StatusProbe = {runner = runner, attempt_id = attempt.attempt_id, generation = attempt.attachment_generation, probe = probe}
    local replies = assert(process.listen(protocol.TOPIC_STDIN, {message = true}))
    local events = assert(process.events())
    local monitored, monitor_error = process.monitor(runner)
    if not monitored then
        process.unlisten(replies)
        return fail("CONFLICT", "stdin closure cannot monitor runner: " .. tostring(monitor_error))
    end
    local sent, send_error = process.send(runner, protocol.TOPIC_CONTROL, {command = "close_stdin", control_token = control_token, attempt_id = attempt.attempt_id, probe = probe})
    local answer: protocol.StdinReply? = nil
    local failure: string? = nil
    if not sent then failure = "stdin closure send failed: " .. tostring(send_error) end
    local runner_ended = false
    local exit_failure: string? = nil
    while not answer and not failure do
        local selected
        if runner_ended then
            selected = channel.select({replies:case_receive(), default = true})
            if selected.default then break end
        else
            selected = channel.select({replies:case_receive(), events:case_receive()})
        end
        if not selected.ok then failure = "stdin closure observation channel closed"; break end
        if selected.channel == replies then
            local message = selected.value
            answer = protocol.stdin_reply_accepted(tostring(message:from()), message:payload():data(), expected)
        elseif selected.value.kind == process.event.EXIT and tostring(selected.value.from) == runner then
            runner_ended = true
            local result = selected.value.result
            if result and result.error then exit_failure = "runner exited before stdin closure acknowledgement: " .. tostring(result.error) end
        elseif selected.value.kind == process.event.CANCEL then
            failure = "stdin closure observer cancelled before acknowledgement"
        end
    end
    process.unmonitor(runner)
    process.unlisten(replies)
    if not answer then return fail("CONFLICT", failure or exit_failure or "runner exited without a stdin closure acknowledgement") end
    local current, current_error = load(attempt.attempt_id)
    if not current then return assert(current_error) end
    return succeed({attempt = current, closed = answer.closed, reason = answer.reason})
end
-- A runner that answers a typed status request for this attempt is
-- supervising it: that proves supervision and reports what the runner
-- observes, never that the child runs or that its scope is gone.
runner_status = function(row: store.Row?, attempt: types.Attempt): (string?, string?)
    local runner = row and row.runner_pid or nil
    if type(runner) ~= "string" or runner == "" then return nil, nil end
    local control_token = runner_authority(attempt.attempt_id)
    if not control_token then return nil, nil end
    local probe, probe_error = uuid.v4()
    if probe_error or not probe then return nil, nil end
    local expected: protocol.StatusProbe = {runner = runner, attempt_id = attempt.attempt_id, generation = attempt.attachment_generation, probe = probe}
    local replies = assert(process.listen(protocol.TOPIC_STATUS, {message = true}))
    local events = assert(process.events())
    local monitored = process.monitor(runner)
    if not monitored then process.unlisten(replies); return nil, "runtime owner is absent" end
    local sent = process.send(runner, protocol.TOPIC_CONTROL, {command = "status", control_token = control_token, attempt_id = attempt.attempt_id, probe = probe})
    if not sent then process.unmonitor(runner); process.unlisten(replies); return nil, "runtime owner is absent" end
    local detail: string? = nil
    local execution: string? = nil
    while true do
        local selected = channel.select({replies:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL
                or (selected.value.kind == process.event.EXIT and tostring(selected.value.from) == runner) then break end
            goto next_status
        end
        local message = selected.value
        local status = protocol.status_reply_accepted(tostring(message:from()), message:payload():data(), expected)
        if status then
            execution = status.execution
            detail = "runner reports " .. status.execution .. ", generation " .. tostring(status.generation) .. ", eof " .. tostring(status.eof_seen) .. ", pending outputs " .. tostring(status.pending_outputs) .. ", remembered writes " .. tostring(status.remembered_writes)
            break
        end
        ::next_status::
    end
    process.unmonitor(runner)
    process.unlisten(replies)
    return execution, detail
end
function M.runner_present(row: store.Row): (boolean?, string?)
    local runner = bounds.id(row.runner_pid)
    if not runner then return false, nil end
    local monitored, problem = process.monitor(runner)
    if monitored then process.unmonitor(runner); return true, nil end
    if problem and problem:kind() == errors.NOT_FOUND then return false, nil end
    if problem and problem:kind() == errors.ALREADY_EXISTS then return true, nil end
    return nil, tostring(problem or "runtime monitor unavailable")
end
function M.reconcile_attempt(attempt: types.Attempt): Reply
    if attempt.execution_state == "uncertain" then
        local restarted = M.host_restart(recorded_row(attempt.attempt_id))
        if restarted then return restarted_exit(attempt, restarted) end
    end
    if not transitions.live(attempt.execution_state) then return succeed(attempt) end
    local row = recorded_row(attempt.attempt_id)
    if attempt.execution_state == "starting" and row then
        local db = assert(store.open())
        local monitors = assert(db:query("SELECT sequence FROM bee_placement_evidence WHERE attempt_id = ? AND kind IN ('runner.start_accepted', 'runner.monitored') LIMIT 1", {attempt.attempt_id}))
        db:release()
        local present = #monitors > 0 or M.runner_present(row)
        if present == false then
            local recovery_db = assert(store.open())
            local intents = assert(recovery_db:query("SELECT kind FROM bee_placement_evidence WHERE attempt_id = ? AND kind IN ('workdir_preparer.state', 'child.creating')", {attempt.attempt_id}))
            recovery_db:release()
            local prepared, creating = false, false
            for _, item in ipairs(intents) do
                if item.kind == "workdir_preparer.state" then prepared = true end
                if item.kind == "child.creating" then creating = true end
            end
            if prepared and not creating and row.pid == nil and row.pgid == nil then
                M.retire_gateway(attempt, "runtime owner ended before child creation")
                return transition(attempt.attempt_id, {execution = "exited", fields = {exit_source = "runner"},
                    evidence = {kind = "child.not_started", detail = "runtime monitor reports owner absent; preparer persisted without child creation intent"}})
            end
        end
        if present then
            local enforcement = M.supervise_grants(attempt)
            if enforcement then return enforcement end
            return transition(attempt.attempt_id, {evidence = {kind = "reconcile.supervised", detail = "startup outcome belongs to the runtime runner monitor"}})
        end
    end
    local execution, detail = runner_status(row, attempt)
    if execution then
        local enforcement = M.supervise_grants(attempt)
        if enforcement then return enforcement end
        return transition(attempt.attempt_id, {evidence = {kind = "reconcile.supervised", detail = detail or "runtime owner responds"}})
    end
    local restarted = M.host_restart(row)
    if restarted then return restarted_exit(attempt, restarted) end
    M.retire_gateway(attempt, "runtime owner unavailable")
    return transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "reconcile.unobserved",
        detail = "runtime owner unavailable; native handle recovery is unsupported"}})
end
function M.reconcile(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid end
    local attempt, denied = load(id)
    if not attempt then return assert(denied) end
    return M.reconcile_attempt(attempt)
end
-- sweep: placement's own supervision reconciles every live attempt, which
-- bounds how long a revoked grant or projection stays in use.
function M.wake_supervision(kind: unknown)
    assert(demand.wake(kind == "docker" and "bee.placement.docker/image" or M.SWEEPER_NAME))
end
function M.pending(): boolean
    local db, problem = store.open()
    if not db then error(problem or "open placement backlog") end
    local called, pending = pcall(function(): boolean
        return supervision.pending(db, "native")
    end)
    db:release()
    if not called then error(tostring(pending)) end
    return pending == true
end
function M.sweep(): Reply
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local rows, err = supervision.rows(db, "native", M.SWEEP_BOUND)
    if err or not rows then
        db:release()
        return fail("STORAGE", "read live attempts")
    end
    local live: {types.Attempt} = {}
    for _, row in ipairs(rows) do
        local attempt_id = bounds.id(row.attempt_id)
        if not attempt_id then
            db:release()
            return fail("STORAGE", "live attempt identifier is corrupt")
        end
        local attempt, attempt_error = store.attempt(db, attempt_id)
        if attempt_error or not attempt then
            db:release()
            return fail("STORAGE", attempt_error or "live attempt row is corrupt")
        end
        live[#live + 1] = attempt
    end
    db:release()
    local outcomes: {{attempt_id: string, ok: boolean, code: string?}} = {}
    for index, attempt in ipairs(live) do
        local result: Reply
        if attempt.execution_state == "exited" then result = M.cleanup_attempt(attempt, true)
        else
            result = M.supervise_grants(attempt) or transition(attempt.attempt_id, {
                evidence = {kind = "reconcile.supervised", detail = "resource grants checked; child lifecycle belongs to its runtime owner"}})
        end
        outcomes[index] = {attempt_id = attempt.attempt_id, ok = result.ok, code = result.error and result.error.code or nil}
    end
    return succeed({reconciled = #live, outcomes = outcomes})
end
local function completion_observed(attempt: types.Attempt, row: store.Row): (boolean, string)
    if attempt.exit_source == "runner" or attempt.exit_source == "terminal" then
        return true, "exit observed by the runtime handle"
    end
    local restarted = M.host_restart(row)
    if restarted then return true, restarted end
    return false, "runtime exit not observed"
end
-- A live attempt keeps the authority it still holds: its leases are renewed.
-- One whose grant does not resolve is stopped; enforcement stays pending
-- until the exit is proven.
function M.supervise_grants(attempt: types.Attempt): Reply?
    local db = store.open()
    if not db then return nil end
    local row = store.row(db, attempt.attempt_id)
    local request = row and store.request(row) or nil
    db:release()
    if not row or not request then return nil end
    local refused, subject = M.check_grants(row, request)
    if not refused then
        local unrenewed = M.renew_leases(row, request)
        if unrenewed then
            local noted = transition(attempt.attempt_id, {evidence = {kind = "lease.unrenewed", detail = tostring(unrenewed.error and unrenewed.error.code) .. ": " .. tostring(unrenewed.error and unrenewed.error.message)}})
            if not noted.ok then return noted end
        end
        return nil
    end
    local noted = transition(attempt.attempt_id, {evidence = {kind = tostring(subject) .. ".revoked", detail = tostring(refused.error and refused.error.code) .. ": " .. tostring(refused.error and refused.error.message) .. "; stopping, enforcement pending"}})
    if not noted.ok then return noted end
    return M.stop_attempt(attempt, "cooperative")
end
-- A resource epoch advance reports attempts whose grants it fenced. The
-- resource owner alone may call this entry; recheck the recorded launch so
-- a stale or unrelated grant reference cannot stop an attempt.
function M.stop_revoked(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local attempt, read_error = store.attempt(db, id)
    db:release()
    if read_error then return fail("STORAGE", read_error) end
    if not attempt then return fail("NOT_FOUND", "attempt is not recorded") end
    local stopped = M.supervise_grants(attempt)
    if not stopped then return fail("CONFLICT", "attempt has no revoked resource grant") end
    return stopped
end
-- Cleanup follows the runtime owner's completion record.
function M.cleanup(value: unknown): Reply
    local id, invalid = named(value)
    if not id then return invalid end
    local attempt, denied = load(id)
    if not attempt then return assert(denied) end
    return M.cleanup_attempt(attempt)
end
function M.cleanup_attempt(attempt: types.Attempt, preparers_only: boolean?): Reply
    if attempt.cleanup_state == "complete" then return succeed(attempt) end
    if attempt.execution_state ~= "start_failed" and not transitions.may_clean(attempt.execution_state) then return fail("CONFLICT", "cleanup needs a proven exit; execution is " .. attempt.execution_state) end
    local row, row_error = recorded_row(attempt.attempt_id)
    if row_error then return fail("STORAGE", row_error) end
    if not row then return fail("STORAGE", "attempt is not recorded") end
    local proven, why = completion_observed(attempt, row)
    -- Materialization can acknowledge a stop before creating any child. Its
    -- completion and child.not_started record authorize cleanup together.
    if not proven and (attempt.start_cancelled or attempt.exit_source == "runner" or attempt.execution_state == "start_failed")
        and row.pid == nil and row.pgid == nil then
        local db, open_error = store.open()
        if not db then return fail("STORAGE", open_error or "open placement store") end
        local proofs, proof_error = db:query("SELECT sequence FROM bee_placement_evidence WHERE attempt_id = ? AND kind = 'child.not_started' LIMIT 1", {attempt.attempt_id})
        db:release()
        if proof_error then return fail("STORAGE", "read child creation evidence") end
        if proofs and #proofs == 1 then
            proven, why = true, "the runner recorded completion before creating a child"
        end
    end
    if not proven then
        -- A refusal is durable evidence: a continuation that waits on this
        -- cleanup reads its reason from the previous attempt's ledger.
        local message = "cleanup requires runtime completion: " .. why
        local noted = transition(attempt.attempt_id, {evidence = {kind = "cleanup.refused", detail = message}})
        if not noted.ok then return noted end
        return fail("CONFLICT", message)
    end
    local preparers_ok, preparers_err = workdir_preparers.cleanup(attempt)
    if preparers_only then
        if not preparers_ok then return fail("UNAVAILABLE", preparers_err or "workdir cleanup failed") end
        return transition(attempt.attempt_id, {evidence = {kind = "workdir_preparers.settled", detail = "all planned preparers cleaned or retained"}})
    end
    local home_key = row.home_key
    local remove_error: string? = nil
    if type(home_key) == "string" and home_key ~= "" then remove_error = homes.remove_attempt(home_key) end
    if not preparers_ok or remove_error then
        local message = preparers_err and remove_error and (preparers_err .. "; " .. remove_error) or preparers_err or remove_error or "workdir cleanup failed"
        local noted = transition(attempt.attempt_id, {cleanup = "uncertain", evidence = {kind = "cleanup.failed", detail = message}})
        if not noted.ok then return noted end
        return fail("UNAVAILABLE", message)
    end
    return transition(attempt.attempt_id, {cleanup = "complete", evidence = {kind = "cleanup.complete", detail = (home_key and "attempt home removed" or "no attempt home was created") .. "; " .. why}})
end
function M.evidence(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "evidence request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "after", "limit"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return assert(denied) end
    local after = bounds.integer(object.after == nil and 0 or object.after)
    if not after or after < 0 then return fail("INVALID", "after must be a nonnegative integer") end
    local limit = bounds.integer(object.limit == nil and store.MAX_EVIDENCE_PAGE or object.limit)
    if not limit then return fail("INVALID", "limit must be an integer") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local page, page_error = store.evidence(db, attempt.attempt_id, after, limit)
    db:release()
    if not page then return fail("STORAGE", page_error or "read evidence") end
    return succeed(page)
end
-- attach: bind the recipient under a generation the owner supplies (its
-- carrier epoch); a generation at or below the current one is a stale
-- carrier and is refused. The runner resends what the previous recipient
-- never acknowledged.
function M.attach(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "attach request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "recipient", "generation"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local recipient = bounds.text(object.recipient, 256)
    if not recipient or recipient == "" then return fail("INVALID", "recipient must be a process address") end
    local generation = bounds.integer(object.generation)
    if not generation or generation < 1 then return fail("INVALID", "generation must be a positive integer") end
    local attempt, denied = load(object.attempt_id)
    if not attempt then return assert(denied) end
    -- A runner outlives an exited child while it holds unacknowledged
    -- output or an unanswered write, so an exited attempt is attachable
    -- exactly as long as its runner still answers the fence.
    local exited = attempt.execution_state == "exited"
    if not transitions.live(attempt.execution_state) and attempt.execution_state ~= "intended" and not exited then return fail("CONFLICT", "the attempt is not live") end
    if generation <= attempt.attachment_generation then return fail("CONFLICT", "generation " .. tostring(generation) .. " is not newer than " .. tostring(attempt.attachment_generation)) end
    local row = recorded_row(attempt.attempt_id)
    local runner = row and row.runner_pid or nil
    local previous_recipient: unknown = sql.NULL
    if row and type(row.recipient) == "string" then previous_recipient = row.recipient end
    if exited and (type(runner) ~= "string" or runner == "") then return fail("CONFLICT", "the attempt has exited and its runner is gone") end
    local control_token: string? = nil
    if type(runner) == "string" and runner ~= "" then
        local authority_error: string?
        control_token, authority_error = runner_authority(attempt.attempt_id)
        if not control_token then return fail("CONFLICT", authority_error or "runner authority is unavailable") end
        -- Startup is supervised and unbounded. The fence protocol begins
        -- only once the runner can receive controls after materialization.
        local changes = assert(cdc.stream("bee:changes", {tables = {"bee_placement_attempts"}, ops = {"update"}}))
        local updates = changes:channel()
        local events = assert(process.events())
        local monitored, monitor_error = process.monitor(runner)
        if not monitored then changes:close(); return fail("CONFLICT", "attachment cannot monitor runner: " .. tostring(monitor_error)) end
        local current, current_error = load(attempt.attempt_id)
        local awaiting_start = current ~= nil and current.execution_state == "starting"
        local failure: string? = nil
        while awaiting_start do
            local selected = channel.select({updates:case_receive(), events:case_receive()})
            if not selected.ok then failure = "attachment startup observation closed"; break end
            if selected.channel == events and selected.value.kind == process.event.EXIT and tostring(selected.value.from) == runner then
                failure = "runner exited before attachment startup completed"
                break
            elseif selected.channel == events and selected.value.kind == process.event.CANCEL then
                failure = "attachment startup observer cancelled"
                break
            end
            current, current_error = load(attempt.attempt_id)
            awaiting_start = current ~= nil and current.execution_state == "starting"
        end
        process.unmonitor(runner)
        changes:close()
        if failure then return fail("CONFLICT", failure) end
        if not current then return assert(current_error) end
        if not transitions.live(current.execution_state) and current.execution_state ~= "exited" then
            return fail("CONFLICT", "the attempt is not live after startup")
        end
        if generation <= current.attachment_generation then return fail("CONFLICT", "attachment generation changed during startup") end
        attempt = current
    end
    local result = transition(attempt.attempt_id, {fields = {attachment_generation = generation, recipient = recipient}, evidence = {kind = "attach", detail = "generation " .. tostring(generation)}})
    if not result.ok then return result end
    if type(runner) == "string" and runner ~= "" then
        -- Success requires the runner's fence reply after its installation
        -- evidence commits. A deadline records uncertainty and refuses attach;
        -- it cannot acknowledge replacement of the execution-channel recipient.
        local fences = assert(process.listen(protocol.TOPIC_FENCED, {message = true}))
        process.send(runner, protocol.TOPIC_CONTROL, {command = "attach", control_token = control_token, recipient = recipient, generation = generation})
        local timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")
        local fenced = false
        local answered = false
        local refused = false
        local refusal_reason: string? = nil
        while not answered do
            local selected = channel.select({fences:case_receive(), timer:case_receive()})
            if not selected.ok or selected.channel == timer then
                answered = true
            else
                local message = selected.value
                local data: unknown = message:payload():data()
                if tostring(message:from()) == runner and type(data) == "table" and data.attempt_id == attempt.attempt_id and data.generation == generation then
                    answered = true
                    fenced = data.fenced == true
                    refused = data.refused == true
                    if type(data.reason) == "string" then refusal_reason = data.reason end
                end
            end
        end
        process.unlisten(fences)
        if refused then
            local restored = transition(attempt.attempt_id, {fields = {attachment_generation = attempt.attachment_generation, recipient = previous_recipient},
                evidence = {kind = "attach.refused", detail = "runner refused generation " .. tostring(generation) .. ": " .. (refusal_reason or "recipient is not monitorable")}})
            if not restored.ok then return restored end
            return fail("CONFLICT", "runner refused attachment: " .. (refusal_reason or "recipient is not monitorable"))
        end
        if not fenced then
            if exited then
                transition(attempt.attempt_id, {evidence = {kind = "attach.unanswered", detail = "runner gone after exit; generation " .. tostring(generation) .. " has nothing to attach to"}})
                return fail("CONFLICT", "the attempt has exited and its runner is gone")
            end
            local uncertain = transition(attempt.attempt_id, {execution = "uncertain", evidence = {kind = "attach.unfenced", detail = "runner did not acknowledge generation " .. tostring(generation) .. " within " .. tostring(protocol.FENCE_TIMEOUT_MS) .. " ms"}})
            if not uncertain.ok then return uncertain end
            return fail("UNAVAILABLE", "runner did not acknowledge attachment generation " .. tostring(generation))
        end
        local attached, read_error = load(attempt.attempt_id)
        if not attached then return assert(read_error) end
        return succeed(attached)
    end
    return result
end
-- What this placement is: its measured capability, its interim authority
-- limits and its bounds. Roots are host policy, grants are correlation
-- data, and no credential broker exists yet.
function M.capabilities(): Reply
    local measured = capability.measure()
    local mode, mode_error, mode_code = resources.resource_mode()
    if not mode then return fail(mode_code or "UNAVAILABLE", "resource mode is unavailable: " .. tostring(mode_error)) end
    local measurement = executable.capabilities()
    return succeed({capability = measured.capability, exit_observation = measured.exit_observation, stdin_close = measured.stdin_close, detail = measured.detail,
        executable_measurement = {streaming = measurement.streaming, read_only_volume = measurement.read_only_volume, detail = measurement.detail},
        resource_authority = mode, delegated_resource_grants = mode == "granted",
        revocation_enforcement = {mode = "stop_on_reconcile", scheduling_delay_ms = M.SWEEP_INTERVAL_MS, reconcile_timeout_ms = M.RECONCILE_TIMEOUT_MS, stop_grace_ms = "per attempt", sweep_bound = M.SWEEP_BOUND},
        credential_broker = true, credential_projections = {"environment", "file"}, max_chunk_bytes = protocol.MAX_CHUNK_BYTES,
        gateway = {materialization = "placement_authorized_key", token_projection = "environment", takeover_grace_ms = protocol.TAKEOVER_GRACE_MS, seal_on = {"child_exit"}, revocation_on = {"refused_start", "carrier_loss_without_takeover", "reconcile_end", "carrier_close"},
            hook_events = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"}, shutdown_events_not_admitted = {"SessionEnd", "StopFailure"}},
        max_write_bytes = protocol.MAX_WRITE_BYTES, max_outstanding_chunks = protocol.MAX_OUTSTANDING_CHUNKS, max_spool_bytes = protocol.MAX_SPOOL_BYTES,
        max_evidence_page = store.MAX_EVIDENCE_PAGE, canonical = canonical.encode({capability = measured.capability})})
end
return M
