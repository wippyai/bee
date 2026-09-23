-- MIT. Process-local native PTY ownership for a managed window.
--
-- This module is intentionally a library rather than a process entry. The
-- broker must spawn its caller with the terminal grant; executor:terminal()
-- consumes the current actor's grant and cannot be performed through a
-- funcs.call boundary. The caller keeps the application lifecycle loop and
-- uses this value only as a process-local facade.
local exec = require("exec")
local tty = require("tty")
local process = require("process")
local security = require("security")
local bounds = require("bounds")
local store = require("store")
local resources = require("resources")
local materialization = require("materialization")
local executable = require("executable")
local quote = require("quote")
local funcs = require("funcs")
local service = require("service")
local protocol = require("protocol")
local identity = require("identity")

type Options = {width: integer, height: integer, term: string, expected_binding: string?, expected_placement_binding: string?, generation: integer?}
type Window = {
    send: (Window, tty.TTYEvent) -> (boolean, string?),
    done: (Window) -> exec.TerminalResultChannel,
    status: (Window) -> ("running" | "done", string?),
    close: (Window) -> (boolean, string?),
    finish: (Window) -> (boolean, string?),
}

local M = {}
local MAX_WIDTH = 1000
local MAX_HEIGHT = 500

local function actor_id(): string?
    local actor = security.actor()
    if not actor then return nil end
    local id: unknown = actor:id()
    if type(id) ~= "string" then return nil end
    local bounded = bounds.id(id)
    if type(bounded) ~= "string" then return nil end
    return bounded :: string
end

local function error_text(value: unknown): string?
    if value == nil then return nil end
    return tostring(value)
end

local function fail(db, reason: string, gateway_binding: string?, attempt_id: string?): (Window?, string?)
    if gateway_binding then
        -- A gateway binding may have been minted before a later PTY step
        -- failed. Revoke it here; bytes never enter this facade's return
        -- value or a durable record.
        local raw, revoke_error = funcs.call(resources.GATEWAY_REVOKE, {binding_id = gateway_binding})
        local reply = type(raw) == "table" and raw :: {[string]: unknown} or nil
        if revoke_error or not reply or reply.ok ~= true then
            if attempt_id then
                store.transition(db, attempt_id, {evidence = {kind = "gateway.revoke_failed", detail = "window open failed: " .. tostring(revoke_error or "gateway refused revoke")}})
            end
        elseif attempt_id then
            store.transition(db, attempt_id, {evidence = {kind = "gateway.revoked", detail = "window open failed; binding revoked"}})
        end
    end
    if db then db:release() end
    return nil, reason
end

local function options(value: unknown): (Options?, string?)
    if type(value) ~= "table" then return nil, "window options must be an object" end
    local object = value :: {[string]: unknown}
    for key in pairs(object) do
        if key ~= "width" and key ~= "height" and key ~= "term" and key ~= "expected_binding" and key ~= "expected_placement_binding" and key ~= "generation" then
            return nil, "unknown window option " .. tostring(key)
        end
    end
    if type(object.width) ~= "number" or type(object.height) ~= "number" or type(object.term) ~= "string" then
        return nil, "window options require width, height and term"
    end
    local width_value: unknown = bounds.integer(object.width)
    local height_value: unknown = bounds.integer(object.height)
    if type(width_value) ~= "number" or type(height_value) ~= "number" then return nil, "window dimensions must be integers" end
    local width, height = math.floor(width_value :: number), math.floor(height_value :: number)
    local term = object.term :: string
    if width < 1 or width > MAX_WIDTH or height < 1 or height > MAX_HEIGHT then return nil, "window dimensions are out of bounds" end
    if term == "" or #term > 64 or term:find("[%z%c]", 1) then return nil, "window term is invalid" end
    local expected_binding = object.expected_binding
    if expected_binding ~= nil and not bounds.id(expected_binding) then return nil, "expected_binding is invalid" end
    local expected_placement_binding = object.expected_placement_binding
    if expected_placement_binding ~= nil and not bounds.id(expected_placement_binding) then return nil, "expected_placement_binding is invalid" end
    local generation = bounds.integer(object.generation)
    if object.generation ~= nil and (not generation or generation < 1) then return nil, "generation is invalid" end
    return {generation = generation, width = width, height = height, term = term, expected_binding = expected_binding :: string?, expected_placement_binding = expected_placement_binding :: string?}, nil
