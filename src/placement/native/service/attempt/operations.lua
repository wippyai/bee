-- MIT. Native placement operations on a recorded attempt: status, activity, session forget, executable measurement, stdin close, evidence and attach.
local process = require("process")
local seam = require("seam")
local channel = require("channel")
local sql = require("sql")
local cdc = require("cdc")
local uuid = require("uuid")
local bounds = require("bounds")
local types = require("types")
local transitions = require("transitions")
local store = require("store")
local executable = require("executable")
local homes = require("homes")
local protocol = require("protocol")
local materialization = require("materialization")
local part_preparation = require("part_preparation")
type Reply = part_preparation.Reply
local fail = part_preparation.fail
local succeed = part_preparation.succeed
local actor = part_preparation.actor
local transition = part_preparation.transition
local attempt_access = require("attempt_access")
local load = attempt_access.load
local named = attempt_access.named
local recorded_row = attempt_access.recorded_row
local runner_authority = attempt_access.runner_authority
local M = {}
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
-- forget_session removes the files placement materialized into a removed
-- session's home and their records. Everything else in the home, such as the
-- agent's own conversation files, stays where the agent wrote it.
function M.forget_session(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"session", "thread_id", "owner_id", "history"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local owner_id, session_ref = bounds.id(object.owner_id), bounds.id(object.session)
    if not owner_id or not session_ref then return fail("INVALID", "owner_id and session must be identifiers") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if caller ~= owner_id then return fail("FORBIDDEN", "the session belongs to another owner") end
    local session_key, key_error = homes.session_key(owner_id, session_ref)
    if not session_key then return fail("INTERNAL", key_error or "derive session home") end
    local db, open_error = store.open()
    if not db then return fail("STORAGE", open_error or "open placement store") end
    local held, held_error = store.session_held(db, owner_id, session_ref)
    if held == nil then db:release(); return fail("STORAGE", held_error or "read session holders") end
    if held then db:release(); return fail("CONFLICT", "an unfinished attempt still holds the session home") end
    local paths, paths_error = store.session_files(db, owner_id, session_ref)
    if not paths then db:release(); return fail("STORAGE", paths_error or "read session files") end
    for _, path in ipairs(paths) do
        local remove_error = homes.remove_session_file(session_key, path)
        if remove_error then db:release(); return fail("STORAGE", remove_error) end
        local forget_error = store.forget_session_file(db, owner_id, session_ref, path)
        if forget_error then db:release(); return fail("STORAGE", forget_error) end
    end
    db:release()
    return succeed({session = session_ref, files = #paths})
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
        local updates, updates_error = changes:channel()
        if not updates then changes:close(); return fail("UNAVAILABLE", "attachment cannot follow the attempt: " .. tostring(updates_error)) end
        local events = assert(process.events())
        local monitored, monitor_error = process.monitor(runner)
        if not monitored then changes:close(); return fail("CONFLICT", "attachment cannot monitor runner: " .. tostring(monitor_error)) end
        local current, current_error = load(attempt.attempt_id)
        local awaiting_start = current ~= nil and current.execution_state == "starting"
        local failure: string? = nil
        if awaiting_start then seam.call("bee.placement.native.service.service.attach_startup", {attempt_id = attempt.attempt_id}) end
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
        local timer = seam.after("bee.placement.native.service.service.fence_timer", tostring(protocol.FENCE_TIMEOUT_MS) .. "ms", {attempt_id = attempt.attempt_id})
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
return M
