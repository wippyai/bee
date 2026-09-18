-- SPDX-License-Identifier: MIT
-- The actual app actor attaches the existing container to its broker terminal
-- grant. The placement service owns creation, stop, exit evidence and cleanup.
local funcs = require("funcs")
local process = require("process")
local docker = require("docker_pty")
local exec = require("exec")
local tty = require("tty")
local bounds = require("bounds")
local M = {}
local BINDING = "bee.placement.docker:binding"
type Object = {[string]: unknown}
type Window = {
    send: (Window, tty.TTYEvent) -> (boolean, string?),
    done: (Window) -> exec.TerminalCompletionChannel,
    status: (Window) -> ("running" | "done", string?),
    close: (Window) -> (boolean, string?),
    finish: (Window) -> (boolean, string?),
}
local function call(method: string, request: unknown): (Object?, string?)
    local raw, err = funcs.call("bee.placement.docker:" .. method, request)
    if err then return nil, tostring(err) end
    local reply = bounds.object(raw)
    if not reply then return nil, "Docker placement returned no reply" end
    if reply.ok ~= true then
        local fault = bounds.object(reply.error) or {}
        return nil, tostring(fault.code or "UNAVAILABLE") .. ": " .. tostring(fault.message or "Docker placement refused")
    end
    local value = bounds.object(reply.value)
    if not value then return nil, "Docker placement returned an invalid value" end
    return value, nil
end
local function error_text(value: unknown): string?
    if value == nil then return nil end
    return tostring(value)
end
function M.open(attempt_id: string, value: unknown): (Window?, string?)
    if not bounds.id(attempt_id) then return nil, "attempt_id is invalid" end
    local options = bounds.object(value)
    if not options then return nil, "Docker window options must be an object" end
    local extra = bounds.fields(options, {"width", "height", "term", "expected_binding", "expected_placement_binding", "generation"})
    if extra then return nil, extra end
    if options.expected_placement_binding ~= BINDING then return nil, "Docker window requires its admitted placement binding" end
    local width, height, generation = bounds.integer(options.width), bounds.integer(options.height), bounds.integer(options.generation)
    local term = bounds.text(options.term, 64)
    if not width or width < 1 or width > 1000 or not height or height < 1 or height > 500
        or not generation or generation < 1 or not term or term == "" or term:find("%c") then
        return nil, "Docker window geometry or generation is invalid"
    end
    local gateway = options.expected_binding
    if gateway ~= nil and not bounds.id(gateway) then return nil, "gateway binding is invalid" end
    local started, start_error = call("start", {attempt_id = attempt_id, gateway_binding = gateway})
    if not started then return nil, start_error end
    if started.attempt_id ~= attempt_id or started.execution_state ~= "running" then return nil, "Docker placement did not confirm a running attempt" end
    local identity, identity_error = call("container_identity", {attempt_id = attempt_id, recipient = process.pid(), generation = generation})
    if not identity then return nil, identity_error end
    -- The native attachment boundary validates the exact identity and checks
    -- docker.attach under this app's actor and host-selected permission scope.
    local container_id, image_id, started_at = bounds.text(identity.container_id, 64), bounds.text(identity.image_id, 71), bounds.text(identity.started_at, 64)
    local raw_labels = bounds.object(identity.labels)
    if not container_id or not image_id or not started_at or not raw_labels then return nil, "Docker attachment identity is incomplete" end
    local labels: {[string]: string} = {}
    local count = 0
    for key, raw in pairs(raw_labels) do
        local label = bounds.text(raw, 4096)
        count = count + 1
        if count > 32 or #key > 256 or not label then return nil, "Docker attachment labels are invalid" end
        labels[key] = label
    end
    local child, attach_error = docker.attach({container_id = container_id, image_id = image_id, started_at = started_at, labels = labels})
    if not child then return nil, error_text(attach_error) end
    local terminal, terminal_error = child:attach_terminal()
    if not terminal then child:close(true); return nil, error_text(terminal_error) end
    local resized, resize_error = terminal:send({type = "resize", width = width, height = height})
    if not resized then terminal:close(); return nil, error_text(resize_error) end
    local closed, finished = false, false
    local close_error: string? = nil
    local handle: Window = {
        send = function(_, event: tty.TTYEvent): (boolean, string?)
            local ok, err = terminal:send(event)
            return ok, error_text(err)
        end,
        done = function(_): exec.TerminalCompletionChannel return terminal:done() end,
        status = function(_): ("running" | "done", string?)
            local state, err = terminal:status()
            return state, error_text(err)
        end,
        close = function(_): (boolean, string?)
            if closed then return close_error == nil, close_error end
            closed = true
            -- Detach first so a slow daemon stop cannot retain terminal I/O.
            local detached, detach_error = terminal:close()
            local stopped, stop_error = call("stop", {attempt_id = attempt_id, mode = "cooperative"})
            close_error = stop_error or (not detached and error_text(detach_error) or nil)
            return stopped ~= nil and detached, close_error
        end,
        finish = function(_): (boolean, string?)
            if finished then return true, nil end
            -- Terminal completion is transport completion. Only placement's
            -- daemon observation can establish exit and release its session.
            local reconciled, reconcile_error = call("reconcile", {attempt_id = attempt_id})
            if not reconciled then return false, reconcile_error end
            if reconciled.attempt_id ~= attempt_id or reconciled.execution_state ~= "exited" then return false, "Docker execution has not been confirmed stopped" end
            local cleaned, cleanup_error = call("cleanup", {attempt_id = attempt_id})
            if not cleaned then return false, cleanup_error end
            if cleaned.attempt_id ~= attempt_id or cleaned.cleanup_state ~= "complete" then return false, "Docker cleanup is unconfirmed" end
            finished = true
            return true, nil
        end,
    }
    return handle, nil
end
return M
