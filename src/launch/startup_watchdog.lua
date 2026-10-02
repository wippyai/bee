-- MIT. Track the ten-second inactivity budget for verified retained startup progress.
local M = {}

type State = {phase: string, deadline_ms: integer, timeout_ms: integer, revision: integer}

local ORDER: {[string]: integer} = {
    starting = 0, booting = 1, host_leasing = 2, host_attaching = 3,
    client_boot = 4, admitting = 5, rendering = 6, running = 7}

function M.new(now_ms: integer, timeout_ms: integer): State
    if now_ms < 0 or timeout_ms < 1 then error("Invalid retained startup watchdog bounds") end
    return {phase = "starting", deadline_ms = now_ms + timeout_ms, timeout_ms = timeout_ms, revision = 0}
end

function M.advance(state: State, phase: string, now_ms: integer, revision: integer?): boolean
    local current, next_phase = ORDER[state.phase], ORDER[phase]
    if not current or not next_phase or next_phase < current or now_ms < 0 then return false end
    local progressed = revision and revision > state.revision
    if next_phase == current and not progressed then return false end
    if progressed and revision then state.revision = revision end
    state.phase = phase
    state.deadline_ms = now_ms + state.timeout_ms
    return true
end

function M.expired(state: State, now_ms: integer): boolean
    return now_ms >= state.deadline_ms
end

function M.remaining(state: State, now_ms: integer): integer
    local remaining = state.deadline_ms - now_ms
    if remaining < 0 then return 0 end
    return remaining
end

function M.phase(state: State): string
    return state.phase
end

return M