end

-- Open is the only constructor. It derives the caller from the authenticated
-- actor and performs the intended-to-start compare-and-set before materializing
-- anything or creating a child. The returned value contains only process-local
-- native handles and lifecycle methods.
function M.open(attempt_id: string, value: unknown): (Window?, string?)
    local owner = actor_id()
    if not owner then return nil, "no authenticated actor" end
    local bounded_attempt_id = bounds.id(attempt_id)
    if type(bounded_attempt_id) ~= "string" then return nil, "attempt_id is invalid" end
    attempt_id = bounded_attempt_id :: string
    local chosen, option_error = options(value)
    if not chosen then return nil, option_error end

    local db, open_error = store.open()
    if not db then return nil, open_error or "open placement store" end
    local row, row_error = store.row(db, attempt_id)
    if not row then return fail(db, row_error or "attempt is not recorded", nil) end
    if row.owner_id ~= owner then return fail(db, "attempt is owned by another actor", nil) end
    local request, request_error = store.request(row)
    if not request then return fail(db, request_error or "attempt request is unreadable", nil) end
    if request.owner_id ~= owner or request.attempt_id ~= attempt_id then return fail(db, "attempt owner does not match its request", nil) end
    if chosen.expected_placement_binding and request.placement_binding_ref ~= chosen.expected_placement_binding then
        return fail(db, "attempt uses another placement binding", nil)
    end
    if request.placement_binding_ref and request.placement_binding_ref ~= "bee.placement.native:binding" then
        return fail(db, "native window cannot use a non-native placement binding", nil)
    end
    if chosen.generation and (row.attachment_generation ~= chosen.generation or row.recipient ~= process.pid()) then
        return fail(db, "window attachment generation is not admitted", nil)
    end
    if row.execution_state ~= "intended" then return fail(db, "attempt is already in use or has settled", nil) end

    local starting = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting", fields = {runner_pid = process.pid()}, evidence = {kind = "window.started", detail = "managed window owner " .. process.pid()}})
    if not starting.ok then return fail(db, starting.message or "attempt is no longer intended", nil) end

    local attempt = store.attempt(db, attempt_id)
    if not attempt then return fail(db, "attempt is not recorded", nil) end
    local authorized_key, authorization_error = service.authorize_materialization(attempt, row, request, chosen.expected_binding)
    if authorization_error then
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "window.authorization_failed", detail = tostring(authorization_error.error and authorization_error.error.message or "launch authorization failed")}})
        return fail(db, authorization_error.error and authorization_error.error.message or "launch authorization failed", nil)
    end

    local generation = type(row.attachment_generation) == "number" and math.floor(row.attachment_generation :: number) or 0
    local prepared, preparation_error, gateway_binding = materialization.prepare(db, request, attempt_id, generation, chosen.expected_binding, authorized_key)
    if not prepared then
        -- Materialization records its own terminal evidence. Keep the gateway
        -- identity long enough for fail() to revoke it if needed.
        return fail(db, preparation_error or "attempt materialization", gateway_binding, attempt_id)
    end

    local executor_ref, reference_error = resources.executor()
    local executor, executor_error
    if executor_ref then executor, executor_error = exec.get(executor_ref) else executor_error = reference_error end
    if not executor then
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "executor.failed", detail = tostring(executor_error)}})
        return fail(db, "executor unavailable", gateway_binding, attempt_id)
    end
    if request.executable then
        local verified, verify_error = executable.verify(request.launch.executable, request.executable)
        if not verified then
            store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "executable.changed", detail = tostring(verify_error)}})
            executor:release()
            return fail(db, verify_error or "executable changed", gateway_binding, attempt_id)
        end
        store.transition(db, attempt_id, {evidence = {kind = "executable.measured", detail = verified.revision .. " " .. verified.kind .. " digest " .. verified.digest}})
    end

    local argv: {string} = {request.launch.executable}
    for _, argument in ipairs(prepared.arguments) do argv[#argv + 1] = argument end

    local closed = false
    local finished = false
    -- The handle exists only once executor:terminal() has returned. Until
    -- then the listener answers supervision as starting and leaves a stop to
    -- the committed row, which the startup settlement below reads.
    local terminal: exec.TerminalProcess? = nil
    local controls = process.listen(protocol.TOPIC_CONTROL, {message = true})
    if not controls then
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "child.not_started", detail = "window control listener unavailable before child creation"}})
        executor:release()
        return fail(db, "window control listener unavailable", gateway_binding, attempt_id)
    end
    -- The PTY owner is the recorded runner. Answer the same supervision probe
    -- as a streamed runner, without consuming the application's done channel.
    -- A stop message alone carries no authority: the placement service must
    -- have committed stopping for this exact attempt first.
    coroutine.spawn(function()
        while not finished do
            local message, ok = controls:receive()
            if not ok or finished then return end
            local raw: unknown = message:payload():data()
            if type(raw) == "table" then
                local data = raw :: {[string]: unknown}
                local current_terminal = terminal
                if data.command == "status" and data.attempt_id == attempt_id and bounds.id(data.probe) then
                    local current = store.row(db, attempt_id)
                    local execution: "starting" | "running" | "stopping" | "exited" = "running"
                    if not current_terminal or (current and current.execution_state == "starting") then
                        execution = "starting"
                    elseif current_terminal:status() == "done" then
                        execution = "exited"
                    elseif closed then
                        execution = "stopping"
                    end
                    process.send(tostring(message:from()), protocol.TOPIC_STATUS, {
                        attempt_id = attempt_id, generation = generation, probe = data.probe,
                        execution = execution,
                        eof_seen = 0, pending_outputs = 0, remembered_writes = 0, truncated = false,
                    })
                elseif data.command == "stop" and current_terminal then
                    local current = store.row(db, attempt_id)
                    if current and current.owner_id == owner and current.runner_pid == process.pid()
                        and current.execution_state == "stopping" then
                        local stopped = current_terminal:close()
                        if stopped then closed = true end
                    end
                end
            end
        end
    end)

    -- executor:terminal() consumes the broker-installed terminal grant of this
    -- actor and returns only after the child has started, so the handle
    -- carries the host process identity from its first use.
    local started, start_error = executor:terminal(quote.line(argv), {work_dir = prepared.working_directory, env = prepared.environment,
        pty = {width = chosen.width, height = chosen.height, term = chosen.term}, process_group = row.capability == "process_group"})
    if not started then
        finished = true
        process.unlisten(controls)
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "child.refused", detail = "executor refused the PTY command: " .. tostring(start_error)}})
        executor:release()
        return fail(db, "start terminal: " .. tostring(start_error), gateway_binding, attempt_id)
    end
    terminal = started

    local fields: {[string]: unknown} = {}
    local identity_detail = "execution identity unavailable"
    local pid, pid_error = started:pid()
    if pid then
        local found, read_error = identity.read(executor, pid)
        if found then
            fields.pid = found.pid
            if found.pgid then fields.pgid = found.pgid end
            if found.start_ticks then fields.start_ticks = found.start_ticks end
            if found.boot_id then fields.boot_id = found.boot_id end
            identity_detail = "pid " .. tostring(found.pid) .. " pgid " .. tostring(found.pgid)
                .. " start_ticks " .. tostring(found.start_ticks) .. " boot_id " .. tostring(found.boot_id)
        else
            identity_detail = "execution identity unavailable: " .. tostring(read_error or "identity read failed")
        end
    elseif pid_error then
        identity_detail = "execution identity unavailable: " .. tostring(pid_error)
    end
    local function fields_with_exit(): {[string]: unknown}
        local exited: {[string]: unknown} = {}
        for name, value in pairs(fields) do exited[name] = value end
        exited.exit_source = "terminal"
        return exited
    end

    -- Leaving starting is one compare-and-set. A child that already ended
    -- records its exit; otherwise readiness is published. When the set loses,
    -- a stop committed while the child was starting or its identity was being
    -- read wins: request close and preserve the stopping state until
    -- terminal:status() observes done; terminal completion does not prove
    -- that a process group is absent.
    local settled
    local startup_exit = started:status() == "done"
    if startup_exit then
        settled = store.transition(db, attempt_id, {expected_execution = "starting", execution = "exited", fields = fields_with_exit(), evidence = {kind = "child.exited", detail = "terminal completed during startup; " .. identity_detail}})
    else
        settled = store.transition(db, attempt_id, {expected_execution = "starting", execution = "running", fields = fields, evidence = {kind = "child.attached", detail = "managed PTY attached to the broker terminal grant; " .. identity_detail}})
    end
    if not settled.ok then
        finished = true
        process.unlisten(controls)
        started:close()
        local current = store.row(db, attempt_id)
        if not current or current.execution_state ~= "stopping" then
            executor:release()
            return fail(db, settled.message or "record terminal start", gateway_binding, attempt_id)
        end
        local stopped
        if started:status() == "done" then
            stopped = store.transition(db, attempt_id, {expected_execution = "stopping", execution = "exited", fields = fields_with_exit(), evidence = {kind = "child.exited", detail = "terminal completed during startup stop; " .. identity_detail}})
        else
            stopped = store.transition(db, attempt_id, {expected_execution = "stopping", fields = fields, evidence = {kind = "stop.pending", detail = "terminal close requested during startup; " .. identity_detail}})
        end
        executor:release()
        if not stopped.ok then return fail(db, stopped.message or "record terminal stop", gateway_binding, attempt_id) end
        return fail(db, "window stopped during startup", gateway_binding, attempt_id)
    end
    if startup_exit then
        finished = true
        process.unlisten(controls)
        executor:release()
        return fail(db, "terminal completed during startup", gateway_binding, attempt_id)
    end

    local function retire_gateway(why: string)
        if not gateway_binding then return end
        local binding = gateway_binding
        gateway_binding = nil
        local raw, revoke_error = funcs.call(resources.GATEWAY_REVOKE, {binding_id = binding})
        local reply = type(raw) == "table" and raw :: {[string]: unknown} or nil
        if revoke_error or not reply or reply.ok ~= true then
            store.transition(db, attempt_id, {evidence = {kind = "gateway.revoke_failed", detail = why .. ": " .. tostring(revoke_error or "gateway refused revoke")}})
        else
            store.transition(db, attempt_id, {evidence = {kind = "gateway.revoked", detail = why .. ": binding " .. binding}})
        end
    end
    local function finish(self: Window): (boolean, string?)
        if finished then return true, nil end
        local state, status_error = started:status()
        if state ~= "done" then return false, "terminal is still running" end
        finished = true
        local detail = "terminal process completed; exit status unavailable"
        if status_error then detail = detail .. ": " .. tostring(status_error) end
        local ended = store.transition(db, attempt_id, {execution = "exited", fields = {exit_source = "terminal"}, evidence = {kind = "child.exited", detail = detail}})
        if not ended.ok then
            finished = false
            return false, ended.message or "record terminal exit"
        end
        process.unlisten(controls)
        retire_gateway("terminal process completed")
        executor:release()
        db:release()
        return true, nil
    end
    local facade: Window = {
        send = function(_, event: tty.TTYEvent): (boolean, string?)
            local ok, send_error = started:send(event)
            return ok, error_text(send_error)
        end,
        done = function(_): exec.TerminalResultChannel
            return started:done()
        end,
        status = function(_): ("running" | "done", string?)
            local state: "running" | "done", status_error = started:status()
            return state, error_text(status_error)
        end,
        close = function(_): (boolean, string?)
            if closed then return true, nil end
            local ok, close_error = started:close()
            if ok then closed = true end
            return ok, error_text(close_error)
        end,
        finish = finish,
    }
    return facade, nil
end

return M
