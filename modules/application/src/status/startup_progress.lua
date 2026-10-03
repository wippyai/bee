-- MIT. Retained startup progress values.
local M = {}

type State = {phase: string, revision: integer}
local ORDER: {[string]: integer} = {
    starting = 0, booting = 1, host_leasing = 2, host_attaching = 3,
    client_boot = 4, admitting = 5, rendering = 6, running = 7}
function M.new(): State
    return {phase = "starting", revision = 0}
end
function M.advance(state: State, phase: string, revision: integer?): boolean
    local current, next_phase = ORDER[state.phase], ORDER[phase]
    if not current or not next_phase or next_phase < current then return false end
    local progressed = revision and revision > state.revision
    if next_phase == current and not progressed then return false end
    if progressed and revision then state.revision = revision end
    state.phase = phase
    return true
end
function M.phase(state: State): string
    return state.phase
end

local STARTUP_PHASES: {[string]: boolean} = {
    booting = true, host_leasing = true, host_attaching = true,
    client_boot = true, admitting = true, rendering = true, running = true}
function M.decode(value: unknown): string?
    if type(value) ~= "table" or value.version ~= 1 or type(value.phase) ~= "string"
        or not STARTUP_PHASES[value.phase] then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "phase" then return nil end
    end
    return value.phase
end

return M
