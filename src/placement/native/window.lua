-- MIT. Process-local native PTY ownership for a managed window.
--
-- This module is intentionally a library rather than a process entry. The
-- broker must spawn its caller with the terminal grant; attach_terminal()
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

type Options = {width: integer, height: integer, term: string, expected_binding: string?}
type Window = {
    send: (Window, tty.TTYEvent) -> (boolean, string?),
    done: (Window) -> exec.TerminalCompletionChannel,
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
        if key ~= "width" and key ~= "height" and key ~= "term" and key ~= "expected_binding" then
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
    return {width = width, height = height, term = term, expected_binding = expected_binding :: string?}, nil
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

    local executor, executor_error = exec.get(resources.EXECUTOR)
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
    for _, argument in ipairs(request.launch.argv) do argv[#argv + 1] = argument end
    local child, exec_error = executor:exec(quote.line(argv), {work_dir = prepared.working_directory, env = prepared.environment,
        pty = {width = chosen.width, height = chosen.height, term = chosen.term}, process_group = row.capability == "process_group"})
    if not child then
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "child.refused", detail = "executor refused the PTY command"}})
        executor:release()
        return fail(db, "executor refused the PTY command", gateway_binding, attempt_id)
    end

    -- attach_terminal consumes the unstarted process and transfers its
    -- lifecycle to the terminal session. It must run in this actor, where
    -- the broker-installed terminal grant is present.
    local terminal, attach_error = child:attach_terminal()
    if not terminal then
        child:close(true)
        store.transition(db, attempt_id, {execution = "exited", evidence = {kind = "child.attach_failed", detail = tostring(attach_error)}})
        executor:release()
        return fail(db, "attach terminal: " .. tostring(attach_error), gateway_binding, attempt_id)
    end

    local running = store.transition(db, attempt_id, {execution = "running", evidence = {kind = "child.attached", detail = "managed PTY attached to the broker terminal grant"}})
    if not running.ok then
        terminal:close()
        executor:release()
        return fail(db, running.message or "record PTY start", gateway_binding, attempt_id)
    end

    local closed = false
    local finished = false
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
        local state, status_error = terminal:status()
        if state ~= "done" then return false, "terminal is still running" end
        finished = true
        local detail = "terminal session completed; exit status unavailable"
        if status_error then detail = detail .. ": " .. tostring(status_error) end
        local ended = store.transition(db, attempt_id, {execution = "exited", fields = {exit_source = "terminal"}, evidence = {kind = "child.exited", detail = detail}})
        if not ended.ok then
            finished = false
            return false, ended.message or "record terminal exit"
        end
        retire_gateway("terminal session completed")
        executor:release()
        db:release()
        return true, nil
    end
    local facade: Window = {
        send = function(_, event: tty.TTYEvent): (boolean, string?)
            local ok, send_error = terminal:send(event)
            return ok, error_text(send_error)
        end,
        done = function(_): exec.TerminalCompletionChannel
            return terminal:done()
        end,
        status = function(_): ("running" | "done", string?)
            local state: "running" | "done", status_error = terminal:status()
            return state, error_text(status_error)
        end,
        close = function(_): (boolean, string?)
            if closed then return true, nil end
            local ok, close_error = terminal:close()
            if ok then closed = true end
            return ok, error_text(close_error)
        end,
        finish = finish,
    }
    return facade, nil
end

return M
